import AppKit
import UniformTypeIdentifiers
import Win7Core
import Win7Theme

/// A taskbar button's Windows 7 jump list: a white panel above the button with the app's recent
/// documents and its tasks (`JumpList`). It opens on a right click or an upward drag on the button,
/// takes key focus for Up/Down/Enter/Esc, and closes on a choice, Esc, or a click elsewhere.
///
/// Focus follows the window popup's rules (`WindowPopupDismissal`, opened as a pinned popup): the app
/// that was frontmost gets focus back when the list closes without a choice, or with a choice that
/// does not bring another app forward (`JumpList.choiceTakesFocus`).
@MainActor
final class JumpListController {
    /// Runs the chosen item for the button's app. `previous` is the app the list would give focus
    /// back to, for an action whose own window (the confirmation box) may be cancelled.
    var onChoose: ((JumpListAction, _ bundleID: String, _ previous: NSRunningApplication?) -> Void)?
    /// What part of the taskbar a screen point is on.
    var taskbarHit: ((NSPoint) -> TaskbarHit)?

    var isOpen: Bool { panel != nil }
    /// The app focus goes back to, kept after a taskbar click closed the list (`.keep`) so the
    /// menu, list or popup that click opens can still give it back; forgotten once another app
    /// is activated.
    var rememberedApp: NSRunningApplication? { previousApp.flatMap { $0.isTerminated ? nil : $0 } }

    private var state = WindowPopupDismissal()
    private var panel: JumpListPanel?
    private var previousApp: NSRunningApplication?
    /// Never removed: the controller lives as long as the taskbar view, and the block holds it weakly.
    private var activationToken: NSObjectProtocol?

