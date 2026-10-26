import AppKit
import Carbon.HIToolbox
import Win7Core
import Win7Theme

/// Windows 7's Screen Resolution window, opened from the desktop's "Screen resolution" and Control
/// Panel ▸ Display ▸ "Adjust resolution". "Change the appearance of your display", the monitor picture (one numbered
/// monitor per NSScreen, laid out as the displays are arranged; a click selects one), Detect (reads the displays and
/// modes again) and Identify (a big number on each screen for 3 s), the Display, Resolution and Orientation combos
/// (Landscape only), the links, and OK / Cancel / Apply.
///
/// Applying a resolution goes through DisplayModes and CoreGraphicsDisplays (the public CoreGraphics configuration
/// API, the only display change the shell makes) and then asks "Do you want to keep these display settings?" in a
/// ShellDialog with a 15 s KeepChangesCountdown: Keep changes keeps it; Revert, Esc, closing the dialog or this
/// window, or the countdown running out puts the previous mode back. A mode that fails to apply shows "The display
/// settings could not be applied." and the old mode stays. After any change the work-area keeper sweeps the app
/// windows into the new work area (the shell windows re-place themselves on the screen-change notification).
///
/// the trial mode lasts only while the shell runs (DisplayModes.apply is `.untilQuit`), Keep changes stores
/// it (DisplayModes.finish → persist), and the shell terminating mid-countdown reverts at once
/// (`revertPendingChange`, from applicationWillTerminate). The countdown runs to a deadline, not a tick count.
@MainActor
final class ScreenResolutionWindow: ShellWindow {
    static let shared = ScreenResolutionWindow()
    static let contentSize = NSSize(width: 620, height: 470)
    static let displaysURL = URL(string: "x-apple.systempreferences:" + ControlPanelCatalog.Pane.displays)!
    /// The Accessibility pane itself: the `?Seeing_Display` anchor does not occur in AccessibilitySettingsExtension
    /// (macOS 27.0.1; only a lowercase `seeing_display` string of unknown role), so no anchor is passed.
    static let accessibilityURL = URL(string: "x-apple.systempreferences:" + ControlPanelCatalog.Pane.accessibility)!
    /// The work-area sweep's fallback when no screen-change notification follows a mode change.
    static let sweepFallbackSeconds: TimeInterval = 2
    static let keepQuestion = "Do you want to keep these display settings?"
    static let identifySeconds: TimeInterval = 3

    /// One display: its CoreGraphics id, Windows' number ("1" is the main display) and its arrangement.
    struct Monitor: Equatable {
        var id: CGDirectDisplayID
        var number: Int
        var name: String
        var frame: NSRect
    }

    /// A running "Keep changes?" countdown (its deadline starts when the session is made, right after the switch).
    private final class KeepSession {
        var countdown = KeepChangesCountdown(now: Date())
        let display: CGDirectDisplayID
        let previous: DisplayModeInfo
        let closeWhenKept: Bool
        var timer: Timer?
        weak var dialog: ShellDialog?

        init(display: CGDirectDisplayID, previous: DisplayModeInfo, closeWhenKept: Bool) {
            self.display = display
            self.previous = previous
            self.closeWhenKept = closeWhenKept
        }
    }

    private let displays: DisplayConfiguring
    private let page = ScreenResolutionView(frame: NSRect(origin: .zero, size: ScreenResolutionWindow.contentSize))
    private var monitors: [Monitor] = []
    private var selected: CGDirectDisplayID?
    private var modes: [DisplayModeEntry] = []
    /// The resolution chosen in the combo, not applied yet.
    private var chosen: DisplayModeEntry?
    private var session: KeepSession?
    private var identifyWindows: [NSWindow] = []
    private var identifyGeneration = 0
    /// A work-area sweep waits for the next screen-change notification (or the fallback timer).
    private var sweepPending = false
    private var sweepGeneration = 0
    /// The window, once made — so terminating can revert without making it.
    private static weak var live: ScreenResolutionWindow?

