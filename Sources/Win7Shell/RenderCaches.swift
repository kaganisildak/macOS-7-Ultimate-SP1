import AppKit
import Win7Core
import Win7Theme

/// Icons pre-rendered at the size they are drawn. An app or file icon from NSWorkspace
/// carries representations up to 1024 px; drawing it picks one and scales it on every draw. These are
/// single-bitmap images of exactly `side` × `scale` pixels, drawn 1:1.
@MainActor
final class ScaledIconCache {
    static let shared = ScaledIconCache()

    private struct Key: Hashable {
        var id: String
        var side: CGFloat
        var scale: CGFloat
    }
    private var images = BoundedCache<Key, NSImage>(capacity: 256)

    /// The icon `id` (a bundle ID, path or type key) at `side` points for `scale`; `source` gives the
    /// full icon on a miss.
    func icon(_ id: String, side: CGFloat, scale: CGFloat, source: () -> NSImage) -> NSImage {
        images.value(for: Key(id: id, side: side, scale: scale)) {
            Self.render(source(), side: side, scale: scale) ?? source()
        }
    }

    func removeAll() { images.removeAll() }

    static func render(_ image: NSImage, side: CGFloat, scale: CGFloat) -> NSImage? {
        let px = Int((side * scale).rounded())
        guard px > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
    }
}

/// Taskbar button backgrounds pre-rendered per look (state, stack depth, glow colour, size and scale),
/// blitted instead of redrawing their gradients and paths on every hover.
@MainActor
final class TaskbarButtonImages {
    private var images = BoundedCache<TaskbarButtonLook, CGImage>(capacity: 96)

    func image(for look: TaskbarButtonLook, size: CGSize, scale: CGFloat, glow: CGColor?) -> CGImage? {
        if let hit = images.hit(look) { return hit }   // counts as a use for the LRU order
        guard let made = W7CreateTaskbarButtonImage(size, scale, look.running, look.active, look.hover, look.windows,
                                                    look.hover ? glow : nil) else { return nil }
        return images.value(for: look) { made }
    }

    func removeAll() { images.removeAll() }
}
