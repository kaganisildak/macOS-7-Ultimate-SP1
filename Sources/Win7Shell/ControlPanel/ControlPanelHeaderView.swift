import AppKit
import Win7Core
import Win7Theme

/// The Control Panel's address row on the Aero glass under the caption: the back and forward orbs in their
/// trough, the breadcrumb address bar ("▸ Control Panel ▸ <category>") and the "Search Control Panel" box.
/// Non-flipped, as Win7Theme draws.
@MainActor
final class ControlPanelHeaderView: NSView, NSTextFieldDelegate {
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onCrumb: ((ControlPanelLocation) -> Void)?
    var onSearch: ((String) -> Void)?
    /// Return in the search box (the Personalization and Desktop Background pages search on Return, passing the
    /// typed text to the Control Panel, instead of on every keystroke).
    var onSubmit: ((String) -> Void)?
    /// The icon before the breadcrumbs (the window's own).
    var addressIcon: (CGFloat) -> NSImage = { ControlPanelIcons.window(side: $0) }

    private(set) var crumbs: [ControlPanelCrumb] = []
    private var canGoBack = false
    private var canGoForward = false
    private let search = NSTextField()
    private enum Part: Equatable { case back, forward, crumb(Int), clear }
    private var hover: Part?
    private var pressed: Part?

    private static let backSize: CGFloat = 28, forwardSize: CGFloat = 24
    private static let searchWidth: CGFloat = 220, boxHeight: CGFloat = 24
    private static let font = W7UIFont(12)
    private static let separatorLine = NSColor(srgbRed: 0xA0 / 255, green: 0xAF / 255, blue: 0xC3 / 255, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A plain field inside the drawn Windows 7 search box, as in the Start menu.
        search.isBordered = false
        search.isBezeled = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.font = Self.font
        search.cell?.isScrollable = true
        search.cell?.usesSingleLineMode = true
        setPlaceholder("Search Control Panel")
        search.delegate = self
        addSubview(search)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The search box's grey italic hint ("Search Control Panel"; Devices and Printers has its own).
    func setPlaceholder(_ text: String) {
        let italic = NSFontManager.shared.convert(Self.font, toHaveTrait: .italicFontMask)
        search.placeholderAttributedString = NSAttributedString(string: text, attributes: [
            .font: italic, .foregroundColor: NSColor(srgbRed: 0x6D / 255, green: 0x6D / 255, blue: 0x6D / 255, alpha: 1),
        ])
    }

    /// A click acts even while the shell isn't the active app (as the taskbar's do).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    func update(crumbs: [ControlPanelCrumb], canGoBack: Bool, canGoForward: Bool) {
        self.crumbs = crumbs
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        needsDisplay = true
    }

    var searchText: String { search.stringValue }

    func clearSearch() {
        search.stringValue = ""
        needsDisplay = true
    }

    func focusSearch() { window?.makeFirstResponder(search) }

    /// The search box itself, for a window's Tab order.
    var searchField: NSView { search }

    /// Puts `text` in the search box (a search passed on from another window).
    func setSearchText(_ text: String) {
        search.stringValue = text
        needsDisplay = true
    }

    // MARK: Geometry

    private var rowY: CGFloat { floor((bounds.height - Self.boxHeight) / 2) }
    private func rect(_ p: Part) -> NSRect {
        switch p {
        case .back: NSRect(x: 6, y: floor((bounds.height - Self.backSize) / 2), width: Self.backSize, height: Self.backSize)
        case .forward:
            NSRect(x: 6 + Self.backSize - 1, y: floor((bounds.height - Self.forwardSize) / 2),
                   width: Self.forwardSize, height: Self.forwardSize)
        case .crumb(let i): i < crumbRects.count ? crumbRects[i] : .zero
        case .clear: NSRect(x: searchBox.maxX - 22, y: searchBox.minY, width: 22, height: searchBox.height)
        }
    }
    private var addressBox: NSRect {
        let x = 6 + Self.backSize + Self.forwardSize + 8
        return NSRect(x: x, y: rowY, width: max(60, searchBox.minX - 8 - x), height: Self.boxHeight)
    }
    private var searchBox: NSRect {
        NSRect(x: bounds.width - 8 - Self.searchWidth, y: rowY, width: Self.searchWidth, height: Self.boxHeight)
    }

