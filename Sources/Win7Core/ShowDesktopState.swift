public enum ShowDesktopAction: Equatable, Sendable { case hide([String]), unhide([String]) }

public struct ShowDesktopState: Sendable {
    private var hidden: [String]?
    public init() {}

    /// First call hides `visibleApps` and remembers them; the next call restores exactly those.
    public mutating func toggle(visibleApps: [String]) -> ShowDesktopAction {
        if let h = hidden {
            hidden = nil
            return .unhide(h)
        }
        hidden = visibleApps
        return .hide(visibleApps)
    }

    public mutating func reset() { hidden = nil }
}
