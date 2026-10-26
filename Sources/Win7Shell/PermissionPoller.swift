import ApplicationServices
import CoreGraphics
import Win7Core

/// The one 5 s permission poll. The app delegate's feature gate and the Action Center used
/// to run their own 5 s timers over the same two checks; now one timer reads both once per tick and
/// hands the result to every subscriber. The checks never prompt.
@MainActor
final class PermissionPoller {
    static let shared = PermissionPoller()
    static let interval: TimeInterval = 5

    private let gate = PermissionGate(
        isAXTrusted: { AXIsProcessTrusted() },
        hasScreenCapture: { CGPreflightScreenCaptureAccess() })
    private(set) var current: PermissionSnapshot
    private var subscribers: [(PermissionSnapshot) -> Void] = []
    private var timer: Timer?

    private init() { current = gate.snapshot() }

    /// Calls `handler` now with the current state and after every poll. Subscribers live as long as
    /// the shell (the app delegate and the tray's Action Center).
    func subscribe(_ handler: @escaping (PermissionSnapshot) -> Void) {
        subscribers.append(handler)
        handler(current)
        guard timer == nil else { return }
        // Common modes: the Action Center flag updates while a menu is tracking, as before.
        timer = Timer.w7Scheduled(Self.interval, repeats: true, mode: .common) { _ in
            MainActor.assumeIsolated { PermissionPoller.shared.poll() }
        }
    }

    private func poll() {
        current = ShellPerf.measure("permissionPoll") { gate.snapshot() }
        for s in subscribers { s(current) }
    }

    /// Both grants read now (not the last poll's state), without prompting.
    func liveSnapshot() -> PermissionSnapshot { gate.snapshot() }
}

/// asks for a missing grant with the system's own prompt, which only opens the matching System
/// Settings pane: `AXIsProcessTrustedWithOptions` with the prompt option and `CGRequestScreenCaptureAccess`.
/// The shell never grants anything and never touches TCC. Once per launch for any missing grant, and again
/// when the user chooses something that needs it (at most once per 60 s per grant,
/// `PermissionGate.shouldPrompt`); then the balloon says what to enable, with an "Open System Settings"
/// button. The 5 s poll itself never prompts.
@MainActor
final class PermissionPrompter {
    static let shared = PermissionPrompter()
    /// Shows the balloon for a grant (the app delegate's).
    var presentBalloon: ((PermissionKind) -> Void)?
    private var lastPromptAt: [PermissionKind: Date] = [:]

    private init() {}

    /// At launch: the system prompt for each missing grant, once; not again when a previous launch
    /// prompted less than 60 s ago (a KeepAlive respawn loop), kept in the shell's defaults.
    func launch(_ snapshot: PermissionSnapshot) {
        let now = Date()
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: PermissionGate.launchPromptDefaultsKey) as? Date
        guard PermissionGate.shouldPrompt(snapshot: snapshot, lastPromptAt: lastPromptAt.values.max(), now: now,
                                          trigger: .launch),
              PermissionGate.shouldPromptAtLaunch(snapshot: snapshot, previousLaunchPromptAt: previous, now: now)
        else { return }
        defaults.set(now, forKey: PermissionGate.launchPromptDefaultsKey)
        for kind in [PermissionKind.accessibility, .screenCapture] where snapshot.missing.contains(kind) { prompt(kind) }
    }

    /// The user chose something that needs `kind`. Returns whether it was missing and the user was asked
    /// (system prompt and balloon) now.
    @discardableResult
    func needed(_ kind: PermissionKind) -> Bool {
        let now = Date()
        guard PermissionGate.shouldPrompt(snapshot: PermissionPoller.shared.liveSnapshot(), lastPromptAt: lastPromptAt[kind],
                                          now: now, trigger: .use(kind)) else { return false }
        prompt(kind)
        presentBalloon?(kind)
        return true
    }

    private func prompt(_ kind: PermissionKind) {
        lastPromptAt[kind] = Date()
        switch kind {
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .screenCapture:
            _ = CGRequestScreenCaptureAccess()
        }
    }
}
