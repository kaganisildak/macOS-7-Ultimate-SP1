import Foundation
import CoreGraphics

public struct PinnedApp: Codable, Equatable, Sendable {
    public var bundleID: String
    public var name: String
    public init(bundleID: String, name: String) { self.bundleID = bundleID; self.name = name }
}

public struct RunningApp: Equatable, Sendable {
    public var bundleID: String
    public var name: String
    public var pid: Int32
    public var isActive: Bool
    public var launchOrder: Int
    public init(bundleID: String, name: String, pid: Int32, isActive: Bool, launchOrder: Int) {
        self.bundleID = bundleID; self.name = name; self.pid = pid; self.isActive = isActive; self.launchOrder = launchOrder
    }
}

public struct TaskbarItem: Equatable, Sendable {
    public var bundleID: String
    public var name: String
    public var isPinned: Bool
    public var isRunning: Bool
    public var isActive: Bool
    public init(bundleID: String, name: String, isPinned: Bool, isRunning: Bool, isActive: Bool) {
        self.bundleID = bundleID; self.name = name; self.isPinned = isPinned; self.isRunning = isRunning; self.isActive = isActive
    }
}

public enum TaskbarClickAction: Equatable, Sendable {
    case launch, activate, hide, showWindowList
    /// The Dock's reopen (kAEReopenApplication): AppKit deminiaturizes a window or opens a new one.
    case reopen
    /// Accessibility un-minimizes the app's only window, then raises and activates it.
    case unminimize
}

/// What a taskbar click knows about a running app's windows (see `WindowList.counts`). Without
/// Accessibility `minimized` is 0 and minimized windows are not in `total`. `filteredOnScreen`
/// counts on-screen app panels the list leaves out (layers 0..<25 that are not layer 0 or are
/// under 40 pt); status items and desktop-level windows are not counted.
public struct WindowCounts: Equatable, Sendable {
    public var total: Int
    public var minimized: Int
    public var filteredOnScreen: Int
    public init(total: Int, minimized: Int = 0, filteredOnScreen: Int = 0) {
        self.total = total; self.minimized = minimized; self.filteredOnScreen = filteredOnScreen
    }
}

public enum TaskbarModel {
    public static let defaultPins: [PinnedApp] = [
        PinnedApp(bundleID: "com.apple.finder", name: "Finder"),
        PinnedApp(bundleID: "com.apple.Safari", name: "Safari"),
        PinnedApp(bundleID: "com.apple.Music", name: "Music"),
    ]

    /// Pinned apps first (in pin order), then unpinned running apps by launch order.
    /// Several processes with one bundle ID collapse into one item.
    public static func items(pinned: [PinnedApp], running: [RunningApp]) -> [TaskbarItem] {
        var groups: [String: [RunningApp]] = [:]
        for app in running { groups[app.bundleID, default: []].append(app) }

        var result: [TaskbarItem] = []
        var seen = Set<String>()
        for pin in pinned where seen.insert(pin.bundleID).inserted {
            let procs = groups[pin.bundleID] ?? []
            result.append(TaskbarItem(bundleID: pin.bundleID, name: pin.name, isPinned: true,
                                      isRunning: !procs.isEmpty, isActive: procs.contains { $0.isActive }))
        }
        var unpinned: [(order: Int, item: TaskbarItem)] = []
        for (id, procs) in groups where !seen.contains(id) {
            let first = procs.min { $0.launchOrder < $1.launchOrder }!
            let item = TaskbarItem(bundleID: id, name: first.name, isPinned: false,
                                   isRunning: true, isActive: procs.contains { $0.isActive })
            unpinned.append((first.launchOrder, item))
        }
        unpinned.sort { l, r in
            if l.order != r.order { return l.order < r.order }
            return l.item.bundleID < r.item.bundleID
        }
        result.append(contentsOf: unpinned.map { $0.item })
        return result
    }

