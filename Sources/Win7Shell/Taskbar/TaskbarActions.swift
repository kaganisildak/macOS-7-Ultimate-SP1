import AppKit
import ApplicationServices
import Win7Core
import Win7Theme

/// Window actions for the taskbar's menus, jump lists and previews, through the public
/// Accessibility API. Without the Accessibility permission they do nothing (and never prompt).
@MainActor
enum TaskbarWindowActions {
    private static let timeout: Float = 0.25

    static var isTrusted: Bool { AXIsProcessTrusted() }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)   // type checked above
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }

    static func windows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let list = attribute(app, kAXWindowsAttribute) as? [AnyObject] else { return [] }
        return list.compactMap { w in
            let e = element(w)
            if let e { AXUIElementSetMessagingTimeout(e, timeout) }
            return e
        }
    }

    /// The app's focused window, else its main window, else its first window.
    static func frontWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return element(attribute(app, kAXFocusedWindowAttribute)) ?? element(attribute(app, kAXMainWindowAttribute))
            ?? windows(pid: pid).first
    }

    /// Presses the window's close button, as a click on it would.
    @discardableResult
    static func close(_ window: AXUIElement) -> Bool { press(window) == .success }

    /// The AXError of pressing the window's close button: the error of reading the button when there
    /// is none to press.
    static func press(_ window: AXUIElement) -> AXError {
        var value: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &value)
        guard read == .success else { return read }
        guard let button = element(value) else { return .noValue }
        return AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    /// The press result per window tried (the first that closes ends it).
    @discardableResult
    static func closeFrontWindow(pids: [pid_t]) -> [AXError] {
        guard isTrusted else { return [] }
        var results: [AXError] = []
        for pid in pids {
            guard let w = frontWindow(pid: pid) else { continue }
            let r = press(w)
            results.append(r)
            if r == .success { break }
        }
        return results
    }

    /// The press result per window.
    @discardableResult
    static func closeAllWindows(pids: [pid_t]) -> [AXError] {
        guard isTrusted else { return [] }
        return pids.flatMap { pid in windows(pid: pid).map(press) }
    }

    private static func isStandard(_ w: AXUIElement) -> Bool {
        (attribute(w, kAXSubroleAttribute) as? String) == (kAXStandardWindowSubrole as String)
    }

    private static func bool(_ w: AXUIElement, _ name: String) -> Bool {
        (attribute(w, name) as? Bool) ?? false
    }

    private static func frame(_ w: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let p = attribute(w, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(w, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID(),
              AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Size, then position, then size again (the first size can be clamped by the old position).
    private static func setFrame(_ w: AXUIElement, _ f: CGRect) {
        var size = f.size, origin = f.origin
        if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
        if let v = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
        if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
    }

    /// The taskbar menu's Cascade / Stacked / Side by side: the visible standard windows of regular
    /// apps whose centre is on the main screen, in the visible area above the taskbar. Apps are
    /// taken front to back (CGWindowList order), each app's windows in Accessibility order.
    static func arrange(_ kind: WindowArrangement) {
        guard isTrusted, let screen = NSScreen.screens.first else { return }
        let primaryHeight = screen.frame.height
        let area = WindowArranger.area(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                       taskbarHeight: W7TaskbarHeight, primaryHeight: primaryHeight)
        let screenAX = Coordinates.ax(fromAppKit: screen.frame, primaryHeight: primaryHeight)
        let own = ProcessInfo.processInfo.processIdentifier
        let regular = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != own }
            .map(\.processIdentifier))
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var order: [pid_t] = []
        for w in info where (w[kCGWindowLayer as String] as? Int) == 0 {
            if let pid = w[kCGWindowOwnerPID as String] as? pid_t, regular.contains(pid), !order.contains(pid) { order.append(pid) }
        }
        var targets: [AXUIElement] = []
        for pid in order {
            for w in windows(pid: pid) where isStandard(w) && !bool(w, kAXMinimizedAttribute) && !bool(w, "AXFullScreen") {
                if let f = frame(w), screenAX.contains(CGPoint(x: f.midX, y: f.midY)) { targets.append(w) }
            }
        }
        let frames = WindowArranger.frames(kind, count: targets.count, in: area)
        // Cascade puts frame 0 at the back (top-left), so the front window ends up on top.
        let ordered = kind == .cascade ? Array(targets.reversed()) : targets
        for (w, f) in zip(ordered, frames) { setFrame(w, f) }
    }
}

/// Brings an app to the front after a taskbar click restored it. macOS may refuse an
/// activation the shell asks for while another app is active, so each attempt is checked against
/// `frontmostApplication` after 300 ms and retried once with a stronger method (`RestoreActivation`).
@MainActor
enum TaskbarActivation {
    /// Bumped by every request and by `cancel()`: a pending check of an older request does nothing.
    private static var generation = 0