    /// Each crumb's button, after the window icon and a ▸ before every crumb.
    private var crumbRects: [NSRect] {
        let box = addressBox
        var x = box.minX + 4 + 16 + 4 + 14
        return crumbs.map { c in
            let w = ceil((c.title as NSString).size(withAttributes: [.font: Self.font]).width) + 10
            defer { x += w + 14 }
            return NSRect(x: x, y: box.minY + 1, width: min(w, max(0, box.maxX - 2 - x)), height: box.height - 2)
        }
    }

    override func layout() {
        super.layout()
        let box = searchBox
        let h = ceil(search.intrinsicContentSize.height)
        search.frame = NSRect(x: box.minX + 5, y: box.midY - h / 2, width: box.width - 28, height: h)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let active = window?.isKeyWindow ?? true
        // The glass continues the caption's: its lower colour, flat, as the frame's sides draw it.
        ctx.saveGState()
        ctx.clip(to: bounds)
        W7DrawGlassFill(ctx, CGRect(x: 0, y: 0, width: bounds.width, height: 10_000), active)
        ctx.restoreGState()
        Self.separatorLine.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        let back = rect(.back), forward = rect(.forward)
        W7DrawNavTrough(ctx, NSRect(x: back.minX + 2, y: floor((bounds.height - 22) / 2), width: forward.maxX - back.minX - 1, height: 22))
        W7DrawNavButton(ctx, forward, true, state(.forward, enabled: canGoForward))
        W7DrawNavButton(ctx, back, false, state(.back, enabled: canGoBack))

        let box = addressBox
        W7DrawAddressBar(ctx, box, false)
        addressIcon(16).draw(in: NSRect(x: box.minX + 4, y: box.midY - 8, width: 16, height: 16))
        let rects = crumbRects
        for (i, crumb) in crumbs.enumerated() {
            let r = rects[i]
            guard r.width > 4 else { break }
            W7DrawChevron(ctx, CGPoint(x: r.minX - 7, y: box.midY), .right, 0x000000, 0.8)
            let st = state(.crumb(i), enabled: true)
            if st == .hover || st == .pressed { W7DrawAddressButton(ctx, r, st) }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let size = (crumb.title as NSString).size(withAttributes: [.font: Self.font])
            (crumb.title as NSString).draw(in: NSRect(x: r.minX + 5, y: r.midY - size.height / 2, width: r.width - 6, height: size.height),
                                           withAttributes: [.font: Self.font, .foregroundColor: NSColor.black, .paragraphStyle: style])
        }
        W7DrawSearchBox(ctx, searchBox, search.currentEditor() != nil, !search.stringValue.isEmpty)
    }

    private func state(_ p: Part, enabled: Bool) -> W7ControlState {
        guard enabled else { return .disabled }
        if pressed == p && hover == p { return .pressed }
        return hover == p && pressed == nil ? .hover : .normal
    }

    // MARK: Mouse

    private func part(at p: NSPoint) -> Part? {
        for orb in [Part.back, .forward] {
            let r = rect(orb)
            if hypot(p.x - r.midX, p.y - r.midY) <= r.width / 2 { return orb }
        }
        if !search.stringValue.isEmpty && rect(.clear).contains(p) { return .clear }
        return crumbRects.indices.first { crumbRects[$0].contains(p) }.map { Part.crumb($0) }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = part(at: convert(event.locationInWindow, from: nil))
        if p != hover { hover = p; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hover != nil { hover = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        pressed = part(at: convert(event.locationInWindow, from: nil))
        hover = pressed
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = part(at: convert(event.locationInWindow, from: nil))
        if p != hover { hover = p; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let hit = part(at: convert(event.locationInWindow, from: nil))
        let was = pressed
        pressed = nil
        needsDisplay = true
        guard let hit, hit == was else { return }
        switch hit {
        case .back: if canGoBack { onBack?() }
        case .forward: if canGoForward { onForward?() }
        case .crumb(let i): if i < crumbs.count { onCrumb?(crumbs[i].location) }
        case .clear:
            clearSearch()
            onSearch?("")
        }
    }

    // MARK: Search field

    func controlTextDidChange(_ obj: Notification) {
        needsDisplay = true
        onSearch?(search.stringValue)
    }
    func controlTextDidBeginEditing(_ obj: Notification) { needsDisplay = true }

    /// Return searches when the window asked for it (`onSubmit`); Esc empties a box holding text.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)), let onSubmit {
            onSubmit(search.stringValue)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)), !search.stringValue.isEmpty {
            clearSearch()
            onSearch?("")
            return true
        }
        return false
    }
    func controlTextDidEndEditing(_ obj: Notification) { needsDisplay = true }
}
