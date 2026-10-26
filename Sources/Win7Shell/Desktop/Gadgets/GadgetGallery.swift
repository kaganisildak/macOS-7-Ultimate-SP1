import AppKit
import Win7Core
import Win7Theme

/// Windows 7's gadget gallery: an Aero-framed window with a tile per gadget (its picture and name).
/// Double-click a tile, or select it and press Add, to put the gadget on the desktop.
@MainActor
final class GadgetGallery: AeroDialog {
    static let tile = CGSize(width: 96, height: 104)
    static let spacing: CGFloat = 12

    private let tiles: GadgetTilesView
    private var addButton: NSButton!

    init(onAdd: @escaping (GadgetKind) -> Void) {
        let count = GadgetKind.allCases.count
        let width = Self.spacing + CGFloat(count) * (Self.tile.width + Self.spacing)
        let height = Self.spacing * 2 + Self.tile.height + 46
        tiles = GadgetTilesView(onAdd: onAdd)
        super.init(title: "Gadgets", size: NSSize(width: width, height: height))
        tiles.frame = NSRect(x: 0, y: 0, width: width, height: height - 46)
        body.addSubview(tiles)
        let close = bandButton("Close", slot: 0, action: #selector(closeGallery(_:)))
        close.keyEquivalent = "\u{1b}"
        addButton = bandButton("Add", slot: 1, action: #selector(addSelected(_:)))
        addButton.keyEquivalent = "\r"
        tiles.onSelectionChange = { [weak self] in self?.addButton.isEnabled = $0 != nil }
        addButton.isEnabled = false
    }

    func present() {
        if !isVisible, let screen = NSScreen.screens.first {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.midY - frame.height / 2))
        }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    override func cancelOperation(_ sender: Any?) { close() }
    @objc private func closeGallery(_ sender: Any?) { close() }
    @objc private func addSelected(_ sender: Any?) { tiles.addSelected() }
}

/// The gallery's tiles, laid out by GadgetGalleryLayout (flipped: top-left origin).
private final class GadgetTilesView: NSView {
    private let kinds = GadgetKind.allCases
    private let onAdd: (GadgetKind) -> Void
    private var selected: Int? { didSet { needsDisplay = true; onSelectionChange?(selected) } }
    private var hover: Int? { didSet { if hover != oldValue { needsDisplay = true } } }
    private var previews: [GadgetKind: NSImage] = [:]
    private var tracking: NSTrackingArea?
    var onSelectionChange: ((Int?) -> Void)?

    init(onAdd: @escaping (GadgetKind) -> Void) {
        self.onAdd = onAdd
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var rects: [CGRect] {
        GadgetGalleryLayout.tileRects(count: kinds.count, width: bounds.width, tile: GadgetGallery.tile, spacing: GadgetGallery.spacing)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        hover = GadgetGalleryLayout.index(at: convert(event.locationInWindow, from: nil), in: rects)
    }
    override func mouseExited(with event: NSEvent) { hover = nil }

    override func mouseDown(with event: NSEvent) {
        let i = GadgetGalleryLayout.index(at: convert(event.locationInWindow, from: nil), in: rects)
        selected = i
        if event.clickCount >= 2, let i { onAdd(kinds[i]) }
    }

    func addSelected() {
        if let selected { onAdd(kinds[selected]) }
    }

    /// The gadget itself, drawn once at its size; the tile scales it down.
    private func preview(_ kind: GadgetKind) -> NSImage {
        if let hit = previews[kind] { return hit }
        let view = GadgetController.content(for: kind, preview: true)
        let image = NSImage(size: kind.size)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            image.addRepresentation(rep)
        }
        previews[kind] = image
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        let rs = rects
        for (i, kind) in kinds.enumerated() {
            let r = rs[i]
            if selected == i || hover == i, let ctx = NSGraphicsContext.current?.cgContext {
                // W7DrawNavPaneRow expects a non-flipped context: flip locally around the tile.
                ctx.saveGState()
                ctx.translateBy(x: 0, y: r.maxY + r.minY)
                ctx.scaleBy(x: 1, y: -1)
                W7DrawNavPaneRow(ctx, r, selected == i, hover == i && selected != i)
                ctx.restoreGState()
            }
            let img = preview(kind)
            let side: CGFloat = 72
            let s = min(side / img.size.width, side / img.size.height)
            let w = img.size.width * s, h = img.size.height * s
            img.draw(in: NSRect(x: r.midX - w / 2, y: r.minY + 6 + (side - h) / 2, width: w, height: h),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            (kind.title as NSString).draw(in: NSRect(x: r.minX, y: r.minY + 82, width: r.width, height: 18),
                                          withAttributes: [.font: W7UIFont(12), .foregroundColor: NSColor.black, .paragraphStyle: style])
        }
    }
}