    /// Another taskbar click supersedes a pending check (a second click may hide the app on purpose).
    static func cancel() { generation += 1 }

    /// Any process of the app (a taskbar button stands for the bundle ID).
    static func bringForward(bundleID: String) {
        start {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        }
    }

    /// One process: the app whose window was chosen in a taskbar preview.
    static func bringForward(pid: pid_t) {
        start { NSRunningApplication(processIdentifier: pid).flatMap { $0.isTerminated ? nil : [$0] } ?? [] }
    }

    /// `targets` lists the live processes that count as "the app"; the first is activated.
    private static func start(_ targets: @escaping @MainActor () -> [NSRunningApplication]) {
        generation += 1
        let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
        attempt(0, targets: targets, before: before, generation: generation)
    }

    private static func attempt(_ n: Int, targets: @escaping @MainActor () -> [NSRunningApplication],
                                before: pid_t?, generation token: Int) {
        guard let app = targets().first else { return }
        activate(app, with: RestoreActivation.method(attempt: n, accessibility: TaskbarWindowActions.isTrusted))
        Timer.w7Scheduled(RestoreActivation.checkDelay, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard token == generation else { return }
                let verdict = RestoreActivation.verdict(
                    frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                    target: Set(targets().map(\.processIdentifier)),
                    shell: ProcessInfo.processInfo.processIdentifier, before: before, attemptsMade: n + 1)
                if verdict == .retry { attempt(n + 1, targets: targets, before: before, generation: token) }
            }
        }
    }

    private static func activate(_ app: NSRunningApplication, with method: ActivationMethod) {
        app.unhide()
        switch method {
        case .cooperative:
            handOff(to: app)
        case .accessibilityFrontmost:
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.25)
            if AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue) != .success {
                handOff(to: app)
            }
        case .shellHandOff:
            // The shell was just clicked, so it may activate itself; then it hands activation over.
            NSApp.activate()
            handOff(to: app)
        }
    }

    /// Cooperative activation: yield to the app and activate it from the shell; when the shell is
    /// not the active app that is refused, so the plain request follows.
    private static func handOff(to app: NSRunningApplication) {
        NSApp.yieldActivation(to: app)
        if !app.activate(from: NSRunningApplication.current, options: []) { app.activate(options: []) }
    }
}

/// "Close window" from a jump list, or a preview's ×, without Accessibility: the system prompt and the
/// Accessibility balloon (with "Open System Settings") explain why nothing closed, at most once per
/// 60 s.
@MainActor
final class CloseWindowHint {
    static let shared = CloseWindowHint()

    func needed() { PermissionPrompter.shared.needed(.accessibility) }
}

/// Launching from the taskbar (no Accessibility, no AppleScript).
@MainActor
enum TaskbarLaunch {
    static let finderID = "com.apple.finder"

    /// Starts a program that is not running (a pinned button, a middle click, the jump list's program row). Terminal
    /// starts as Command Prompt, with the "Win7 Command Prompt" profile file, as from the Start menu.
    static func launch(bundleID: String) {
        if CommandPromptLaunch.isCommandPrompt(bundleID: bundleID) { StartMenuPrograms.launchCommandPrompt(); return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// A middle click, Shift+click or the jump list's app name on a running app: the reopen event
    /// (AppKit opens a window when none is visible), and for Finder a window at the home folder.
    static func newWindow(bundleID: String) {
        if bundleID == finderID { openFinderHome(); return }
        guard let url = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = false
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    /// "Open Windows Explorer": Finder at the home folder.
    static func openFinderHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finderID) else {
            NSWorkspace.shared.open(home); return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([home], withApplicationAt: finder, configuration: config)
    }

    /// A Finder jump list's frequent folder, opened in Finder. The folder is handed to Finder as is:
    /// the shell never lists or reads it (it may be a privacy-protected folder).
    static func openFolder(path: String) {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finderID) else {
            NSWorkspace.shared.open(folder); return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([folder], withApplicationAt: finder, configuration: config)
    }

    /// A jump list's recent document, opened with the button's app.
    static func open(path: String, bundleID: String) {
        let file = URL(fileURLWithPath: path)
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            NSWorkspace.shared.open(file); return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: config)
    }

    /// "Start Task Manager": Activity Monitor.
    static func startTaskManager() { launch(bundleID: "com.apple.ActivityMonitor") }
}

/// A Windows 7 message box with the warning icon and two buttons, the confirming one left of Cancel
/// (Windows' order). Used to confirm quitting an app from "Close all windows".
@MainActor
final class TaskbarConfirmBox: AeroDialog {
    private let onConfirm: () -> Void
    /// The app focus goes back to on Cancel (the box activated the shell).
    private var cancelFocus: NSRunningApplication?
    private static var current: TaskbarConfirmBox?

