import AppKit
import Win7Core
import Win7Theme

/// The glass frame round a flyout: `W7DrawGlassFrame` with a white content area inset by `border`.
private final class FlyoutFrameView: NSView {
    static let border: CGFloat = 6

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        W7DrawGlassFrame(ctx, bounds, true)
        let inner = bounds.insetBy(dx: FlyoutFrameView.border, dy: FlyoutFrameView.border)
        NSColor.white.setFill()
        inner.fill()
        NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35).setStroke()
        NSBezierPath(rect: inner.insetBy(dx: -0.5, dy: -0.5)).stroke()
    }
}

/// A Windows 7 notification area flyout: a borderless glass panel above the clicked tray item,
/// right-aligned to it and kept on screen. The glass sits on the taskbar's dark behind-window blur
/// (`GlassBlur`), so what lies behind the flyout doesn't show sharply through its frame. It becomes
/// key (the shell activates first) and closes on Esc, when it resigns key, or on another tray click.
/// Only one flyout is open at a time.
@MainActor
final class TrayFlyout: NSPanel {
    /// The open flyout. Held strongly: nothing else keeps an open panel alive.
    private(set) static var current: TrayFlyout?
    /// What opened the flyout, so a second click on the same tray item closes it instead.
    let owner: String
    var onClose: (() -> Void)?
    private var closing = false
    private let content: NSView

    /// Closes the open flyout, if any. Returns the owner of the flyout that was closed.
    @discardableResult
    static func closeCurrent() -> String? {
        guard let f = current else { return nil }
        f.dismiss()
        return f.owner
    }

    /// Shows `content` (sized by its frame) above `anchor`, a rect in screen coordinates.
    @discardableResult
    static func show(_ content: NSView, owner: String, above anchor: NSRect) -> TrayFlyout {
        closeCurrent()
        let flyout = TrayFlyout(content: content, owner: owner)
        flyout.place(above: anchor)
        current = flyout
        NSApp.activate()
        flyout.makeKeyAndOrderFront(nil)
        return flyout
    }

    private init(content: NSView, owner: String) {
        self.owner = owner
        self.content = content
        let b = FlyoutFrameView.border
        let size = NSSize(width: content.frame.width + b * 2, height: content.frame.height + b * 2)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: ShellWindowLevels.trayFlyout)
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        let frameView = FlyoutFrameView(frame: NSRect(origin: .zero, size: size))
        content.setFrameOrigin(NSPoint(x: b, y: b))
        frameView.addSubview(content)
        contentView = GlassBlur.host(frameView, cornerRadius: 6)
        initialFirstResponder = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private func place(above anchor: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens.first
        var origin = NSPoint(x: anchor.maxX - frame.width, y: anchor.maxY + 2)
        if let s = screen?.frame {
            origin.x = min(max(origin.x, s.minX + 4), s.maxX - frame.width - 4)
            origin.y = min(origin.y, s.maxY - frame.height)
        }
        setFrameOrigin(origin)
    }

    /// Resizes the panel to its content's current size, keeping its bottom and right edges, so a
    /// flyout whose content grows (more messages, more networks) grows upward.
    func fitContent() {
        let b = FlyoutFrameView.border
        let size = NSSize(width: content.frame.width + b * 2, height: content.frame.height + b * 2)
        guard size != frame.size else { return }
        var r = NSRect(origin: NSPoint(x: frame.maxX - size.width, y: frame.minY), size: size)
        if let s = screen?.frame { r.origin.y = min(r.origin.y, s.maxY - size.height) }
        setFrame(r, display: true)
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss() } else { super.keyDown(with: event) }
    }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    func dismiss() {
        guard !closing else { return }
        closing = true
        if TrayFlyout.current === self { TrayFlyout.current = nil }
        orderOut(nil)
        // Removing the content stops its timers (the clock face only ticks while it has a window).
        contentView?.subviews.forEach { $0.removeFromSuperview() }
        onClose?()
    }
}

// MARK: - Shared flyout widgets

/// A blue Windows 7 link label that runs `action` when clicked.
@MainActor
final class FlyoutLink: NSView {
    private let title: String
    private let action: () -> Void
    private var hover = false
    static let font = W7UIFont(12)
    static let color = NSColor(srgbRed: 0x00 / 255.0, green: 0x66 / 255.0, blue: 0xCC / 255.0, alpha: 1)

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
        let w = ceil((title as NSString).size(withAttributes: [.font: FlyoutLink.font]).width) + 2
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: 18))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        var attrs: [NSAttributedString.Key: Any] = [.font: FlyoutLink.font, .foregroundColor: FlyoutLink.color]
        if hover { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        (title as NSString).draw(at: NSPoint(x: 1, y: 1), withAttributes: attrs)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

/// Opens a System Settings pane and closes the flyout.
@MainActor
func openSettings(_ url: String) {
    TrayFlyout.closeCurrent()
    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
}

/// Opens a System Settings pane and closes the flyout.
@MainActor
func openSettings(_ pane: SettingsPane) {
    TrayFlyout.closeCurrent()
    NSWorkspace.shared.open(pane.url)
}

/// A plain label for flyout text.
@MainActor
func flyoutLabel(_ text: String, size: CGFloat = 12, color: NSColor = .black, bold: Bool = false) -> NSTextField {
    let f = NSTextField(labelWithString: text)
    f.font = bold ? NSFontManager.shared.convert(W7UIFont(size), toHaveTrait: .boldFontMask) : W7UIFont(size)
    f.textColor = color
    f.sizeToFit()
    return f
}
