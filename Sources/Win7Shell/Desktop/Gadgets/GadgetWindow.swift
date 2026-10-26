import AppKit
import Win7Core
import Win7Theme

/// A gadget's content. Gadgets draw themselves (non-flipped, like Win7Theme's drawing) and get clicks
/// that weren't drags; `start`/`stop` run their timers while the gadget is on the desktop.
@MainActor
class GadgetContentView: NSView {
    func start() {}
    func stop() {}
    /// A click (not a drag) at `point`, in the view's coordinates.
    func click(at point: NSPoint) {}
    /// The pointer moved over the gadget at `point` (view coordinates), or left it (nil).
    func hover(at point: NSPoint?) {}
    /// The mouse button went down at `point`, or came up or turned into a drag (nil).
    func press(at point: NSPoint?) {}
    /// The gadget has an Options dialog: the toolbar's options button and the context menu's Options open it.
    var hasOptions: Bool { false }
    func showOptions() {}
}

/// A Windows 7 desktop gadget: a borderless window just above the desktop window and below normal
/// windows, on every Space. Dragging anywhere moves it; hovering shows the toolbar at its right edge
/// (× closes; the options button is enabled when the gadget has options). Right-click: Add gadgets...,
/// Options, Close gadget.
@MainActor
final class GadgetWindow: NSPanel {
    static let level = NSWindow.Level(rawValue: DesktopWindow.level.rawValue + 1)

    let kind: GadgetKind
    let content: GadgetContentView
    /// The gadget was dragged; the argument is the content's new bottom-left corner on screen.
    var onMoved: ((NSPoint) -> Void)?
    var onClose: (() -> Void)?
    var onAddGadgets: (() -> Void)?

    init(kind: GadgetKind, content: GadgetContentView) {
        self.kind = kind
        self.content = content
        let size = NSSize(width: kind.size.width + GadgetBoard.toolbarWidth, height: kind.size.height)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = GadgetWindow.level
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        let frameView = GadgetFrameView(content: content)
        frameView.owner = self
        contentView = frameView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Puts the content's bottom-left corner at `origin`.
    func place(contentOrigin origin: NSPoint) { setFrameOrigin(origin) }
}

private final class GadgetFrameView: NSView {
    weak var owner: GadgetWindow?
    private let content: GadgetContentView
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var hoverButton = -1 { didSet { if hoverButton != oldValue { needsDisplay = true } } }
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var dragged = false
    private var tracking: NSTrackingArea?

    init(content: GadgetContentView) {
        self.content = content
        super.init(frame: .zero)
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var toolbarRect: NSRect {
        NSRect(x: bounds.maxX - GadgetBoard.toolbarWidth, y: bounds.maxY - 60, width: GadgetBoard.toolbarWidth, height: 60)
    }

    override func layout() {
        super.layout()
        content.frame = NSRect(x: 0, y: 0, width: bounds.width - GadgetBoard.toolbarWidth, height: bounds.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseEntered(with event: NSEvent) { hovering = true; forwardHover(event) }
    override func mouseExited(with event: NSEvent) { hovering = false; hoverButton = -1; content.hover(at: nil) }
    override func mouseMoved(with event: NSEvent) {
        hovering = true
        hoverButton = button(at: convert(event.locationInWindow, from: nil))
        forwardHover(event)
    }

    private func forwardHover(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        content.hover(at: content.frame.contains(p) ? content.convert(p, from: self) : nil)
    }

    private func button(at p: NSPoint) -> Int {
        for i in 0..<2 where W7GadgetToolbarButtonRect(toolbarRect, i).contains(p) { return i }
        return -1
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering, let ctx = NSGraphicsContext.current?.cgContext else { return }
        W7DrawGadgetToolbarWithOptions(ctx, toolbarRect, hoverButton, content.hasOptions)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        if button(at: p) >= 0 { dragStart = nil; return }
        dragStart = (NSEvent.mouseLocation, window?.frame.origin ?? .zero)
        dragged = false
        if content.frame.contains(p) { content.press(at: content.convert(p, from: self)) }
    }

    /// Windows 7's gadget menu, trimmed to what the shell has.
    override func rightMouseDown(with event: NSEvent) {
        dragStart = nil
        content.press(at: nil)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(DesktopActions.item("Add gadgets...") { [weak self] in self?.owner?.onAddGadgets?() })
        let options = DesktopActions.item("Options") { [weak self] in self?.content.showOptions() }
        options.isEnabled = content.hasOptions
        menu.addItem(options)
        menu.addItem(.separator())
        menu.addItem(DesktopActions.item("Close gadget") { [weak self] in self?.owner?.onClose?() })
        NSApp.activate()
        ShellMenus.show(menu, at: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let window else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - start.mouse.x, dy = m.y - start.mouse.y
        if !dragged, hypot(dx, dy) < 3 { return }
        if !dragged { content.press(at: nil) }
        dragged = true
        window.setFrameOrigin(NSPoint(x: start.origin.x + dx, y: start.origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer { dragStart = nil; dragged = false }
        if dragStart == nil {
            switch button(at: p) {
            case 0: owner?.onClose?()
            case 1: if content.hasOptions { content.showOptions() }
            default: break
            }
            return
        }
        if !dragged { content.press(at: nil) }
        if dragged {
            if let w = owner { w.onMoved?(w.frame.origin) }
        } else if content.frame.contains(p) {
            content.click(at: content.convert(p, from: self))
        }
    }
}
