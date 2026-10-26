import AppKit
import Win7Core

/// Tracks regular GUI apps (excluding the shell) via NSWorkspace notifications.
@MainActor
final class RunningAppsObserver {
    var onChange: (() -> Void)?
    /// Fired when an app other than the shell becomes active.
    var onForeignActivation: (() -> Void)?

    private(set) var apps: [RunningApp] = []
    private var orderByPID: [Int32: Int] = [:]
    private var nextOrder = 0
    private var tokens: [NSObjectProtocol] = []
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    /// Launch order of the shell's own windows with a taskbar button (ShellWindowButtons).
    private var orderByShellWindow: [String: Int] = [:]

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in names {
            let isActivation = name == NSWorkspace.didActivateApplicationNotification
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated { self?.handle(activatedPID: isActivation ? pid : nil) }
            })
        }
        tokens.append(NotificationCenter.default.addObserver(forName: ShellWindowButtons.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(activatedPID: nil) }
        })
        refresh()
    }


    private func handle(activatedPID: Int32?) {
        refresh()
        onChange?()
        if let pid = activatedPID, pid != ownPID { onForeignActivation?() }
    }

    func refresh() {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID && $0.bundleIdentifier != nil }
            .sorted { ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture) }
        var live = Set<Int32>()
        apps = running.map { app in
            let pid = app.processIdentifier
            live.insert(pid)
            if orderByPID[pid] == nil { orderByPID[pid] = nextOrder; nextOrder += 1 }
            return RunningApp(bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? app.bundleIdentifier ?? "",
                              pid: pid, isActive: app.isActive, launchOrder: orderByPID[pid] ?? 0)
        }
        orderByPID = orderByPID.filter { live.contains($0.key) }
        // The shell's own windows that show in the taskbar (the Control Panel), as long as they are open.
        let shellWindows = ShellWindowButtons.runningApps(pid: ownPID) { id in
            if let order = orderByShellWindow[id] { return order }
            orderByShellWindow[id] = nextOrder
            nextOrder += 1
            return nextOrder - 1
        }
        orderByShellWindow = orderByShellWindow.filter { entry in shellWindows.contains { $0.bundleID == entry.key } }
        apps += shellWindows
    }

    /// Bundle IDs of apps that are currently visible (not hidden), for Show Desktop.
    func visibleBundleIDs() -> [String] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID && !$0.isHidden }
            .compactMap(\.bundleIdentifier)
            .filter { seen.insert($0).inserted }
    }
}
