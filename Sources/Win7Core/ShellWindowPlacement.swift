import CoreGraphics

/// Where a shell window (the Control Panel, Device Manager, Devices and Printers) goes when it is shown (
/// ). AppKit coordinates (bottom-left origin). `usable` holds each screen's work area: its visible frame, on
/// the taskbar's screen ending at the bar's top edge (WorkArea.visible), so a shell window never opens under the bar.
public enum ShellWindowPlacement {
    /// A frame shows on a screen when at least this much of it is inside that screen's work area.
    public static let minimumVisible = CGSize(width: 100, height: 60)

    /// The frame to move to, or nil when `current` can stay.
    /// - No work area shows `current` (by `minimumVisible`): `defaultSize` centred in `main` (its height clamped
    ///   to `main`, its bottom never below `main`'s).
    /// - Otherwise, on the work area that holds its centre (else the one it overlaps most): moved up when its
    ///   bottom is below the area, down when its top is above it; taller than the area, clamped to the area's
    ///   height. x and width never change.
    public static func frame(current: CGRect, defaultSize: CGSize, usable: [CGRect], main: CGRect?) -> CGRect? {
        let areas = usable.filter { !$0.isEmpty }
        guard !areas.isEmpty else { return nil }
        let shown = areas.contains { a in
            let i = a.intersection(current)
            return !i.isNull && i.width >= minimumVisible.width && i.height >= minimumVisible.height
        }
        guard shown else {
            guard let m = main ?? areas.first else { return nil }
            let h = min(defaultSize.height, m.height)
            return CGRect(x: m.midX - defaultSize.width / 2, y: max(m.minY, m.midY - h / 2),
                          width: defaultSize.width, height: h)
        }
        guard let area = area(holding: current, in: areas) else { return nil }
        var f = current
        if f.height > area.height {
            f.size.height = area.height
            f.origin.y = area.minY
        } else if f.minY < area.minY {
            f.origin.y = area.minY
        } else if f.maxY > area.maxY {
            f.origin.y = area.maxY - f.height
        }
        return f == current ? nil : f
    }

    /// The work area `rect` belongs to: the one holding its centre, else the one it overlaps most; nil when it
    /// overlaps none (empty areas are ignored). Shell dialogs are kept inside it (ShellDialogLayout.origin).
    public static func area(holding rect: CGRect, in usable: [CGRect]) -> CGRect? {
        let areas = usable.filter { !$0.isEmpty }
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        if let a = areas.first(where: { $0.contains(centre) }) { return a }
        guard let best = areas.max(by: { overlap($0, rect) < overlap($1, rect) }), overlap(best, rect) > 0 else { return nil }
        return best
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }
}
