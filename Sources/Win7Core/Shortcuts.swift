import CoreGraphics

/// Windows-key shortcuts. A Mac keyboard has no Win key, and Command/Option shortcuts collide with
/// every app, so "Win" is Control+Option, as in the Ctrl+Option+arrows Snap shortcuts.

/// Hot-key modifiers; `carbonFlags` gives the `RegisterEventHotKey` mask.
public struct ShortcutModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let shift = ShortcutModifiers(rawValue: 1 << 1)
    public static let option = ShortcutModifiers(rawValue: 1 << 2)
    public static let control = ShortcutModifiers(rawValue: 1 << 3)
    /// The Windows key.
    public static let win: ShortcutModifiers = [.control, .option]

    /// Carbon's cmdKey, shiftKey, optionKey and controlKey (Events.h).
    public var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= 0x0100 }
        if contains(.shift) { flags |= 0x0200 }
        if contains(.option) { flags |= 0x0800 }
        if contains(.control) { flags |= 0x1000 }
        return flags
    }

    /// None of these modifiers is down in `flags` (e.g. `CGEventSource.flagsState`).
    public func isReleased(in flags: CGEventFlags) -> Bool {
        let masks: [(ShortcutModifiers, CGEventFlags)] =
            [(.command, .maskCommand), (.shift, .maskShift), (.option, .maskAlternate), (.control, .maskControl)]
        return !masks.contains { contains($0.0) && flags.contains($0.1) }
    }
}

/// A virtual key code (the ANSI layout's, as Carbon's kVK_* constants) plus modifiers.
public struct KeyCombo: Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: ShortcutModifiers
    public init(keyCode: UInt32, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode; self.modifiers = modifiers
    }
}

public enum ShortcutAction: Hashable, Sendable {
    case showDesktop, minimizeAll, restoreMinimized, openComputer, lock, run, minimizeOthers, peekDesktop
    /// Zero-based taskbar button index.
    case taskbarButton(Int)
    case focusTaskbar, verticalMaximize, previousScreen, nextScreen

    /// Moving or minimizing a chosen window needs Accessibility; without it the shell shows the
    /// permission balloon instead. Win+M has a no-Accessibility fallback (hiding apps).
    public var needsAccessibility: Bool {
        switch self {
        case .minimizeOthers, .verticalMaximize, .previousScreen, .nextScreen: return true
        default: return false
        }
    }

    /// Lasts while the key is held: it begins on key down and ends on key up.
    public var isHeld: Bool { self == .peekDesktop }
}

public struct Shortcut: Sendable {
    public var combo: KeyCombo
    public var action: ShortcutAction
    /// As Windows writes it, e.g. "Win+Shift+M".
    public var name: String
}

public enum Shortcuts {
    private enum Key {
        static let d: UInt32 = 2, m: UInt32 = 46, e: UInt32 = 14, l: UInt32 = 37, r: UInt32 = 15, t: UInt32 = 17
        static let digits: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]   // 1…9
        static let home: UInt32 = 115, space: UInt32 = 49, escape: UInt32 = 53, tab: UInt32 = 48
        static let left: UInt32 = 123, right: UInt32 = 124, down: UInt32 = 125, up: UInt32 = 126
    }

    private static func win(_ key: UInt32, shift: Bool = false, _ keyName: String, _ action: ShortcutAction) -> Shortcut {
        Shortcut(combo: KeyCombo(keyCode: key, modifiers: shift ? [.win, .shift] : .win), action: action,
                 name: "Win+" + (shift ? "Shift+" : "") + keyName)
    }

    public static let all: [Shortcut] = [
        win(Key.d, "D", .showDesktop),
        win(Key.m, "M", .minimizeAll),
        win(Key.m, shift: true, "M", .restoreMinimized),
        win(Key.e, "E", .openComputer),
        win(Key.l, "L", .lock),
        win(Key.r, "R", .run),
        win(Key.home, "Home", .minimizeOthers),
        win(Key.space, "Space", .peekDesktop),
        win(Key.t, "T", .focusTaskbar),
        win(Key.up, shift: true, "Up", .verticalMaximize),
        win(Key.left, shift: true, "Left", .previousScreen),
        win(Key.right, shift: true, "Right", .nextScreen),
    ] + Key.digits.enumerated().map { i, key in win(key, "\(i + 1)", .taskbarButton(i)) }

    /// Registered elsewhere: Start (Ctrl+Esc), Snap (Win+arrows) and the switcher (Option+Tab,
    /// Option+Shift+Tab, read by an event tap).
    public static let reserved: [KeyCombo] =
        [Key.left, Key.right, Key.up, Key.down].map { KeyCombo(keyCode: $0, modifiers: .win) } + [
            KeyCombo(keyCode: Key.escape, modifiers: .control),
            KeyCombo(keyCode: Key.tab, modifiers: .option),
            KeyCombo(keyCode: Key.tab, modifiers: [.option, .shift]),
        ]

    /// Ends Win+T's taskbar focus; registered only while that focus lasts.
    public static let escape = KeyCombo(keyCode: Key.escape, modifiers: [])

    public static func action(for combo: KeyCombo) -> ShortcutAction? {
        all.first { $0.combo == combo }?.action
    }
}
