import CoreGraphics

/// One window as Accessibility reports it (needs the Accessibility permission).
public struct AXWindowInfo: Equatable, Sendable {
    public var id: UInt32
    public var title: String?
    public var isMinimized: Bool
    public init(id: UInt32, title: String?, isMinimized: Bool) {
        self.id = id; self.title = title; self.isMinimized = isMinimized
    }
}

/// One window as `CGWindowListCopyWindowInfo` reports it (no permission needed; `name` needs
/// Screen Recording and is nil without it).
public struct CGWindowInfo: Equatable, Sendable {
    public var id: UInt32
    public var name: String?
    public var bounds: CGRect
    public var layer: Int
    public var isOnScreen: Bool
    public init(id: UInt32, name: String?, bounds: CGRect, layer: Int, isOnScreen: Bool) {
        self.id = id; self.name = name; self.bounds = bounds; self.layer = layer; self.isOnScreen = isOnScreen
    }

    /// The windows owned by `pid` in a `CGWindowListCopyWindowInfo` result, in its (front-to-back) order.
    /// The dylib's frame overlays are dropped (WindowList.droppingFrameBorderOverlays).
    public static func list(from info: [[String: Any]], pid: Int32) -> [CGWindowInfo] {
        WindowList.droppingFrameBorderOverlays(info.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid else { return nil }
            return parse(w)
        })
    }

    /// Every owner's windows from one pass over a `CGWindowListCopyWindowInfo` result, each list in
    /// the result's (front-to-back) order: what `list(from:pid:)` gives per pid.
    public static func byPID(from info: [[String: Any]]) -> [Int32: [CGWindowInfo]] {
        unfilteredByPID(from: info).mapValues(WindowList.droppingFrameBorderOverlays)
    }

    /// The window numbers in a `CGWindowListCopyWindowInfo` result that are the dylib's frame overlays
    /// (WindowList.droppingFrameBorderOverlays, per owner), for callers that walk the raw result
    /// themselves, as the Option+Tab switcher does.
    public static func frameBorderOverlayIDs(in info: [[String: Any]]) -> Set<UInt32> {
        var out = Set<UInt32>()
        for windows in unfilteredByPID(from: info).values where windows.count > 1 {
            let kept = Set(WindowList.droppingFrameBorderOverlays(windows).map(\.id))
            for w in windows where !kept.contains(w.id) { out.insert(w.id) }
        }
        return out
    }

    private static func unfilteredByPID(from info: [[String: Any]]) -> [Int32: [CGWindowInfo]] {
        var out: [Int32: [CGWindowInfo]] = [:]
        for w in info {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, let parsed = parse(w) else { continue }
            out[pid, default: []].append(parsed)
        }
        return out
    }

    private static func parse(_ w: [String: Any]) -> CGWindowInfo? {
        guard let id = w[kCGWindowNumber as String] as? UInt32 else { return nil }
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        func num(_ k: String) -> CGFloat { CGFloat(b[k] as? Double ?? 0) }
        return CGWindowInfo(id: id, name: w[kCGWindowName as String] as? String,
                            bounds: CGRect(x: num("X"), y: num("Y"), width: num("Width"), height: num("Height")),
                            layer: w[kCGWindowLayer as String] as? Int ?? 0,
                            isOnScreen: w[kCGWindowIsOnscreen as String] as? Bool ?? false)
    }
}

/// A row of a taskbar button's window list / preview popup.
public struct WindowListEntry<Image> {
    public var id: UInt32
    public var title: String
    public var isMinimized: Bool
    public var image: Image?
    public init(id: UInt32, title: String, isMinimized: Bool, image: Image?) {
        self.id = id; self.title = title; self.isMinimized = isMinimized; self.image = image
    }
}
extension WindowListEntry: Equatable where Image: Equatable {}
extension WindowListEntry: Sendable where Image: Sendable {}

public enum WindowList {
    /// Windows smaller than this on either side are helpers, not documents.
    public static let minimumSide: CGFloat = 40

    /// Width of the Aero frame the dylib draws round decorated windows. Must equal Win7Theme's
    /// `W7FrameBorderWidth` (W7Drawing.m), which W7FrameBorder.m sizes the overlay with; Win7Core cannot
    /// import Win7Theme, so Win7PerfTests (which links both) pins the two together.
    public static let frameBorderWidth: CGFloat = 8

