import AppKit
import Win7Core
import Win7Theme

private final class SnapPreviewView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        W7DrawSnapPreview(ctx, bounds.insetBy(dx: W7SnapPreviewInset, dy: W7SnapPreviewInset))
    }
}

/// Translucent Aero Snap outline. `show` takes an AppKit (bottom-left) frame.
@MainActor
final class SnapPreviewWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = NSWindow.Level(rawValue: ShellWindowLevels.snapPreview)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = SnapPreviewView()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(appKitFrame: NSRect) {
        if frame != appKitFrame { setFrame(appKitFrame, display: true) }
        if !isVisible { orderFrontRegardless() }
    }

    func hide() { orderOut(nil) }
}
