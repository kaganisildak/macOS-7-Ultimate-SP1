import AppKit
import ApplicationServices
import os
import Win7Core
import Win7ChromeCore

/// A jump list's "Close window" / "Close all windows".
///
/// When the dylib is in the app (`isDecorated`), the app is asked through the close channel
/// (`com.win7mac.closeWindow.<pid>` / `com.win7mac.closeAllWindows.<pid>`, no userInfo): it closes its
/// windows with performClose: and exits when none is left (never Finder), acknowledging with
/// `com.win7mac.closeHandled.<pid>`. When neither the acknowledgement nor a drop in the window count
/// arrives within 0.7 s, the undecorated path runs: Accessibility when trusted, else the hint or the
/// confirmation. After its own Accessibility closes the shell quits the app when, 1 s later, it has no
/// window left (`JumpList.shouldTerminate`), so undecorated apps exit as in Windows 7 too. "No window"
/// means neither Accessibility nor CGWindowList `.optionAll` (every Space) sees one.
///
/// One log line per request (subsystem com.win7mac.shell, category close): action, effect, decorated,
/// trusted, windows before → after, acknowledged, fallback, the AXError of each press, whether the shell
/// quit the app. No window titles.
@MainActor
final class TaskbarCloseRequest: NSObject {
    static let log = Logger(subsystem: "com.win7mac.shell", category: "close")
    static let askAppWait: TimeInterval = 0.7
    static let exitCheckDelay: TimeInterval = 1.0
    /// Requests waiting for their timers; each removes itself when it has logged.
    private static var inFlight: [TaskbarCloseRequest] = []

