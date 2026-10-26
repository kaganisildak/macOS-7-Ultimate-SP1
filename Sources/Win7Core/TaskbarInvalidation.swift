import CoreGraphics

/// A part of the taskbar that draws differently while the pointer is over it.
public enum TaskbarHoverTarget: Hashable, Sendable {
    case orb
    case button(Int)
    case showDesktop
    /// 0: the up paging arrow, 1: the down one.
    case pageArrow(Int)
}

/// What the pointer is over on the taskbar.
public struct TaskbarHover: Equatable, Sendable {
    public var button: Int?
    public var orb: Bool
    public var showDesktop: Bool
    public var arrow: Int?

    public init(button: Int? = nil, orb: Bool = false, showDesktop: Bool = false, arrow: Int? = nil) {
        self.button = button; self.orb = orb; self.showDesktop = showDesktop; self.arrow = arrow
    }

    public var targets: Set<TaskbarHoverTarget> {
        var s = Set<TaskbarHoverTarget>()
        if let button { s.insert(.button(button)) }
        if orb { s.insert(.orb) }
        if showDesktop { s.insert(.showDesktop) }
        if let arrow { s.insert(.pageArrow(arrow)) }
        return s
    }

    /// The targets that went hot or cold.
    public static func changedTargets(from old: TaskbarHover, to new: TaskbarHover) -> Set<TaskbarHoverTarget> {
        old.targets.symmetricDifference(new.targets)
    }
}

public enum TaskbarInvalidation {
    /// The rects to redraw for a hover change: the rect of every target that went hot or cold.
    /// `rect` returns nil for a target that is not on screen (a paging arrow without overflow).
    public static func dirtyRects(from old: TaskbarHover, to new: TaskbarHover,
                                  rect: (TaskbarHoverTarget) -> CGRect?) -> [CGRect] {
        TaskbarHover.changedTargets(from: old, to: new).compactMap(rect)
    }
}

/// Everything a taskbar button's background drawing depends on: the key of its cached image.
public struct TaskbarButtonLook: Hashable, Sendable {
    public struct RGBA: Hashable, Sendable {
        public var r: UInt8, g: UInt8, b: UInt8, a: UInt8
        public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) { self.r = r; self.g = g; self.b = b; self.a = a }
    }

    public let running: Bool
    public let active: Bool
    public let hover: Bool
    /// The stacked edges behind a running button: 0, 1 (two windows) or 2 (three or more).
    public let stackDepth: Int
    /// The hot-track glow; only a hovered button draws it.
    public let glow: RGBA?
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(running: Bool, active: Bool, hover: Bool, windows: Int, glow: RGBA?, size: CGSize, scale: CGFloat) {
        self.running = running
        self.active = active
        self.hover = hover
        stackDepth = running ? min(2, max(0, windows - 1)) : 0
        self.glow = hover ? glow : nil
        pixelWidth = Int((size.width * scale).rounded())
        pixelHeight = Int((size.height * scale).rounded())
    }

    /// The window count that draws this look's stack.
    public var windows: Int { stackDepth + 1 }
}
