import CoreGraphics
import Foundation

/// View ▸ icon sizes of the Windows 7 desktop.
public enum DesktopIconSize: String, Codable, Sendable, CaseIterable {
    case large, medium, small

    public var iconSide: CGFloat {
        switch self {
        case .large: 96
        case .medium: 48
        case .small: 32
        }
    }

    public var cell: CGSize {
        switch self {
        case .large: CGSize(width: 120, height: 128)
        case .medium: CGSize(width: 76, height: 86)
        case .small: CGSize(width: 68, height: 70)
        }
    }
}

/// The desktop icon grid. Coordinates have a top-left origin; positions are `[col, row]`, filled
/// column-major from the top-left as in Windows 7.
public struct DesktopLayout: Sendable {
    public let bounds: CGSize
    public let size: DesktopIconSize
    public let margin: CGFloat

    public init(bounds: CGSize, size: DesktopIconSize, margin: CGFloat = 10) {
        self.bounds = bounds
        self.size = size
        self.margin = margin
    }

    /// floor((height - 2*margin) / cell.height), at least 1.
    public var rows: Int { max(1, Int(((bounds.height - 2 * margin) / size.cell.height).rounded(.down))) }
    /// floor((width - 2*margin) / cell.width), at least 1.
    public var columns: Int { max(1, Int(((bounds.width - 2 * margin) / size.cell.width).rounded(.down))) }

    public func origin(col: Int, row: Int) -> CGPoint {
        CGPoint(x: margin + CGFloat(col) * size.cell.width, y: margin + CGFloat(row) * size.cell.height)
    }

    public func rect(col: Int, row: Int) -> CGRect {
        CGRect(origin: origin(col: col, row: row), size: size.cell)
    }

    /// The cell under `point`, clamped to the grid (0..<columns, 0..<rows).
    public func cell(at point: CGPoint) -> (col: Int, row: Int) {
        let col = Int(((point.x - margin) / size.cell.width).rounded(.down))
        let row = Int(((point.y - margin) / size.cell.height).rounded(.down))
        return clamped(col, row)
    }

    private func clamped(_ col: Int, _ row: Int) -> (col: Int, row: Int) {
        (min(max(0, col), columns - 1), min(max(0, row), rows - 1))
    }

    /// Whether `[col, row]` lies on the current screen's grid.
    public func isOnGrid(_ p: [Int]) -> Bool {
        p.count == 2 && p[0] >= 0 && p[0] < columns && p[1] >= 0 && p[1] < rows
    }

    public func firstFreeCell(occupied: Set<[Int]>) -> (col: Int, row: Int) {
        firstFreeCell(occupied: occupied, from: (0, 0))
    }

    /// First unoccupied cell at or after `start` (clamped to the grid) in column-major order, wrapping
    /// to the top-left. Only when the whole grid is full does it continue in columns past the right edge.
    public func firstFreeCell(occupied: Set<[Int]>, from start: (col: Int, row: Int)) -> (col: Int, row: Int) {
        let s = clamped(start.col, start.row)
        let total = columns * rows
        let first = s.col * rows + s.row
        for i in 0..<total {
            let index = (first + i) % total
            if !occupied.contains([index / rows, index % rows]) { return (index / rows, index % rows) }
        }
        var col = columns, row = 0
        while occupied.contains([col, row]) {
            row += 1
            if row >= rows { row = 0; col += 1 }
        }
        return (col, row)
    }

    /// Items whose cell rect intersects `rect` (the rubber band).
    public func itemsIntersecting(_ rect: CGRect, positions: [String: [Int]]) -> Set<String> {
        var hit: Set<String> = []
        for (id, p) in positions where p.count == 2 && rect.intersects(self.rect(col: p[0], row: p[1])) {
            hit.insert(id)
        }
        return hit
    }

    /// Resolves where `ids` (in sort order) are shown. Without auto-arrange a stored on-grid position is
    /// honoured unless an earlier id already holds that cell; everything else goes to the first free cell.
    /// `stored` is what to persist: vanished ids pruned, new placements recorded, and a manual position
    /// that is off the current grid (a smaller screen) kept. Auto-arrange only prunes.
    public func arrange(_ ids: [String], stored: [String: [Int]], autoArrange: Bool)
        -> (display: [String: [Int]], stored: [String: [Int]]) {
        let present = Set(ids)
        let pruned = stored.filter { present.contains($0.key) }
        var display: [String: [Int]] = [:]
        if autoArrange {
            for (i, id) in ids.enumerated() { display[id] = [i / rows, i % rows] }
            return (display, pruned)
        }
        var occupied: Set<[Int]> = []
        for id in ids {
            if let p = pruned[id], isOnGrid(p), !occupied.contains(p) {
                display[id] = p
                occupied.insert(p)
            }
        }
        var start = (col: 0, row: 0)
        for id in ids where display[id] == nil {
            let c = firstFreeCell(occupied: occupied, from: start)
            display[id] = [c.col, c.row]
            occupied.insert([c.col, c.row])
            start = c
        }
        var newStored = display
        for (id, p) in pruned where !isOnGrid(p) { newStored[id] = p }
        return (display, newStored)
    }

