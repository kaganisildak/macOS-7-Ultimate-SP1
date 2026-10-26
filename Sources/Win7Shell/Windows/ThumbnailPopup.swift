import AppKit
import Win7Core
import Win7Theme

/// Glass popup above a taskbar button listing that app's windows: one 200-wide thumbnail per
/// window when any image exists, otherwise a Windows 7 Basic style vertical list.
///
/// Hovering a button opens it in hover mode (closes shortly after the pointer leaves). Clicking a
/// button with several windows opens it pinned: it stays until a window is chosen, a click lands
/// outside it, Esc is pressed, or the same button is clicked again. `WindowPopupDismissal` decides.
@MainActor
final class ThumbnailPopup {
    static let thumbWidth: CGFloat = 200
    private var panel: PopupPanel?
    private var task: Task<Void, Never>?
    private var closeTimer: Timer?
    private var state = WindowPopupDismissal()
    /// Screen rect of the button that opened the popup.
    private var anchor = NSRect.zero
    private var monitors: [Any] = []
    /// The app that was frontmost when a pinned popup activated the shell; focus goes back to it
    /// when the popup is dismissed without another app taking focus.
    private var previousApp: NSRunningApplication?
    private let provider: ThumbnailProvider
    var onSelect: ((pid_t, CGWindowID) -> Void)?
    /// Closes one window (Accessibility): the × on a hovered preview.
    var closeWindow: ((pid_t, CGWindowID) -> Void)?
    /// What part of the taskbar a screen point is on.
    var taskbarHit: ((NSPoint) -> TaskbarHit)?
    /// The app a dismissed popup would give focus back to, for a taskbar menu or jump list that
    /// opens while the shell holds the focus a pinned popup took.
    var rememberedApp: NSRunningApplication? { previousApp.flatMap { $0.isTerminated ? nil : $0 } }
    /// The other way round: the app a taskbar jump list that this click closed would have given
    /// focus back to, for a pinned popup opened while the shell is frontmost because of it.
    var fallbackFocus: (() -> NSRunningApplication?)?
    /// The pid and button rect the open popup was loaded for, so closing a window can reload it.
    private var shown: (pid: pid_t, rect: NSRect)?

    /// Never removed: the popup is created once and lives as long as the shell (AppDelegate holds
    /// it), and the block holds it weakly, so there is no deinit to remove it from.
    private var activationToken: NSObjectProtocol?