    private init() {
        displays = CoreGraphicsDisplays.shared
        super.init(spec: Spec(identifier: ShellWindowTarget.screenResolution.identifier,
                              title: ShellWindowTarget.screenResolution.title, frameName: "Win7ScreenResolution",
                              defaultSize: Self.contentSize, minSize: Self.contentSize, resizable: false,
                              icon: { Self.icon(side: $0) }, logName: "screen resolution"))
        page.onAction = { [weak self] action in self?.perform(action) }
        contentView = page
        finishSetup()
        Self.live = self
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.sweepPending {
                    // One turn later: the taskbar and the shell windows re-place themselves on this same notification.
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.sweep() } }
                }
                guard self.isVisible, self.session == nil else { return }
                self.reload()
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.chosen = nil
                self?.endIdentify()
            }
        }
    }

    /// The Control Panel Display item's picture.
    static func icon(side: CGFloat) -> NSImage {
        ControlPanelIcons.image(names: ["cp-display"], glyph: .nav(.computer), side: side)
    }

    // MARK: Showing

    /// Brings the window forward; opening it (it was closed) reads the displays and their modes again.
    func show() {
        if !isVisible && !isMiniaturized { reload() }
        present("screen resolution")
    }

    /// Reads the displays and the selected one's modes (Detect, a screen change, opening); drops an unapplied choice.
    private func reload() {
        let screens = NSScreen.screens
        monitors = screens.enumerated().compactMap { i, screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return Monitor(id: id, number: i + 1, name: screen.localizedName, frame: screen.frame)
        }
        if selected == nil || !monitors.contains(where: { $0.id == selected }) { selected = monitors.first?.id }
        modes = selected.map { DisplayModes.list(for: $0, using: displays) } ?? []
        chosen = nil
        let list = modes.map(\.title).joined(separator: ", ")
        ShellWindowButtons.log.info("screen resolution: \(self.monitors.count) displays, \(self.modes.count) modes for the selected one: \(list, privacy: .public)")
        refreshPage()
    }

    private var monitor: Monitor? { monitors.first { $0.id == selected } }
    private var shownMode: DisplayModeEntry? { chosen ?? modes.first(where: \.isCurrent) }

    private func refreshPage() {
        page.state = ScreenResolutionView.State(
            monitors: monitors, selected: selected,
            display: monitor.map { "\($0.number). \($0.name)" } ?? "",
            resolution: shownMode?.title ?? "",
            canApply: (chosen.map { !$0.isCurrent } ?? false) && session == nil)
    }

    /// The OK button's default ring follows the key state.
    override func keyStateChanged() { page.needsDisplay = true }

    // MARK: Actions

    private func perform(_ action: ScreenResolutionView.Action) {
        guard session == nil else { return }
        switch action {
        case .monitor(let id):
            guard id != selected else { return }
            selected = id
            reload()
        case .displayMenu(let anchor): popUp(displayMenu(), anchor)
        case .resolutionMenu(let anchor): popUp(resolutionMenu(), anchor)
        case .orientationMenu(let anchor): popUp(orientationMenu(), anchor)
        case .detect: reload()
        case .identify: identify()
        case .advanced: NSWorkspace.shared.open(Self.displaysURL)
        case .textSize: NSWorkspace.shared.open(Self.accessibilityURL)
        case .help:
            // The Help window's topic; the Control Panel info page if that topic is ever missing.
            if HelpTopics.topic(HelpTopics.displaySettingsTopic) != nil {
                HelpWindow.shared.show(topic: HelpTopics.displaySettingsTopic)
            } else {
                ControlPanelWindow.shared.show(.info(title: "What display settings should I choose?",
                                                     text: ControlPanelCatalog.displaySettingsInfo, category: .appearance))
            }
        case .ok: apply(thenClose: true)
        case .cancel: performClose(nil)
        case .apply: apply(thenClose: false)
        }
    }

    /// Shows `menu` under the combo at `anchor` (page coordinates), as wide as the combo.
    private func popUp(_ menu: NSMenu, _ anchor: NSRect) {
        let bottomLeft = convertPoint(toScreen: page.convert(NSPoint(x: anchor.minX, y: anchor.maxY), to: nil))
        ShellMenus.show(menu, at: bottomLeft, minWidth: anchor.width)
    }

    private func displayMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for m in monitors {
            let item = MenuAction.item("\(m.number). \(m.name)") { [weak self] in self?.perform(.monitor(m.id)) }
            item.state = m.id == selected ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func resolutionMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let shown = shownMode
        for entry in modes {
            let item = MenuAction.item(entry.title) { [weak self] in
                guard let self else { return }
                self.chosen = entry.isCurrent ? nil : entry
                self.refreshPage()
            }
            item.state = entry == shown ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// Landscape only: macOS rotates displays in System Settings, which this window doesn't drive.
    private func orientationMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (i, title) in ["Landscape", "Portrait", "Landscape (flipped)", "Portrait (flipped)"].enumerated() {
            let item = MenuAction.item(title, enabled: i == 0) {}
            item.state = i == 0 ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    // MARK: Applying

    /// Apply, or OK (which then closes the window once the change is kept, or at once when nothing changed).
    private func apply(thenClose: Bool) {
        guard let chosen, !chosen.isCurrent, let monitor else {
            if thenClose { performClose(nil) }
            return
        }
        ShellWindowButtons.log.info("screen resolution: applying \(chosen.title, privacy: .public) to display \(monitor.number)")
        switch DisplayModes.apply(chosen.mode, to: monitor.id, using: displays) {
        case .unchanged:
            reload()
            if thenClose { performClose(nil) }
        case .failed(let message):
            reload()
            showError(message)
        case .applied(let previous):
            screensChanged()
            startCountdown(display: monitor.id, previous: previous, closeWhenKept: thenClose)
        }
    }

    private func startCountdown(display: CGDirectDisplayID, previous: DisplayModeInfo, closeWhenKept: Bool) {
        let s = KeepSession(display: display, previous: previous, closeWhenKept: closeWhenKept)
        session = s
        refreshPage()
        let dialog = ShellDialog(title: "Display Settings", message: Self.countdownText(s.countdown), buttons: [
            .init(title: "Keep changes", role: .default) { [weak self] in self?.endCountdown(keep: true) },
            .init(title: "Revert", role: .cancel) { [weak self] in self?.endCountdown(keep: false) },
        ])
        s.dialog = dialog
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.1   // the seconds shown come from the deadline, so a late fire only shows late
        RunLoop.main.add(timer, forMode: .common)   // keeps counting while a menu tracks
        s.timer = timer
        dialog.present(over: self)
    }

    private static func countdownText(_ c: KeepChangesCountdown) -> String { keepQuestion + "\n\n" + c.message }

    private func tick() {
        guard let s = session else { return }
        s.countdown.tick(now: Date())
        if s.countdown.isFinished { finishCountdown() } else { s.dialog?.message = Self.countdownText(s.countdown) }
    }

    /// Keep changes, or Revert (also Esc, the dialog's ×, this window closing).
    private func endCountdown(keep: Bool) {
        guard let s = session else { return }
        if keep { s.countdown.keep() } else { s.countdown.revert() }
        finishCountdown()
    }

    private func finishCountdown() {
        guard let s = session, s.countdown.isFinished else { return }
        session = nil
        s.timer?.invalidate()
        s.dialog?.close()   // after the countdown ran out; its cancel action then finds no session
        ShellWindowButtons.log.info("screen resolution: countdown ended \(String(describing: s.countdown.state), privacy: .public)")
        let outcome = DisplayModes.finish(s.countdown, previous: s.previous, on: s.display, using: displays)
        switch outcome {
        case .reverted, .revertFailed:
            if case .revertFailed(let message) = outcome {
                ShellWindowButtons.log.error("screen resolution: the previous mode could not be restored")
                if isVisible { showError(message) }
            }
            screensChanged()
            if isVisible { reload() }
        case .kept, .keptUntilQuit, nil:
            if outcome == .keptUntilQuit {
                ShellWindowButtons.log.error("screen resolution: the kept mode could not be stored; it lasts until the shell quits")
            }
            reload()
            if s.closeWhenKept { performClose(nil) }
        }
    }

    /// The shell is terminating: a mode still on trial goes back now (macOS would also undo the app-only change when
    /// the process exits; this re-asserts the stored mode at once). No UI.
    static func revertPendingChange() { live?.revertPendingChangeNow() }

    private func revertPendingChangeNow() {
        guard let s = session else { return }
        session = nil
        s.timer?.invalidate()
        s.countdown.revert()
        let outcome = DisplayModes.finish(s.countdown, previous: s.previous, on: s.display, using: displays)
        ShellWindowButtons.log.info("screen resolution: terminating mid-countdown, \(String(describing: outcome), privacy: .public)")
    }

    /// After a mode change: once the screens have settled (the next screen-change notification, then one turn for
    /// the taskbar and the shell windows to re-place themselves; at the latest after 2 s), the work-area keeper
    /// looks at every app window again.
    private func screensChanged() {
        sweepPending = true
        sweepGeneration += 1
        let generation = sweepGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sweepFallbackSeconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.sweepGeneration else { return }
                self.sweep()
            }
        }
    }

    private func sweep() {
        guard sweepPending else { return }
        sweepPending = false
        WorkAreaKeeper.sweepActive()
    }

    private func showError(_ message: String) {
        let dialog = ShellDialog(title: "Display Settings", message: message, buttons: [.init(title: "OK", role: .default)])
        dialog.present(over: isVisible ? self : nil)
    }

    // MARK: Identify

    /// A big number on each display for 3 s (borderless, at the pop-up menu level, ignoring the mouse).
    private func identify() {
        endIdentify()
        identifyGeneration += 1
        let generation = identifyGeneration
        for m in monitors {
            let side: CGFloat = 220
            let w = NSWindow(contentRect: NSRect(x: m.frame.midX - side / 2, y: m.frame.midY - side / 2, width: side, height: side),
                             styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .popUpMenu
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            w.contentView = IdentifyNumberView(number: m.number)
            w.orderFrontRegardless()
            identifyWindows.append(w)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.identifySeconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.identifyGeneration else { return }
                self.endIdentify()
            }
        }
    }

    private func endIdentify() {
        identifyWindows.forEach { $0.orderOut(nil) }
        identifyWindows = []
    }

    // MARK: Keyboard

    /// Return is OK, Esc is Cancel (both only while no countdown runs; the dialog has the keys then).
    override func handleKey(_ event: NSEvent) -> Bool {
        let flags = Self.flags(event)
        if flags.isEmpty {
            switch Int(event.keyCode) {
            case kVK_Return, kVK_ANSI_KeypadEnter: perform(.ok); return true
            case kVK_Escape: perform(.cancel); return true
            default: break
            }
        }
        return super.handleKey(event)
    }
}

