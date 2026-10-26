import CoreGraphics

public enum WindowPopupStyle: Equatable, Sendable { case thumbnails, list }

/// Geometry of the taskbar window popup's list style (Windows 7 Basic: vertical rows of a 16 pt
/// app icon and the window title). Coordinates are AppKit's (bottom-left origin); row 0 is on top.
public enum WindowPopupLayout {
    public static let pad: CGFloat = 8
    public static let rowHeight: CGFloat = 24
    public static let iconSize: CGFloat = 16
    public static let listWidth: CGFloat = 260

    /// Thumbnails when at least one window has an image; otherwise the list.
    public static func style<Image>(for entries: [WindowListEntry<Image>]) -> WindowPopupStyle {
        entries.contains { $0.image != nil } ? .thumbnails : .list
    }

    public static func listSize(rows: Int) -> CGSize {
        CGSize(width: listWidth, height: CGFloat(rows) * rowHeight + pad * 2)
    }

    /// How many rows fit in `availableHeight` (at least one when there is any entry).
    public static func listRowCount(entries: Int, availableHeight: CGFloat) -> Int {
        guard entries > 0 else { return 0 }
        let fit = Int(((availableHeight - pad * 2) / rowHeight).rounded(.down))
        return min(entries, max(1, fit))
    }

    public static func listRowRect(_ i: Int, rows: Int) -> CGRect {
        CGRect(x: pad, y: pad + CGFloat(rows - 1 - i) * rowHeight, width: listWidth - pad * 2, height: rowHeight)
    }

    public static func listRow(at p: CGPoint, rows: Int) -> Int? {
        (0..<rows).first { listRowRect($0, rows: rows).contains(p) }
    }
}

public enum WindowPopupMode: Equatable, Sendable {
    /// Opened by hovering a taskbar button; closes shortly after the pointer leaves.
    case hover
    /// Opened by clicking a button with several windows; stays until a choice, an outside click,
    /// Esc, or another click on the same button.
    case pinned
}

public enum WindowPopupEvent: Equatable, Sendable {
    case hoverRequested(pid: Int32)
    case buttonClicked(pid: Int32)
    case mouseEntered, mouseExited
    /// The pointer left the taskbar button that opened the popup.
    case hoverEnded
    case closeTimerFired
    /// A click in the taskbar window, or the Start hot key (reported as `.control`).
    case clickedInTaskbar(TaskbarClickTarget)
    /// A click in another of the shell's windows (the desktop, a flyout). That window takes focus:
    /// the desktop makes itself key, and its context menu activates the shell, as on Windows 7,
    /// where clicking the desktop focuses the desktop.
    case clickedInShell
    /// A click in another app, which activates itself.
    case clickedInOtherApp
    /// The windows were fetched and there was nothing to show.
    case nothingToShow
    case escape, selected
}

public enum TaskbarMouseButton: Equatable, Sendable {
    case left, right
    /// Button number 2.
    case middle
    /// Any further button (back/forward and the like), which the taskbar ignores.
    case other
}

/// The part of the taskbar under a point.
public enum TaskbarHit: Equatable, Sendable {
    case button, orb, showDesktop, tray
    /// The overflow paging arrows.
    case pager
    /// Bare taskbar.
    case bare

    /// Whether a click with `mouse` here runs a handler, which then decides focus itself. Left:
    /// every control. Right: a button (its jump list), the orb (its menu), the tray (its menus), and
    /// bare taskbar or the pager (the taskbar menu); Show Desktop has none. Middle: only a button
    /// (a new window, or a launch). Other buttons: nothing.
    public func handles(_ mouse: TaskbarMouseButton) -> Bool {
        switch mouse {
        case .left: return self != .bare
        case .right: return self != .showDesktop
        case .middle: return self == .button
        case .other: return false
        }
    }
}

