import CoreGraphics
import Foundation

// MARK: - Gadget kinds and the board

/// The desktop gadgets of Windows 7 that the shell offers.
public enum GadgetKind: String, Codable, CaseIterable, Sendable {
    case clock, calendar, cpuMeter, slideShow

    public var title: String {
        switch self {
        case .clock: "Clock"
        case .calendar: "Calendar"
        case .cpuMeter: "CPU Meter"
        case .slideShow: "Slide Show"
        }
    }

    /// The gadget's size in points: Windows 7's docked (small) size, the body size its HTML/CSS/JS sets (clock.css
    /// 130×130; calendar.js Dock() 130×141; cpu.js dockedState() 130×101; slideShow.js dockedState() 130×100).
    public var size: CGSize {
        switch self {
        case .clock: CGSize(width: 130, height: 130)
        case .calendar: CGSize(width: 130, height: 141)
        case .cpuMeter: CGSize(width: 130, height: 101)
        case .slideShow: CGSize(width: 130, height: 100)
        }
    }
}

/// Where a gadget sits: the bottom-left corner of its content, in AppKit screen coordinates.
public struct GadgetPlacement: Codable, Equatable, Sendable {
    public var kind: GadgetKind
    public var x: CGFloat
    public var y: CGFloat
}

/// The gadgets on the desktop, at most one per kind, in the order they were added. Each gadget's hover
/// toolbar (`toolbarWidth`) sits to the right of its content and counts towards its footprint.
public struct GadgetBoard: Equatable, Sendable {
    public static let toolbarWidth: CGFloat = 18
    public static let margin: CGFloat = 10
    public static let gap: CGFloat = 10

    public private(set) var placements: [GadgetPlacement] = []

    public init() {}

    public var kinds: [GadgetKind] { placements.map(\.kind) }

    /// The gadget's content rect, nil when it isn't on the board.
    public func frame(of kind: GadgetKind) -> CGRect? {
        placements.first { $0.kind == kind }.map { CGRect(origin: CGPoint(x: $0.x, y: $0.y), size: kind.size) }
    }

    private static func footprint(_ p: GadgetPlacement) -> CGRect {
        CGRect(x: p.x, y: p.y, width: p.kind.size.width + toolbarWidth, height: p.kind.size.height)
    }

    /// Adds `kind` in the first free slot, docked as Windows 7 does: down the right edge from the top,
    /// then in columns further left. Returns false when the kind is already on the board.
    @discardableResult
    public mutating func add(_ kind: GadgetKind, in area: CGRect) -> Bool {
        guard frame(of: kind) == nil else { return false }
        let size = kind.size
        let width = size.width + Self.toolbarWidth
        let column = (GadgetKind.allCases.map(\.size.width).max() ?? size.width) + Self.toolbarWidth + Self.gap
        let taken = placements.map(Self.footprint)
        var right = area.maxX - Self.margin
        while right - width >= area.minX {
            let tops = ([area.maxY - Self.margin] + taken.map { $0.minY - Self.gap }).sorted(by: >)
            for top in tops where top - size.height >= area.minY + Self.margin && top <= area.maxY - Self.margin {
                let candidate = CGRect(x: right - width, y: top - size.height, width: width, height: size.height)
                if !taken.contains(where: { $0.intersects(candidate) }) {
                    placements.append(GadgetPlacement(kind: kind, x: candidate.minX, y: candidate.minY))
                    return true
                }
            }
            right -= column
        }
        // No free slot: top right, overlapping.
        placements.append(GadgetPlacement(kind: kind, x: area.maxX - Self.margin - width, y: area.maxY - Self.margin - size.height))
        return true
    }

    /// Moves `kind`'s content origin to `origin`, kept with its toolbar fully inside `area`.
    public mutating func move(_ kind: GadgetKind, to origin: CGPoint, in area: CGRect) {
        guard let i = placements.firstIndex(where: { $0.kind == kind }) else { return }
        let p = Self.clamp(origin, size: kind.size, in: area)
        placements[i].x = p.x
        placements[i].y = p.y
    }

    public mutating func remove(_ kind: GadgetKind) {
        placements.removeAll { $0.kind == kind }
    }

    /// Pulls every gadget back inside `area` (after a screen change).
    public mutating func clampAll(in area: CGRect) {
        for i in placements.indices {
            let p = Self.clamp(CGPoint(x: placements[i].x, y: placements[i].y), size: placements[i].kind.size, in: area)
            placements[i].x = p.x
            placements[i].y = p.y
        }
    }

    private static func clamp(_ o: CGPoint, size: CGSize, in area: CGRect) -> CGPoint {
        let maxX = max(area.minX, area.maxX - size.width - toolbarWidth)
        let maxY = max(area.minY, area.maxY - size.height)
        return CGPoint(x: min(max(o.x, area.minX), maxX), y: min(max(o.y, area.minY), maxY))
    }

    // MARK: Persistence

    private struct Stored: Codable {
        var kind: String
        var x: CGFloat
        var y: CGFloat
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(placements.map { Stored(kind: $0.kind.rawValue, x: $0.x, y: $0.y) })) ?? Data()
    }

    /// The board stored by `encoded()`. Bad data gives an empty board; unknown kinds and repeats are dropped.
    public static func decode(_ data: Data?) -> GadgetBoard {
        var board = GadgetBoard()
        guard let data, let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return board }
        for s in stored {
            guard let kind = GadgetKind(rawValue: s.kind), board.frame(of: kind) == nil else { continue }
            board.placements.append(GadgetPlacement(kind: kind, x: s.x, y: s.y))
        }
        return board
    }
}