/// Identify's number: white, bold, outlined in black, as Windows 7 shows it.
@MainActor
private final class IdentifyNumberView: NSView {
    private let number: Int
    init(number: Int) {
        self.number = number
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let s = "\(number)" as NSString
        let font = NSFont.boldSystemFont(ofSize: 160)
        let fill: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white,
                                                   .strokeColor: NSColor.black, .strokeWidth: -3]
        let size = s.size(withAttributes: fill)
        s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: fill)
    }
}

/// The window's page, drawn: white, the header, the monitor picture, the rows of combos, the links and the push
/// buttons. Flipped (top-left origin), fixed size.
@MainActor
final class ScreenResolutionView: NSView {
    struct State {
        var monitors: [ScreenResolutionWindow.Monitor] = []
        var selected: CGDirectDisplayID?
        var display = ""
        var resolution = ""
        var canApply = false
    }

    enum Action {
        case monitor(CGDirectDisplayID)
        case displayMenu(NSRect), resolutionMenu(NSRect), orientationMenu(NSRect)
        case detect, identify, advanced, textSize, help, ok, cancel, apply
    }

    private enum Part: Hashable {
        case monitor(CGDirectDisplayID)
        case detect, identify, display, resolution, orientation, advanced, textSize, help, ok, cancel, apply
    }

