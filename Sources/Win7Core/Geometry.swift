import CoreGraphics

public enum Win7 { public static let version = "0.1.0" }

/// AX coordinates are global with a top-left origin; AppKit's are bottom-left relative to the primary screen.
public enum Coordinates {
    public static func ax(fromAppKit r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
    public static func appKit(fromAX r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}

public enum SnapTarget: Equatable, Sendable { case leftHalf, rightHalf, maximize }
public enum Arrow: Sendable { case left, right, up, down }
public enum SnapAction: Equatable, Sendable { case snap(SnapTarget), restore, minimize }

/// All rects and points here are in AX (global, top-left) coordinates.
public enum SnapGeometry {
    private static func contains(_ r: CGRect, _ p: CGPoint) -> Bool {
        p.x >= r.minX && p.x < r.maxX && p.y >= r.minY && p.y < r.maxY
    }

    public static func target(cursor: CGPoint, screens: [CGRect]) -> (target: SnapTarget, screenIndex: Int)? {
        guard let index = screens.firstIndex(where: { contains($0, cursor) }) else { return nil }
        let s = screens[index]
        func free(_ p: CGPoint) -> Bool {
            !screens.enumerated().contains { $0.offset != index && contains($0.element, p) }
        }
        if cursor.x <= s.minX, free(CGPoint(x: cursor.x - 1, y: cursor.y)) { return (.leftHalf, index) }
        if cursor.x >= s.maxX - 1, free(CGPoint(x: cursor.x + 1, y: cursor.y)) { return (.rightHalf, index) }
        if cursor.y <= s.minY, free(CGPoint(x: cursor.x, y: cursor.y - 1)) { return (.maximize, index) }
        return nil
    }

    /// The area a snap fills: on the taskbar's screen exactly the work area the
    /// WorkAreaKeeper keeps windows in (`WorkArea.visible`), so a snapped window is never nudged; on
    /// another screen (`bar` nil) its visible frame. AX coordinates.
    public static func usableRect(screenVisible: CGRect, bar: CGRect?) -> CGRect {
        guard let bar else { return screenVisible }
        return WorkArea.visible(screenVisible: screenVisible, bar: bar)
    }

    public static func frame(for target: SnapTarget, usable: CGRect) -> CGRect {
        let half = (usable.width / 2).rounded(.down)
        switch target {
        case .maximize: return usable
        case .leftHalf: return CGRect(x: usable.minX, y: usable.minY, width: half, height: usable.height)
        case .rightHalf:
            return CGRect(x: usable.minX + half, y: usable.minY, width: usable.width - half, height: usable.height)
        }
    }

    /// A snapped window is title-bar-dragged out only when its size is untouched and its origin moved over 10 pt.
    /// A size change means a resize (or other manipulation), which must not restore.
    public static func shouldRestore(snapped: CGRect, current: CGRect) -> Bool {
        current.size == snapped.size && hypot(current.minX - snapped.minX, current.minY - snapped.minY) > 10
    }

    public static func keyboardAction(current: SnapTarget?, arrow: Arrow) -> SnapAction? {
        switch (current, arrow) {
        case (nil, .left): return .snap(.leftHalf)
        case (nil, .right): return .snap(.rightHalf)
        case (nil, .up): return .snap(.maximize)
        case (nil, .down): return .minimize
        case (.leftHalf, .left), (.rightHalf, .right), (.maximize, .up): return nil
        case (.leftHalf, .right), (.rightHalf, .left), (.maximize, .down): return .restore
        case (.leftHalf, .up), (.rightHalf, .up): return .snap(.maximize)
        case (.leftHalf, .down), (.rightHalf, .down): return .restore
        case (.maximize, .left): return .snap(.leftHalf)
        case (.maximize, .right): return .snap(.rightHalf)
        }
    }
}

public struct SnapMemory: Sendable {
    private var originals: [UInt32: CGRect] = [:]
    private var targets: [UInt32: SnapTarget] = [:]
    public init() {}
    /// Keeps the first remembered frame, so re-snapping a snapped window still restores to the true original.
    public mutating func remember(_ id: UInt32, frame: CGRect, snapped: SnapTarget) {
        if originals[id] == nil { originals[id] = frame }
        targets[id] = snapped
    }
    public func original(_ id: UInt32) -> CGRect? { originals[id] }
    public func current(_ id: UInt32) -> SnapTarget? { targets[id] }
    public mutating func forget(_ id: UInt32) { originals[id] = nil; targets[id] = nil }
}

/// Win+Shift+Up and Win+Shift+Left/Right. AX coordinates; `usable` rects exclude the taskbar.
public enum WindowMoves {
    /// Full usable height; x and width unchanged.
    public static func verticallyMaximized(_ frame: CGRect, usable: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: usable.minY, width: frame.width, height: usable.height)
    }

    /// The next (or previous) screen left to right, then top to bottom, wrapping around; nil with one screen.
    public static func neighborScreen(of index: Int, screens: [CGRect], forward: Bool) -> Int? {
        guard screens.count > 1, screens.indices.contains(index) else { return nil }
        let order = screens.indices.sorted { (screens[$0].minX, screens[$0].minY) < (screens[$1].minX, screens[$1].minY) }
        guard let at = order.firstIndex(of: index) else { return nil }
        return order[(at + (forward ? 1 : order.count - 1)) % order.count]
    }

    /// The frame at the same relative position and size in `to` as it had in `from`, in whole points.
    public static func frame(_ frame: CGRect, movedFrom from: CGRect, to: CGRect) -> CGRect {
        guard from.width > 0, from.height > 0 else { return frame }
        let sx = to.width / from.width, sy = to.height / from.height
        return CGRect(x: (to.minX + (frame.minX - from.minX) * sx).rounded(),
                      y: (to.minY + (frame.minY - from.minY) * sy).rounded(),
                      width: (frame.width * sx).rounded(), height: (frame.height * sy).rounded())
    }
}