    init(provider: ThumbnailProvider) {
        self.provider = provider
        // Once the user activates another app while no list is pinned, the remembered app is stale.
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app, app != NSRunningApplication.current, self.state.mode != .pinned else { return }
                self.previousApp = nil
            }
        }
    }

    /// Hover over a running button. `buttonRect` is in screen coordinates.
    func show(pid: pid_t, above buttonRect: NSRect) {
        apply(state.handle(.hoverRequested(pid: pid)), pid: pid, rect: buttonRect)
    }

    /// Click on a button with several windows: opens pinned, or closes if already pinned there.
    func toggle(pid: pid_t, above buttonRect: NSRect) {
        apply(state.handle(.buttonClicked(pid: pid)), pid: pid, rect: buttonRect)
    }

    /// A taskbar control was used without a mouse event reaching the monitors (the Start hot key),
    /// or by the orb and Show Desktop handlers themselves: settles any owed restore.
    func taskbarControlUsed() { apply(state.handle(.clickedInTaskbar(.control))) }

    /// The pointer left the taskbar button; a pinned popup stays.
    func scheduleClose() { apply(state.handle(.hoverEnded)) }

    /// Closes whatever is open, in any mode, for another taskbar button's click. That click
    /// activates, launches or reopens an app, so the app to restore is forgotten.
    func close() {
        state.closed()
        teardown(focus: .release)
    }

    private func apply(_ response: WindowPopupResponse, pid: pid_t = 0, rect: NSRect = .zero) {
        switch response {
        case .ignore: break
        case .show:
            anchor = rect
            load(pid: pid, above: rect)
        case .pin:
            cancelClose()
            anchor = rect
            if panel != nil { enterPinned() }   // still loading: `present` pins it
        case .scheduleClose:
            closeTimer?.invalidate()
            closeTimer = Timer.w7Scheduled(0.2, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.apply(self.state.handle(.closeTimerFired))
                }
            }
        case .cancelClose: cancelClose()
        case .close(let focus): teardown(focus: focus)
        }
    }

    private func cancelClose() { closeTimer?.invalidate(); closeTimer = nil }

    private func teardown(focus: WindowPopupFocus) {
        cancelClose()
        removeMonitors()
        task?.cancel(); task = nil
        panel?.orderOut(nil)
        panel = nil
        shown = nil
        switch focus {
        case .restore:
            if NSApp.isActive, let app = previousApp, !app.isTerminated { app.activate() }
            previousApp = nil
        case .release: previousApp = nil
        case .keep: break
        }
    }

    /// A newer request cancels any pending capture.
    private func load(pid: pid_t, above buttonRect: NSRect) {
        shown = (pid, buttonRect)
        cancelClose()
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            let entries = await provider.thumbnails(pid: pid, maxWidth: Self.thumbWidth)
            guard !Task.isCancelled else { return }
            self.present(entries, pid: pid, above: buttonRect)
        }
    }

    private func present(_ entries: [ThumbnailProvider.Entry], pid: pid_t, above buttonRect: NSRect) {
        panel?.orderOut(nil); panel = nil
        removeMonitors()
        guard !entries.isEmpty else { apply(state.handle(.nothingToShow)); return }
        let screen = NSScreen.screens.first { $0.frame.intersects(buttonRect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let icon = IconOverrides.app(pid: pid, side: 48)   // the placeholder's size; list rows draw it smaller
        let view: WindowPopupTrackingView
        switch WindowPopupLayout.style(for: entries) {
        case .thumbnails:
            let maxCells = max(1, Int((visible.width - 16) / ThumbnailPopupView.cellSize(for: nil).width))
            // The × is always there, as in Windows 7; without Accessibility it explains itself
            // (the balloon) instead of closing.
            view = ThumbnailPopupView(entries: Array(entries.prefix(maxCells)), icon: icon,
                                      closable: closeWindow != nil)
        case .list:
            let rows = WindowPopupLayout.listRowCount(entries: entries.count,
                                                      availableHeight: visible.maxY - buttonRect.maxY - 8)
            view = WindowListPopupView(entries: Array(entries.prefix(rows)), icon: icon)
        }
        view.onSelect = { [weak self] id in
            guard let self else { return }
            self.onSelect?(pid, id)
            // The popup goes away after the click that chose has been handled.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.apply(self.state.handle(.selected)) }
            }
        }
        view.onClose = { [weak self] id in
            guard let self else { return }
            guard TaskbarWindowActions.isTrusted else { CloseWindowHint.shared.needed(); return }
            self.closeWindow?(pid, id)
            self.reloadAfterClose(pid: pid)
        }
        view.onMouseEnter = { [weak self] in
            guard let self else { return }
            self.apply(self.state.handle(.mouseEntered))
        }
        view.onMouseExit = { [weak self] in
            guard let self else { return }
            self.apply(self.state.handle(.mouseExited))
        }
        var frame = NSRect(origin: .zero, size: view.frame.size)
        frame.origin.x = min(max(buttonRect.midX - frame.width / 2, visible.minX + 4), visible.maxX - frame.width - 4)
        frame.origin.y = buttonRect.maxY + 4
        let p = PopupPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: ShellWindowLevels.thumbnailPopup)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        view.pointerStartsInside = frame.contains(NSEvent.mouseLocation)
        p.contentView = view
        p.onEscape = { [weak self] in
            guard let self else { return }
            self.apply(self.state.handle(.escape))
        }
        p.orderFrontRegardless()
        panel = p
        if state.mode == .pinned {
            enterPinned()
        } else if state.restoreOwed {
            // A hover popup that replaced a pinned one: clicks must still settle the restore.
            installMonitors()
        }
    }

    /// The closed window takes a moment to go; then the popup shows what is left (or closes).
    private func reloadAfterClose(pid: pid_t) {
        Timer.w7Scheduled(0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let shown = self.shown, shown.pid == pid, self.panel != nil else { return }
                self.load(pid: pid, above: shown.rect)
            }
        }
    }

    /// Pinned: watch clicks elsewhere, and take key focus so Esc reaches the panel. The shell
    /// activates first, as the tray flyouts do; the chosen window's app is activated after, or the
    /// app that was frontmost gets focus back when the popup is dismissed (`teardown`). With the
    /// shell already frontmost (a list opened from a taskbar click that closed another), the app
    /// remembered then is kept.
    private func enterPinned() {
        guard let panel else { return }
        installMonitors()
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            previousApp = front
        } else if previousApp == nil {
            previousApp = fallbackFocus?()   // the shell is frontmost because a jump list activated it
        }
        panel.isPinned = true
        NSApp.activate()
        panel.makeKey()
        // a list the user clicked open without previews (no Screen Recording) asks for the grant:
        // the system prompt and the balloon with "Open System Settings", at most once per 60 s. A hover never asks.
        if let trigger = PermissionGate.previewTrigger(features: provider.features, openedByClick: true),
           case .use(let kind) = trigger {
            PermissionPrompter.shared.needed(kind)
        }
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.apply(self.state.handle(.clickedInOtherApp))
            }
        }) { monitors.append(m) }
        // Clicks in the shell's own windows. These monitors run before the window's own handler,
        // which decides focus. In the taskbar, a left click on the opening button toggles the popup;
        // any other click a control handles (including a right click on that button, which opens
        // its jump list, or on bare taskbar, which opens the taskbar menu) closes it, and a click
        // that does nothing there (a left click on bare taskbar, a right click on Show Desktop, a
        // middle click off the buttons: `TaskbarHit.handles`) closes it like Esc. A click in the
        // desktop or a flyout closes it and leaves focus there.
        if let m = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window !== self.panel else { return }
                if event.window is TaskbarWindow {
                    let p = NSEvent.mouseLocation
                    let target = TaskbarClickTarget.classify(
                        TaskbarMouseButton(event), at: p, anchor: self.anchor, hit: self.taskbarHit?(p) ?? .button)
                    self.apply(self.state.handle(.clickedInTaskbar(target)))
                } else {
                    self.apply(self.state.handle(.clickedInShell))
                }
            }
            return event
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }
}