    var state = State() { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var onAction: ((Action) -> Void)?
    private var hover: Part?
    private var pressed: Part?

    private static let font = W7UIFont(12)
    private static let headerFont = W7UIFont(16)
    private static let margin: CGFloat = 30
    private static let comboX: CGFloat = 150, comboWidth: CGFloat = 300, comboHeight: CGFloat = 22

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Layout

    private var pictureArea: NSRect { NSRect(x: Self.margin + 20, y: 56, width: bounds.width - 2 * Self.margin - 40, height: 140) }

    private func buttonRect(_ index: Int, of count: Int, titles: [String], y: CGFloat) -> NSRect {
        let widths = titles.map { ShellDialogLayout.buttonWidth(titleWidth: ControlPanelText.width($0, Self.font)) }
        var x = bounds.width - Self.margin - widths.reduce(0, +) - CGFloat(count - 1) * ShellDialogLayout.buttonGap
        for i in 0..<index { x += widths[i] + ShellDialogLayout.buttonGap }
        return NSRect(x: x, y: y, width: widths[index], height: ShellDialogLayout.buttonHeight)
    }

    private static let pictureButtons = ["Detect", "Identify"]
    private static let footerButtons = ["OK", "Cancel", "Apply"]
    private static let rows = ["Display:", "Resolution:", "Orientation:"]
    private static let rowTop: CGFloat = 222, rowStep: CGFloat = 34

    private func comboRect(_ row: Int) -> NSRect {
        NSRect(x: Self.comboX, y: Self.rowTop + CGFloat(row) * Self.rowStep, width: Self.comboWidth, height: Self.comboHeight)
    }

    private func linkRect(_ title: String, x: CGFloat? = nil, rightEdge: CGFloat? = nil, y: CGFloat) -> NSRect {
        let w = ControlPanelText.width(title, Self.font)
        return NSRect(x: rightEdge.map { $0 - w } ?? x ?? 0, y: y, width: w, height: 18)
    }

    private static let advancedTitle = "Advanced settings"
    private static let textSizeTitle = "Make text and other items larger or smaller"
    private static let helpTitle = "What display settings should I choose?"

    /// Every clickable part and its rect.
    private var parts: [(Part, NSRect)] {
        var p: [(Part, NSRect)] = monitorRects().map { (.monitor($0.0), $0.1) }
        let pictureY = pictureArea.maxY - ShellDialogLayout.buttonHeight
        p.append((.detect, buttonRect(0, of: 2, titles: Self.pictureButtons, y: pictureY)))
        p.append((.identify, buttonRect(1, of: 2, titles: Self.pictureButtons, y: pictureY)))
        p.append((.display, comboRect(0)))
        p.append((.resolution, comboRect(1)))
        p.append((.orientation, comboRect(2)))
        let linksY = Self.rowTop + 3 * Self.rowStep + 6
        p.append((.advanced, linkRect(Self.advancedTitle, rightEdge: Self.comboX + Self.comboWidth, y: linksY)))
        p.append((.textSize, linkRect(Self.textSizeTitle, x: Self.margin + 20, y: linksY + 40)))
        p.append((.help, linkRect(Self.helpTitle, x: Self.margin + 20, y: linksY + 66)))
        let footerY = bounds.height - 16 - ShellDialogLayout.buttonHeight
        for (i, part) in [Part.ok, .cancel, .apply].enumerated() {
            p.append((part, buttonRect(i, of: 3, titles: Self.footerButtons, y: footerY)))
        }
        return p
    }

    /// The monitors laid out as the displays are arranged, scaled to fit the picture area and centred in it.
    private func monitorRects() -> [(CGDirectDisplayID, NSRect)] {
        let ms = state.monitors
        guard let first = ms.first else { return [] }
        let union = ms.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        let area = pictureArea.insetBy(dx: 90, dy: 10)
        guard union.width > 0, union.height > 0 else { return [] }
        let scale = min(area.width / union.width, area.height / union.height, 0.12)
        let w = union.width * scale, h = union.height * scale
        let origin = NSPoint(x: area.midX - w / 2, y: area.midY - h / 2)
        return ms.map { m in
            // AppKit's y grows upward; the page is flipped.
            let r = NSRect(x: origin.x + (m.frame.minX - union.minX) * scale, y: origin.y + (union.maxY - m.frame.maxY) * scale,
                           width: m.frame.width * scale, height: m.frame.height * scale)
            return (m.id, r.insetBy(dx: 2, dy: 2).integral)
        }
    }

    private func enabled(_ part: Part) -> Bool { part == .apply ? state.canApply : true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.white.setFill()
        bounds.fill()
        ("Change the appearance of your display" as NSString).draw(
            at: NSPoint(x: Self.margin, y: 18), withAttributes: [.font: Self.headerFont, .foregroundColor: ControlPanelText.navy])

        for (id, r) in monitorRects() {
            drawMonitor(ctx, r, number: state.monitors.first { $0.id == id }?.number ?? 0, selected: id == state.selected)
        }
        for (part, r) in parts {
            switch part {
            case .detect, .identify, .ok, .cancel, .apply:
                drawButton(ctx, r, part: part)
            case .display, .resolution, .orientation:
                drawCombo(ctx, r, part: part)
            case .advanced, .textSize, .help:
                let title = part == .advanced ? Self.advancedTitle : part == .textSize ? Self.textSizeTitle : Self.helpTitle
                (title as NSString).draw(at: r.origin, withAttributes: ControlPanelText.attributes(
                    Self.font, ControlPanelText.linkBlue, underline: hover == part))
            case .monitor:
                break
            }
        }
        for (i, label) in Self.rows.enumerated() {
            let r = comboRect(i)
            (label as NSString).draw(at: NSPoint(x: Self.margin + 20, y: r.minY + 3),
                                     withAttributes: [.font: Self.font, .foregroundColor: NSColor.black])
        }
    }

    private func controlState(_ part: Part) -> W7ControlState {
        guard enabled(part) else { return .disabled }
        if pressed == part && hover == part { return .pressed }
        if hover == part && pressed == nil { return .hover }
        return .normal
    }

    /// Theme drawing expects a non-flipped context: each control is drawn in a flipped-back frame.
    private func unflipped(_ ctx: CGContext, _ r: NSRect, _ body: (CGRect) -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: r.maxY + r.minY)
        ctx.scaleBy(x: 1, y: -1)
        body(r)
        ctx.restoreGState()
    }

