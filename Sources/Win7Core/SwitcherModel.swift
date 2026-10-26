public struct SwitcherWindow: Equatable, Sendable {
    public var windowID: UInt32
    public var pid: Int32
    public var title: String
    public var appName: String

    public init(windowID: UInt32, pid: Int32, title: String, appName: String) {
        self.windowID = windowID
        self.pid = pid
        self.title = title
        self.appName = appName
    }
}

/// Selection state for the Alt-Tab switcher. Windows are given front-to-back, so the first
/// Tab lands on the previous window (index 1).
public struct SwitcherModel: Sendable {
    public let windows: [SwitcherWindow]
    public private(set) var index: Int

    /// `reverse` (Option+Shift+Tab) starts on the last window, as Windows does.
    public init(windows: [SwitcherWindow], reverse: Bool = false) {
        self.windows = windows
        if reverse { self.index = max(0, windows.count - 1) } else { self.index = windows.count >= 2 ? 1 : 0 }
    }

    public var selected: SwitcherWindow? { windows.indices.contains(index) ? windows[index] : nil }

    public mutating func next() {
        guard !windows.isEmpty else { return }
        index = (index + 1) % windows.count
    }

    public mutating func previous() {
        guard !windows.isEmpty else { return }
        index = (index - 1 + windows.count) % windows.count
    }
}