/// Can become key only once `enterPinned` sets `isPinned`, so Esc can close a pinned popup; a hover
/// popup never takes key focus, even when clicked.
@MainActor
private final class PopupPanel: NSPanel {
    var onEscape: (() -> Void)?
    var isPinned = false
    override var canBecomeKey: Bool { isPinned }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

/// Either layout's shared pointer handling: enter/exit callbacks, the hovered item, selection, and
/// the hovered item's × where the layout has one.
@MainActor
class WindowPopupTrackingView: NSView {
    var onSelect: ((CGWindowID) -> Void)?
    var onClose: ((CGWindowID) -> Void)?
    var onMouseEnter: (() -> Void)?
    var onMouseExit: (() -> Void)?
    var hoverIndex: Int? { didSet { if hoverIndex != oldValue { needsDisplay = true } } }
    /// The pointer is on the hovered item's ×.
    var hoverClose = false { didSet { if hoverClose != oldValue { needsDisplay = true } } }

    func index(at p: NSPoint) -> Int? { nil }
    func windowID(at i: Int) -> CGWindowID? { nil }
    /// The × of item `i`, or nil when the layout has none.
    func closeRect(_ i: Int) -> NSRect? { nil }
    /// Set when the popup is rebuilt under the pointer (after its × closed a window), so leaving it
    /// still reports an exit although no entry was seen.
    var pointerStartsInside = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        var options: NSTrackingArea.Options = [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        if pointerStartsInside { options.insert(.assumeInside) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onMouseEnter?() }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil; hoverClose = false; onMouseExit?() }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverIndex = index(at: p)
        hoverClose = hoverIndex.flatMap(closeRect)?.contains(p) ?? false
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = index(at: p), let id = windowID(at: i) else { return }
        if closeRect(i)?.contains(p) == true { onClose?(id) } else { onSelect?(id) }
    }

    static func drawHover(_ ctx: CGContext, _ r: NSRect) {
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.3).cgColor)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.fillPath()
    }
}

@MainActor
final class ThumbnailPopupView: WindowPopupTrackingView {
    private static let pad: CGFloat = 8
    private static let captionHeight: CGFloat = 20
    private static let closeSize = NSSize(width: 22, height: 17)
    private let entries: [ThumbnailProvider.Entry]
    private let icon: NSImage?
    private let closable: Bool

    static func cellSize(for entry: ThumbnailProvider.Entry?) -> NSSize {
        var h: CGFloat = 112
        if let img = entry?.image, img.width > 0 {
            h = min(200, ThumbnailPopup.thumbWidth * CGFloat(img.height) / CGFloat(img.width))
        }
        return NSSize(width: ThumbnailPopup.thumbWidth + pad * 2, height: h + captionHeight + pad * 2)
    }

