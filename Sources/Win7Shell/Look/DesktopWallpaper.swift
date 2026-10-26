import AppKit
import ImageIO
import Win7Core
import Win7Theme

/// The desktop picture chosen in Personalization or Desktop Background. The shell's desktop
/// window is transparent (DesktopWindow), so the system desktop picture IS what the user sees: every choice is set
/// with `NSWorkspace.setDesktopImageURL` on every screen, nothing is drawn by the shell. A slideshow is a one-shot
/// timer re-armed after each change (WallpaperPlayer decides what and when). The choice is kept in the shell's
/// defaults (`W7WallpaperSettings`) and the slideshow resumes at launch without changing the current picture.
///
/// a picture set outside the shell (System Settings, another app) wins. The slideshow's tick and the
/// wake-up change only the screens that still show one of the shell's pictures (WallpaperSlideshow); once none does,
/// the slideshow stops and the saved choice is cleared, so it does not come back at the next launch. Other Spaces
/// get the current picture when they come forward, again only where they show one of ours. A newly connected
/// screen keeps the picture macOS gives it. Desktop Background's preview and Cancel work per display
/// (WallpaperPreviewSession, keyed by CGDirectDisplayID).
@MainActor
final class WallpaperController {
    static let shared = WallpaperController()
    typealias Options = [NSWorkspace.DesktopImageOptionKey: Any]

