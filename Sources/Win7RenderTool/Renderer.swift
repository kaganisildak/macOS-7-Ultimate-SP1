import AppKit
import Win7ChromeCore
import Win7Theme

/// Renders each Windows 7 component at 2× scale for the fidelity gallery. Glass components
/// are drawn over the default wallpaper, as they would be seen on the desktop.
@MainActor
enum Renderer {
    static let scale = 2

    /// Every component, in gallery order: (file name without extension, size in points, draw).
    static var components: [(name: String, size: NSSize, draw: (CGContext, NSSize) -> Void)] {
        var list: [(String, NSSize, (CGContext, NSSize) -> Void)] = [
            ("taskbar-800x40", NSSize(width: 800, height: 40), drawTaskbar),
            ("titlebar-active-600x30", NSSize(width: 600, height: 30), { drawTitlebar($0, $1, active: true) }),
            ("titlebar-inactive-600x30", NSSize(width: 600, height: 30), { drawTitlebar($0, $1, active: false) }),
        ]
        let kinds: [(String, W7CaptionKind, CGFloat)] = [("min", .minimize, W7CaptionSmallWidth),
                                                         ("max", .maximize, W7CaptionSmallWidth),
                                                         ("close", .close, W7CaptionCloseWidth)]
        let states: [(String, W7ControlState)] = [("normal", .normal), ("hover", .hover), ("pressed", .pressed)]
        for (kn, kind, width) in kinds {
            for (sn, state) in states {
                list.append(("caption-\(kn)-\(sn)", NSSize(width: width + 8, height: W7CaptionHeight + 8), { ctx, size in
                    W7DrawGlassFill(ctx, CGRect(origin: .zero, size: size), true)
                    W7DrawCaptionButton(ctx, CGRect(x: 4, y: 4, width: width, height: W7CaptionHeight), kind, state)
                }))
            }
        }
        list += [
            ("menu-popup", menuSize, drawMenuPopup),
            ("menustrip-600x20", NSSize(width: 600, height: 20), drawMenuStrip),
            ("startmenu-400x535", NSSize(width: 400, height: 535), StartMenuRender.draw),
            ("explorer-navbar-800x34", NSSize(width: 800, height: 34), { drawExplorerBar($0, $1, navBar: true) }),
            ("explorer-commandbar-800x32", NSSize(width: 800, height: 32), { drawExplorerBar($0, $1, navBar: false) }),
            // Internet Explorer 7-style Safari chrome.
            ("ie-tabrow-600x30", NSSize(width: 600, height: 30), drawIETabRow),
            ("ie-navorbs-60x32", NSSize(width: 60, height: 32), { ctx, size in
                W7DrawGlassFill(ctx, CGRect(origin: .zero, size: size), true)
                let orbs = W7IENavOrbsSize()
                W7DrawIENavOrbs(ctx, CGRect(x: 4, y: (size.height - orbs.height) / 2, width: orbs.width, height: orbs.height), true, false)
            }),
            ("ie-statusbar-600x22", NSSize(width: 600, height: 22), drawIEStatusBar),
            ("snap-preview-300x200", NSSize(width: 300, height: 200), { ctx, size in
                let r = CGRect(origin: .zero, size: size)
                W7DrawWallpaper(ctx, r)
                W7DrawSnapPreview(ctx, r.insetBy(dx: W7SnapPreviewInset, dy: W7SnapPreviewInset))
            }),
            ("wallpaper-640x400", NSSize(width: 640, height: 400), { W7DrawWallpaper($0, CGRect(origin: .zero, size: $1)) }),
            // Full-screen wallpaper at common display pixel sizes (named by pixels: drawn at half the size in
            // points, so the 2× render is the bitmap DefaultWallpaper writes for that display).
            ("wallpaper-1920x1080", NSSize(width: 960, height: 540), { W7DrawWallpaper($0, CGRect(origin: .zero, size: $1)) }),
            ("wallpaper-2880x1800", NSSize(width: 1440, height: 900), { W7DrawWallpaper($0, CGRect(origin: .zero, size: $1)) }),
        ]
        // Explorer folder icons: every kind at the small, open and largest size classes, drawn
        // at the gallery's scale so the render is the bitmap Finder would get.
        let folders: [(String, W7FolderIconKind)] = [("plain", .plain), ("documents", .documents), ("pictures", .pictures),
                                                     ("music", .music), ("videos", .videos), ("downloads", .downloads),
                                                     ("desktop", .desktop), ("user", .user)]
        for (name, kind) in folders {
            for points in [16, 48, 256] {
                let side = CGFloat(points)
                list.append(("folder-\(name)-\(points)", NSSize(width: side, height: side), { ctx, size in
                    guard let icon = W7CreateFolderIconImage(kind, size.width, CGFloat(scale)) else { return }
                    ctx.interpolationQuality = .none
                    ctx.draw(icon, in: CGRect(origin: .zero, size: size))
                }))
            }
        }
        list += task32Components
        list += controlComponents
        return list.map { (name: $0.0, size: $0.1, draw: $0.2) }
    }

