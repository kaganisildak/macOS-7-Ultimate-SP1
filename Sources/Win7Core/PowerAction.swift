public enum PowerAction: CaseIterable, Sendable {
    case shutDown, restart, logOff, sleep, lock, switchUser

    /// Fast user switching's documented helper. It is gone from recent macOS releases, so the shell
    /// offers Switch user only when this file exists.
    public static let cgSessionPath = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"

    /// Data only; nothing here executes. `nil` means the shell handles it (lock posts Ctrl+Cmd+Q).
    public var command: [String]? {
        func system(_ verb: String) -> [String] { ["/usr/bin/osascript", "-e", "tell application \"System Events\" to \(verb)"] }
        switch self {
        case .shutDown: return system("shut down")
        case .restart: return system("restart")
        case .logOff: return system("log out")
        case .sleep: return ["/usr/bin/pmset", "sleepnow"]
        case .lock: return nil
        case .switchUser: return [PowerAction.cgSessionPath, "-suspend"]
        }
    }
}