    private(set) var settings: WallpaperSettings?
    private lazy var player = WallpaperPlayer { [unowned self] item, position in
        Self.setDesktop(item, position: position, only: self.tickDisplays)
    }
    private var timer: Timer?
    private var started = false
    private var previewing = false
    /// The displays the slideshow's tick may change (nil: every screen, for a choice the user just made).
    private var tickDisplays: Set<DisplayID>?
    /// Desktop Background's open preview.
    private var session = WallpaperPreviewSession<Options>()
    /// The last ended preview: its pictures stay "ours" (a Space left showing one gets the current picture, or
    /// after a Cancel its own picture back, when it comes forward).
    private var ended: WallpaperPreviewSession<Options>?
    private var endedByCancel = false
    /// Called after the choice changed (the Personalization page redraws its tiles).
    var onChange: [() -> Void] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: WallpaperSettings.defaultsKey) {
            settings = WallpaperSettings(data: data)
        }
    }

    /// At launch: resumes a saved slideshow (unless the desktop no longer shows any of its pictures) and follows
    /// Space, screen and wake changes.
    func start() {
        guard !started else { return }
        started = true
        if let settings {
            if settings.isSlideshow && WallpaperSlideshow.shouldStop(current: Self.currentURLs(), ours: ours()) {
                ShellWindowButtons.log.info("wallpaper: the desktop shows a picture set elsewhere; the saved slideshow is not resumed")
                clearChoice()
            } else {
                player.start(settings, now: Date(), applyFirst: false, showing: shownItem(of: settings))
                if settings.isSlideshow {
                    schedule()
                    ShellWindowButtons.log.info("wallpaper: slideshow of \(settings.items.count) resumed, every \(settings.interval.rawValue) s")
                }
            }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WallpaperController.shared.refreshScreens() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WallpaperController.shared.fire() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { WallpaperController.shared.refreshScreens() }
        }
    }

    // MARK: Choosing

    /// Saves and shows a choice (Desktop Background's Save changes, a theme click) on every screen.
    func apply(_ s: WallpaperSettings) {
        finishPreview(cancelled: false)
        settings = s
        UserDefaults.standard.set(s.data(), forKey: WallpaperSettings.defaultsKey)
        player.start(s, now: Date())
        schedule()
        ShellWindowButtons.log.info("wallpaper: \(s.items.count) item(s) from \(s.location.rawValue, privacy: .public), \(s.position.rawValue, privacy: .public), slideshow=\(s.isSlideshow)")
        for f in onChange { f() }
    }

    func applyTheme(_ theme: WallpaperTheme) { apply(.theme(theme)) }

    /// Desktop Background shows a clicked picture at once, as Windows 7 does; the slideshow waits meanwhile. The
    /// first preview remembers what every display shows, for Cancel.
    func preview(_ item: WallpaperItem, position: WallpaperPosition) {
        guard let url = Self.url(for: item) else { return }
        session.willPreview(url, current: Self.currentDesktops())
        previewing = true
        timer?.invalidate()
        _ = Self.setDesktop(item, position: position)
    }

    /// Cancel: the displays still showing a picture of this preview get their own picture back (by display ID;
    /// others are left alone), and the slideshow goes on.
    func cancelPreview() {
        guard previewing else { return }
        for (display, shown) in session.restorePlan(current: Self.currentURLs()) {
            Self.set(shown.url, options: shown.options, on: display)
        }
        finishPreview(cancelled: true)
        schedule()
    }

    private func finishPreview(cancelled: Bool) {
        if session.isActive {
            ended = session
            endedByCancel = cancelled
        }
        session = WallpaperPreviewSession()
        previewing = false
    }

    /// Forgets the choice (the user set a picture elsewhere): no slideshow now or at the next launch.
    private func clearChoice() {
        player.stop()
        timer?.invalidate()
        timer = nil
        settings = nil
        UserDefaults.standard.removeObject(forKey: WallpaperSettings.defaultsKey)
        for f in onChange { f() }
    }

    // MARK: What the screens show

    static func displayID(_ screen: NSScreen) -> DisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Every screen's current picture, by display ID.
    static func currentURLs() -> [DisplayID: URL] {
        var out: [DisplayID: URL] = [:]
        for screen in NSScreen.screens {
            if let id = displayID(screen), let url = NSWorkspace.shared.desktopImageURL(for: screen) { out[id] = url }
        }
        return out
    }

    /// Every screen's current picture and options, for a preview's snapshot.
    static func currentDesktops() -> [DisplayID: WallpaperPreviewSession<Options>.Shown] {
        var out: [DisplayID: WallpaperPreviewSession<Options>.Shown] = [:]
        for screen in NSScreen.screens {
            guard let id = displayID(screen), let url = NSWorkspace.shared.desktopImageURL(for: screen) else { continue }
            out[id] = .init(url: url, options: NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:])
        }
        return out
    }

    /// The shell's pictures: the choice, the catalogue, the colour pictures and the last preview's pictures.
    private func ours() -> Set<URL> {
        let catalogue = themes().flatMap(\.pictures)
        let previewed = session.previewed.union(ended?.previewed ?? [])
        return WallpaperSlideshow.ours(items: settings?.items ?? [], catalogue: catalogue, previewed: previewed,
                                       solidFolder: Self.solidFolder)
    }

    /// The choice's item the main screen shows now, if any (where a restarted slideshow goes on from).
    private func shownItem(of s: WallpaperSettings) -> WallpaperItem? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let shown = NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL.path else { return nil }
        return s.items.first { item in
            switch item {
            case .picture(let url): url.standardizedFileURL.path == shown
            case .color(let c): Self.solidFolder.appendingPathComponent(c.fileName).standardizedFileURL.path == shown
            }
        }
    }

    // MARK: Catalogue

    /// Assets/ holding `wallpapers/` (the installed copy first, then the repo's, as AssetStore looks).
    static var assetsRoot: URL? { AssetStore.shared.url("wallpapers")?.deletingLastPathComponent() }
    static var picturesFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures") }

    func themes() -> [WallpaperTheme] {
        Self.assetsRoot.map { WallpaperCatalog.themes(in: $0.appendingPathComponent("wallpapers")) } ?? []
    }

    func locations() -> [WallpaperLocation] {
        WallpaperCatalog.locations(assetsRoot: Self.assetsRoot, pictures: Self.picturesFolder)
    }

    /// The item the desktop shows now (the slideshow's current picture), else the first chosen one.
    var currentItem: WallpaperItem? { player.current ?? settings?.items.first }

    // MARK: Slideshow timer

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard !previewing, let due = player.nextFire else { return }
        let t = Timer(fire: due, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { WallpaperController.shared.fire() }
        }
        t.tolerance = min(30, max(1, (settings?.interval.seconds ?? 10) * 0.05))
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The timer and the wake-up: the next picture, on the screens that still show one of ours; none left, the
    /// slideshow ends.
    private func fire() {
        guard !previewing, let settings, settings.isSlideshow else { return }
        let current = Self.currentURLs(), mine = ours()
        if WallpaperSlideshow.shouldStop(current: current, ours: mine) {
            ShellWindowButtons.log.info("wallpaper: no screen shows the slideshow's pictures any more; the slideshow stops")
            clearChoice()
            return
        }
        tickDisplays = Set(WallpaperSlideshow.screensToUpdate(current: current, ours: mine))
        defer { tickDisplays = nil }
        if player.tick(now: Date()) { for f in onChange { f() } }
        schedule()
    }

    /// A Space or a screen came forward: screens showing nothing, an older picture of this choice, a picture of a
    /// preview or one of the shell's colour pictures get the current one; a picture set elsewhere is left alone.
    /// Without a choice, a Space left on a cancelled preview gets its own picture back.
    private func refreshScreens() {
        guard !previewing else { return }
        guard let settings, let item = currentItem, let url = Self.url(for: item) else {
            if let ended, endedByCancel {
                for (display, shown) in ended.restorePlan(current: Self.currentURLs()) {
                    Self.set(shown.url, options: shown.options, on: display)
                }
            }
            return
        }
        let mine = Set(ours().map(\.standardizedFileURL.path))
        let target = url.standardizedFileURL.path
        for screen in NSScreen.screens {
            let shown = NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL.path
            guard shown != target else { continue }
            if shown.map({ mine.contains($0) }) ?? true {
                try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: Self.options(item, settings.position))
            }
        }
    }

    // MARK: Setting the desktop picture

    /// Where the colour pictures are written: ~/Library/Application Support/Win7Mac/Wallpaper/.
    static var solidFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Win7Mac/Wallpaper")
    }

    /// A picture's file, or the colour's small PNG (written once).
    static func url(for item: WallpaperItem) -> URL? {
        switch item {
        case .picture(let url): return url
        case .color(let c): return solidPicture(c)
        }
    }

    private static func solidPicture(_ c: SolidColor) -> URL? {
        let url = solidFolder.appendingPathComponent(c.fileName)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let side = 32
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        do {
            try FileManager.default.createDirectory(at: solidFolder, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func options(_ item: WallpaperItem, _ position: WallpaperPosition) -> Options {
        if case .color(let c) = item {
            return [.imageScaling: NSNumber(value: NSImageScaling.scaleAxesIndependently.rawValue),
                    .allowClipping: NSNumber(value: true),
                    .fillColor: NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)]
        }
        let scaling = NSImageScaling(rawValue: position.scaling.rawValue) ?? .scaleProportionallyUpOrDown
        return [.imageScaling: NSNumber(value: scaling.rawValue), .allowClipping: NSNumber(value: position.allowsClipping)]
    }

    /// Sets `url` on the screen with display ID `display` (gone: nothing).
    @discardableResult
    static func set(_ url: URL, options: Options, on display: DisplayID) -> Bool {
        guard let screen = NSScreen.screens.first(where: { displayID($0) == display }) else { return false }
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
            return true
        } catch {
            ShellWindowButtons.log.error("wallpaper: could not set the desktop picture: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Sets `item` on every screen (or only on the displays in `only`); false when it could not be set on any.
    static func setDesktop(_ item: WallpaperItem, position: WallpaperPosition, only: Set<DisplayID>? = nil) -> Bool {
        guard let url = url(for: item) else { return false }
        let opts = options(item, position)
        var ok = false
        for screen in NSScreen.screens {
            guard let id = displayID(screen), only?.contains(id) ?? true else { continue }
            if set(url, options: opts, on: id) { ok = true }
        }
        return ok
    }
}

/// Small pictures of wallpapers for the grids, made with ImageIO off the main thread (a Windows 7 wallpaper is a
/// 1920×1200 JPEG; the grid needs ~260 px) and kept in memory.
@MainActor
final class WallpaperThumbnails {
    static let shared = WallpaperThumbnails()
    private let cache = NSCache<NSString, NSImage>()
    private var waiting: [String: [(NSImage) -> Void]] = [:]
    private let queue = OperationQueue()

    private init() {
        cache.countLimit = 600
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated
    }

    /// The thumbnail if made already; otherwise nil, and `ready` runs on the main actor once it is.
    func image(for url: URL, maxPixels: Int, ready: @escaping (NSImage) -> Void) -> NSImage? {
        let key = "\(url.path)|\(maxPixels)"
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if waiting[key] != nil { waiting[key]?.append(ready); return nil }
        waiting[key] = [ready]
        queue.addOperation {
            let made = Self.make(url, maxPixels: maxPixels)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let image = made.image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                        ?? NSImage(size: NSSize(width: 1, height: 1))
                    WallpaperThumbnails.shared.cache.setObject(image, forKey: key as NSString)
                    for f in WallpaperThumbnails.shared.waiting.removeValue(forKey: key) ?? [] { f(image) }
                }
            }
        }
        return nil
    }

    private final class Made: @unchecked Sendable {
        let image: CGImage?
        init(_ image: CGImage?) { self.image = image }
    }

    nonisolated private static func make(_ url: URL, maxPixels: Int) -> Made {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return Made(nil) }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return Made(CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary))
    }
}

/// Draws a grid cell's picture or colour into `rect`, filling it (cropped), with Windows 7's thin grey frame.
@MainActor
enum WallpaperTileDrawing {
    static func draw(_ item: WallpaperItem?, in rect: NSRect, maxPixels: Int = 260, redraw: @escaping () -> Void) {
        NSColor(white: 0.93, alpha: 1).setFill()
        rect.fill()
        switch item {
        case .color(let c)?:
            NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1).setFill()
            rect.fill()
        case .picture(let url)?:
            if let image = WallpaperThumbnails.shared.image(for: url, maxPixels: maxPixels, ready: { _ in redraw() }), image.size.width > 1 {
                let s = max(rect.width / image.size.width, rect.height / image.size.height)
                let size = NSSize(width: image.size.width * s, height: image.size.height * s)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: rect).addClip()
                image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                NSGraphicsContext.restoreGraphicsState()
            }
        case nil:
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.clip(to: rect)
                // The built-in Windows 7 style picture, as install sets it when nothing was imported.
                W7DrawWallpaper(ctx, rect)
                ctx.restoreGState()
            }
        }
        NSColor(white: 0.55, alpha: 1).setStroke()
        let frame = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        frame.lineWidth = 1
        frame.stroke()
    }
}
