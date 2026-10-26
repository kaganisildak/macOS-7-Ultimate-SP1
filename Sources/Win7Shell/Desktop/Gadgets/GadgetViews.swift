import AppKit
import ImageIO
import Win7Core
import Win7Theme

/// A repeating main-run-loop timer that also fires during tracking (menus, drags).
@MainActor
func gadgetTimer(_ interval: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Timer {
    let t = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { body() } }
    RunLoop.main.add(t, forMode: .common)
    return t
}

/// Text with a soft dark shadow, as gadgets draw it on the desktop.
func gadgetText(_ s: String, size: CGFloat, color: NSColor, bold: Bool = false, shadow: Bool = false) -> NSAttributedString {
    var attrs: [NSAttributedString.Key: Any] = [
        .font: bold ? NSFontManager.shared.convert(W7UIFont(size), toHaveTrait: .boldFontMask) : W7UIFont(size),
        .foregroundColor: color,
    ]
    if shadow {
        let s = NSShadow()
        s.shadowColor = NSColor(white: 0, alpha: 0.6)
        s.shadowOffset = NSSize(width: 0, height: -1)
        s.shadowBlurRadius = 2
        attrs[.shadow] = s
    }
    return NSAttributedString(string: s, attributes: attrs)
}

func drawCentered(_ text: NSAttributedString, x: CGFloat, y: CGFloat) {
    let size = text.size()
    text.draw(at: NSPoint(x: x - size.width / 2, y: y - size.height / 2))
}

// MARK: - Slide Show

/// The Slide Show gadget: the images at the top level of ~/Pictures (not its subfolders), one every
/// 10 s, aspect-filled in a dark frame. ~/Pictures is only looked at once the gadget is on the desktop,
/// and only after FileManager.isReadableFile says it can be. Without any image there, the imported wallpapers
/// (Assets/wallpapers/<Theme>/) stand in for Windows 7's Sample Pictures; without those too, a placeholder.
/// (~/Pictures is not one of the folders macOS asks about, so normally there is no prompt; should
/// macOS ever ask once for Pictures access, declining just leaves the placeholder.)
/// With the user's artwork (Assets/gadgets/SlideShow/images/), as slideShow.js draws it docked: the glass frame
/// `in_sidebar/slideshow_glass_frame.png` (`on_desktop/` scaled down when only that one is there), the picture fitted
/// and centred in its 120×90 opening, and while the pointer is over the gadget the bar `in_sidebar/bg_sidebar.png`
/// with prev, pause/play, next and reveal (`_rest`, `_hov`, `_down`); reveal opens the picture in Preview. Without a
/// frame image: the drawn frame, as before (a click shows the next picture).
final class SlideShowGadgetView: GadgetContentView {
    static let interval: TimeInterval = 10
    private typealias L = GadgetLayout.SlideShow
    private let preview: Bool
    private let art = GadgetArt(folder: "SlideShow", kind: .slideShow)
    private var urls: [URL] = []
    private var index = 0
    private var image: CGImage?
    private var timer: Timer?
    private var playing = true
    private var pointerInside = false
    private var hoverButton: Int?
    private var pressedButton: Int?
    /// Bumped per load; a decode that finishes after a newer load started is dropped, so the shown image
    /// always belongs to the current index.
    private var loadGeneration = 0

    init(preview: Bool) {
        self.preview = preview
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    private static var pictures: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures") }

    override func start() {
        guard !preview else { return }
        let dir = Self.pictures
        urls = []
        if FileManager.default.isReadableFile(atPath: dir.path) {
            let all = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            urls = SlideShowPlaylist.images(in: all).map { dir.appendingPathComponent($0) }
        }
        if urls.isEmpty { urls = Self.samplePictures() }
        index = 0
        load()
        startTimer()
    }

    /// The imported wallpapers, theme folder by theme folder (Finder-sorted), at most 500 pictures; the first
    /// asset root that has any wins.
    private static func samplePictures() -> [URL] {
        let fm = FileManager.default
        for root in AssetStore.shared.candidates("wallpapers") {
            guard let themes = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            var found: [URL] = []
            for theme in themes.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) where !theme.hasPrefix(".") {
                let dir = root.appendingPathComponent(theme)
                guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                found += SlideShowPlaylist.images(in: files).map { dir.appendingPathComponent($0) }
                if found.count >= 500 { return Array(found.prefix(500)) }
            }
            if !found.isEmpty { return found }
        }
        return []
    }

    private func startTimer() {
        timer?.invalidate()
        timer = gadgetTimer(Self.interval) { [weak self] in self?.advance() }
    }

    override func stop() { timer?.invalidate(); timer = nil }

    /// The frame image: the docked one, else the desktop (larger) one, scaled to the gadget.
    private var frameImage: NSImage? {
        art.image("in_sidebar/slideshow_glass_frame.png") ?? art.image("on_desktop/slideshow_glass_frame.png")
    }

    private var hasArt: Bool {
        if frameImage != nil { return true }
        _ = art.has(["in_sidebar/slideshow_glass_frame.png"])   // logs once
        return false
    }

    private static let buttonNames = ["prev", "pause", "next", "reveal"]

    private func buttonName(_ i: Int) -> String { i == 1 && !playing ? "play" : Self.buttonNames[i] }