    static func present(title: String, message: String, confirm: String, cancelFocus: NSRunningApplication?,
                        onConfirm: @escaping () -> Void) {
        current?.cancelFocus = nil   // replaced, not cancelled: the new box takes focus
        current?.close()
        let box = TaskbarConfirmBox(title: title, message: message, confirm: confirm, onConfirm: onConfirm)
        box.cancelFocus = cancelFocus
        current = box
        if let screen = NSScreen.screens.first {
            let v = screen.visibleFrame
            box.setFrameOrigin(NSPoint(x: v.midX - box.frame.width / 2, y: v.midY - box.frame.height / 2))
        }
        NSApp.activate()
        box.makeKeyAndOrderFront(nil)
    }

    private init(title: String, message: String, confirm: String, onConfirm: @escaping () -> Void) {
        self.onConfirm = onConfirm
        let size = NSSize(width: 400, height: 136)
        super.init(title: title, size: size)
        let body = MessageBoxBody(frame: NSRect(origin: .zero, size: size))
        body.message = message
        contentView = body
        let cancel = button("Cancel", slot: 0, in: body, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let ok = button(confirm, slot: 1, in: body, action: #selector(confirm(_:)))
        ok.keyEquivalent = "\r"
    }

    private func button(_ title: String, slot: Int, in body: MessageBoxBody, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .push
        b.font = W7UIFont(12)
        let w: CGFloat = 82, gap: CGFloat = 6
        let x = body.bounds.width - 10 - w - CGFloat(slot) * (w + gap)
        b.frame = NSRect(x: x, y: body.bounds.height - MessageBoxBody.bandHeight / 2 - 13, width: w, height: 26)
        body.addSubview(b)
        return b
    }

    /// Whether the box is closing because its confirm button was chosen.
    private var confirmed = false

    override func cancelOperation(_ sender: Any?) { close() }

    /// Cancel, Esc and the title bar's × all end here: unless confirmed, focus goes back to the app
    /// the jump list would have restored.
    override func close() {
        guard isVisible || TaskbarConfirmBox.current === self else { return }
        super.close()
        if TaskbarConfirmBox.current === self { TaskbarConfirmBox.current = nil }
        if !confirmed, NSApp.isActive, let app = cancelFocus, !app.isTerminated { app.activate() }
        cancelFocus = nil
    }

    @objc private func cancel(_ sender: Any?) { close() }

    @objc private func confirm(_ sender: Any?) {
        confirmed = true
        close()
        onConfirm()
    }
}

/// White over the grey `#F0F0F0` button band with a `#DFDFDF` line, the 32 pt warning icon and the
/// message, as Windows 7 message boxes draw them.
private final class MessageBoxBody: NSView {
    static let bandHeight: CGFloat = 46
    var message = ""
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        let band = NSRect(x: 0, y: bounds.height - Self.bandHeight, width: bounds.width, height: Self.bandHeight)
        NSColor(srgbRed: 0xF0 / 255, green: 0xF0 / 255, blue: 0xF0 / 255, alpha: 1).setFill()
        band.fill()
        NSColor(srgbRed: 0xDF / 255, green: 0xDF / 255, blue: 0xDF / 255, alpha: 1).setFill()
        NSRect(x: 0, y: band.minY, width: bounds.width, height: 1).fill()
        Self.drawWarningIcon(NSRect(x: 14, y: 16, width: 32, height: 32))
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        (message as NSString).draw(in: NSRect(x: 58, y: 16, width: bounds.width - 72, height: band.minY - 24),
                                   withAttributes: [.font: W7UIFont(12), .foregroundColor: NSColor.black, .paragraphStyle: style])
    }

    /// A yellow triangle with a black "!" (flipped view coordinates).
    private static func drawWarningIcon(_ r: NSRect) {
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: r.midX, y: r.minY + 2))
        tri.line(to: NSPoint(x: r.maxX - 1, y: r.maxY - 3))
        tri.line(to: NSPoint(x: r.minX + 1, y: r.maxY - 3))
        tri.close()
        tri.lineJoinStyle = .round
        NSGradient(starting: NSColor(srgbRed: 0xFF / 255, green: 0xE8 / 255, blue: 0x6B / 255, alpha: 1),
                   ending: NSColor(srgbRed: 0xF2 / 255, green: 0xB4 / 255, blue: 0x00 / 255, alpha: 1))?
            .draw(in: tri, angle: 90)
        NSColor(srgbRed: 0xA6 / 255, green: 0x7A / 255, blue: 0x00 / 255, alpha: 1).setStroke()
        tri.lineWidth = 1
        tri.stroke()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: r.midX - 1.5, y: r.minY + 11, width: 3, height: 11), xRadius: 1.5, yRadius: 1.5).fill()
        NSBezierPath(ovalIn: NSRect(x: r.midX - 1.75, y: r.maxY - 9, width: 3.5, height: 3.5)).fill()
    }
}
