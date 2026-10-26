import AppKit
import Carbon.HIToolbox
import Win7ChromeCore
import Win7Core
import Win7Theme

/// The shell's framed windows, factored out of the Control Panel: a titled window with
/// the Aero caption from Win7ChromeCore, a taskbar button (ShellWindowButtons, by identifier), a remembered frame
/// (`Win7<Name>`), placement inside the work area (ShellWindowPlacement, again whenever the screens change), and
/// the common keys (Alt+F4, Cmd+W, Cmd+M). Show Desktop does not cover it yet: AppDelegate.toggleShowDesktop hides
/// other apps by bundle id and never the shell's own windows (the Control Panel has the same gap; a later task can
/// minimize them through ShellWindowButtons). Its dialogs are ShellDialogs.
///
/// A subclass calls `init(spec:)`, builds its content, then `finishSetup()` — the Control Panel's order before
/// the split: content first, then centring, autosave, decoration and registration.
@MainActor
class ShellWindow: NSWindow {
    struct Spec {
        var identifier: String
        /// The caption and the taskbar button's name.
        var title: String
        /// Frame autosave name, `Win7<Name>`.
        var frameName: String
        var defaultSize: NSSize
        var minSize: NSSize
        var resizable = true
        /// The window's icon at a side (taskbar button, jump list).
        var icon: (CGFloat) -> NSImage
        /// The diagnostics' prefix ("control panel").
        var logName: String
    }

    let spec: Spec