    /// Whether the dylib runs in the app with the close channel on: the dylib's own eligibility rule
    /// (W7ShouldLoadInProcess: not denylisted, not the shell, not an agent or background app, chrome not
    /// switched off) on the app's Info.plist, and `W7CloseChannelDisabled` not set. The global defaults
    /// domain is in the shell's search list, so these read what the dylib reads.
    static func isDecorated(bundleID: String, app: NSRunningApplication? = nil) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "W7CloseChannelDisabled") { return false }
        let running = app ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        let info = running?.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary }
        let extra = defaults.array(forKey: "W7ChromeDenylist") as? [String] ?? []
        return W7ShouldLoadInProcess(bundleID, info, extra, defaults.bool(forKey: "W7ChromeDisabled"))
    }

    /// The app's windows as the taskbar counts them (CGWindowList; with Accessibility its minimized
    /// windows too).
    static func windowCount(pids: [pid_t], ax: Bool) -> Int {
        pids.reduce(0) { $0 + WindowSnapshotStore.query(pid: $1, ax: ax).counts.total }
    }

    static func start(_ action: JumpListAction, item: TaskbarItem, previous: NSRunningApplication?,
                      onActed: @escaping @MainActor () -> Void) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID).filter { !$0.isTerminated }
        let trusted = TaskbarWindowActions.isTrusted
        let decorated = isDecorated(bundleID: item.bundleID, app: apps.first)
        guard let effect = JumpList.closeEffect(action, accessibility: trusted, decorated: decorated) else { return }
        let request = TaskbarCloseRequest(action: action, item: item, apps: apps, previous: previous, trusted: trusted,
                                          decorated: decorated, effect: effect, onActed: onActed)
        inFlight.append(request)
        if effect == .askApp { request.askApp() } else { request.perform(effect) }
    }

    private let action: JumpListAction
    private let item: TaskbarItem
    private let apps: [NSRunningApplication]
    private let previous: NSRunningApplication?
    private let trusted: Bool
    private let decorated: Bool
    private let effect: JumpListCloseEffect
    private let onActed: @MainActor () -> Void
    private let before: Int
    private var after: Int?
    private var acknowledged = false
    private var fallback: JumpListCloseEffect?
    private var presses: [AXError] = []
    private var terminated = false
    private var observing = false

    private var pids: [pid_t] { apps.map(\.processIdentifier) }

    private init(action: JumpListAction, item: TaskbarItem, apps: [NSRunningApplication], previous: NSRunningApplication?,
                 trusted: Bool, decorated: Bool, effect: JumpListCloseEffect, onActed: @escaping @MainActor () -> Void) {
        self.action = action; self.item = item; self.apps = apps; self.previous = previous
        self.trusted = trusted; self.decorated = decorated; self.effect = effect; self.onActed = onActed
        self.before = Self.windowCount(pids: apps.map(\.processIdentifier), ax: trusted)
        super.init()
    }

    // MARK: Asking the app

    private func askApp() {
        let request: W7CloseRequest = action == .closeAllWindows ? .allWindows : .window
        // "Close window" is one window: the app's first process; "Close all windows" asks every process.
        let targets = action == .closeAllWindows ? pids : Array(pids.prefix(1))
        let center = DistributedNotificationCenter.default()
        for pid in targets {
            center.addObserver(self, selector: #selector(acknowledgement(_:)),
                               name: NSNotification.Name(W7CloseChannelAckName(pid)), object: nil,
                               suspensionBehavior: .deliverImmediately)
        }
        observing = true
        // A save sheet the app brings up may then take focus (the jump list hands focus back meanwhile).
        if let app = apps.first { NSApp.yieldActivation(to: app) }
        for pid in targets {
            center.postNotificationName(NSNotification.Name(W7CloseChannelNotificationName(request, pid)), object: nil,
                                        userInfo: nil, deliverImmediately: true)
        }
        onActed()
        Timer.w7Scheduled(Self.askAppWait, repeats: false) { [self] _ in
            MainActor.assumeIsolated { self.checkAnswer() }
        }
    }

    /// Delivered on the main thread (the run loop the observer was added on).
    @objc nonisolated private func acknowledgement(_ note: Notification) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { acknowledged = true }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.acknowledged = true } }
        }
    }

    private func stopObserving() {
        guard observing else { return }
        DistributedNotificationCenter.default().removeObserver(self)
        observing = false
    }

    private func checkAnswer() {
        stopObserving()
        let count = Self.windowCount(pids: pids, ax: trusted)
        after = count
        let fallback = JumpList.closeFallback(action, acknowledged: acknowledged, windowsBefore: before,
                                              windowsAfter: count, accessibility: TaskbarWindowActions.isTrusted)
        self.fallback = fallback
        if let fallback { perform(fallback) } else { finish() }
    }

    // MARK: The undecorated path

    private func perform(_ effect: JumpListCloseEffect) {
        switch effect {
        case .closeFrontWindow:
            presses = TaskbarWindowActions.closeFrontWindow(pids: pids)
            onActed()
        case .closeEachWindow:
            presses = TaskbarWindowActions.closeAllWindows(pids: pids)
            onActed()
        case .hintAccessibility:
            CloseWindowHint.shared.needed()
        case .confirmQuit:
            let name = item.name, bundleID = item.bundleID
            TaskbarConfirmBox.present(
                title: name,
                message: "Close all windows of \(name)? Without the Accessibility permission the windows can only be closed by quitting \(name).",
                confirm: "Quit", cancelFocus: previous) {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { app.terminate() }
            }
        case .askApp:
            break
        }
        guard JumpList.shellChecksExit(after: effect) else { finish(); return }
        Timer.w7Scheduled(Self.exitCheckDelay, repeats: false) { [self] _ in
            MainActor.assumeIsolated { self.checkExit() }
        }
    }

    /// The app's document windows on every Space (CGWindowList `.optionAll`, on screen or not), which
    /// Accessibility does not list beyond the current Space.
    static func allSpacesWindowCount(pids: [pid_t]) -> Int {
        let info = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        return pids.reduce(0) { $0 + WindowList.eligibleCount(CGWindowInfo.list(from: info, pid: $1)) }
    }

    /// `W7CloseKeepAlive` (global defaults; the dylib reads the same key).
    static var keepAlive: [String] {
        JumpList.keepAlive(fromDefaultsValue: UserDefaults.standard.object(forKey: JumpList.keepAliveDefaultsKey))
    }

    /// Windows 7 exits a program whose last window was closed from the taskbar (never Finder or a
    /// W7CloseKeepAlive app). Both counts must be 0: a window on another Space keeps the app running.
    private func checkExit() {
        let left = JumpList.windowsLeft(ax: Self.windowCount(pids: pids, ax: TaskbarWindowActions.isTrusted),
                                        cg: Self.allSpacesWindowCount(pids: pids))
        after = left
        if JumpList.shouldTerminate(bundleID: item.bundleID, windowsLeft: left, keepAlive: Self.keepAlive) {
            for app in apps where !app.isTerminated { app.terminate() }
            terminated = true
            onActed()
        }
        finish()
    }

    private func finish() {
        stopObserving()
        let line = Self.describe(action: action, effect: effect, decorated: decorated, trusted: trusted, before: before,
                                 after: after, acknowledged: effect == .askApp ? acknowledged : nil,
                                 fallback: fallback, presses: presses, terminated: terminated)
        Self.log.notice("\(line, privacy: .public)")
        Self.inFlight.removeAll { $0 === self }
    }

    /// The log line (no titles, no bundle ids).
    static func describe(action: JumpListAction, effect: JumpListCloseEffect, decorated: Bool, trusted: Bool, before: Int,
                         after: Int?, acknowledged: Bool?, fallback: JumpListCloseEffect?, presses: [AXError],
                         terminated: Bool) -> String {
        func yn(_ b: Bool) -> String { b ? "yes" : "no" }
        let ack = acknowledged.map(yn) ?? "-"
        let press = presses.map { String($0.rawValue) }.joined(separator: ",")
        return "close request: action=\(action) effect=\(effect) decorated=\(yn(decorated)) trusted=\(yn(trusted)) "
            + "windows=\(before)->\(after.map(String.init) ?? "?") ack=\(ack) fallback=\(fallback.map { "\($0)" } ?? "none") "
            + "presses=[\(press)] terminated=\(yn(terminated))"
    }
}
