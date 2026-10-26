/// What happens to the power splash ("Logging off…" / "Shutting down…").
public enum PowerSplashEvent: Equatable, Sendable {
    /// Log off, Restart or Shut down was chosen.
    case start
    /// SessionSplashKind.minimumDuration passed: time to send the command.
    case minimumElapsed
    /// An app other than the shell became active (loginwindow's confirmation, a "Save changes?" sheet, a
    /// privacy prompt…). `terminated` when that app has already quit (activation races during logout).
    case otherAppActivated(terminated: Bool)
    /// NSWorkspace.willPowerOffNotification: the logout or shutdown is really going ahead.
    case willPowerOff
    /// The command reported failure.
    case commandFailed
    /// The timer armed last (armTimeout or armLinger) ran out.
    case timeout
}

/// Where the splash sits.
public enum PowerSplashLevel: Equatable, Sendable {
    /// Over everything (screen-saver level): only before the command is sent.
    case top
    /// Below alerts, panels and system prompts (modal panel − 1), above app windows.
    case belowAlerts
    /// Below normal windows (normal − 1), above the desktop icons: quitting apps' windows and their sheets
    /// ("Save changes?", Terminal's terminate sheet) at level 0 stay on top.
    case belowWindows
}

public enum PowerSplashEffect: Equatable, Sendable {
    case show(PowerSplashLevel)
    case hide
    case runCommand
    /// (Re)start the SessionSplashKind.failureTimeout cap.
    case armTimeout
    /// (Re)start the SessionSplashKind.lingerAfterDismiss wait for a late willPowerOff.
    case armLinger
    /// Stop observing for good: a later shutdown from elsewhere must not bring this splash back.
    case stopObserving
}

public enum PowerSplashPhase: Equatable, Sendable {
    case idle
    /// The first 1.2 s: on top of everything, nothing sent yet.
    case covering
    /// The command was sent; the splash sits below alerts until another app activates.
    case waiting
    /// Closed; for `lingerAfterDismiss` a willPowerOff still brings it back.
    case dismissed
    /// willPowerOff arrived: shown again below normal windows.
    case poweringOff
    /// Done; nothing brings it back.
    case finished
}

/// The power splash's state machine. The screen-saver level is used only before the command is sent;
/// after that the splash never covers system prompts or apps' sheets, closes when a live app activates,
/// and comes back only on willPowerOff within the linger time. Shown phases are capped by the failure
/// timeout.
public struct PowerSplashMachine: Sendable {
    public private(set) var phase: PowerSplashPhase = .idle

    public init() {}

    public mutating func handle(_ event: PowerSplashEvent) -> [PowerSplashEffect] {
        switch (phase, event) {
        case (.idle, .start):
            phase = .covering
            return [.show(.top), .armTimeout]
        case (.covering, .minimumElapsed):
            phase = .waiting
            return [.show(.belowAlerts), .runCommand]
        case (.covering, .timeout), (.waiting, .otherAppActivated), (.waiting, .commandFailed), (.waiting, .timeout),
             (.poweringOff, .otherAppActivated(terminated: false)), (.poweringOff, .commandFailed), (.poweringOff, .timeout):
            phase = .dismissed
            return [.hide, .armLinger]
        case (.waiting, .willPowerOff), (.dismissed, .willPowerOff):
            phase = .poweringOff
            return [.show(.belowWindows), .armTimeout]
        case (.dismissed, .timeout):
            phase = .finished
            return [.stopObserving]
        default:
            return []
        }
    }
}