    public static func clickAction(for item: TaskbarItem) -> TaskbarClickAction {
        if !item.isRunning { return .launch }
        return item.isActive ? .hide : .activate
    }

    /// Windows 7 grouped buttons, for a running app:
    /// - two or more windows (minimized or not) open its window list;
    /// - one window that is minimized is un-minimized (needs Accessibility to know);
    /// - no listed window (everything minimized without Accessibility, a hidden app without it, or
    ///   none open) gets the Dock's unhide + reopen, except that the active app showing only
    ///   filtered-out windows (a panel) keeps the old toggle;
    /// - one window keeps the app-level activate/hide behaviour.
    public static func clickAction(for item: TaskbarItem, windows: WindowCounts) -> TaskbarClickAction {
        guard item.isRunning else { return .launch }
        if windows.total >= 2 { return .showWindowList }
        if windows.total == 1 && windows.minimized == 1 { return .unminimize }
        if windows.total == 0 && !(item.isActive && windows.filteredOnScreen > 0) { return .reopen }
        return clickAction(for: item)
    }
}

// MARK: - Pin reorder (drag a pinned button)

/// What a drag that started on a taskbar button does.
public enum TaskbarDragGesture: Equatable, Sendable {
    /// Horizontal, on a pinned button: move it among the pinned buttons.
    case reorder
    /// Upward: open the button's jump list.
    case jumpList
}

public enum TaskbarDrag {
    /// Horizontal travel that starts a reorder.
    public static let reorderThreshold: CGFloat = 6
    /// Upward travel that opens the jump list.
    public static let jumpListThreshold: CGFloat = 20

    /// `dx`, `dy` from the press, in AppKit coordinates (y up). nil: still a click.
    public static func gesture(dx: CGFloat, dy: CGFloat, isPinned: Bool) -> TaskbarDragGesture? {
        if dy > jumpListThreshold && dy > abs(dx) { return .jumpList }
        if isPinned && abs(dx) > reorderThreshold && abs(dx) >= abs(dy) { return .reorder }
        return nil
    }
}

public enum TaskbarPinOrder {
    /// `pins` without duplicates (the first of each stays), with `bundleID` moved to `slot`
    /// (clamped). Unchanged when `bundleID` is not pinned.
    public static func moved(_ pins: [PinnedApp], bundleID: String, to slot: Int) -> [PinnedApp] {
        var seen = Set<String>()
        var unique = pins.filter { seen.insert($0.bundleID).inserted }
        guard let from = unique.firstIndex(where: { $0.bundleID == bundleID }) else { return pins }
        let pin = unique.remove(at: from)
        unique.insert(pin, at: min(max(0, slot), unique.count))
        return unique
    }

    /// The pinned slot (an item index) under a dragged button whose centre is at `centerX`. Buttons
    /// are `buttonWidth` wide from `firstX`, where item `firstIndex` is drawn; the result stays among
    /// the `pinCount` pinned items and not before `firstIndex`.
    public static func slot(centerX: CGFloat, firstX: CGFloat, buttonWidth: CGFloat, firstIndex: Int, pinCount: Int) -> Int {
        let last = max(0, pinCount - 1)
        let raw = firstIndex + Int(((centerX - firstX) / buttonWidth).rounded(.down))
        return min(max(raw, min(firstIndex, last)), last)
    }
}

// MARK: - Overflow paging

/// Windows 7 pages taskbar buttons that don't fit before the notification area, with small up/down
/// arrows at the right end of the button area.
public struct TaskbarPaging: Equatable, Sendable {
    public static let arrowWidth: CGFloat = 17
    public let count: Int
    public let perPage: Int
    public let pageCount: Int
    public var showsArrows: Bool { pageCount > 1 }

    public init(count: Int, available: CGFloat, buttonWidth: CGFloat) {
        self.count = count
        if CGFloat(count) * buttonWidth <= available {
            perPage = max(count, 1)
            pageCount = 1
        } else {
            perPage = max(1, Int(((available - TaskbarPaging.arrowWidth) / buttonWidth).rounded(.down)))
            pageCount = (count + perPage - 1) / perPage
        }
    }