    init(entries: [ThumbnailProvider.Entry], icon: NSImage?, closable: Bool) {
        self.entries = entries
        self.icon = icon
        self.closable = closable
        super.init(frame: .zero)
        setFrameSize(fittingSize)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        let sizes = entries.map { Self.cellSize(for: $0) }
        return NSSize(width: sizes.reduce(0) { $0 + $1.width } + Self.pad * 2,
                      height: (sizes.map(\.height).max() ?? 0) + Self.pad * 2)
    }

    private func cellRect(_ i: Int) -> NSRect {
        var x = Self.pad
        for j in 0..<i { x += Self.cellSize(for: entries[j]).width }
        let s = Self.cellSize(for: entries[i])
        return NSRect(x: x, y: Self.pad, width: s.width, height: s.height)
    }

    override func index(at p: NSPoint) -> Int? { entries.indices.first { cellRect($0).contains(p) } }
    override func windowID(at i: Int) -> CGWindowID? { entries[i].id }

    /// Windows 7's preview close button: the top right of the hovered cell, over the caption row.
    override func closeRect(_ i: Int) -> NSRect? {
        guard closable else { return nil }
        let r = cellRect(i)
        return NSRect(x: r.maxX - Self.pad / 2 - Self.closeSize.width, y: r.maxY - Self.pad / 2 - Self.closeSize.height,
                      width: Self.closeSize.width, height: Self.closeSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        W7DrawGlassFrame(ctx, bounds, true)
        defer {
            if let i = hoverIndex, let x = closeRect(i) { W7DrawCaptionButton(ctx, x, .close, hoverClose ? .hover : .normal) }
        }
        for (i, e) in entries.enumerated() {
            let r = cellRect(i)
            if hoverIndex == i { Self.drawHover(ctx, r) }
            let imgRect = NSRect(x: r.minX + Self.pad, y: r.minY + Self.pad + Self.captionHeight,
                                 width: ThumbnailPopup.thumbWidth,
                                 height: r.height - Self.pad * 2 - Self.captionHeight)
            if let img = e.image {
                let scale = min(imgRect.width / CGFloat(img.width), imgRect.height / CGFloat(img.height))
                let w = CGFloat(img.width) * scale, h = CGFloat(img.height) * scale
                ctx.draw(img, in: NSRect(x: imgRect.midX - w / 2, y: imgRect.midY - h / 2, width: w, height: h))
            } else {
                // Minimized (or not capturable): a placeholder with the app icon.
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.25).cgColor)
                ctx.fill(imgRect)
                let side: CGFloat = 48
                icon?.draw(in: NSRect(x: imgRect.midX - side / 2, y: imgRect.midY - side / 2, width: side, height: side))
            }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            (e.title as NSString).draw(
                in: NSRect(x: imgRect.minX, y: r.minY + Self.pad, width: imgRect.width, height: Self.captionHeight - 2),
                withAttributes: [.font: W7UIFont(12), .foregroundColor: NSColor.black, .paragraphStyle: style])
        }
    }
}

/// Windows 7 Basic window list: one row per window, 16 pt app icon and title, on glass.
@MainActor
final class WindowListPopupView: WindowPopupTrackingView {
    private let entries: [ThumbnailProvider.Entry]
    private let icon: NSImage?

    init(entries: [ThumbnailProvider.Entry], icon: NSImage?) {
        self.entries = entries
        self.icon = icon
        super.init(frame: NSRect(origin: .zero, size: WindowPopupLayout.listSize(rows: entries.count)))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func index(at p: NSPoint) -> Int? { WindowPopupLayout.listRow(at: p, rows: entries.count) }
    override func windowID(at i: Int) -> CGWindowID? { entries[i].id }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        W7DrawGlassFrame(ctx, bounds, true)
        let side = WindowPopupLayout.iconSize
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let font = W7UIFont(12)
        for (i, e) in entries.enumerated() {
            let r = WindowPopupLayout.listRowRect(i, rows: entries.count)
            if hoverIndex == i { Self.drawHover(ctx, r) }
            let iconRect = NSRect(x: r.minX + 4, y: r.midY - side / 2, width: side, height: side)
            icon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: e.isMinimized ? 0.6 : 1)
            let textX = iconRect.maxX + 6
            let textH = ceil(font.ascender - font.descender)
            (e.title as NSString).draw(
                in: NSRect(x: textX, y: r.midY - textH / 2, width: r.maxX - 4 - textX, height: textH),
                withAttributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: style])
        }
    }
}
