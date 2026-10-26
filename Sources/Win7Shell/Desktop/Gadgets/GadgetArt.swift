import AppKit
import ImageIO
import Win7Core
import Win7Theme

/// A gadget's Windows 7 artwork, imported from the user's own media into Assets/gadgets/<folder>/images/ (see
/// README "Gadgets"). Each file is looked up once per view. Without the files a gadget keeps its drawn look, and one
/// log line per gadget kind says which file was missing.
@MainActor
final class GadgetArt {
    let folder: String
    let kind: GadgetKind
    private var cache: [String: NSImage?] = [:]
    private static var logged: Set<GadgetKind> = []

    init(folder: String, kind: GadgetKind) {
        self.folder = folder
        self.kind = kind
    }

    /// The largest file and side accepted (the largest gadget picture is 360×280); anything bigger counts as missing.
    static let maxFileBytes = 2 * 1024 * 1024
    static let maxPixels = 1024

    /// `images/<file>` of this gadget, e.g. "trad_h.png" or "on_desktop/slideshow_glass_frame.png", decoded once, one
    /// point per pixel as the gadget's HTML lays it out (some of the PNGs say 96 dpi, which NSImage would shrink).
    /// Nil when it is missing, too large, or does not decode completely, so the gadget falls back instead of drawing
    /// a blank.
    func image(_ file: String) -> NSImage? {
        if let hit = cache[file] { return hit }
        let img = Self.load(AssetStore.shared.url("gadgets/\(folder)/images/\(file)"))
        cache[file] = .some(img)
        return img
    }

    private static func load(_ url: URL?) -> NSImage? {
        guard let url,
              let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              bytes > 0, bytes <= maxFileBytes,
              let data = try? Data(contentsOf: url), isComplete(data),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(src, 0) == .statusComplete,
              cg.width > 0, cg.height > 0, cg.width <= maxPixels, cg.height <= maxPixels else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// ImageIO decodes a cut-off PNG as complete (the missing rows clear), so the file must end the way its format
    /// ends: a PNG with its IEND chunk, a JPEG with FFD9, a GIF with its 3B trailer.
    private static func isComplete(_ d: Data) -> Bool {
        let b = [UInt8](d.prefix(4)), tail = [UInt8](d.suffix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return tail.count == 12 && Array(tail[4..<8]) == Array("IEND".utf8) }
        if b.starts(with: [0xFF, 0xD8]) {   // FFD9, allowing a little padding after it
            let end = [UInt8](d.suffix(64))
            return zip(end, end.dropFirst()).contains { $0 == 0xFF && $1 == 0xD9 }
        }
        if b.starts(with: Array("GIF".utf8)) { return tail.last == 0x3B }
        return false
    }

    /// True when every file is there, without logging.
    func exists(_ files: [String]) -> Bool { files.allSatisfy { image($0) != nil } }

    /// True when every file is there; otherwise false, and the first time per kind a log line names the missing ones.
    func has(_ files: [String]) -> Bool {
        let missing = files.filter { image($0) == nil }
        if !missing.isEmpty, Self.logged.insert(kind).inserted {
            NSLog("Win7Shell: \(kind.title) gadget keeps its drawn look: \(missing.joined(separator: ", ")) not imported "
                  + "(Assets/gadgets/\(folder)/images/; see README \"Gadgets\")")
        }
        return missing.isEmpty
    }
}

// MARK: - Drawing at the HTML's top-left positions in a non-flipped gadget view

/// A gadget view's drawing helpers: rects and baselines are top-left measurements (Win7Core's GadgetLayout), turned
/// into the non-flipped view's coordinates with its height.
@MainActor
struct GadgetCanvas {
    let height: CGFloat

    func rect(_ r: CGRect) -> NSRect { GadgetLayout.flip(r, height: height) }

    /// A top-left point of the view (for hit tests against GadgetLayout rects).
    func topLeft(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: height - p.y) }

    /// `image` at its own size with its top-left corner at `origin`.
    func draw(_ image: NSImage, at origin: CGPoint) {
        draw(image, in: CGRect(origin: origin, size: image.size))
    }

    func draw(_ image: NSImage, in r: CGRect) {
        image.draw(in: rect(r), from: .zero, operation: .sourceOver, fraction: 1)
    }

    /// `image` drawn in `r`, turned `degrees` clockwise about the rect's centre (the gadgets' g:image Rotation). With
    /// `shadow`, the gadgets' addShadow("grey", 2, 40, 2, 2): grey at 40 %, blur 2, 2 pt right and down.
    func draw(_ image: NSImage, in r: CGRect, rotated degrees: Double, shadow: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let box = rect(r)
        ctx.saveGState()
        if shadow {
            ctx.setShadow(offset: CGSize(width: 2, height: -2), blur: 2,
                          color: CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 0.4))
        }
        ctx.translateBy(x: box.midX, y: box.midY)
        ctx.rotate(by: -degrees * .pi / 180)
        ctx.interpolationQuality = .high
        image.draw(in: NSRect(x: -box.width / 2, y: -box.height / 2, width: box.width, height: box.height),
                   from: .zero, operation: .sourceOver, fraction: 1)
        ctx.restoreGState()
    }

    enum Align { case left, center, right }

    /// One line of text with its baseline `baseline` from the top, its left edge, centre or right edge at `x`,
    /// shortened with "…" to `maxWidth`.
    func text(_ s: String, font: NSFont, color: NSColor, x: CGFloat, baseline: CGFloat, align: Align = .left,
              maxWidth: CGFloat = .greatestFiniteMagnitude) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var shown = s
        var width = (shown as NSString).size(withAttributes: attrs).width
        while width > maxWidth, shown.count > 1 {
            shown = String(shown.dropLast(shown.hasSuffix("…") ? 2 : 1)) + "…"
            width = (shown as NSString).size(withAttributes: attrs).width
        }
        let left: CGFloat
        switch align {
        case .left: left = x
        case .center: left = x - width / 2
        case .right: left = x - width
        }
        // Without .usesLineFragmentOrigin the rect's origin is the first line's baseline.
        (shown as NSString).draw(with: NSRect(x: left, y: height - baseline, width: width + 2, height: font.pointSize * 2),
                                 options: [], attributes: attrs, context: nil)
    }
}

/// Fonts the gadgets name in their CSS, when the user has them installed; otherwise Segoe UI (W7UIFont) or the
/// system font.
@MainActor
enum GadgetFonts {
    static func segoe(_ size: CGFloat, bold: Bool = false) -> NSFont {
        let f = W7UIFont(size)
        return bold ? NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) : f
    }

    /// cpu.css: Calibri 10 px, bold (the body's font-weight).
    static func calibriBold(_ size: CGFloat) -> NSFont {
        NSFont(name: "Calibri-Bold", size: size) ?? segoe(size, bold: true)
    }
}
