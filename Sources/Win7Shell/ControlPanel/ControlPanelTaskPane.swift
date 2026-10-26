import AppKit
import Win7Core
import Win7Theme

/// What a click in the Control Panel does.
enum ControlPanelTarget: Equatable {
    case navigate(ControlPanelLocation)
    case perform(ControlPanelLink)
}

/// A clickable area of a Control Panel view.
struct ControlPanelHot {
    var rect: NSRect
    var target: ControlPanelTarget
}

/// Text runs shared by the task pane and the body (flipped views).
enum ControlPanelText {
    static let linkBlue = NSColor(srgbRed: 0x00 / 255, green: 0x66 / 255, blue: 0xCC / 255, alpha: 1)
    static let navy = NSColor(srgbRed: 0x1E / 255, green: 0x39 / 255, blue: 0x5B / 255, alpha: 1)
    static let grey = NSColor(srgbRed: 0x6D / 255, green: 0x6D / 255, blue: 0x6D / 255, alpha: 1)

    static func attributes(_ font: NSFont, _ color: NSColor, underline: Bool = false, wrap: Bool = false) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        if underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return a
    }

    static func width(_ s: String, _ font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Height of `s` wrapped to `width`.
    static func height(_ s: String, _ font: NSFont, width: CGFloat) -> CGFloat {
        ceil((s as NSString).boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin],
                                          attributes: attributes(font, .black, wrap: true)).height)
    }
}

/// The left task pane: Windows 7's light blue gradient (`#E9F1FA→#D7E4F2`) with a 1 pt `#A8BED6` right border,
/// "Control Panel Home" and the eight categories (the current page bold), and "See also: System Settings".
@MainActor
final class ControlPanelTaskPane: NSView {
    var onTarget: ((ControlPanelTarget) -> Void)?

    private var current: ControlPanelLocation = .home
    private var categories: [ControlPanelCategory] = ControlPanelCategory.allCases
    private struct Entry { var title: String; var rect: NSRect; var bold: Bool; var hot: Int?; var grey: Bool }
    private var entries: [Entry] = []
    private var hots: [ControlPanelHot] = []
    private var hover: Int?
    private var pressed: Int?

    private static let top = NSColor(srgbRed: 0xE9 / 255, green: 0xF1 / 255, blue: 0xFA / 255, alpha: 1)
    private static let bottom = NSColor(srgbRed: 0xD7 / 255, green: 0xE4 / 255, blue: 0xF2 / 255, alpha: 1)
    private static let border = NSColor(srgbRed: 0xA8 / 255, green: 0xBE / 255, blue: 0xD6 / 255, alpha: 1)
    private static let font = W7UIFont(12)
    private static let bold = NSFontManager.shared.convert(W7UIFont(12), toHaveTrait: .boldFontMask)
    private static let inset: CGFloat = 14

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A click acts even while the shell isn't the active app (as the taskbar's do).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(current: ControlPanelLocation, categories: [ControlPanelCategory]) {
        self.current = current
        self.categories = categories
        rebuild()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuild()
    }

    private func rebuild() {
        entries = []
        hots = []
        hover = nil
        let width = bounds.width - 2 * Self.inset
        var y: CGFloat = 16
        func add(_ title: String, _ target: ControlPanelTarget?, bold: Bool = false, grey: Bool = false, gap: CGFloat = 8) {
            let font = bold ? Self.bold : Self.font
            let h = ControlPanelText.height(title, font, width: width)
            let w = min(width, ControlPanelText.width(title, font))
            let rect = NSRect(x: Self.inset, y: y, width: h > 18 ? width : w, height: h)
            var hot: Int?
            if let target, !bold {
                hot = hots.count
                hots.append(ControlPanelHot(rect: rect, target: target))
            }
            entries.append(Entry(title: title, rect: rect, bold: bold, hot: hot, grey: grey))
            y += h + gap
        }
        add("Control Panel Home", .navigate(.home), bold: current == .home, gap: 14)
        for c in categories {
            add(c.title, .navigate(.category(c)), bold: current == .category(c))
        }
        // "See also" sits at the bottom when there is room, else right under the links.
        y = max(y + 16, bounds.height - 56)
        add("See also", nil, grey: true, gap: 6)
        add("System Settings", .perform(ControlPanelLink("System Settings", ControlPanelCatalog.systemSettings)))
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: Self.top, ending: Self.bottom)?.draw(in: bounds, angle: 90)
        Self.border.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        for e in entries {
            let color = e.bold ? NSColor.black : (e.grey ? ControlPanelText.grey : ControlPanelText.navy)
            let underline = e.hot != nil && e.hot == hover
            (e.title as NSString).draw(with: e.rect, options: [.usesLineFragmentOrigin],
                                       attributes: ControlPanelText.attributes(e.bold ? Self.bold : Self.font, color,
                                                                               underline: underline, wrap: true))
        }
    }

    override func resetCursorRects() {
        for h in hots { addCursorRect(h.rect, cursor: .pointingHand) }
    }

    private func hot(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return hots.indices.first { hots[$0].rect.contains(p) }
    }

    override func mouseMoved(with event: NSEvent) {
        let h = hot(at: event)
        if h != hover { hover = h; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hover != nil { hover = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) { pressed = hot(at: event) }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard let h = hot(at: event), h == pressed else { return }
        onTarget?(hots[h].target)
    }
}