    init() {
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app, app != NSRunningApplication.current, self.panel == nil else { return }
                self.previousApp = nil
            }
        }
    }
    private var bundleID = ""
    private var monitors: [Any] = []
    private var resignToken: NSObjectProtocol?
    /// A stable popup identity per bundle ID (the dismissal model keys popups by pid).
    private var identities: [String: Int32] = [:]

    /// Opens the list above `buttonRect` (screen coordinates). `remembered` is the app to give focus
    /// back to when the shell is already frontmost (a pinned window popup activated it).
    func show(bundleID: String, sections: [JumpListSection], appIcon: NSImage, above buttonRect: NSRect,
              remembered: NSRunningApplication?) {
        TaskbarActivation.cancel()   // the list takes focus: a pending restore check must not steal it
        close()
        let id: Int32
        if let known = identities[bundleID] { id = known } else { id = Int32(identities.count + 1); identities[bundleID] = id }
        guard case .show = state.handle(.buttonClicked(pid: id)) else { state.closed(); return }
        self.bundleID = bundleID
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = (front != nil && front != NSRunningApplication.current) ? front : (rememberedApp ?? remembered)

        let view = JumpListView(sections: sections, appIcon: appIcon)
        view.onChoose = { [weak self] item in self?.choose(item) }
        let screen = NSScreen.screens.first { $0.frame.intersects(buttonRect) } ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var frame = NSRect(origin: .zero, size: view.frame.size)
        frame.origin.x = min(max(buttonRect.midX - frame.width / 2, visible.minX + 4), visible.maxX - frame.width - 4)
        frame.origin.y = buttonRect.maxY + 2
        let p = JumpListPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: ShellWindowLevels.jumpList)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.contentView = view
        // Another shell window taking key focus without a click (the Start menu's hot key).
        p.onResignKey = { [weak self] in
            guard let self else { return }
            self.apply(self.state.handle(.clickedInShell))
        }
        p.onKey = { [weak self, weak view] key in
            guard let self, let view else { return }
            switch key {
            case .up: view.moveSelection(by: -1)
            case .down: view.moveSelection(by: 1)
            case .enter: if let item = view.selectedItem { self.choose(item) }
            case .escape: self.apply(self.state.handle(.escape))
            }
        }
        panel = p
        // The shell is an accessory app: it must be active for the keys to reach the panel.
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    /// Closes the list for another taskbar action (the remembered app is kept, as for `.keep`).
    func close() {
        guard panel != nil else { return }
        state.closed()
        teardown(.keep)
    }

    private func choose(_ item: JumpListItem) {
        let takesFocus = JumpList.choiceTakesFocus(item.action, accessibility: TaskbarWindowActions.isTrusted,
                                                   decorated: TaskbarCloseRequest.isDecorated(bundleID: bundleID))
        let id = bundleID, previous = rememberedApp
        // Closing first gives focus back before the action runs, so the action's own window (the
        // confirmation box) or app is what ends up in front.
        apply(state.handle(takesFocus ? .selected : .escape))
        onChoose?(item.action, id, previous)
    }

    private func apply(_ response: WindowPopupResponse) {
        if case .close(let focus) = response { teardown(focus) }
    }

    private func teardown(_ focus: WindowPopupFocus) {
        removeMonitors()
        panel?.orderOut(nil)
        panel = nil
        switch focus {
        case .restore:
            if NSApp.isActive, let app = previousApp, !app.isTerminated { app.activate() }
            previousApp = nil
        case .release: previousApp = nil
        case .keep: break
        }
    }

    private func installMonitors() {
        removeMonitors()
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.apply(self.state.handle(.clickedInOtherApp))
            }
        }) { monitors.append(m) }
        // Clicks in the shell's windows run before their handlers. In the taskbar, a click a control
        // handles (another button, the orb, a right click opening a menu) closes the list and lets
        // the handler decide focus; a click that does nothing there gives focus back, like Esc.
        if let m = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window !== self.panel else { return }
                if event.window is TaskbarWindow {
                    let p = NSEvent.mouseLocation
                    let target = TaskbarClickTarget.classify(TaskbarMouseButton(event), at: p, anchor: .zero,
                                                             hit: self.taskbarHit?(p) ?? .button)
                    self.apply(self.state.handle(.clickedInTaskbar(target)))
                } else {
                    self.apply(self.state.handle(.clickedInShell))
                }
            }
            return event
        }) { monitors.append(m) }
        // Cmd+Tab or anything else that activates another app.
        resignToken = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.apply(self.state.handle(.clickedInOtherApp))
            }
        }
    }

    private func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        if let t = resignToken { NotificationCenter.default.removeObserver(t) }
        resignToken = nil
    }
}

@MainActor
private final class JumpListPanel: NSPanel {
    enum Key { case up, down, enter, escape }
    var onKey: ((Key) -> Void)?
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onKey?(.escape) }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: onKey?(.up)
        case 125: onKey?(.down)
        case 36, 76: onKey?(.enter)
        case 53: onKey?(.escape)
        default: super.keyDown(with: event)
        }
    }
}

/// The list itself: section headings ("Frequent", "Recent", "Tasks") in grey small caps with a
/// rule, 24 pt rows with 16 pt icons, the menu highlight under the pointer or keyboard selection,
/// and the tasks on a light band at the bottom. Flipped: row 0 is at the top.
@MainActor
private final class JumpListView: NSView {
    private enum Row {
        case heading(String)
        case item(JumpListItem, icon: NSImage?, glyph: Glyph?)
    }
    private enum Glyph { case pin, unpin, close }

    static let width: CGFloat = 256
    private static let pad: CGFloat = 6
    private static let rowHeight: CGFloat = 24
    private static let headingHeight: CGFloat = 26
    private static let iconSize: CGFloat = 16

    var onChoose: ((JumpListItem) -> Void)?
    private var rows: [(row: Row, rect: NSRect)] = []
    private var tasksTop: CGFloat = 0
    private var hover: Int? { didSet { if hover != oldValue { needsDisplay = true } } }
    private var selected: Int? { didSet { if selected != oldValue { needsDisplay = true } } }