    /// Moves `ids` by the offset that takes `primary` to `target`, snapped to and clamped within the grid.
    /// Movers whose wanted cell is free take it first; the rest go to the next free cell after the cell
    /// they wanted (column-major, wrapping).
    public func move(_ ids: [String], primary: String, to target: (col: Int, row: Int),
                     positions: [String: [Int]]) -> [String: [Int]] {
        guard let from = positions[primary], from.count == 2 else { return positions }
        let goal = clamped(target.col, target.row)
        let dc = goal.col - from[0], dr = goal.row - from[1]
        let moving = Set(ids)
        var result = positions
        var occupied = Set(positions.filter { !moving.contains($0.key) }.values)
        let ordered = [primary] + ids.filter { $0 != primary }
        var bumped: [(id: String, want: (col: Int, row: Int))] = []
        for id in ordered {
            guard let p = positions[id], p.count == 2 else { continue }
            let want = clamped(p[0] + dc, p[1] + dr)
            if occupied.contains([want.col, want.row]) {
                bumped.append((id, want))
            } else {
                result[id] = [want.col, want.row]
                occupied.insert([want.col, want.row])
            }
        }
        for b in bumped {
            let c = firstFreeCell(occupied: occupied, from: b.want)
            result[b.id] = [c.col, c.row]
            occupied.insert([c.col, c.row])
        }
        return result
    }

    /// Ids in layout (column-major) order; used for Shift-click ranges.
    public static func layoutOrder(_ positions: [String: [Int]]) -> [String] {
        positions.filter { $0.value.count == 2 }.sorted { a, b in
            (a.value[0], a.value[1], a.key) < (b.value[0], b.value[1], b.key)
        }.map(\.key)
    }

    /// The nearest item from `id` in `direction`, preferring the same row or column.
    public static func neighbor(of id: String, _ direction: Arrow, positions: [String: [Int]]) -> String? {
        guard let p = positions[id], p.count == 2 else { return nil }
        var best: (key: String, score: (Int, Int, String))?
        for (other, q) in positions where other != id && q.count == 2 {
            let dc = q[0] - p[0], dr = q[1] - p[1]
            let primary: Int, secondary: Int
            switch direction {
            case .up: primary = -dr; secondary = abs(dc)
            case .down: primary = dr; secondary = abs(dc)
            case .left: primary = -dc; secondary = abs(dr)
            case .right: primary = dc; secondary = abs(dr)
            }
            guard primary > 0 else { continue }
            let score = (secondary, primary, other)
            if best == nil || score < best!.score { best = (other, score) }
        }
        return best?.key
    }
}

public enum DesktopSort: String, Sendable, CaseIterable { case name, size, type, dateModified }

public struct DesktopEntry: Equatable, Sendable {
    public var name: String
    public var size: Int64
    public var type: String
    public var modified: Date

    public init(name: String, size: Int64, type: String, modified: Date) {
        self.name = name
        self.size = size
        self.type = type
        self.modified = modified
    }
}

public enum DesktopOrdering {
    /// Name: Finder-style `localizedStandardCompare`. Size and date: largest/newest first. Type: by type
    /// description. Ties are broken by name.
    public static func sorted(_ e: [DesktopEntry], by sort: DesktopSort) -> [DesktopEntry] {
        func byName(_ a: DesktopEntry, _ b: DesktopEntry) -> Bool {
            let r = a.name.localizedStandardCompare(b.name)
            return r == .orderedSame ? a.name < b.name : r == .orderedAscending
        }
        return e.sorted { a, b in
            switch sort {
            case .name:
                return byName(a, b)
            case .size:
                return a.size != b.size ? a.size > b.size : byName(a, b)
            case .dateModified:
                return a.modified != b.modified ? a.modified > b.modified : byName(a, b)
            case .type:
                let r = a.type.localizedStandardCompare(b.type)
                return r != .orderedSame ? r == .orderedAscending : byName(a, b)
            }
        }
    }
}
