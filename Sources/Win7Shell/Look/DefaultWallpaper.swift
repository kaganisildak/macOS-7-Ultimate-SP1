import AppKit
import Win7Theme

/// Renders the built-in Windows 7 style wallpaper (W7DrawWallpaper) to a PNG. Used by install.sh when no
/// Assets/wallpaper.jpg was imported.
enum DefaultWallpaper {
    /// Used when no screen is connected (or none can be read).
    static let fallbackSize = (width: 2880, height: 1800)

    /// The backing pixel size of the largest connected screen (by pixel count), so the picture is drawn
    /// at full resolution there and only scaled down on smaller displays.
    static func pixelSize(screens: [(size: CGSize, scale: CGFloat)]) -> (width: Int, height: Int) {
        let sizes = screens.map { (width: Int(($0.size.width * $0.scale).rounded()), height: Int(($0.size.height * $0.scale).rounded())) }
            .filter { $0.width > 0 && $0.height > 0 }
        return sizes.max { $0.width * $0.height < $1.width * $1.height } ?? fallbackSize
    }

    @discardableResult
    static func write(to path: String) -> Bool {
        let (width, height) = pixelSize(screens: NSScreen.screens.map { ($0.frame.size, $0.backingScaleFactor) })
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        W7DrawWallpaper(ctx, CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            // Atomic: a regenerated picture replaces the old file in one step (a new file, not a rewrite).
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
