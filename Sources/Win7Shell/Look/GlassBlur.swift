import AppKit

/// The blur under Aero glass. Windows 7 blurs whatever lies behind its glass; the shell's glass
/// surfaces (taskbar, Start menu) draw a translucent tint, so they sit on a dark behind-window blur and
/// nothing behind them shows sharply. The theme's tints are calibrated on this blur (Global Constraints).
@MainActor
enum GlassBlur {
    /// A container holding the blur, then `content` filling it. `cornerRadius` clips the blur to the
    /// content's rounded outline.
    static func host(_ content: NSView, cornerRadius: CGFloat = 0) -> NSView {
        let container = NSView(frame: content.frame)
        let blur = NSVisualEffectView(frame: container.bounds)
        blur.material = .hudWindow
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        if cornerRadius > 0 { blur.maskImage = roundedMask(cornerRadius) }
        container.addSubview(blur)
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
        return container
    }

    /// A stretchable rounded-rect mask with `radius` corners.
    private static func roundedMask(_ radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