/// What a click in the taskbar window hit, as far as the window popup is concerned.
public enum TaskbarClickTarget: Equatable, Sendable {
    /// A left click on the button that opened the popup: that button toggles it.
    case anchor
    /// A click whose handler acts (another button, the orb, Show Desktop, the tray, a right click
    /// that opens a menu or jump list, including on the anchor): the handler decides focus.
    case control
    /// A click that does nothing (bare taskbar with the left button, Show Desktop with the right,
    /// anything but a button with the middle): like Esc.
    case empty

    public static func classify(_ mouse: TaskbarMouseButton, at point: CGPoint, anchor: CGRect, hit: TaskbarHit) -> TaskbarClickTarget {
        if mouse == .left && anchor.contains(point) { return .anchor }
        return hit.handles(mouse) ? .control : .empty
    }
}

/// What happens to the app that was frontmost before a pinned popup activated the shell.
public enum WindowPopupFocus: Equatable, Sendable {
    /// Nothing else takes focus: give it back to that app, then forget it.
    case restore
    /// Something else takes focus (the chosen window's app, a clicked app or shell window): forget it.
    case release
    /// Leave focus alone: the taskbar's own click handler decides it (menu, Start, a new list), or
    /// no restore is owed. The app stays remembered, so a list a taskbar click opens next still
    /// restores it; the shell forgets it as soon as any other app is activated.
    case keep
}

public enum WindowPopupResponse: Equatable, Sendable {
    case ignore, show(WindowPopupMode), pin, scheduleClose, cancelClose
    case close(WindowPopupFocus)
}

/// When the taskbar window popup opens, stays and closes.
public struct WindowPopupDismissal: Sendable {
    public private(set) var mode: WindowPopupMode?
    private var pid: Int32?
    /// A pinned popup activated the shell and nothing has settled focus since: closing without a
    /// choice gives it back. Survives a hover popup replacing the pinned one; a taskbar click, a
    /// choice, a click elsewhere or a restore settles it. While it is true the shell must report
    /// every click in its windows (and the Start hot key) even in hover mode, or a later close
    /// timer would restore focus over whatever that click opened.
    public private(set) var restoreOwed = false

    public init() {}

    /// Resets to closed with nothing owed. Every close path ends here; the shell also calls it
    /// for closes it decides itself (another button's click).
    public mutating func closed() { mode = nil; pid = nil; restoreOwed = false }

    /// Closes, restoring focus only if a pinned popup still owes it.
    private mutating func closeOwed() -> WindowPopupResponse {
        let focus: WindowPopupFocus = restoreOwed ? .restore : .keep
        closed()
        return .close(focus)
    }

    public mutating func handle(_ event: WindowPopupEvent) -> WindowPopupResponse {
        switch event {
        case .hoverRequested(let p):
            if mode == .pinned && pid == p { return .ignore }
            mode = .hover; pid = p
            return .show(.hover)
        case .buttonClicked(let p):
            if pid == p && mode == .pinned { return closeOwed() }
            restoreOwed = true
            if pid == p && mode == .hover { mode = .pinned; return .pin }
            mode = .pinned; pid = p
            return .show(.pinned)
        case .mouseEntered:
            return mode == .hover ? .cancelClose : .ignore
        case .mouseExited, .hoverEnded:
            return mode == .hover ? .scheduleClose : .ignore
        case .closeTimerFired:
            guard mode == .hover else { return .ignore }
            return closeOwed()
        case .clickedInTaskbar(let target):
            guard mode != nil else { return .ignore }
            switch target {
            case .anchor: return .ignore
            case .control: closed(); return .close(.keep)
            case .empty: return closeOwed()
            }
        case .clickedInShell, .clickedInOtherApp:
            guard mode != nil else { return .ignore }
            closed(); return .close(.release)
        case .nothingToShow:
            return closeOwed()
        case .escape:
            guard mode != nil else { return .ignore }
            return closeOwed()
        case .selected:
            closed(); return .close(.release)
        }
    }
}
