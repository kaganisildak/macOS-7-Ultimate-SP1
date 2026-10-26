import Foundation

// keyboard access for the shell's drawn Windows 7 controls (push buttons, drop-down lists, check boxes,
// links) and its drawn lists and grids: which key does what, the Tab order and arrow movement. AppKit-free; the
// shell's views read the key codes (Carbon's kVK_ values, spelled out here) and call these.

/// A key as the drawn controls understand it.
public enum ShellKey: Equatable, Sendable {
    case tab, backTab, space, enter, escape, up, down, left, right
    /// Alt+↓ (Option+↓) or F4: opens a drop-down list, as in Windows.
    case openList
    /// Cmd+A.
    case selectAll

    /// nil for keys the controls leave alone (and for Ctrl/Cmd combinations other than Cmd+A).
    public init?(keyCode: UInt16, shift: Bool, option: Bool, command: Bool, control: Bool) {
        if command {
            guard keyCode == 0x00, !shift, !option, !control else { return nil }   // kVK_ANSI_A
            self = .selectAll
            return
        }
        guard !control else { return nil }
        switch keyCode {
        case 0x30: self = shift ? .backTab : .tab                 // kVK_Tab
        case 0x31 where !option: self = .space                    // kVK_Space
        case 0x24 where !option, 0x4C where !option: self = .enter // kVK_Return, kVK_ANSI_KeypadEnter
        case 0x35: self = .escape                                 // kVK_Escape
        case 0x7B: self = .left
        case 0x7C: self = .right
        case 0x7D: self = option ? .openList : .down
        case 0x7E: self = .up
        case 0x76: self = .openList                               // kVK_F4
        default: return nil
        }
    }
}

public enum ShellControlKind: Sendable {
    case pushButton, checkBox, link, popUp
}

public enum ShellKeyAction: Equatable, Sendable {
    /// What a click does.
    case activate
    /// Opens a drop-down list's choices.
    case open
    /// Steps a closed drop-down list to the previous or next choice.
    case previous, next
}

public enum ShellKeyboard {
    /// Space and Return press buttons, check boxes and links; a drop-down list opens on Space, Return, Alt+↓ or F4
    /// and its arrows step the choice while it is closed.
    public static func action(_ key: ShellKey, for kind: ShellControlKind) -> ShellKeyAction? {
        switch (kind, key) {
        case (.pushButton, .space), (.pushButton, .enter), (.checkBox, .space), (.checkBox, .enter),
             (.link, .space), (.link, .enter):
            return .activate
        case (.popUp, .space), (.popUp, .enter), (.popUp, .openList): return .open
        case (.popUp, .up), (.popUp, .left): return .previous
        case (.popUp, .down), (.popUp, .right): return .next
        default: return nil
        }
    }

    /// A drop-down list's choice after `action` (it stops at either end).
    public static func stepped(_ index: Int, by action: ShellKeyAction, count: Int) -> Int {
        guard count > 0 else { return index }
        switch action {
        case .previous: return max(0, min(index, count) - 1)
        case .next: return min(count - 1, index + 1)
        default: return index
        }
    }

    /// Tab (or Shift-Tab) from stop `current`: the next stop that can take the focus, wrapping; the first (last)
    /// one when nothing has the focus; nil when none can.
    public static func nextFocus(from current: Int?, canFocus: [Bool], backward: Bool) -> Int? {
        let n = canFocus.count
        guard n > 0, canFocus.contains(true) else { return nil }
        let start: Int
        if let current, canFocus.indices.contains(current) { start = current } else { start = backward ? 0 : n - 1 }
        for step in 1...n {
            let i = ((start + (backward ? -step : step)) % n + n) % n
            if canFocus[i] { return i }
        }
        return nil
    }

    /// An arrow in a one-line list (a task pane: ↑/↓; a row of links: ←/→): the neighbouring entry, stopping at
    /// either end; the first entry when none has the focus; nil for keys of the other axis.
    public static func moveInList(_ key: ShellKey, from current: Int?, count: Int, vertical: Bool) -> Int? {
        guard count > 0 else { return nil }
        let back: ShellKey = vertical ? .up : .left, forward: ShellKey = vertical ? .down : .right
        guard key == back || key == forward else { return nil }
        guard let current, (0..<count).contains(current) else { return 0 }
        return key == back ? max(0, current - 1) : min(count - 1, current + 1)
    }

    /// An arrow in a grid of cells (centres in flipped coordinates, in reading order): ←/→ the previous or next
    /// cell in reading order, ↑/↓ the nearest cell of the row above or below (across group headers too); the first
    /// cell when none has the focus; nil for other keys.
    public static func moveInGrid(_ key: ShellKey, from current: Int?, centers: [CGPoint]) -> Int? {
        guard !centers.isEmpty, [.left, .right, .up, .down].contains(key) else { return nil }
        guard let current, centers.indices.contains(current) else { return 0 }
        switch key {
        case .left: return max(0, current - 1)
        case .right: return min(centers.count - 1, current + 1)
        default:
            let here = centers[current]
            let rows = centers.indices.filter { key == .up ? centers[$0].y < here.y - 0.5 : centers[$0].y > here.y + 0.5 }
            guard let rowY = (key == .up ? rows.map { centers[$0].y }.max() : rows.map { centers[$0].y }.min()) else { return current }
            let row = rows.filter { abs(centers[$0].y - rowY) <= 0.5 }
            return row.min { abs(centers[$0].x - here.x) < abs(centers[$1].x - here.x) } ?? current
        }
    }
}