    public func clamped(_ page: Int) -> Int { min(max(page, 0), pageCount - 1) }
    public func range(page: Int) -> Range<Int> {
        let p = clamped(page)
        return min(count, p * perPage)..<min(count, (p + 1) * perPage)
    }
    public func page(containing index: Int) -> Int { clamped(index / perPage) }
    public func canPageUp(_ page: Int) -> Bool { clamped(page) > 0 }
    public func canPageDown(_ page: Int) -> Bool { clamped(page) < pageCount - 1 }
}

// MARK: - Taskbar menu: arranging windows

public enum WindowArrangement: Equatable, Sendable {
    case cascade
    /// "Show windows stacked": one above the other.
    case stacked
    /// "Show windows side by side".
    case sideBySide
}

/// Frame math for the taskbar menu's window arrangements. Rects are AX (top-left origin) coordinates.
public enum WindowArranger {
    /// Each cascaded window sits one title bar lower and to the right of the one behind it.
    public static let cascadeStep: CGFloat = 30

    /// The area windows are arranged in: the AppKit `visibleFrame` above the taskbar strip of
    /// `screenFrame`, converted to AX coordinates.
    public static func area(screenFrame: CGRect, visibleFrame: CGRect, taskbarHeight: CGFloat, primaryHeight: CGFloat) -> CGRect {
        var r = visibleFrame
        let floor = screenFrame.minY + taskbarHeight
        if r.minY < floor { r.size.height -= floor - r.minY; r.origin.y = floor }
        return Coordinates.ax(fromAppKit: r, primaryHeight: primaryHeight)
    }

    /// `count` frames. Cascade: frame 0 is top-left (pass windows back to front so the front one
    /// ends on top); tiles: frame 0 is top-left (pass front to back). Four or more windows tile in a
    /// grid of ⌊√n⌋ rows (side by side) or columns (stacked); the later ones take the extra windows.
    public static func frames(_ kind: WindowArrangement, count: Int, in area: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        switch kind {
        case .cascade: return cascade(count: count, in: area)
        case .sideBySide: return grid(count: count, in: area, linesAreRows: true)
        case .stacked: return grid(count: count, in: area, linesAreRows: false)
        }
    }

    private static func cascade(count: Int, in area: CGRect) -> [CGRect] {
        let w = (area.width * 2 / 3).rounded(.down), h = (area.height * 2 / 3).rounded(.down)
        let run = max(1, Int(min((area.width - w) / cascadeStep, (area.height - h) / cascadeStep).rounded(.down)) + 1)
        return (0..<count).map { i in
            let k = CGFloat(i % run)
            return CGRect(x: area.minX + k * cascadeStep, y: area.minY + k * cascadeStep, width: w, height: h)
        }
    }

    /// `n + 1` integral edges splitting `length` from `start`; the last piece takes the remainder.
    private static func edges(_ start: CGFloat, _ length: CGFloat, _ n: Int) -> [CGFloat] {
        (0...n).map { $0 == n ? start + length : start + (length * CGFloat($0) / CGFloat(n)).rounded(.down) }
    }

    private static func grid(count: Int, in area: CGRect, linesAreRows: Bool) -> [CGRect] {
        let lines = max(1, Int(Double(count).squareRoot()))
        let base = count / lines, extra = count % lines
        let lineEdges = linesAreRows ? edges(area.minY, area.height, lines) : edges(area.minX, area.width, lines)
        var frames: [CGRect] = []
        for line in 0..<lines {
            let n = base + (line >= lines - extra ? 1 : 0)
            let along = linesAreRows ? edges(area.minX, area.width, n) : edges(area.minY, area.height, n)
            let l0 = lineEdges[line], l1 = lineEdges[line + 1]
            for j in 0..<n {
                let a0 = along[j], a1 = along[j + 1]
                frames.append(linesAreRows ? CGRect(x: a0, y: l0, width: a1 - a0, height: l1 - l0)
                                           : CGRect(x: l0, y: a0, width: l1 - l0, height: a1 - a0))
            }
        }
        return frames
    }
}

