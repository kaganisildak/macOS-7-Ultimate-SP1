import AppKit
import Win7Core

/// The user's icon overrides, `Assets/icons/<name>.png` (see IconOverrideNames and `make import-icons`):
/// read through AssetStore (the installed Assets first, then the repo's), each file once, its largest
/// representation kept and rendered per size as an image holding 1x and 2x bitmaps. A missing or unreadable
/// file is remembered as absent, so callers fall back to their drawn or system icon. The files are user data:
/// one over 2 MB, truncated, with an image over 1024 px, or reached through a symlink out of its folder counts as absent.
/// The files are read when first needed after the shell starts; restarting the shell picks up newly imported icons.
@MainActor
enum IconOverrides {
    private static var sources: [String: CGImage?] = [:]
    private static var sized = BoundedCache<String, NSImage>(capacity: 128)

    /// True when `icons/<name>.png` exists and decodes.
    static func has(_ name: String) -> Bool { source(name) != nil }

    /// `icons/<name>.png` aspect-fit into a `side`-point square, with 1x and 2x bitmaps; nil when absent.
    static func image(_ name: String, side: CGFloat) -> NSImage? {
        guard side > 0, let src = source(name) else { return nil }
        return sized.value(for: "\(name)|\(side)") {
            let image = NSImage(size: NSSize(width: side, height: side))
            for scale: CGFloat in [1, 2] {
                guard let cg = render(src, pixels: Int((side * scale).rounded())) else { continue }
                let rep = NSBitmapImageRep(cgImage: cg)
                rep.size = image.size
                image.addRepresentation(rep)
            }
            return image
        }
    }

    /// The `app-<bundle id>` override for an application at `side` points, or nil to use its own icon.
    static func app(_ bundleID: String?, side: CGFloat) -> NSImage? {
        IconOverrideNames.app(bundleID: bundleID).flatMap { image($0, side: side) }
    }

    /// A running process's icon: its `app-<bundle id>` override, else the application's own icon.
    static func app(pid: pid_t, side: CGFloat) -> NSImage? {
        let running = NSRunningApplication(processIdentifier: pid)
        return app(running?.bundleIdentifier, side: side) ?? running?.icon
    }

    /// Draws `icons/<name>.png` aspect-fit into the square `rect` of the current graphics context (flipped or
    /// not) and returns true, or returns false and draws nothing when it is absent.
    @discardableResult
    static func draw(_ name: String, in rect: NSRect) -> Bool {
        guard let img = image(name, side: min(rect.width, rect.height)) else { return false }
        let side = img.size.width
        img.draw(in: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        return true
    }

    private static func source(_ name: String) -> CGImage? {
        if let hit = sources[name] { return hit }
        // IconOverrideNames.decodeIcon: the file's largest image, or nil when it isn't a regular file directly in
        // its icons folder, is over 2 MB, isn't a complete PNG (truncated), has an image over 1024 px, or doesn't decode.
        let cg = AssetStore.shared.url("icons/\(name).png").flatMap { url in autoreleasepool { IconOverrideNames.decodeIcon(at: url) } }
        sources[name] = .some(cg)
        return cg
    }

    private static func render(_ image: CGImage, pixels: Int) -> CGImage? {
        guard pixels > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height), side = CGFloat(pixels)
        let s = min(side / max(w, 1), side / max(h, 1))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (side - w * s) / 2, y: (side - h * s) / 2, width: w * s, height: h * s))
        return ctx.makeImage()
    }
}