/// The gadget gallery's grid of tiles (top-left origin), `spacing` from the left and top and between tiles.
public enum GadgetGalleryLayout {
    public static func tileRects(count: Int, width: CGFloat, tile: CGSize, spacing: CGFloat) -> [CGRect] {
        let columns = max(1, Int(width / (tile.width + spacing)))
        return (0..<max(0, count)).map { i in
            CGRect(x: spacing + CGFloat(i % columns) * (tile.width + spacing),
                   y: spacing + CGFloat(i / columns) * (tile.height + spacing),
                   width: tile.width, height: tile.height)
        }
    }

    public static func index(at point: CGPoint, in rects: [CGRect]) -> Int? {
        rects.firstIndex { $0.contains(point) }
    }
}

// MARK: - Clock and Calendar

/// Hand angles of the analog clock, in degrees clockwise from 12.
public struct ClockHands: Equatable, Sendable {
    public var hour: Double
    public var minute: Double
    public var second: Double

    public init(date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        let h = Double((c.hour ?? 0) % 12), m = Double(c.minute ?? 0), s = Double(c.second ?? 0)
        hour = h * 30 + m * 0.5 + s * (0.5 / 60)
        minute = m * 6 + s * 0.1
        second = s * 6
    }
}

/// The Calendar gadget's day page and month view, in the calendar's locale and first weekday.
public struct CalendarPage: Equatable, Sendable {
    public var day: Int
    /// The full weekday name ("Friday").
    public var weekday: String
    /// Month and year ("October 2026").
    public var monthYear: String
    /// Single-letter weekday headers starting at the calendar's first weekday.
    public var weekdaySymbols: [String]
    /// The month's weeks, 7 slots each; nil before the 1st and after the last day.
    public var weeks: [[Int?]]

    public init(date: Date, calendar: Calendar = .current) {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = calendar.locale ?? .current
        f.timeZone = calendar.timeZone
        day = calendar.component(.day, from: date)
        f.dateFormat = "EEEE"
        weekday = f.string(from: date)
        f.setLocalizedDateFormatFromTemplate("MMMMy")
        monthYear = f.string(from: date)
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        weekdaySymbols = (0..<7).map { symbols[(first + $0) % 7] }
        let start = calendar.dateInterval(of: .month, for: date)?.start ?? date
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: date)?.count ?? 30
        var slots: [Int?] = Array(repeating: nil, count: offset) + (1...count).map { Optional($0) }
        while slots.count % 7 != 0 { slots.append(nil) }
        weeks = stride(from: 0, to: slots.count, by: 7).map { Array(slots[$0..<$0 + 7]) }
    }
}

// MARK: - CPU Meter

/// One core's cumulative tick counters (host_processor_info's natural_t values, which wrap).
public struct CPUTicks: Equatable, Sendable {
    public var user, system, idle, nice: UInt32
    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// Page counts from host_statistics64(HOST_VM_INFO64).
public struct VMPageCounts: Equatable, Sendable {
    public var free, active, inactive, wired, compressed, speculative: UInt64
    public init(free: UInt64, active: UInt64, inactive: UInt64, wired: UInt64, compressed: UInt64, speculative: UInt64) {
        self.free = free
        self.active = active
        self.inactive = inactive
        self.wired = wired
        self.compressed = compressed
        self.speculative = speculative
    }
}

public enum SystemLoad {
    /// CPU use in percent between two samples: busy (user + system + nice) ticks over all ticks, summed
    /// over the cores both samples have. 0 when no time passed.
    public static func cpuPercent(previous: [CPUTicks], current: [CPUTicks]) -> Double {
        var busy: UInt64 = 0, total: UInt64 = 0
        for (a, b) in zip(previous, current) {
            let u = UInt64(b.user &- a.user), s = UInt64(b.system &- a.system)
            let n = UInt64(b.nice &- a.nice), i = UInt64(b.idle &- a.idle)
            busy += u + s + n
            total += u + s + n + i
        }
        guard total > 0 else { return 0 }
        return min(100, Double(busy) / Double(total) * 100)
    }

    /// Physical memory in use, in percent: wired, active and compressor pages over the installed memory.
    public static func memoryPercent(_ p: VMPageCounts, pageSize: UInt64, totalBytes: UInt64) -> Double {
        guard totalBytes > 0 else { return 0 }
        let used = Double(p.wired + p.active + p.compressed) * Double(pageSize)
        return min(100, max(0, used / Double(totalBytes) * 100))
    }
}

// MARK: - Slide Show

public enum SlideShowPlaylist {
    public static let extensions: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "heic"]

    /// The image names among a folder's top-level `names`, Finder-sorted; hidden files are skipped.
    public static func images(in names: [String]) -> [String] {
        names.filter { !$0.hasPrefix(".") && extensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func next(after index: Int, count: Int) -> Int? {
        count > 0 ? (index + 1) % count : nil
    }

    public static func previous(before index: Int, count: Int) -> Int? {
        count > 0 ? ((index - 1) % count + count) % count : nil
    }

    /// A picture of `size` scaled to fit inside `box`, centred (slideShow.js: the picture in a centred table cell);
    /// `box` itself for an empty size.
    public static func fit(_ size: CGSize, in box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return box }
        let s = min(box.width / size.width, box.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }
}