    private func drawButton(_ ctx: CGContext, _ r: NSRect, part: Part) {
        let isDefault = part == .ok && (window?.isKeyWindow ?? false)
        unflipped(ctx, r) { W7DrawPushButton(ctx, $0, controlState(part), isDefault) }
        let title: String
        switch part {
        case .detect: title = "Detect"
        case .identify: title = "Identify"
        case .ok: title = "OK"
        case .cancel: title = "Cancel"
        default: title = "Apply"
        }
        let color = enabled(part) ? NSColor.black : ControlPanelText.grey
        let size = (title as NSString).size(withAttributes: [.font: Self.font])
        (title as NSString).draw(at: NSPoint(x: (r.midX - size.width / 2).rounded(), y: (r.midY - size.height / 2).rounded()),
                                 withAttributes: [.font: Self.font, .foregroundColor: color])
    }

    private func drawCombo(_ ctx: CGContext, _ r: NSRect, part: Part) {
        unflipped(ctx, r) { W7DrawComboBox(ctx, $0, controlState(part)) }
        let text: String
        switch part {
        case .display: text = state.display
        case .resolution: text = state.resolution
        default: text = "Landscape"
        }
        let attrs = ControlPanelText.attributes(Self.font, .black)
        let h = ceil((text as NSString).size(withAttributes: attrs).height)
        (text as NSString).draw(in: NSRect(x: r.minX + 6, y: r.midY - h / 2, width: r.width - 6 - 20, height: h), withAttributes: attrs)
    }

