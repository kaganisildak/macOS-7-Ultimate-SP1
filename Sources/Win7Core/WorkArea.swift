import CoreGraphics
import Foundation

/// Why a window must be left where it is, whatever its overlap with the taskbar.
public struct WorkAreaFlags: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// A native fullscreen window (its own Space; the bar does not cover it there).
    public static let fullscreen = WorkAreaFlags(rawValue: 1 << 0)
    /// A sheet, panel or dialog: anything but a standard window.
    public static let sheetOrPanel = WorkAreaFlags(rawValue: 1 << 1)
    /// One of the shell's own windows.
    public static let shellOwned = WorkAreaFlags(rawValue: 1 << 2)
    /// The left mouse button is down: the user may be dragging or resizing; never fight that.
    public static let userDragging = WorkAreaFlags(rawValue: 1 << 3)
}

/// Windows 7's work area: app windows are kept out of the taskbar band.
/// All rects are AX coordinates (global, top-left origin), as the shell's window service reads them.
public enum WorkArea {
    /// Overlaps under this are an app's rounding, not a window under the bar (no endless nudging).
    public static let tolerance: CGFloat = 0.5

    /// The area windows may use on the bar's screen: the screen's visible frame (menu bar and any
    /// Dock already off) ending at the bar's top edge.
    public static func visible(screenVisible: CGRect, bar: CGRect) -> CGRect {
        let maxY = min(screenVisible.maxY, bar.minY)
        return CGRect(x: screenVisible.minX, y: screenVisible.minY,
                      width: screenVisible.width, height: max(0, maxY - screenVisible.minY))
    }

    /// Where a window that reaches into the taskbar band should go, or nil when nothing is to be done.
    ///
    /// - Any flag: nil.
    /// - Only a window that overlaps the bar horizontally, reaches below the bar's top edge by more
    ///   than `tolerance`, and whose top edge is above the bar's bottom edge (so a window on a display
    ///   below this one is left alone) is adjusted.
    /// - A window no taller than `visible` moves up by the overlap (never above `visible.minY`); its
    ///   size is kept. A taller one is clamped: origin at `visible.minY`, height `visible.height`.
    ///   x and width never change.
    public static func adjusted(frame: CGRect, visible: CGRect, bar: CGRect, flags: WorkAreaFlags) -> CGRect? {
        guard flags.isEmpty, !bar.isEmpty, !visible.isEmpty, !frame.isEmpty else { return nil }
        guard frame.maxX > bar.minX, frame.minX < bar.maxX else { return nil }
        guard frame.minY < bar.maxY else { return nil }
        let overlap = frame.maxY - bar.minY
        guard overlap > tolerance else { return nil }
        if frame.height > visible.height + tolerance {
            return CGRect(x: frame.minX, y: visible.minY, width: frame.width, height: visible.height)
        }
        let y = max(visible.minY, frame.minY - overlap)
        return CGRect(x: frame.minX, y: y, width: frame.width, height: frame.height)
    }
}

/// What the WorkAreaKeeper remembers about one app's windows, so it never fights an app:
/// - a frame is looked at once (`shouldLook` / `noteLooked`), and a frame the keeper moved a window
///   FROM is never adjusted again (an app that restores its saved bounds is tried once);
/// - at most `maxMoves` moves per window per `moveWindow` seconds (`canMove` / `noteMoved`);
/// - past `capacity` windows the memory is cleared (a long-lived app opening and closing windows);
///   the cost is one more look per window.
public struct WorkAreaMemory: Sendable {
    public static let maxMoves = 2
    public static let moveWindow: TimeInterval = 10
    public static let capacity = 256
    /// Frames moved from, kept per window (the latest ones).
    static let movedFromLimit = 8

    private struct Entry: Sendable {
        var lastFrame: CGRect?
        var movedFrom: [CGRect] = []
        var moves: [TimeInterval] = []
    }
    private var entries: [UInt32: Entry] = [:]

    public init() {}

    /// Windows remembered.
    public var count: Int { entries.count }

    /// Whether a window settled at `frame` is worth looking at: not the frame it was last looked at
    /// (or left at), and not a frame the keeper already moved it from.
    public func shouldLook(id: UInt32, frame: CGRect) -> Bool {
        guard let e = entries[id] else { return true }
        return e.lastFrame != frame && !e.movedFrom.contains(frame)
    }

    public mutating func noteLooked(id: UInt32, frame: CGRect) {
        if entries[id] == nil, entries.count >= Self.capacity { entries = [:] }
        entries[id, default: Entry()].lastFrame = frame
    }

    /// The screens changed (a resolution change): every window is worth one more look in the new
    /// work area. Frames the keeper moved windows from, and the recent moves, are kept.
    public mutating func forgetLooks() {
        for id in entries.keys { entries[id]?.lastFrame = nil }
    }

    /// Fewer than `maxMoves` moves of this window in the last `moveWindow` seconds (`now`: uptime).
    public func canMove(id: UInt32, now: TimeInterval) -> Bool {
        (entries[id]?.moves.filter { now - $0 < Self.moveWindow }.count ?? 0) < Self.maxMoves
    }

    /// The keeper moved the window from `from`; the app left it at `to`.
    public mutating func noteMoved(id: UInt32, from: CGRect, to: CGRect, now: TimeInterval) {
        if entries[id] == nil, entries.count >= Self.capacity { entries = [:] }
        var e = entries[id] ?? Entry()
        e.movedFrom = Array((e.movedFrom + [from]).suffix(Self.movedFromLimit))
        e.moves = e.moves.filter { now - $0 < Self.moveWindow } + [now]
        e.lastFrame = to
        entries[id] = e
    }
}

/// The shell's window levels (raw `CGWindowLevel` values), shared by the windows and the tests so the
/// order is pinned: the taskbar sits at the Dock's level, above app windows (0), floating palettes (3)
/// and modal panels (8) and below the Dock-level system UI that comes later (the screenshot thumbnail)
/// and the menu bar; every popup the shell opens from the bar sits above it.
public enum ShellWindowLevels {
    /// `legacy` (defaults `W7TaskbarLevelLegacy`): the old `.statusBar` level (25).
    public static func taskbar(legacy: Bool) -> Int {
        Int(CGWindowLevelForKey(legacy ? .statusWindow : .dockWindow))
    }

    private static let statusBar = Int(CGWindowLevelForKey(.statusWindow))
    private static let popUpMenu = Int(CGWindowLevelForKey(.popUpMenuWindow))

    public static let startMenu = popUpMenu
    public static let trayFlyout = popUpMenu
    public static let jumpList = statusBar + 1
    public static let thumbnailPopup = statusBar + 1
    public static let switcher = Int(CGWindowLevelForKey(.screenSaverWindow))
    public static let snapPreview = statusBar
    public static let permissionBalloon = statusBar

    /// Every shell window that must open above the taskbar, by name.
    public static let aboveTaskbar: [(name: String, level: Int)] = [
        ("start menu", startMenu), ("tray flyout", trayFlyout), ("jump list", jumpList),
        ("thumbnail popup", thumbnailPopup), ("switcher", switcher), ("snap preview", snapPreview),
        ("permission balloon", permissionBalloon),
    ]
}
