import AppKit
import Win7ChromeCore
import Win7Theme

/// Window corners: a decorated window as it reaches the screen. The window is drawn as macOS shapes it
/// (its corner radii and its own 1 pt edge line, here dark so a gap would show), the frame overlay on top; the
/// gallery shows 4× crops of its corners, one row per corner path.
@MainActor
enum FrameCornersRender {
    /// A rect with its top corners rounded by `top` and its bottom ones by `bottom` (non-flipped).
    static func roundedRect(_ r: CGRect, top: CGFloat, bottom: CGFloat) -> CGPath {
        let lim = min(r.width, r.height) / 2, t = min(top, lim), b = min(bottom, lim)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX + b, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: b)
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: t)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: t)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: b)
        p.closeSubpath()
        return p
    }

    /// The decorated window inside its shape: white client, the caption (W7DrawCaptionGlassSlice, as the title
    /// bar draws it under an overlay) with its title and caption buttons, and macOS's edge line along the shape.
    static func drawWindow(_ ctx: CGContext, _ window: CGRect, top: CGFloat, bottom: CGFloat, active: Bool, title: String) {
        let shape = roundedRect(window, top: top, bottom: bottom)
        let caption = CGRect(x: window.minX, y: window.maxY - W7TitlebarHeight, width: window.width, height: W7TitlebarHeight)
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(window)
        W7DrawCaptionGlassSlice(ctx, caption, caption, active)
        let r = W7CaptionLayout(caption)
        W7DrawCaptionButton(ctx, r.minimize, .minimize, .normal)
        W7DrawCaptionButton(ctx, r.maximize, .maximize, .normal)
        W7DrawCaptionButton(ctx, r.close, .close, .normal)
        let font = W7UIFont(12)
        let h = ceil(font.ascender - font.descender)
        W7DrawGlassText(title, CGRect(x: caption.minX + 30, y: caption.midY - h / 2, width: max(0, r.minimize.minX - caption.minX - 36),
                                      height: h), font, .left)
        ctx.restoreGState()
        let edge = roundedRect(window.insetBy(dx: 0.5, dy: 0.5), top: max(0, top - 0.5), bottom: max(0, bottom - 0.5))
        ctx.addPath(edge)
        ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    /// Wallpaper, then a window of `windowTop` / `windowBottom` radii with its overlay framing it; `bounds` is the
    /// overlay's frame.
    static func drawScene(_ ctx: CGContext, canvas: CGRect, bounds: CGRect, windowTop: CGFloat, windowBottom: CGFloat,
                          active: Bool, title: String) {
        W7DrawWallpaper(ctx, canvas.insetBy(dx: -200, dy: -200))
        let window = W7FrameBorderHoleRect(bounds)
        drawWindow(ctx, window, top: windowTop, bottom: windowBottom, active: active, title: title)
        W7DrawFrameBorder(ctx, bounds, window, windowTop, windowBottom, W7TitlebarHeight, active)
    }

    static let cornerCrop: CGFloat = 24, zoom: CGFloat = 4, gap: CGFloat = 8
    static var cornersSize: NSSize {
        let tile = cornerCrop * zoom
        return NSSize(width: 3 * tile + 4 * gap, height: 2 * tile + 3 * gap)
    }

    /// 4× crops (top-left, top-right, bottom-left) of an active framed window: the top row with macOS's 16 pt
    /// corners under the overlay's wedges (the wedge path), the bottom row with the window's own Windows 7
    /// radii, 6 pt top and square bottom (the radius path). Neither row may show an arc, a dark edge line or a
    /// change of tone at the window's corners: only the frame's 6 pt outer top corners and square bottom ones.
    static func drawCorners(_ ctx: CGContext, _ size: NSSize) {
        ctx.setFillColor(CGColor(srgbRed: 0xF0 / 255.0, green: 0xF0 / 255.0, blue: 0xF0 / 255.0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let margin: CGFloat = 8
        let bounds = CGRect(x: margin, y: margin, width: 176, height: 118)
        let canvas = CGRect(x: 0, y: 0, width: bounds.maxX + margin, height: bounds.maxY + margin)
        let scale = CGFloat(Renderer.scale)
        let c = cornerCrop
        // Crops in canvas points, bottom-left origin: 4 pt of desktop outside the overlay's corner.
        let crops = [CGRect(x: bounds.minX - 4, y: bounds.maxY + 4 - c, width: c, height: c),
                     CGRect(x: bounds.maxX + 4 - c, y: bounds.maxY + 4 - c, width: c, height: c),
                     CGRect(x: bounds.minX - 4, y: bounds.minY - 4, width: c, height: c)]
        for (row, radii) in [(16.0, 16.0), (W7FrameOuterRadius, 0)].enumerated() {
            guard let scene = image(canvas.size, scale: scale, { ctx in
                drawScene(ctx, canvas: canvas, bounds: bounds, windowTop: radii.0, windowBottom: radii.1, active: true, title: "Notepad")
            }) else { continue }
            for (col, crop) in crops.enumerated() {
                // CGImage pixels are top-left origin.
                let px = CGRect(x: crop.minX * scale, y: (canvas.height - crop.maxY) * scale, width: c * scale, height: c * scale)
                guard let part = scene.cropping(to: px) else { continue }
                let tile = c * zoom
                let dest = CGRect(x: gap + CGFloat(col) * (tile + gap), y: size.height - CGFloat(row + 1) * (tile + gap),
                                  width: tile, height: tile)
                ctx.interpolationQuality = .none
                ctx.draw(part, in: dest)
            }
        }
    }

    /// Draws into a `scale`× sRGB bitmap (user space in points, origin bottom-left).
    static func image(_ size: NSSize, scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        draw(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