// MARK: - Hot-track glow colour

/// An sRGB colour, components 0...1.
public struct RGBColor: Equatable, Sendable {
    public var r: Double, g: Double, b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
}

/// Windows 7 tints a hovered taskbar button's glow with its icon's dominant colour.
public enum IconTint {
    /// The average of the opaque (alpha ≥ 128) pixels of premultiplied RGBA8 data, saturation-boosted
    /// and brightened so the glow reads; nil when there is no opaque pixel.
    public static func dominantColor(premultipliedRGBA px: [UInt8]) -> RGBColor? {
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        var i = 0
        while i + 3 < px.count {
            let a = Double(px[i + 3])
            if a >= 128 {
                r += Double(px[i]) / a; g += Double(px[i + 1]) / a; b += Double(px[i + 2]) / a
                n += 1
            }
            i += 4
        }
        guard n > 0 else { return nil }
        r = min(1, r / n); g = min(1, g / n); b = min(1, b / n)
        // In HSV terms: saturation × 1.6 (capped), value raised to at least 0.85, hue kept.
        let maxC = max(r, g, b), minC = min(r, g, b)
        let v = max(maxC, 0.85)
        guard maxC > minC else { return RGBColor(r: v, g: v, b: v) }   // grey stays grey
        let s = min(1, (maxC - minC) / maxC * 1.6)
        func channel(_ c: Double) -> Double { v * (1 - s * (maxC - c) / (maxC - minC)) }
        return RGBColor(r: channel(r), g: channel(g), b: channel(b))
    }
}

// MARK: - Bringing a restored app forward

/// How the shell asks for an app to become frontmost.
public enum ActivationMethod: Equatable, Sendable {
    /// Cooperative activation: the shell yields activation to the app, then activates it from itself.
    case cooperative
    /// Accessibility: set the app element's AXFrontmost (only when the shell is trusted).
    case accessibilityFrontmost
    /// The shell activates itself first (it was just clicked), then yields and activates the app.
    case shellHandOff
}

public enum ActivationVerdict: Equatable, Sendable {
    /// The app is frontmost.
    case done
    /// Try again, with the next method.
    case retry
    /// Leave it: out of attempts, the app is gone, or the user moved on to another app.
    case stop
}

/// A taskbar click that restores an app (activate, reopen, un-minimize) or chooses a window in a
/// preview must also bring the app to the front, as Windows 7 does. macOS may refuse an activation the shell asks for while another app
/// is active (cooperative activation), so the shell checks `frontmostApplication` 300 ms after each
/// attempt and retries once with a stronger method.
public enum RestoreActivation {
    public static let checkDelay: TimeInterval = 0.3
    /// The first attempt and one retry.
    public static let maxAttempts = 2

    /// The method for attempt `attempt` (0 first).
    public static func method(attempt: Int, accessibility: Bool) -> ActivationMethod {
        guard attempt > 0 else { return .cooperative }
        return accessibility ? .accessibilityFrontmost : .shellHandOff
    }

    /// After `attemptsMade` attempts: done when one of `target` (the app's processes) is frontmost.
    /// Another app than the shell or the one that was frontmost `before` the click means the user
    /// switched elsewhere, and it is never taken back from them.
    public static func verdict(frontmost: Int32?, target: Set<Int32>, shell: Int32, before: Int32?,
                               attemptsMade: Int) -> ActivationVerdict {
        if let frontmost, target.contains(frontmost) { return .done }
        guard !target.isEmpty, attemptsMade < maxAttempts else { return .stop }
        if let frontmost, frontmost != shell, frontmost != before { return .stop }
        return .retry
    }
}