    // MARK: Window frame and message box

    static var task32Components: [(String, NSSize, (CGContext, NSSize) -> Void)] {
        [
            ("frame-active-416x268", NSSize(width: 416, height: 268), { drawFramedWindow($0, $1, active: true) }),
            ("frame-inactive-416x268", NSSize(width: 416, height: 268), { drawFramedWindow($0, $1, active: false) }),
            ("messagebox", messageBoxSize, drawMessageBox),
            ("controls2-360x220", NSSize(width: 360, height: 220), drawControls2),
            // Window corners at 4×: the wedge path above, the radius path below.
            ("frame-corners-4x", FrameCornersRender.cornersSize, FrameCornersRender.drawCorners),
        ]
    }

    /// Controls slice 2 on the #F0F0F0 dialog face: text fields (normal, focused, disabled), combos (normal,
    /// hover, pressed), a tab strip over its pane, a progress bar, a slider and a group box.
    static func drawControls2(_ ctx: CGContext, _ size: NSSize) {
        ctx.setFillColor(CGColor(srgbRed: 0xF0 / 255.0, green: 0xF0 / 255.0, blue: 0xF0 / 255.0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        W7DrawTextFieldBox(ctx, CGRect(x: 10, y: 188, width: 100, height: 22), false, true)
        W7DrawTextFieldBox(ctx, CGRect(x: 125, y: 188, width: 100, height: 22), true, true)
        W7DrawTextFieldBox(ctx, CGRect(x: 240, y: 188, width: 100, height: 22), false, false)
        let states: [W7ControlState] = [.normal, .hover, .pressed]
        for (i, s) in states.enumerated() {
            W7DrawComboBox(ctx, CGRect(x: 10 + CGFloat(i) * 115, y: 156, width: 100, height: 22), s)
        }
        W7DrawTabPane(ctx, CGRect(x: 10, y: 60, width: 160, height: 66))
        W7DrawTabItem(ctx, CGRect(x: 72, y: 125, width: 60, height: 20), false, true)
        W7DrawTabItem(ctx, CGRect(x: 10, y: 125, width: 64, height: 22), true, false)
        W7DrawProgressBar(ctx, CGRect(x: 190, y: 120, width: 150, height: 16), 0.4)
        W7DrawSliderTrack(ctx, CGRect(x: 190, y: 80, width: 150, height: 22))
        W7DrawSliderThumb(ctx, CGRect(x: 240, y: 80, width: 11, height: 21), .normal)
        W7DrawGroupBox(ctx, CGRect(x: 190, y: 10, width: 150, height: 56), 38)
        let font = W7UIFont(12)
        ("Group" as NSString).draw(at: NSPoint(x: 198, y: 66 - font.ascender + 2), withAttributes: [.font: font, .foregroundColor: NSColor.black])
    }

    /// A 400 × 260 window with the 8 pt frame overlay round it (left, right, bottom) over the wallpaper: the
    /// window with the Windows 7 radii the corner radius path gives it (6 pt top, square bottom; ) with the
    /// bordered caption, title and caption buttons and a white client area, under the overlay
    /// (FrameCornersRender; frame-corners-4x shows the wedge path too).
    static func drawFramedWindow(_ ctx: CGContext, _ size: NSSize, active: Bool) {
        let bounds = CGRect(origin: .zero, size: size)
        FrameCornersRender.drawScene(ctx, canvas: bounds, bounds: bounds, windowTop: W7FrameOuterRadius, windowBottom: 0,
                                     active: active, title: "Untitled - Notepad")
    }

    static func makeAlert() -> NSAlert {
        let a = NSAlert()
        a.messageText = "Do you want to save changes to Untitled?"
        a.informativeText = "Your changes will be lost if you don't save them."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.window.appearance = NSAppearance(named: .aqua)
        a.window.title = "Notepad"
        a.layout()
        return a
    }

    static let messageBoxSize: NSSize = MainActor.assumeIsolated {
        let a = makeAlert()
        defer { a.window.close() }
        return a.window.contentView?.frame.size ?? NSSize(width: 260, height: 240)
    }

    /// A real NSAlert's content view restyled as a Windows 7 message box (W7StyleMessageBoxIfNeeded).
    static func drawMessageBox(_ ctx: CGContext, _ size: NSSize) {
        let a = makeAlert()
        defer { a.window.close() }
        W7MessageBoxUseDisabledOverride(0)
        defer { W7MessageBoxUseDisabledOverride(-1) }
        W7StyleMessageBoxIfNeeded(a.window)
        if let content = a.window.contentView { drawView(content, in: ctx) }
    }

    /// Writes `<dir>/<name>.png` for every component and returns the files written.
    @discardableResult
    static func renderAll(to dir: URL) throws -> [URL] {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        for c in components {
            let url = dir.appendingPathComponent(c.name + ".png")
            try png(size: c.size, c.draw).write(to: url)
            out.append(url)
        }
        return out
    }

    /// Draws into a 2× sRGB bitmap (the context's user space is in points, origin bottom-left).
    static func png(size: NSSize, _ draw: (CGContext, NSSize) -> Void) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RenderError.bitmap }
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        draw(ctx, size)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw RenderError.encode
        }
        return data
    }

    enum RenderError: Error { case bitmap, encode }

    /// Draws `view` (laid out at its current bounds) and its subviews into `ctx` at `origin`.
    static func drawView(_ view: NSView, in ctx: CGContext, at origin: CGPoint = .zero) {
        view.layoutSubtreeIfNeeded()
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        view.displayIgnoringOpacity(view.bounds, in: gc)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    // MARK: Standard controls

    /// The Windows 7 dialog face the controls sit on.
    static func drawDialogFace(_ ctx: CGContext, _ size: NSSize) {
        ctx.setFillColor(CGColor(srgbRed: 0xF0 / 255.0, green: 0xF0 / 255.0, blue: 0xF0 / 255.0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
    }

    /// Push buttons (Windows 7's 75×23 dialog button with a centred title), check boxes and radio buttons
    /// with a label, and scroll bars (a 17 pt track with its thumb), on the dialog face.
    static var controlComponents: [(String, NSSize, (CGContext, NSSize) -> Void)] {
        var list: [(String, NSSize, (CGContext, NSSize) -> Void)] = []
        let buttons: [(String, W7ControlState, Bool)] = [("normal", .normal, false), ("hover", .hover, false),
                                                          ("pressed", .pressed, false), ("default", .normal, true),
                                                          ("disabled", .disabled, false)]
        for (name, state, isDefault) in buttons {
            list.append(("pushbutton-\(name)", NSSize(width: 91, height: 35), { ctx, size in
                drawDialogFace(ctx, size)
                let r = CGRect(x: 8, y: 6, width: 75, height: 23)
                W7DrawPushButton(ctx, r, state, isDefault)
                drawLabel("OK", in: r, centred: true, enabled: state != .disabled)
            }))
        }
        let boxes: [(String, W7ControlState, W7CheckValue)] = [("off", .normal, .off), ("on", .normal, .on),
                                                               ("mixed", .normal, .mixed), ("hover", .hover, .on),
                                                               ("pressed", .pressed, .on), ("disabled", .disabled, .on)]
        for (name, state, value) in boxes {
            list.append(("checkbox-\(name)", NSSize(width: 110, height: 21), { ctx, size in
                drawDialogFace(ctx, size)
                W7DrawCheckBox(ctx, CGRect(x: 4, y: 4, width: 13, height: 13), state, value)
                drawLabel("Word wrap", in: CGRect(x: 22, y: 0, width: 88, height: 21), centred: false, enabled: state != .disabled)
            }))
        }
        let radios: [(String, W7ControlState, Bool)] = [("off", .normal, false), ("on", .normal, true), ("hover", .hover, true),
                                                        ("pressed", .pressed, true), ("disabled", .disabled, true)]
        for (name, state, selected) in radios {
            list.append(("radio-\(name)", NSSize(width: 110, height: 21), { ctx, size in
                drawDialogFace(ctx, size)
                W7DrawRadioButton(ctx, CGRect(x: 4, y: 4, width: 13, height: 13), state, selected)
                drawLabel("Portrait", in: CGRect(x: 22, y: 0, width: 88, height: 21), centred: false, enabled: state != .disabled)
            }))
        }
        let thumbs: [(String, W7ControlState)] = [("normal", .normal), ("hover", .hover), ("pressed", .pressed)]
        for (name, state) in thumbs {
            list.append(("scrollbar-vertical-\(name)", NSSize(width: 17, height: 120), { ctx, size in
                W7DrawScrollerTrack(ctx, CGRect(origin: .zero, size: size), true)
                W7DrawScrollerThumb(ctx, CGRect(x: 0, y: 50, width: 17, height: 44), true, state)
            }))
        }
        list.append(("scrollbar-horizontal", NSSize(width: 160, height: 17), { ctx, size in
            W7DrawScrollerTrack(ctx, CGRect(origin: .zero, size: size), false)
            W7DrawScrollerThumb(ctx, CGRect(x: 20, y: 0, width: 60, height: 17), false, .normal)
        }))
        return list
    }

    /// A control's title in the UI font: black, or Windows 7's disabled grey `#838383`.
    static func drawLabel(_ text: String, in rect: CGRect, centred: Bool, enabled: Bool) {
        let font = W7UIFont(12)
        let para = NSMutableParagraphStyle()
        para.alignment = centred ? .center : .left
        let colour = enabled ? NSColor.black : NSColor(srgbRed: 0x83 / 255.0, green: 0x83 / 255.0, blue: 0x83 / 255.0, alpha: 1)
        let lineH = ceil(font.ascender - font.descender)
        (text as NSString).draw(in: NSRect(x: rect.minX, y: rect.midY - lineH / 2, width: rect.width, height: lineH),
                                withAttributes: [.font: font, .foregroundColor: colour, .paragraphStyle: para])
    }

    // MARK: Taskbar

    /// The taskbar and Start menu draw their tint over a dark behind-window blur (GlassBlur in
    /// Win7Shell), which an offscreen render can't produce. Measured live, that blur turns #0B9FF9 into
    /// about #156FA9: close to darkening by black 0.30, which stands in for it here.
    static func drawBlurStandIn(_ ctx: CGContext, _ rect: CGRect) {
        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.30))
        ctx.fill(rect)
        ctx.restoreGState()
    }

    /// Mirrors TaskbarView/TrayView (Win7Shell) with fixed sample content: orb, a running, an active and
    /// a hovered button, then the notification area with the clock "14:32 / 16.10.2026".
    static func drawTaskbar(_ ctx: CGContext, _ size: NSSize) {
        let bounds = CGRect(origin: .zero, size: size)
        W7DrawWallpaper(ctx, CGRect(x: 0, y: 0, width: size.width, height: size.height * 12))
        drawBlurStandIn(ctx, bounds)
        W7DrawTaskbarBackground(ctx, bounds)
        W7DrawStartOrb(ctx, CGRect(x: 0, y: 0, width: 54, height: size.height), .normal, nil)
        let apps = ["/System/Library/CoreServices/Finder.app", "/Applications/Safari.app", "/System/Applications/Music.app"]
        for (i, path) in apps.enumerated() {
            let r = CGRect(x: 54 + CGFloat(i) * 60, y: 0, width: 60, height: size.height)
            W7DrawTaskbarButton(ctx, r, true, i == 1, i == 2)
            NSWorkspace.shared.icon(forFile: path).draw(in: NSRect(x: r.midX - 16, y: r.midY - 16, width: 32, height: 32))
        }
        // Notification area, right to left: Show Desktop strip (15), clock, volume, network, language, chevron.
        let font = W7UIFont(12)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: para, .shadow: shadow]
        let time = "14:32", date = "16.10.2026"
        let clockW = max(ceil(max((time as NSString).size(withAttributes: attrs).width,
                                  (date as NSString).size(withAttributes: attrs).width)) + 12, 70)
        let sd = CGRect(x: size.width - 15, y: 0, width: 15, height: size.height)
        var x = sd.minX - clockW
        let clock = CGRect(x: x, y: 0, width: clockW, height: size.height)
        let lineH = ceil(font.ascender - font.descender + font.leading)
        let top = (size.height + lineH * 2) / 2
        (time as NSString).draw(in: NSRect(x: clock.minX, y: top - lineH, width: clock.width, height: lineH), withAttributes: attrs)
        (date as NSString).draw(in: NSRect(x: clock.minX, y: top - lineH * 2, width: clock.width, height: lineH), withAttributes: attrs)
        let icons: [(W7TrayIcon, Int, CGFloat)] = [(.volume, 4, 24), (.wifi, 3, 24)]
        for (kind, level, w) in icons {
            x -= w
            W7DrawTrayIcon(ctx, CGRect(x: (x + w / 2 - 8).rounded(), y: ((size.height - 16) / 2).rounded(), width: 16, height: 16), kind, level, false)
        }
        x -= 28
        let lang = W7UIFont(11)
        let lh = ceil(lang.ascender - lang.descender)
        ("EN" as NSString).draw(in: NSRect(x: x, y: (size.height - lh) / 2, width: 28, height: lh),
                                withAttributes: [.font: lang, .foregroundColor: NSColor.white, .paragraphStyle: para, .shadow: shadow])
        x -= 18
        W7DrawTrayIcon(ctx, CGRect(x: (x + 9 - 8).rounded(), y: ((size.height - 16) / 2).rounded(), width: 16, height: 16), .chevron, 0, false)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        ctx.fill(sd)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.4).cgColor)
        ctx.fill(CGRect(x: sd.minX, y: 0, width: 1, height: sd.height))
    }

    // MARK: Title bar, menu strip, menus

    /// A window whose key/main state is fixed, so offscreen title bars draw active or inactive.
    final class FixedStateWindow: NSWindow {
        var active = true
        override var isKeyWindow: Bool { active }
        override var isMainWindow: Bool { active }
    }

    static func makeWindow(size: NSSize, active: Bool) -> FixedStateWindow {
        let w = FixedStateWindow(contentRect: NSRect(x: -8000, y: -8000, width: size.width, height: size.height),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.active = active
        return w
    }

    static func drawTitlebar(_ ctx: CGContext, _ size: NSSize, active: Bool) {
        let w = makeWindow(size: NSSize(width: size.width, height: 200), active: active)
        w.title = "Untitled - Notepad"
        let bar = W7TitlebarView(frame: NSRect(origin: .zero, size: size))
        w.contentView?.addSubview(bar)
        W7DrawWallpaper(ctx, CGRect(x: -100, y: -300, width: size.width + 200, height: 400))
        drawView(bar, in: ctx)
        w.close()
    }

    static func sampleMainMenu() -> NSMenu {
        let main = NSMenu()
        for title in ["Notepad", "File", "Edit", "Format", "View", "Help"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            main.addItem(item)
        }
        return main
    }

    static func drawMenuStrip(_ ctx: CGContext, _ size: NSSize) {
        let saved = NSApp.mainMenu
        NSApp.mainMenu = sampleMainMenu()
        defer { NSApp.mainMenu = saved }
        let strip = W7MenuStripController()
        strip.view.frame = NSRect(origin: .zero, size: size)
        drawView(strip.view, in: ctx)
    }

    /// Six rows: a checked item, a separator, a disabled item, a submenu, a "Ctrl+S" shortcut and the
    /// highlighted row.
    static func sampleMenu() -> NSMenu {
        let m = NSMenu(title: "File")
        m.autoenablesItems = false
        let check = NSMenuItem(title: "Word Wrap", action: nil, keyEquivalent: "")
        check.state = .on
        m.addItem(check)
        m.addItem(.separator())
        let disabled = NSMenuItem(title: "Undo", action: nil, keyEquivalent: "")
        disabled.isEnabled = false
        m.addItem(disabled)
        let sub = NSMenuItem(title: "Recent Files", action: nil, keyEquivalent: "")
        sub.submenu = NSMenu(title: "Recent Files")
        sub.submenu?.addItem(NSMenuItem(title: "notes.txt", action: nil, keyEquivalent: ""))
        m.addItem(sub)
        let save = NSMenuItem(title: "Save", action: nil, keyEquivalent: "s")
        save.keyEquivalentModifierMask = .control
        m.addItem(save)
        m.addItem(NSMenuItem(title: "Page Setup...", action: nil, keyEquivalent: ""))
        return m
    }

    static func menuPreview() -> W7MenuWindow {
        W7MenuWindow.previewWindow(for: sampleMenu(), highlightedRow: 5, minWidth: 0)
    }

    /// The popup's size, measured once.
    static let menuSize: NSSize = {
        let w = menuPreview()
        defer { w.close() }
        return w.contentView!.frame.size
    }()

    static func drawMenuPopup(_ ctx: CGContext, _ size: NSSize) {
        let w = menuPreview()
        drawView(w.contentView!, in: ctx)
        w.close()
    }

    // MARK: Explorer

    /// A Finder-like window adopted as an Explorer window, showing ~/Documents.
    static func drawExplorerBar(_ ctx: CGContext, _ size: NSSize, navBar: Bool) {
        let w = makeWindow(size: NSSize(width: size.width, height: 500), active: true)
        w.styleMask.insert(.fullSizeContentView)
        w.titlebarAppearsTransparent = true
        w.toolbar = NSToolbar(identifier: "W7RenderToolToolbar")
        w.title = "Documents"
        w.representedURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        W7ExplorerAdopt(w)
        W7ChromeController.decorateWindow(w)
        defer { w.close() }
        let bars = w.titlebarAccessoryViewControllers
        let wanted = bars.first { NSStringFromClass(type(of: $0)).contains(navBar ? "NavBar" : "CommandBar") }
        guard let view = wanted?.view else { return }
        // The location (breadcrumbs, search placeholder) is read off the main thread: wait for the
        // address bar to have a folder, at most 2 s.
        let deadline = Date().addingTimeInterval(2)
        while !hasLocation(w.contentView?.superview ?? view), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        view.frame.size.width = size.width
        if navBar { W7DrawWallpaper(ctx, CGRect(x: -100, y: -300, width: size.width + 200, height: 400)) }
        drawView(view, in: ctx)
    }

    // MARK: Internet Explorer 7

    /// The tab row (IE8 on Windows 7, / ): the pale band sampled from the reference; ★ and ✚ at the
    /// left; a normal, the selected (with its close glyph) and a hovered facsimile tab standing on the #8B919F line; the
    /// 28 pt new-tab stub; a hovered command button's flat frame and the command bar's Home, Print and Help glyphs.
    static func drawIETabRow(_ ctx: CGContext, _ size: NSSize) {
        W7DrawIETabRowBand(ctx, CGRect(origin: .zero, size: size), 2)
        W7DrawIEGlyph(ctx, CGRect(x: 8, y: 9, width: 16, height: 16), .favorites)
        W7DrawIEGlyph(ctx, CGRect(x: 30, y: 9, width: 16, height: 16), .addFavorite)
        let tabs: [(W7IETabState, String, W7IETabCloseState)] = [(.normal, "Wikipedia", .hidden),
                                                                 (.selected, "Internet Explorer 8 – Wikipedia", .normal),
                                                                 (.hover, "Example Domain", .hidden)]
        for (i, tab) in tabs.enumerated() {
            let rect = CGRect(x: 52 + CGFloat(i) * 122, y: 2, width: 120, height: size.height - 4)
            let close = CGRect(x: rect.maxX - 22, y: rect.midY - 8, width: 16, height: 16)   // 6 pt from the right
            let room = W7IETabFacsimileLayoutFor(rect, tab.0, false, close, tab.2 != .hidden).title
            let shown = W7IEMiddleTruncatedTitle(tab.1, room.width, W7UIFont(12))
            W7DrawIETabFacsimile(ctx, rect, tab.0, false, nil, shown, .null, close, tab.2)
        }
        W7DrawIENewTabStub(ctx, CGRect(x: 52 + 3 * 122, y: 2, width: 28, height: size.height - 4), false)
        W7DrawIECommandButtonFace(ctx, CGRect(x: 470, y: 3, width: 40, height: 24), .hover)
        for (i, glyph) in [W7IEGlyph.home, .print, .help].enumerated() {
            let x = 474 + CGFloat(i) * 42
            W7DrawIEGlyph(ctx, CGRect(x: x, y: 7, width: 16, height: 16), glyph)
            W7DrawIEDropArrow(ctx, CGPoint(x: x + 26, y: 15))
        }
    }

    /// The real W7StatusBarView with a hovered link and a page two thirds loaded.
    static func drawIEStatusBar(_ ctx: CGContext, _ size: NSSize) {
        let bar = W7StatusBarView(frame: NSRect(origin: .zero, size: size))
        bar.w7SetLoading(true, progress: 0.66)
        bar.w7SetMessage(nil, url: "https://www.example.com/")
        drawView(bar, in: ctx)
    }

    /// Whether the Explorer address bar under `root` shows a folder (its `w7Navigable`).
    static func hasLocation(_ root: NSView) -> Bool {
        let key = NSSelectorFromString("w7Navigable")
        if root.responds(to: key), (root.value(forKey: "w7Navigable") as? Bool) == true { return true }
        return root.subviews.contains { hasLocation($0) }
    }
}
