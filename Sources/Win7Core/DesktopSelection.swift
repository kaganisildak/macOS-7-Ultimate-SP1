/// Windows 7 desktop selection: click, Cmd-click toggle, Shift-click range from the anchor.
public struct DesktopSelection: Equatable, Sendable {
    public private(set) var selected: Set<String> = []
    public var anchor: String?

    public init() {}

    public mutating func click(_ id: String, order: [String]) {
        selected = [id]
        anchor = id
    }

    public mutating func commandClick(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        anchor = id
    }

    /// Selects the range between the anchor and `id` in `order`. The anchor stays put.
    public mutating func shiftClick(_ id: String, order: [String]) {
        guard let anchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) else {
            click(id, order: order)
            return
        }
        selected = Set(order[min(a, b)...max(a, b)])
    }

    public mutating func clear() {
        selected = []
        anchor = nil
    }

    public mutating func set(_ ids: Set<String>) {
        selected = ids
        anchor = nil
    }

    /// Drops ids that no longer exist (after a rescan).
    public mutating func retain(_ ids: Set<String>) {
        selected.formIntersection(ids)
        if let a = anchor, !ids.contains(a) { anchor = nil }
    }
}