    /// Drops the dylib's frame overlays from one app's CG windows. The overlay is a separate
    /// borderless window: in CG's top-left-origin bounds it is another window W of the same app grown by
    /// `frameBorderWidth` on the left, right and bottom, with the same top. A window is dropped only when
    /// such a W is in `windows`; the order of the rest is kept.
    public static func droppingFrameBorderOverlays(_ windows: [CGWindowInfo]) -> [CGWindowInfo] {
        guard windows.count > 1 else { return windows }
        let b = frameBorderWidth
        func same(_ x: CGFloat, _ y: CGFloat) -> Bool { abs(x - y) < 0.01 }
        func frames(_ overlay: CGRect, _ w: CGRect) -> Bool {
            same(overlay.minX, w.minX - b) && same(overlay.minY, w.minY)
                && same(overlay.width, w.width + 2 * b) && same(overlay.height, w.height + b)
        }
        return windows.filter { o in !windows.contains { $0.id != o.id && frames(o.bounds, $0.bounds) } }
    }

    /// Layer 0 and at least `minimumSide` on both sides: a document window, not a helper.
    static func isEligible(_ w: CGWindowInfo) -> Bool {
        w.layer == 0 && w.bounds.width >= minimumSide && w.bounds.height >= minimumSide
    }

    /// How many of `windows` are document windows (`isEligible`), on screen or not: with a
    /// `.optionAll` list this counts windows on other Spaces too.
    public static func eligibleCount(_ windows: [CGWindowInfo]) -> Int { windows.filter(isEligible).count }

    /// Merges what each source knows into the list a taskbar button shows.
    ///
    /// - `ax` nil means Accessibility is unavailable: only on-screen CG windows are listed, since
    ///   CG alone cannot tell a minimized window from an ordered-out or other-Space one. With AX,
    ///   AX decides which windows exist; non-minimized ones take CG's front-to-back order and
    ///   minimized ones are appended in AX order. AX that yields no usable window (a timeout, an
    ///   app without AX support) is treated as unavailable.
    /// - Windows CG reports with a layer other than 0 or a side under `minimumSide` are dropped.
    /// - Untitled windows are labelled with the app name, numbered when there are several.
    public static func merge<Image>(ax: [AXWindowInfo]?, cg: [CGWindowInfo], images: [UInt32: Image],
                                    appName: String) -> [WindowListEntry<Image>] {
        let eligible = isEligible
        let rejected = Set(cg.filter { !eligible($0) }.map(\.id))
        var cgNames: [UInt32: String] = [:]
        for w in cg where eligible(w) { if cgNames[w.id] == nil, let n = w.name, !n.isEmpty { cgNames[w.id] = n } }

        var seen = Set<UInt32>()
        var rows: [(id: UInt32, title: String?, minimized: Bool)] = []
        func add(_ id: UInt32, _ title: String?, _ minimized: Bool) {
            if seen.insert(id).inserted { rows.append((id, title, minimized)) }
        }
        func title(_ t: String?, _ id: UInt32) -> String? { t.flatMap { $0.isEmpty ? nil : $0 } ?? cgNames[id] }

        if let ax, ax.contains(where: { !rejected.contains($0.id) }) {
            var byID: [UInt32: AXWindowInfo] = [:]
            for w in ax where byID[w.id] == nil { byID[w.id] = w }
            for w in cg where eligible(w) {
                if let a = byID[w.id], !a.isMinimized { add(a.id, title(a.title, a.id), false) }
            }
            for a in ax where !a.isMinimized && !rejected.contains(a.id) { add(a.id, title(a.title, a.id), false) }
            for a in ax where a.isMinimized && !rejected.contains(a.id) { add(a.id, title(a.title, a.id), true) }
        } else {
            for w in cg where eligible(w) && w.isOnScreen { add(w.id, title(nil, w.id), false) }
        }

        let untitled = rows.filter { $0.title == nil }.count
        var n = 0
        return rows.map { r in
            var label = r.title
            if label == nil {
                n += 1
                label = untitled > 1 ? "\(appName) (\(n))" : appName
            }
            return WindowListEntry(id: r.id, title: label!, isMinimized: r.minimized, image: images[r.id])
        }
    }

    /// What the taskbar button's click decision sees (same rules as `merge`).
    public static func counts(ax: [AXWindowInfo]?, cg: [CGWindowInfo]) -> WindowCounts {
        let list = merge(ax: ax, cg: cg, images: [UInt32: Never](), appName: "")
        // App panels only: layers 0..<25. Status items (25+) and desktop-level windows
        // (negative, as Finder's desktop) are not windows a click would toggle.
        let filtered = cg.filter { $0.isOnScreen && !isEligible($0) && (0..<25).contains($0.layer) }.count
        return WindowCounts(total: list.count, minimized: list.filter(\.isMinimized).count, filteredOnScreen: filtered)
    }
}