    init(spec: Spec) {
        self.spec = spec
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if spec.resizable { style.insert(.resizable) }
        super.init(contentRect: NSRect(origin: .zero, size: spec.defaultSize), styleMask: style,
                   backing: .buffered, defer: false)
        title = spec.title
        identifier = NSUserInterfaceItemIdentifier(spec.identifier)
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace]
        contentMinSize = spec.minSize
        Self.observeScreenChanges()
    }

    /// Centres the window (an autosaved frame then wins), decorates it, follows its state and registers its
    /// taskbar button. Call once, after the content is built.
    func finishSetup() {
        center()
        setFrameAutosaveName(spec.frameName)
        W7ChromeController.decorateWindow(self)
        observeState()
        ShellWindowButtons.log.info("\(self.spec.logName, privacy: .public): window created, number \(self.windowNumber), frame \(NSStringFromRect(self.frame), privacy: .public)")
        ShellWindowButtons.register(.init(identifier: spec.identifier, name: spec.title,
                                          window: { [weak self] in self },
                                          icon: spec.icon))
    }

    /// Called when the window gains or loses key status, after the caption was redrawn (the Control Panel
    /// redraws its address row's glass).
    func keyStateChanged() {}

    /// Key changes redraw the caption glass (the shell doesn't run W7ChromeController.start()); open, close and
    /// minimize update the taskbar button.
    private func observeState() {
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            nc.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Self.refreshTitlebars(of: self)
                    self.keyStateChanged()
                    ShellWindowButtons.changed()
                }
            }
        }
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
            nc.addObserver(forName: name, object: self, queue: .main) { _ in
                // After the change has happened (willClose comes while the window is still visible).
                DispatchQueue.main.async { MainActor.assumeIsolated { ShellWindowButtons.changed() } }
            }
        }
    }

    /// Redraws `window`'s Aero caption for its key state (shell windows and ShellDialogs).
    static func refreshTitlebars(of window: NSWindow) {
        if let bar = window.standardWindowButton(.closeButton)?.superview { refreshTitlebars(in: bar) }
    }

    private static func refreshTitlebars(in view: NSView) {
        for sub in view.subviews {
            if let bar = sub as? W7TitlebarView { bar.refresh() } else { refreshTitlebars(in: sub) }
        }
    }

    private static var screenObserver: NSObjectProtocol?

    /// Once: when the screens change (a resolution change, a display added or removed), the open shell windows and
    /// then their dialogs are placed again inside the new work areas. Deferred a turn, so the taskbar has reframed
    /// itself (the work area ends at its top edge) by then.
    static func observeScreenChanges() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for case let w as ShellWindow in NSApp.windows where w.isVisible { w.keepInWorkArea() }
                    for case let d as ShellDialog in NSApp.windows where d.isVisible { d.keepInWorkArea() }
                }
            }
        }
    }

    // MARK: Showing

    /// Places the window inside the work area, brings it forward and updates its taskbar button.
    func present(_ what: String) {
        keepInWorkArea()
        ShellWindowButtons.bringForward(self)
        ShellWindowButtons.changed()
        let screenFrame = screen.map { NSStringFromRect($0.frame) } ?? "none"
        ShellWindowButtons.log.info("\(self.spec.logName, privacy: .public): shown at \(what, privacy: .public), frame \(NSStringFromRect(self.frame), privacy: .public), screen \(screenFrame, privacy: .public), visible=\(self.isVisible), onActiveSpace=\(self.isOnActiveSpace), level=\(self.level.rawValue), key=\(self.isKeyWindow), appActive=\(NSApp.isActive)")
        if !isVisible { ShellWindowButtons.log.error("\(self.spec.logName, privacy: .public): still not visible after ordering front") }
    }

    /// A remembered frame no screen shows any more (a display was removed, or a stale autosave) is replaced by the
    /// default size, centred on the main screen; a frame reaching under the taskbar moves up (ShellWindowPlacement).
    /// Run when the window is shown and when the screens change.
    func keepInWorkArea() {
        let main = NSScreen.main ?? NSScreen.screens.first
        let target = ShellWindowPlacement.frame(current: frame, defaultSize: frameRect(forContentRect: NSRect(origin: .zero, size: spec.defaultSize)).size,
                                                usable: NSScreen.screens.map(Self.workArea), main: main.map(Self.workArea))
        guard let target else { return }
        ShellWindowButtons.log.info("\(self.spec.logName, privacy: .public): frame \(NSStringFromRect(self.frame), privacy: .public) is outside the work area, moving to \(NSStringFromRect(target), privacy: .public)")
        setFrame(target, display: true)
    }

    /// A screen's visible frame, on the taskbar's screen ending at the bar's top edge (WorkArea.visible, AX
    /// coordinates in, AppKit out).
    static func workArea(_ screen: NSScreen) -> NSRect {
        guard let bar = NSApp.windows.first(where: { $0 is TaskbarWindow && $0.isVisible })?.frame,
              let primary = NSScreen.screens.first,
              (NSScreen.screens.first { $0.frame.intersects(bar) } ?? primary) == screen else { return screen.visibleFrame }
        let h = primary.frame.height
        let visible = WorkArea.visible(screenVisible: Coordinates.ax(fromAppKit: screen.visibleFrame, primaryHeight: h),
                                       bar: Coordinates.ax(fromAppKit: bar, primaryHeight: h))
        return Coordinates.appKit(fromAX: visible, primaryHeight: h)
    }

    // MARK: Keyboard

    /// Alt+F4 (Option+F4, or Ctrl+Option+F4 as Win+Alt) and Cmd+W close the window, Cmd+M minimizes it; a
    /// subclass handles its own keys first (`handleKey`) and calls super for these. The shell has no main menu, so
    /// the standard edit keys are routed here too.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey(event) { return }
        super.sendEvent(event)
    }

    static func flags(_ event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
    }

    /// The key as the drawn controls read it (ShellKeyboard), or nil.
    static func shellKey(_ event: NSEvent) -> ShellKey? {
        let f = flags(event)
        return ShellKey(keyCode: event.keyCode, shift: f.contains(.shift), option: f.contains(.option),
                        command: f.contains(.command), control: f.contains(.control))
    }

    // MARK: Keyboard focus

    /// Windows 7 draws its dotted focus rectangles only once the keyboard has been used in the window; the drawn
    /// controls ask this before drawing theirs.
    private(set) var showsFocusCues = false

    func setShowsFocusCues(_ on: Bool) {
        guard on != showsFocusCues else { return }
        showsFocusCues = on
        (firstResponder as? NSView)?.needsDisplay = true
    }

    /// Whether `view` has the keyboard focus (a text field: its field editor is first responder).
    func hasFocus(_ view: NSView) -> Bool {
        if firstResponder === view { return true }
        if let editor = firstResponder as? NSTextView, editor.isFieldEditor, (editor.delegate as? NSView) === view { return true }
        return false
    }

    /// Tab and Shift-Tab over `stops` (in order): the focus goes to the next one that can take it.
    func cycleFocus(_ stops: [NSView], backward: Bool) {
        setShowsFocusCues(true)
        let current = stops.firstIndex { hasFocus($0) }
        let canFocus = stops.map { !$0.isHiddenOrHasHiddenAncestor && $0.acceptsFirstResponder }
        guard let next = ShellKeyboard.nextFocus(from: current, canFocus: canFocus, backward: backward) else { return }
        makeFirstResponder(stops[next])
        stops[next].scrollToVisible(stops[next].bounds)
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let flags = Self.flags(event)
        switch Int(event.keyCode) {
        case kVK_F4 where flags == .option || flags == [.control, .option]:
            performClose(nil)
            return true
        case kVK_ANSI_W where flags == .command:
            performClose(nil)
            return true
        case kVK_ANSI_M where flags == .command:
            miniaturize(nil)
            return true
        default:
            return StandardEditKeys.perform(event)
        }
    }
}
