import Testing
import AppKit
import Win7Theme

/// The procedural "Harmony-style" default wallpaper: a deep blue base with a soft central
/// brightening, light ribbons sweeping from the lower left to the upper right, and no logo.
@Suite struct WallpaperTests {
    /// Raw RGBA8 bytes (premultiplied, top-down) of the wallpaper drawn into a `width`×`height` rect.
    static func bytes(_ width: Int, _ height: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            W7DrawWallpaper(ctx, CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }

    static func wallpaper(_ width: Int, _ height: Int) -> (Int, Int) -> Pixel {
        render(width: width, height: height) { W7DrawWallpaper($0, CGRect(x: 0, y: 0, width: width, height: height)) }
    }

    /// The base alone, as specified, at unit position (u, v) with v measured from the top:
    /// the vertical #0B3D91 → #1A64C8 (60%) → #0E4FA8 gradient under #3D8BEA at 0.55 fading to 0 over
    /// 0.65 × the width from (52%, 46%).
    static func base(u: Double, v: Double, aspect: Double) -> (r: Double, g: Double, b: Double) {
        func rgb(_ hex: Int) -> [Double] { [Double(hex >> 16 & 0xFF), Double(hex >> 8 & 0xFF), Double(hex & 0xFF)] }
        func mix(_ a: [Double], _ b: [Double], _ t: Double) -> [Double] { zip(a, b).map { $0 + ($1 - $0) * t } }
        let vertical = v <= 0.6 ? mix(rgb(0x0B3D91), rgb(0x1A64C8), v / 0.6)
                                : mix(rgb(0x1A64C8), rgb(0x0E4FA8), (v - 0.6) / 0.4)
        // Distances in units of the width: the height is 1 / aspect widths.
        let d = hypot(u - 0.52, (v - 0.46) / aspect)
        let alpha = 0.55 * max(0, 1 - d / 0.65)
        let c = mix(vertical, rgb(0x3D8BEA), alpha)
        return (c[0], c[1], c[2])
    }

    static func close(_ p: Pixel, _ c: (r: Double, g: Double, b: Double), _ tolerance: Double) -> Bool {
        abs(Double(p.r) - c.r) <= tolerance && abs(Double(p.g) - c.g) <= tolerance && abs(Double(p.b) - c.b) <= tolerance
    }

    @Test func topAndBottomAreTheDeepBlueBase() {
        let px = Self.wallpaper(320, 200)
        let top = px(2, 197), bottom = px(317, 2)
        #expect(top.a == 255 && bottom.a == 255)
        // The corners are almost untouched by the central brightening and away from every ribbon.
        #expect(Self.close(top, (0x0B, 0x3D, 0x91), 8), "top \(top)")
        #expect(Self.close(bottom, (0x0E, 0x4F, 0xA8), 8), "bottom \(bottom)")
        #expect(Self.close(top, Self.base(u: 2.5 / 320, v: 2.5 / 200, aspect: 1.6), 3), "top vs model \(top)")
        #expect(Self.close(bottom, Self.base(u: 317.5 / 320, v: 197.5 / 200, aspect: 1.6), 3), "bottom vs model \(bottom)")
    }

    /// The middle band is the brighter #1A64C8 lifted by the central brightening, clearly lighter than the top.
    @Test func middleIsBrighterThanTheTop() {
        let px = Self.wallpaper(320, 200)
        let top = px(2, 197), middle = px(2, 80)
        #expect(middle.b > top.b + 25 && middle.g > top.g + 20, "middle \(middle) top \(top)")
    }

    /// A point on the broadest ribbon, away from the bloom, is clearly lighter than the base under it.
    @Test func ribbonIsBrighterThanTheBase() {
        let (w, h) = (640, 400)
        let px = Self.wallpaper(w, h)
        let (u, v) = (0.196, 0.708)   // on the centre line of the broadest ribbon (its Bézier at t = 0.3)
        let p = px(Int(u * Double(w)), Int((1 - v) * Double(h)))
        let base = Self.base(u: u, v: v, aspect: 1.6)
        #expect(Double(p.r) >= base.r + 30 && Double(p.g) >= base.g + 30, "ribbon \(p) base \(base)")
    }

    @Test func rendersAreDeterministic() {
        #expect(Self.bytes(480, 300) == Self.bytes(480, 300))
    }

    /// The composition is laid out in proportions of the rect: the same relative points match at
    /// different pixel sizes.
    @Test func isResolutionIndependent() {
        let small = Self.wallpaper(320, 200), large = Self.wallpaper(1280, 800)
        for (u, v) in [(0.01, 0.01), (0.99, 0.99), (0.196, 0.708), (0.62, 0.40), (0.30, 0.15), (0.80, 0.85)] {
            let a = small(Int(u * 320), Int((1 - v) * 200)), b = large(Int(u * 1280), Int((1 - v) * 800))
            #expect(abs(a.r - b.r) <= 8 && abs(a.g - b.g) <= 8 && abs(a.b - b.b) <= 8, "(\(u), \(v)) \(a) \(b)")
        }
    }

    /// The draw stays inside its rect: a wallpaper drawn into the left half leaves the right half clear.
    @Test func staysInsideItsRect() {
        let px = render(width: 200, height: 100) { W7DrawWallpaper($0, CGRect(x: 0, y: 0, width: 100, height: 100)) }
        #expect(px(50, 50).a == 255)
        #expect(px(150, 50).a == 0 && px(101, 10).a == 0 && px(199, 99).a == 0)
    }
}