    private func button(at p: NSPoint) -> Int? {
        guard !preview, hasArt, art.image("in_sidebar/bg_sidebar.png") != nil else { return nil }
        let q = GadgetCanvas(height: bounds.height).topLeft(p)
        return L.buttons.firstIndex { $0.contains(q) }
    }

    override func hover(at point: NSPoint?) {
        let inside = point != nil && !preview && hasArt
        let b = point.flatMap(button)
        if inside != pointerInside || b != hoverButton {
            pointerInside = inside
            hoverButton = b
            needsDisplay = true
        }
    }

    override func press(at point: NSPoint?) {
        let b = point.flatMap(button)
        if b != pressedButton { pressedButton = b; needsDisplay = true }
    }

    override func click(at point: NSPoint) {
        guard hasArt else { advance(); return }
        switch button(at: point) {
        case 0: back(); playing = true; startTimer()
        case 1:
            if playing {
                playing = false
                timer?.invalidate(); timer = nil
            } else {
                playing = true
                advance()
                startTimer()
            }
        case 2: advance(); playing = true; startTimer()
        case 3: reveal()
        default: break
        }
        needsDisplay = true
    }

    private func back() {
        guard let previous = SlideShowPlaylist.previous(before: index, count: urls.count) else { return }
        index = previous
        load()
    }

    /// slideShow.js's "View": the picture in Preview.
    private func reveal() {
        guard urls.indices.contains(index) else { return }
        let url = urls[index]
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func advance() {
        guard let next = SlideShowPlaylist.next(after: index, count: urls.count) else { return }
        index = next
        load()
    }

    /// Decodes a thumbnail off the main thread.
    private func load() {
        guard urls.indices.contains(index) else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let url = urls[index]
        let maxPixel = Int(max(bounds.width, bounds.height) * 2)
        Task.detached(priority: .utility) {
            var cg: CGImage?
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                             kCGImageSourceCreateThumbnailWithTransform: true,
                                             kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel)]
                cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            }
            let result = cg
            await MainActor.run { [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                self.image = result   // nil (unreadable file): the placeholder rather than the previous picture
                self.needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hasArt, let frameImage {
            drawWithArt(frameImage)
            return
        }
        let frame = bounds.insetBy(dx: 4, dy: 4)
        let path = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.55)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 4
        shadow.set()
        NSColor(white: 0.08, alpha: 1).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        let inner = frame.insetBy(dx: 4, dy: 4)
        if let image, let ctx = NSGraphicsContext.current?.cgContext {
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let s = max(inner.width / iw, inner.height / ih)
            let r = NSRect(x: inner.midX - iw * s / 2, y: inner.midY - ih * s / 2, width: iw * s, height: ih * s)
            ctx.saveGState()
            ctx.clip(to: inner)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: r)
            ctx.restoreGState()
        } else {
            drawPlaceholder(in: inner)
        }
        NSColor(white: 1, alpha: 0.25).setStroke()
        NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).stroke()
    }

    private func drawWithArt(_ frameImage: NSImage) {
        let c = GadgetCanvas(height: bounds.height)
        frameImage.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        let opening = c.rect(L.picture)
        if let image, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.clip(to: opening)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: SlideShowPlaylist.fit(CGSize(width: image.width, height: image.height), in: opening))
            ctx.restoreGState()
        } else {
            drawPlaceholder(in: opening)
        }
        guard pointerInside, let bar = art.image("in_sidebar/bg_sidebar.png") else { return }
        c.draw(bar, in: L.bar)
        for (i, r) in L.buttons.enumerated() {
            let name = buttonName(i)
            let state = pressedButton == i && hoverButton == i ? "down" : (hoverButton == i ? "hov" : "rest")
            if let img = art.image("\(name)_\(state).png") ?? art.image("\(name)_rest.png") { c.draw(img, in: r) }
        }
    }

    /// A landscape picture: sky, sun and hills.
    private func drawPlaceholder(in r: NSRect) {
        NSGradient(starting: NSColor(srgbRed: 0x6F / 255, green: 0xB3 / 255, blue: 0xF0 / 255, alpha: 1),
                   ending: NSColor(srgbRed: 0x1E / 255, green: 0x6F / 255, blue: 0xC0 / 255, alpha: 1))?.draw(in: r, angle: -90)
        NSColor(srgbRed: 1, green: 0.93, blue: 0.55, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: r.maxX - 34, y: r.maxY - 30, width: 16, height: 16)).fill()
        let hills = NSBezierPath()
        hills.move(to: NSPoint(x: r.minX, y: r.minY + r.height * 0.35))
        hills.curve(to: NSPoint(x: r.maxX, y: r.minY + r.height * 0.3),
                    controlPoint1: NSPoint(x: r.minX + r.width * 0.35, y: r.minY + r.height * 0.7),
                    controlPoint2: NSPoint(x: r.minX + r.width * 0.6, y: r.minY + r.height * 0.05))
        hills.line(to: NSPoint(x: r.maxX, y: r.minY))
        hills.line(to: NSPoint(x: r.minX, y: r.minY))
        hills.close()
        NSColor(srgbRed: 0x3F / 255, green: 0x9B / 255, blue: 0x3A / 255, alpha: 1).setFill()
        hills.fill()
        if !preview {
            drawCentered(gadgetText("No pictures", size: 10, color: .white, shadow: true), x: r.midX, y: r.minY + 10)
        }
    }
}