    var selectedItem: JumpListItem? {
        guard let i = selected, case .item(let item, _, _) = rows[i].row else { return nil }
        return item
    }

    init(sections: [JumpListSection], appIcon: NSImage) {
        super.init(frame: .zero)
        var y = Self.pad
        for section in sections {
            if section.kind == .tasks {
                if !rows.isEmpty { y += Self.pad }
                tasksTop = y
                y += 4
            }
            if let title = section.title {
                rows.append((.heading(title), NSRect(x: Self.pad, y: y, width: Self.width - Self.pad * 2, height: Self.headingHeight)))
                y += Self.headingHeight
            }
            for item in section.items {
                let row: Row
                switch item.action {
                case .openRecent(let path):
                    // The icon comes from the file type, so the file itself is never touched: the user's override
                    // for the type (`folder.png`, `file-text.png`, …), else the system icon for it; a package
                    // (`.rtfd`, `.pages`) or an application keeps the system icon.
                    let type = UTType(filenameExtension: (path as NSString).pathExtension)
                    let icon = IconOverrideNames.typeIcon(type).flatMap { IconOverrides.image($0, side: Self.iconSize) }
                        ?? NSWorkspace.shared.icon(for: type ?? .data)
                    row = .item(item, icon: icon, glyph: nil)
                case .openFolder:
                    // The generic folder icon (the user's `folder.png`, else the system's): the folder itself is
                    // never touched.
                    row = .item(item, icon: IconOverrides.image("folder", side: Self.iconSize) ?? NSWorkspace.shared.icon(for: .folder),
                                glyph: nil)
                case .launch: row = .item(item, icon: appIcon, glyph: nil)
                case .pin: row = .item(item, icon: nil, glyph: .pin)
                case .unpin: row = .item(item, icon: nil, glyph: .unpin)
                case .closeWindow, .closeAllWindows: row = .item(item, icon: nil, glyph: .close)
                }
                rows.append((row, NSRect(x: Self.pad, y: y, width: Self.width - Self.pad * 2, height: Self.rowHeight)))
                y += Self.rowHeight
            }
        }
        setFrameSize(NSSize(width: Self.width, height: y + Self.pad))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var selectable: [Int] {
        rows.indices.filter { if case .item = rows[$0].row { return true } else { return false } }
    }

    func moveSelection(by delta: Int) {
        let list = selectable
        let current = (selected ?? hover).flatMap { list.firstIndex(of: $0) }
        hover = nil
        selected = JumpList.moveSelection(current, by: delta, count: list.count).map { list[$0] }
    }

    private func row(at p: NSPoint) -> Int? {
        selectable.first { rows[$0].rect.contains(p) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let r = row(at: convert(event.locationInWindow, from: nil))
        if r != nil { selected = nil }
        hover = r
    }
    override func mouseExited(with event: NSEvent) { hover = nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let i = row(at: convert(event.locationInWindow, from: nil)), case .item(let item, _, _) = rows[i].row else { return }
        onChoose?(item)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // The white pane with the Start menu programs pane's light border.
        let pane = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        NSColor.white.setFill()
        pane.fill()
        // The tasks band.
        NSGraphicsContext.saveGraphicsState()
        pane.addClip()
        let band = NSRect(x: 0, y: tasksTop, width: bounds.width, height: bounds.height - tasksTop)
        Self.color(0xEEF3FA).setFill()
        band.fill()
        if tasksTop > Self.pad { Self.color(0xD6DFEA).setFill(); NSRect(x: 0, y: tasksTop, width: bounds.width, height: 1).fill() }
        NSGraphicsContext.restoreGraphicsState()
        Self.color(0x9DB2BF).setStroke()
        pane.lineWidth = 1
        pane.stroke()

        let font = W7UIFont(12)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let textH = ceil(font.ascender - font.descender)
        for (i, entry) in rows.enumerated() {
            let r = entry.rect
            switch entry.row {
            case .heading(let title):
                let heading = Self.smallCaps(title)
                let w = ceil(heading.size().width)
                heading.draw(at: NSPoint(x: r.minX + 4, y: r.midY - textH / 2))
                Self.color(0xD5DFE5).setFill()
                NSRect(x: r.minX + 4 + w + 6, y: r.midY.rounded(), width: max(0, r.maxX - (r.minX + 4 + w + 6) - 4), height: 1).fill()
            case .item(let item, let icon, let glyph):
                if hover == i || selected == i {
                    // W7DrawMenuHighlight draws in a bottom-left-origin context.
                    ctx.saveGState()
                    ctx.translateBy(x: 0, y: bounds.height)
                    ctx.scaleBy(x: 1, y: -1)
                    W7DrawMenuHighlight(ctx, NSRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height))
                    ctx.restoreGState()
                }
                let iconRect = NSRect(x: r.minX + 6, y: r.midY - Self.iconSize / 2, width: Self.iconSize, height: Self.iconSize)
                if let icon { icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
                if let glyph { Self.draw(glyph, in: iconRect) }
                let textX = iconRect.maxX + 8
                (item.title as NSString).draw(
                    in: NSRect(x: textX, y: r.midY - textH / 2, width: r.maxX - 4 - textX, height: textH),
                    withAttributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: style])
            }
        }
    }

    /// A heading in grey small caps (`JumpList.smallCapsRuns`): the capital at 12 pt, the rest at 9.5.
    private static func smallCaps(_ title: String) -> NSAttributedString {
        let grey = color(0x6D6D6D)
        let out = NSMutableAttributedString()
        for run in JumpList.smallCapsRuns(title) {
            out.append(NSAttributedString(string: run.text, attributes: [
                .font: W7UIFont(run.small ? 9.5 : 12), .foregroundColor: grey, .kern: run.small ? 0.4 : 0]))
        }
        return out
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// The tasks' 16 pt glyphs (flipped coordinates): a pushpin (struck through to unpin) and a red ×.
    private static func draw(_ glyph: Glyph, in r: NSRect) {
        switch glyph {
        case .pin, .unpin:
            let head = NSBezierPath(roundedRect: NSRect(x: r.minX + 4, y: r.minY + 1, width: 8, height: 7), xRadius: 1.5, yRadius: 1.5)
            color(0x5B8FD0).setFill()
            head.fill()
            color(0x2B5A93).setStroke()
            head.lineWidth = 1
            head.stroke()
            let collar = NSBezierPath()
            collar.move(to: NSPoint(x: r.minX + 2, y: r.minY + 8.5))
            collar.line(to: NSPoint(x: r.maxX - 2, y: r.minY + 8.5))
            collar.lineWidth = 1.5
            collar.stroke()
            let needle = NSBezierPath()
            needle.move(to: NSPoint(x: r.midX, y: r.minY + 9))
            needle.line(to: NSPoint(x: r.midX, y: r.maxY - 1))
            color(0x6D6D6D).setStroke()
            needle.lineWidth = 1.2
            needle.stroke()
            if glyph == .unpin {
                let strike = NSBezierPath()
                strike.move(to: NSPoint(x: r.minX + 1, y: r.maxY - 1))
                strike.line(to: NSPoint(x: r.maxX - 1, y: r.minY + 1))
                color(0xC75050).setStroke()
                strike.lineWidth = 1.6
                strike.stroke()
            }
        case .close:
            let x = NSBezierPath()
            let c = NSPoint(x: r.midX, y: r.midY), d: CGFloat = 4.5
            x.move(to: NSPoint(x: c.x - d, y: c.y - d)); x.line(to: NSPoint(x: c.x + d, y: c.y + d))
            x.move(to: NSPoint(x: c.x + d, y: c.y - d)); x.line(to: NSPoint(x: c.x - d, y: c.y + d))
            x.lineCapStyle = .round
            x.lineWidth = 2.2
            color(0xC75050).setStroke()
            x.stroke()
        }
    }
}
