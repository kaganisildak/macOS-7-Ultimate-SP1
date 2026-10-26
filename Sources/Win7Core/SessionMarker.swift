import Foundation

/// Identifies a login session: the boot session UUID (`sysctl kern.bootsessionuuid`) plus the login time,
/// so something can happen once per login (not once per boot, and not again on a crash respawn).
public enum SessionMarker {
    /// "<uuid>|<login time in whole seconds>", or just the UUID without a login time; nil without a UUID.
    public static func marker(bootSessionUUID: String?, loginTime: Date?) -> String? {
        guard let uuid = bootSessionUUID, !uuid.isEmpty else { return nil }
        guard let loginTime else { return uuid }
        return "\(uuid)|\(Int(loginTime.timeIntervalSince1970.rounded(.down)))"
    }

    /// Only on the LaunchAgent's launch (W7_LOGIN=1), and only when this session hasn't had it yet.
    public static func shouldShow(isLoginLaunch: Bool, current: String?, lastShown: String?) -> Bool {
        guard isLoginLaunch, let current else { return false }
        return current != lastShown
    }
}

/// The full-screen Windows 7 session screens.
public enum SessionSplashKind: Sendable {
    case welcome, loggingOff, shuttingDown

    public var text: String {
        switch self {
        case .welcome: "Welcome"
        case .loggingOff: "Logging off…"
        case .shuttingDown: "Shutting down…"
        }
    }

    /// Log off, Restart and Shut down show a splash first; Restart says "Shutting down…" as Windows 7 does.
    public static func forPowerAction(_ action: PowerAction) -> SessionSplashKind? {
        switch action {
        case .logOff: .loggingOff
        case .shutDown, .restart: .shuttingDown
        case .sleep, .lock, .switchUser: nil
        }
    }

    /// The power splash shows at least this long before the action runs.
    public static let minimumDuration: TimeInterval = 1.2
    /// If the action fails or is cancelled, the power splash goes away after this long.
    public static let failureTimeout: TimeInterval = 10
    /// After the power splash closes, a willPowerOff within this long still shows it again; then it's done.
    public static let lingerAfterDismiss: TimeInterval = 15
}
