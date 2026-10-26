import AppKit
import Darwin
import Win7Core
import Win7Theme

/// This login session's marker: the boot session UUID plus the console login time (SessionMarker).
enum LoginSession {
    static var marker: String? { SessionMarker.marker(bootSessionUUID: bootSessionUUID(), loginTime: loginTime()) }

    /// `sysctl kern.bootsessionuuid`: new on every boot.
    static func bootSessionUUID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The latest console login of this user, from the utmpx database.
    static func loginTime() -> Date? {
        let me = NSUserName()
        var latest: Date?
        setutxent()
        defer { endutxent() }
        while let p = getutxent() {
            let e = p.pointee
            guard e.ut_type == USER_PROCESS else { continue }
            let user = withUnsafeBytes(of: e.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let line = withUnsafeBytes(of: e.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard user == me, line == "console" else { continue }
            let t = Date(timeIntervalSince1970: TimeInterval(e.ut_tv.tv_sec))
            if latest == nil || t > latest! { latest = t }
        }
        return latest
    }

    /// Whether this is the LaunchAgent's launch at login (W7_LOGIN=1, Resources/com.win7mac.shell.plist).
    static var isLoginLaunch: Bool { ProcessInfo.processInfo.environment["W7_LOGIN"] == "1" }

    /// True once per login session for `key`: records the marker the first time.
    static func firstTime(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        let current = marker
        guard SessionMarker.shouldShow(isLoginLaunch: isLoginLaunch, current: current, lastShown: defaults.string(forKey: key))
        else { return false }
        defaults.set(current, forKey: key)
        return true
    }
}

/// The full-screen Windows 7 session screen: the blue radial background of the procedural wallpaper,
/// the spinning ring and white "Welcome" / "Logging off…" / "Shutting down…" in the middle, on every
/// screen. Welcome can be dismissed with Esc or a click; the power screens can't. The background (wallpaper
/// and text) is rendered once per view size; only the ring's own layer changes per frame.
@MainActor
final class SessionSplash {
    static let welcomeKey = "welcomeSplashSession"
    static let welcomeDuration: TimeInterval = 2.5
    /// The window level for each PowerSplashLevel: screen saver; below alerts, panels and system prompts
    /// (modal panels are level 8); below normal windows and their sheets (level 0) but above the desktop
    /// icons and gadgets.
    static func windowLevel(_ level: PowerSplashLevel) -> NSWindow.Level {
        switch level {
        case .top: .screenSaver
        case .belowAlerts: NSWindow.Level(rawValue: NSWindow.Level.modalPanel.rawValue - 1)
        case .belowWindows: NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        }
    }

    private var windows: [SplashWindow] = []
    private var timer: Timer?
    private var frame = 0
    private var cursorHidden = false
    private static var current: SessionSplash?

    /// The Welcome screen, on the first shell launch of a login session only.
    static func welcomeIfFirstLaunch() {
        guard LoginSession.firstTime(welcomeKey) else { return }
        weak let s = show(.welcome)
        DispatchQueue.main.asyncAfter(deadline: .now() + welcomeDuration) { MainActor.assumeIsolated { s?.dismiss() } }
    }

    /// Shows a new splash on top of everything (screen-saver level), replacing any other.
    @discardableResult
    static func show(_ kind: SessionSplashKind) -> SessionSplash {
        current?.dismiss()
        let s = SessionSplash(kind)
        current = s
        s.setVisible(true, level: .top)
        return s
    }

    private init(_ kind: SessionSplashKind) {
        let dismissible = kind == .welcome
        for screen in NSScreen.screens {
            let w = SplashWindow(screen: screen, text: kind.text, dismissible: dismissible)
            w.onDismiss = { [weak self] in self?.dismiss() }
            windows.append(w)
        }
    }

    /// Shows or hides the splash at `level` (windowLevel). Only `.top` hides the pointer; the lower levels
    /// keep loginwindow, "Save changes?" and privacy prompts visible and usable.
    func setVisible(_ visible: Bool, level: PowerSplashLevel) {
        guard !windows.isEmpty else { return }
        if visible {
            for w in windows {
                w.level = Self.windowLevel(level)
                w.orderFrontRegardless()
            }
            if windows.first?.canBecomeKey == true {
                NSApp.activate()
                windows.first?.makeKey()
            }
            if timer == nil {
                let t = Timer(timeInterval: 1.0 / Double(W7CursorBusyFrameCount), repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
        } else {
            for w in windows { w.orderOut(nil) }
            timer?.invalidate()
            timer = nil
        }
        setCursorHidden(visible && level == .top)
    }

    private func setCursorHidden(_ hidden: Bool) {
        guard hidden != cursorHidden else { return }
        cursorHidden = hidden
        if hidden { NSCursor.hide() } else { NSCursor.unhide() }
    }

    private func tick() {
        frame += 1
        for w in windows { w.splashView.frameIndex = frame }
    }

    func dismiss() {
        setVisible(false, level: .belowWindows)
        windows = []
        if Self.current === self { Self.current = nil }
    }
}

private final class SplashWindow: NSWindow {
    let splashView: SplashView
    private let dismissible: Bool
    var onDismiss: (() -> Void)?

    init(screen: NSScreen, text: String, dismissible: Bool) {
        splashView = SplashView(text: text)
        self.dismissible = dismissible
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = true
        backgroundColor = .black
        isReleasedWhenClosed = false
        hasShadow = false
        contentView = splashView
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { dismissible }
    override func mouseDown(with event: NSEvent) { if dismissible { onDismiss?() } }
    override func cancelOperation(_ sender: Any?) { if dismissible { onDismiss?() } }
    override func keyDown(with event: NSEvent) {
        if dismissible, event.keyCode == 53 { onDismiss?() } else { super.keyDown(with: event) }
    }
}

/// Layer-backed: the wallpaper and text are one cached image (the view's layer contents), the ring a
/// sublayer whose contents step through cached busy-ring frames.
private final class SplashView: NSView {
    let text: String
    private let ringLayer = CALayer()
    private var renderedKey = ""
    private var backgroundImage: CGImage?
    private var ringFrames: [CGImage] = []
    var frameIndex = 0 { didSet { applyFrame() } }

    /// Shows ring frame `frameIndex` (once the frames for the current size exist).
    private func applyFrame() {
        guard !ringFrames.isEmpty else { return }
        ringLayer.contents = ringFrames[frameIndex % ringFrames.count]
    }

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        wantsLayer = true
        ringLayer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(ringLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var attributes: [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.6)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 4
        return [.font: W7UIFont(30), .foregroundColor: NSColor.white, .shadow: shadow]
    }

    /// The ring sits left of the text, the pair centred.
    private func ringRect(textWidth: CGFloat) -> NSRect {
        let ring: CGFloat = 40, gap: CGFloat = 14
        let total = ring + gap + textWidth
        return NSRect(x: bounds.midX - total / 2, y: bounds.midY - ring / 2, width: ring, height: ring)
    }

    /// The cached background goes straight into the layer: nothing is drawn per frame.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.contents = backgroundImage
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        let key = "\(bounds.size)|\(scale)"
        guard key != renderedKey, bounds.width > 0, bounds.height > 0 else { return }
        renderedKey = key
        let textSize = (text as NSString).size(withAttributes: attributes)
        let ring = ringRect(textWidth: textSize.width)
        backgroundImage = background(scale: scale, ring: ring, textSize: textSize)
        needsDisplay = true
        // The busy ring's 32 pt grid holds a ~20 pt ring; grow the grid so the ring is ~40 pt.
        let grid = ring.insetBy(dx: -ring.width / 3, dy: -ring.height / 3)
        ringLayer.frame = grid
        ringLayer.contentsScale = scale
        ringFrames = (0..<W7CursorBusyFrameCount).compactMap { W7CreateCursorImage(.busy, grid.width / W7CursorSize * scale, $0) }
        applyFrame()
    }

    private func background(scale: CGFloat, ring: NSRect, textSize: NSSize) -> CGImage? {
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        W7DrawWallpaper(ctx, bounds)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (text as NSString).draw(at: NSPoint(x: ring.maxX + 14, y: bounds.midY - textSize.height / 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
