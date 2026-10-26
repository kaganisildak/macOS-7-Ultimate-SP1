import AppKit
import Win7Core

/// One app's windows as the taskbar decides on them: CGWindowList (every window, on screen or not)
/// and, with Accessibility, the AX windows (nil without it).
struct AppWindows: Sendable {
    var cg: [CGWindowInfo]
    var ax: [AXWindowInfo]?

    var counts: WindowCounts { WindowList.counts(ax: ax, cg: cg) }
}

/// cached window snapshots, so hovering and clicking taskbar buttons does not run
/// CGWindowList and Accessibility IPC on the main thread each time.
///
/// - Per app (`AppWindows`): fetched on a background serial queue when a button is hovered
///   (`prefetch`), at most every 250 ms; a click uses the cached counts unless they are older than
///   1 s, and only then queries on the spot; the window popup takes a snapshot at most 250 ms old.
/// - On-screen windows of every app (the stacked look): fetched on the same queue on the stack timer
///   and on app launch/terminate/activate, at most every 250 ms.
/// App launch, termination, activation, hiding and unhiding invalidate everything: the next use
/// refetches. An action on one app's windows (a taskbar click, un-minimize, raise, a preview's ×)
/// invalidates that app with a 1 s hold-off (`invalidate(pid:)`), so the click after it queries on
/// the spot and decides on the new state.
@MainActor
final class WindowSnapshotStore {
    static let refreshInterval: TimeInterval = 0.25
    static let clickMaxAge: TimeInterval = 1.0

    /// Accessibility: AX windows are part of every snapshot (the 5 s permission poll sets it).
    var accessibilityTrusted = false {
        didSet { if accessibilityTrusted != oldValue { perApp.invalidateAll() } }
    }
    /// Delivered on the main actor after each on-screen snapshot: every pid's on-screen windows.
    var onScreenChange: (([Int32: [CGWindowInfo]]) -> Void)?
    /// The pid of the running app whose taskbar button is under the pointer, refetched after an
    /// invalidation so the click that follows still finds fresh counts.
    var hoveredPID: (() -> pid_t?)?

    private var perApp = SnapshotCache<pid_t, AppWindows>(minInterval: WindowSnapshotStore.refreshInterval)
    private var onScreen = SnapshotCache<Int, [Int32: [CGWindowInfo]]>(minInterval: WindowSnapshotStore.refreshInterval)
    private var waiters: [pid_t: [CheckedContinuation<AppWindows, Never>]] = [:]
    private let queue = DispatchQueue(label: "com.win7mac.shell.window-snapshots", qos: .userInitiated)
    private var tokens: [NSObjectProtocol] = []

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            // Never removed: the store lives as long as the shell (the app delegate holds it).
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appsChanged() }
            })
        }
    }

    private func appsChanged() {
        perApp.invalidateAll()
        onScreen.invalidate(0)
        refreshOnScreen()
        if let pid = hoveredPID?() { prefetch(pid: pid) }
    }

    /// After an action on `pid`'s windows: its cached windows are dropped, nothing fetched in the
    /// next `clickMaxAge` is served to a click (the action's effect may not show yet), and the stacked
    /// look is refetched.
    func invalidate(pid: pid_t) {
        perApp.invalidate(pid, holdOff: Self.clickMaxAge, now: now)
        onScreen.invalidate(0)
        refreshOnScreen()
    }

    // MARK: Per app

    /// Starts a background refresh of `pid`'s windows (a taskbar button is hovered), unless one ran
    /// in the last 250 ms or is running.
    func prefetch(pid: pid_t) {
        guard let ticket = perApp.beginRefresh(pid, now: now) else { return }
        fetch(ticket)
    }

    /// What a click decides on: the cached counts when at most 1 s old, else a query on the spot.
    func counts(pid: pid_t) -> WindowCounts {
        if let cached = perApp.value(pid, now: now, maxAge: Self.clickMaxAge) { return cached.counts }
        return ShellPerf.measure("windowCountsFresh") {
            let started = now
            let fresh = Self.query(pid: pid, ax: accessibilityTrusted)
            perApp.store(pid, fresh, takenAt: started)
            return fresh.counts
        }
    }

    /// A snapshot at most 250 ms old, fetched on the background queue when there is none.
    func windows(pid: pid_t) async -> AppWindows {
        if let cached = perApp.value(pid, now: now, maxAge: Self.refreshInterval) { return cached }
        return await withCheckedContinuation { c in
            waiters[pid, default: []].append(c)
            // nil: a refresh is already running; it serves this waiter too.
            if let ticket = perApp.beginRefresh(pid, now: now) { fetch(ticket) }
        }
    }

    private func fetch(_ ticket: SnapshotCache<pid_t, AppWindows>.Ticket) {
        let ax = accessibilityTrusted
        queue.async { [weak self] in
            let result = ShellPerf.measure("windowSnapshot") { Self.query(pid: ticket.key, ax: ax) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(ticket, result) }
            }
        }
    }

    private func finish(_ ticket: SnapshotCache<pid_t, AppWindows>.Ticket, _ result: AppWindows) {
        guard perApp.complete(ticket, with: result) else {
            // Voided by an invalidation: it may predate what changed. Waiters wait for a refresh
            // started after it (nil: one is already running and will serve them).
            if waiters[ticket.key]?.isEmpty == false, let next = perApp.beginRefresh(ticket.key, now: now) { fetch(next) }
            return
        }
        for w in waiters.removeValue(forKey: ticket.key) ?? [] { w.resume(returning: result) }
    }

    nonisolated static func query(pid: pid_t, ax: Bool) -> AppWindows {
        let info = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        return AppWindows(cg: CGWindowInfo.list(from: info, pid: pid), ax: ax ? WindowService.windowInfos(pid: pid) : nil)
    }

    // MARK: On-screen windows of every app

    /// Starts a background refresh of every app's on-screen windows, unless one ran in the last
    /// 250 ms or is running; `onScreenChange` gets the result.
    func refreshOnScreen() {
        guard let ticket = onScreen.beginRefresh(0, now: now) else { return }
        queue.async { [weak self] in
            let result = ShellPerf.measure("onScreenSnapshot") { () -> [Int32: [CGWindowInfo]] in
                let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                    as? [[String: Any]] ?? []
                return CGWindowInfo.byPID(from: info)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onScreen.complete(ticket, with: result)
                    self.onScreenChange?(result)
                }
            }
        }
    }
}