    /// A Windows 7 monitor: a dark bezel, a blue screen with the number, a short stand; the selected one ringed.
    private func drawMonitor(_ ctx: CGContext, _ r: NSRect, number: Int, selected: Bool) {
        if selected {
            NSColor(srgbRed: 0x33 / 255, green: 0x99 / 255, blue: 0xFF / 255, alpha: 1).setStroke()
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: -3), xRadius: 4, yRadius: 4)
            ring.lineWidth = 2
            ring.stroke()
        }
        let bezel = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        NSGradient(starting: NSColor(srgbRed: 0x6D / 255, green: 0x7C / 255, blue: 0x8F / 255, alpha: 1),
                   ending: NSColor(srgbRed: 0x2E / 255, green: 0x37 / 255, blue: 0x43 / 255, alpha: 1))?.draw(in: bezel, angle: 90)
        let screen = r.insetBy(dx: 4, dy: 4)
        NSGradient(starting: NSColor(srgbRed: 0x6F / 255, green: 0xAE / 255, blue: 0xEC / 255, alpha: 1),
                   ending: NSColor(srgbRed: 0x1F / 255, green: 0x5F / 255, blue: 0xB6 / 255, alpha: 1))?.draw(in: screen, angle: 90)
        NSColor(white: 1, alpha: 0.18).setFill()
        NSRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height * 0.45).fill()
        let side = min(screen.height * 0.6, 40)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.6)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: side), .foregroundColor: NSColor.white,
                                                    .shadow: shadow]
        let s = "\(number)" as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2), withAttributes: attrs)
    }

    // MARK: Mouse

    private func part(at event: NSEvent) -> Part? {
        let p = convert(event.locationInWindow, from: nil)
        return parts.first { $0.1.contains(p) }?.0
    }

    override func resetCursorRects() {
        for (part, r) in parts where part == .advanced || part == .textSize || part == .help {
            addCursorRect(r, cursor: .pointingHand)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = part(at: event)
        if p != hover { hover = p; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hover != nil { hover = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        guard let p = part(at: event), enabled(p) else { return }
        switch p {
        case .monitor(let id):
            onAction?(.monitor(id))
        case .display, .resolution, .orientation:
            // A combo opens its menu at once; the menu tracks until it closes.
            pressed = p
            display()
            let r = parts.first { $0.0 == p }!.1
            onAction?(p == .display ? .displayMenu(r) : p == .resolution ? .resolutionMenu(r) : .orientationMenu(r))
            pressed = nil
            hover = nil
            needsDisplay = true
        default:
            pressed = p
            hover = p
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed != nil else { return }
        let p = part(at: event)
        if p != hover { hover = p; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        guard let was = pressed else { return }
        pressed = nil
        needsDisplay = true
        guard part(at: event) == was else { return }
        let action: Action? = switch was {
        case .detect: .detect
        case .identify: .identify
        case .advanced: .advanced
        case .textSize: .textSize
        case .help: .help
        case .ok: .ok
        case .cancel: .cancel
        case .apply: .apply
        default: nil
        }
        if let action { onAction?(action) }
    }
}
