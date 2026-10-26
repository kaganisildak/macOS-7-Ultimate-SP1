public enum SwitcherKeyEvent: Sendable, Equatable {
    case keyDown(code: Int64, option: Bool, shift: Bool, cmd: Bool, ctrl: Bool)
    case keyUp(code: Int64)
    case flagsChanged(option: Bool)
    case tapDisabled
}

public enum SwitcherAction: Sendable, Equatable {
    case open(reverse: Bool), next, previous, commit, cancel
}

/// Pure key-handling decisions for the Option+Tab switcher. Every swallowed keyDown gets exactly
/// one matching keyUp swallowed, so apps never see an unbalanced key-up.
public struct SwitcherKeyState: Sendable {
    public static let tab: Int64 = 48
    public static let esc: Int64 = 53

    public private(set) var isOpen = false
    /// Bumped on every open so a stale deferred open can be told apart from a newer one.
    public private(set) var generation = 0
    private var swallowed: Set<Int64> = []

    public init() {}

    public mutating func handle(_ e: SwitcherKeyEvent) -> (consume: Bool, action: SwitcherAction?) {
        switch e {
        case let .keyDown(code, option, shift, cmd, ctrl):
            if isOpen && !option {  // Option-up was lost: finish and let the key through
                isOpen = false
                return (false, .commit)
            }
            if code == Self.tab {
                if isOpen {
                    swallowed.insert(code)
                    return (true, shift ? .previous : .next)
                }
                if option && !cmd && !ctrl {
                    isOpen = true
                    generation += 1
                    swallowed.insert(code)
                    return (true, .open(reverse: shift))
                }
            } else if code == Self.esc && isOpen {
                isOpen = false
                swallowed.insert(code)
                return (true, .cancel)
            }
            return (false, nil)
        case let .keyUp(code):
            return (swallowed.remove(code) != nil, nil)
        case let .flagsChanged(option):
            if isOpen && !option {
                isOpen = false
                return (false, .commit)
            }
            return (false, nil)
        case .tapDisabled:
            guard isOpen else { return (false, nil) }
            isOpen = false
            return (false, .cancel)
        }
    }

    /// The deferred open found nothing to show; ignored if a newer open has started.
    public mutating func abortOpen(generation g: Int) {
        if g == generation { isOpen = false }
    }
}
