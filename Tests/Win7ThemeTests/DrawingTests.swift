import Testing
import AppKit
import Win7Theme

typealias Pixel = (r: Int, g: Int, b: Int, a: Int)

/// Draws into an sRGB premultiplied RGBA8 bitmap; returns un-premultiplied 0-255 values, origin bottom-left.
func render(width: Int, height: Int, _ draw: (CGContext) -> Void) -> (Int, Int) -> Pixel {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    var data = [UInt8](repeating: 0, count: width * height * 4)
    data.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
    }
    return { x, y in
        let row = height - 1 - y   // memory is top-down; y is bottom-up
        let i = (row * width + x) * 4
        let a = Int(data[i + 3])
        func un(_ v: UInt8) -> Int { a == 0 ? 0 : min(255, Int((Double(v) * 255.0 / Double(a)).rounded())) }
        return (un(data[i]), un(data[i + 1]), un(data[i + 2]), a)
    }
}

@Suite struct DrawingTests {
    @Test func hex() {
        let c = W7RGBAFromHex(0x74B8FC, 0.42)
        #expect(abs(c.r - 0x74 / 255.0) < 0.001 && c.a == 0.42)
    }

    @Test func customOrbIsAspectFitNotStretched() {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let src = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        src.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        src.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        let orb = src.makeImage()!
        let px = render(width: 54, height: 40) { W7DrawStartOrb($0, CGRect(x: 0, y: 0, width: 54, height: 40), .normal, orb) }
        #expect(px(5, 20).a == 0)
        #expect(px(27, 20).r == 255 && px(27, 20).a == 255)
    }

    /// The glass is blue and near-opaque on its own (W7DrawGlassFrame, no backdrop).
    @Test func activeGlassIsSkyBlue() {
        let px = render(width: 300, height: 60) { W7DrawGlassFrame($0, CGRect(x: 0, y: 0, width: 300, height: 60), true) }
        let p = px(150, 10)   // lower half: base + tint
        #expect(p.a >= 225)
        #expect(p.b - p.r >= 60, "\(p)")
    }

    /// the opaque caption (glass over white, as the title bar and the frame draw it) against the values sampled
    /// from the IE8 reference (composited over white; the caption averaged over x 400…990): #E1E9F3 highlight line under
    /// the outer line, #6C91C7 just under it, #6A8FC6 in the middle and at the bottom. Each within ±8/255.
    @Test func activeGlassMatchesTheIE8Reference() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 34)   // the reference caption: 34 px from line to nav row
        let px = render(width: 300, height: 34) { W7DrawGlassCaption($0, rect, true) }
        func near(_ p: Pixel, _ hex: UInt32, _ what: String) {
            let r = Int(hex >> 16 & 0xFF), g = Int(hex >> 8 & 0xFF), b = Int(hex & 0xFF)
            #expect(abs(p.r - r) <= 8 && abs(p.g - g) <= 8 && abs(p.b - b) <= 8 && p.a == 255, "\(what): \(p) vs #\(String(hex, radix: 16))")
        }
        near(px(150, 32), 0xE1E9F3, "highlight line")
        near(px(150, 31), 0x6C91C7, "top, under the highlight")
        near(px(150, 17), 0x6A8FC6, "middle")
        near(px(150, 0), 0x6A8FC6, "bottom")
        // The side frame below the caption (the frame overlay's flat glass): the reference's #658AC1.
        let frame = render(width: 40, height: 120) { W7DrawFrameBorder($0, CGRect(x: 0, y: 0, width: 40, height: 120),
                                                                       CGRect(x: 8, y: 8, width: 24, height: 82), 0, 0, 30, true) }
        near(frame(4, 40), 0x658AC1, "side frame glass")
    }

    /// Inactive glass is the desaturated grey-blue #B9C9DB, lighter than the active glass.
    @Test func inactiveGlassIsLighterThanActive() {
        let active = render(width: 300, height: 60) { W7DrawGlassFrame($0, CGRect(x: 0, y: 0, width: 300, height: 60), true) }(150, 10)
        let inactive = render(width: 300, height: 60) { W7DrawGlassFrame($0, CGRect(x: 0, y: 0, width: 300, height: 60), false) }(150, 10)
        #expect(abs(inactive.r - 0xB9) <= 12 && abs(inactive.g - 0xC9) <= 12 && abs(inactive.b - 0xDB) <= 12, "\(inactive)")
        #expect(inactive.r >= active.r + 25 && inactive.g >= active.g + 10)
        #expect(inactive.a >= 225)
    }

    /// The frame's outer line is the reference's #151C27, with a light inner line inside it.
    @Test func glassFrameOuterLineIsDarkBlue() {
        let px = render(width: 300, height: 60) { W7DrawGlassFrame($0, CGRect(x: 0, y: 0, width: 300, height: 60), true) }
        let outer = px(150, 0), inner = px(150, 1), glass = px(150, 10)
        #expect(abs(outer.r - 0x15) <= 8 && abs(outer.g - 0x1C) <= 8 && abs(outer.b - 0x27) <= 8 && outer.a >= 240, "\(outer)")
        #expect(inner.r > glass.r + 20 && inner.g > glass.g + 12, "inner \(inner) over \(glass)")
    }

    /// A part of a taller glass, drawn with the whole glass rect, matches the same rows of the whole.
    @Test func glassFillIsContinuousAcrossParts() {
        let whole = render(width: 50, height: 64) { W7DrawGlassFill($0, CGRect(x: 0, y: 0, width: 50, height: 64), true) }
        let lower = render(width: 50, height: 34) { W7DrawGlassFill($0, CGRect(x: 0, y: 0, width: 50, height: 64), true) }
        for y in [0, 10, 20, 33] {
            let a = whole(25, y), b = lower(25, y)
            #expect(abs(a.r - b.r) <= 3 && abs(a.g - b.g) <= 3 && abs(a.b - b.b) <= 3, "y=\(y) \(a) \(b)")
        }
    }

    /// Text on the (near-opaque, light blue) glass: black with the white glow reads; plain white didn't.
    @Test func glassTextIsLegibleOnGlass() {
        func luminance(_ p: Pixel) -> Double {
            func lin(_ v: Int) -> Double { let c = Double(v) / 255; return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(p.r) + 0.7152 * lin(p.g) + 0.0722 * lin(p.b)
        }
        func contrast(_ a: Pixel, _ b: Pixel) -> Double {
            let (l1, l2) = (luminance(a), luminance(b))
            return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
        }
        let rect = CGRect(x: 0, y: 0, width: 300, height: 60)
        let textRect = CGRect(x: 10, y: 6, width: 280, height: 18)   // where the switcher puts its title
        func draw(white: Bool) -> (Int, Int) -> Pixel {
            render(width: 300, height: 60) { ctx in
                W7DrawGlassFrame(ctx, rect, true)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                if white {
                    ("Mmmm Wwww" as NSString).draw(in: textRect, withAttributes: [.font: W7UIFont(12), .foregroundColor: NSColor.white])
                } else {
                    W7DrawGlassText("Mmmm Wwww", textRect, W7UIFont(12), .left)
                }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        let background = render(width: 300, height: 60) { W7DrawGlassFrame($0, rect, true) }(150, 15)
        func extreme(_ px: (Int, Int) -> Pixel, darkest: Bool) -> Pixel {
            var best = px(12, 8)
            for y in 7..<24 { for x in 12..<90 {
                let p = px(x, y)
                if darkest ? luminance(p) < luminance(best) : luminance(p) > luminance(best) { best = p }
            } }
            return best
        }
        let black = extreme(draw(white: false), darkest: true)
        #expect(contrast(black, background) >= 4.5, "glass text \(black) on \(background)")
        let white = extreme(draw(white: true), darkest: false)
        // The darker reference glass makes plain white readable too; black with the glow still reads better.
        #expect(contrast(black, background) > contrast(white, background), "plain white \(white) on \(background)")
    }

    /// Close: #C75050 → #D7584B from top to bottom under a light gloss, a 1 pt #4C1F1F border.
    @Test func closeButtonNormalBottomIsRed() {
        let px = render(width: 43, height: 18) { W7DrawCaptionButton($0, CGRect(x: 0, y: 0, width: 43, height: 18), .close, .normal) }
        let p = px(6, 2)
        #expect(abs(p.r - 0xD7) <= 14 && abs(p.g - 0x58) <= 14 && abs(p.b - 0x4B) <= 14, "\(p)")
        let border = px(6, 0)
        #expect(abs(border.r - 0x4C) <= 10 && abs(border.g - 0x1F) <= 10 && abs(border.b - 0x1F) <= 10 && border.a >= 240, "\(border)")
    }

    @Test func closeButtonHoverIsBrighterAndPressedDarker() {
        func bottom(_ s: W7ControlState) -> Pixel {
            render(width: 43, height: 18) { W7DrawCaptionButton($0, CGRect(x: 0, y: 0, width: 43, height: 18), .close, s) }(6, 3)
        }
        let n = bottom(.normal), h = bottom(.hover), p = bottom(.pressed)
        #expect(h.r + h.g + h.b > n.r + n.g + n.b + 30, "hover \(h) vs \(n)")
        #expect(p.r + p.g + p.b < n.r + n.g + n.b - 40, "pressed \(p) vs \(n)")
        #expect(h.r > h.b + 80 && p.r > p.b + 50, "still red")
    }

    @Test func closeGlyphIsWhiteAtCenter() {
        let px = render(width: 43, height: 18) { W7DrawCaptionButton($0, CGRect(x: 0, y: 0, width: 43, height: 18), .close, .normal) }
        let p = px(21, 9)
        #expect(p.r >= 230 && p.g >= 230 && p.b >= 230)
    }

    /// Windows 7's caption buttons hang from the frame top as one strip: square top corners, only the
    /// group's outer bottom corners rounded (minimize bottom-left, close bottom-right).
    @Test func captionButtonsHangFromTheTop() {
        func corners(_ kind: W7CaptionKind, _ w: Int) -> (tl: Int, tr: Int, bl: Int, br: Int) {
            let px = render(width: w, height: 18) { W7DrawCaptionButton($0, CGRect(x: 0, y: 0, width: CGFloat(w), height: 18), kind, .normal) }
            return (px(0, 17).a, px(w - 1, 17).a, px(0, 0).a, px(w - 1, 0).a)
        }
        let mn = corners(.minimize, 26), mx = corners(.maximize, 26), cl = corners(.close, 43)
        // A square corner keeps the border and fill (alpha >= 100 even for the faint min/max fill).
        #expect(mn.tl >= 100 && mn.tr >= 100 && mn.br >= 100 && mn.bl < 60, "minimize \(mn)")
        #expect(mx.tl >= 100 && mx.tr >= 100 && mx.bl >= 100 && mx.br >= 100, "maximize \(mx)")
        #expect(cl.tl >= 100 && cl.tr >= 100 && cl.bl >= 100 && cl.br < 60, "close \(cl)")
    }

    /// Every caption glyph is white with a 1 pt dark #1F2F45 (0.8) outline, as Windows 7 Aero draws them
    /// (not black minimize/maximize glyphs).
    @Test(arguments: [W7CaptionKind.minimize, .maximize])
    func captionGlyphsAreWhiteWithDarkOutline(_ kind: W7CaptionKind) {
        let px = render(width: 52, height: 36) { ctx in
            ctx.scaleBy(x: 2, y: 2)
            W7DrawGlassFill(ctx, CGRect(x: 0, y: 0, width: 26, height: 18), true)
            W7DrawCaptionButton(ctx, CGRect(x: 0, y: 0, width: 26, height: 18), kind, .normal)
        }
        // Minimize: the bar at y 6.5 pt (row 13); maximize: the box's bottom edge at y 6 pt (row 12).
        let row = kind == .minimize ? 13 : 12
        let bar = px(26, row), above = px(26, row + 2), below = px(26, row - 3), plain = px(8, 10)
        #expect(bar.r >= 235 && bar.g >= 235 && bar.b >= 235, "glyph \(bar)")
        for edge in [above, below] {
            // 0.8 of #1F2F45 over the button's glass.
            let r = Int(0.8 * 0x1F + 0.2 * Double(plain.r)), g = Int(0.8 * 0x2F + 0.2 * Double(plain.g))
            let b = Int(0.8 * 0x45 + 0.2 * Double(plain.b))
            #expect(abs(edge.r - r) <= 14 && abs(edge.g - g) <= 14 && abs(edge.b - b) <= 14, "outline \(edge) vs \((r, g, b))")
        }
    }

    /// The close glyph stays white with a dark outline.
    @Test func closeGlyphHasDarkOutline() {
        let px = render(width: 86, height: 36) { ctx in
            ctx.scaleBy(x: 2, y: 2)
            W7DrawCaptionButton(ctx, CGRect(x: 0, y: 0, width: 43, height: 18), .close, .normal)
        }
        func lum(_ p: Pixel) -> Int { (p.r * 2126 + p.g * 7152 + p.b * 722) / 10000 }
        #expect(lum(px(43, 18)) >= 220, "centre \(px(43, 18))")
        #expect(lum(px(43, 22)) < lum(px(10, 18)) - 20, "outline above the crossing")
        let edge = px(43, 22)
        #expect(edge.b > edge.g && edge.r < 110, "the outline is the dark blue #1F2F45, not black \(edge)")
    }

    /// Windows 7's taskbar is light glass: the wallpaper shows through (about half), with a dark top
    /// line and a light line under it, and no gloss.
    @Test func taskbarIsTranslucentBlue() {
        let px = render(width: 100, height: 40) { W7DrawTaskbarBackground($0, CGRect(x: 0, y: 0, width: 100, height: 40)) }
        let low = px(50, 5), high = px(50, 30)
        #expect(abs(low.a - 128) <= 13 && low.b > low.r + 40, "base \(low)")
        #expect(abs(high.r - low.r) <= 3 && high.a == low.a, "no gloss: \(high) vs \(low)")
        let top = px(50, 39), second = px(50, 38)
        #expect(top.r < 40 && top.a >= 200, "top line \(top)")
        #expect(second.r > low.r + 60, "light line \(second)")
    }

    /// Calibration against the reference: #0B9FF9 wallpaper under the taskbar gives #2883C2. The
    /// taskbar window puts a dark HUD blur (NSVisualEffectView, behind-window) under this drawing; its
    /// blur of #0B9FF9 measured live is #156FA9, so the test fills that and draws the tint over it.
    @Test func taskbarOverBlurredWallpaperMatchesReference() {
        let px = render(width: 100, height: 40) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0x15 / 255.0, green: 0x6F / 255.0, blue: 0xA9 / 255.0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 40))
            W7DrawTaskbarBackground(ctx, CGRect(x: 0, y: 0, width: 100, height: 40))
        }
        let p = px(50, 15)
        #expect(abs(p.r - 0x28) <= 10 && abs(p.g - 0x83) <= 10 && abs(p.b - 0xC2) <= 10, "\(p)")
    }

    /// Running buttons are framed glass (dark outer line, light inner line); the active one is a bright
    /// white gloss fading down; pinned, idle buttons draw nothing.
    @Test func taskbarButtonGlass() {
        let r = CGRect(x: 0, y: 0, width: 60, height: 40)
        let idle = render(width: 60, height: 40) { W7DrawTaskbarButton($0, r, false, false, false) }
        #expect(idle(30, 20).a == 0)
        let active = render(width: 60, height: 40) { W7DrawTaskbarButton($0, r, true, true, false) }
        let running = render(width: 60, height: 40) { W7DrawTaskbarButton($0, r, true, false, false) }
        let edge = active(0, 20), inner = active(1, 20)
        #expect(edge.r < 60 && edge.a >= 120, "outer line \(edge)")
        #expect(inner.r > 200 && inner.a >= 110, "inner line \(inner)")
        let top = active(30, 36), bottom = active(30, 6)
        #expect(top.a >= 160 && top.a > bottom.a + 100, "gloss \(top) over \(bottom)")
        #expect(running(30, 36).a < top.a - 60, "running is fainter than active")
        #expect(running(0, 20).a >= 90, "running is framed")
    }

    /// The procedural orb: 0.9 of the bar height, a dark blue body with a cyan glow at the bottom and a
    /// white gloss cap, centred in the hit rect.
    @Test func startOrbGlossAndGlow() {
        let px = render(width: 54, height: 40) { W7DrawStartOrb($0, CGRect(x: 0, y: 0, width: 54, height: 40), .normal, nil) }
        #expect(px(27, 39).a == 0 && px(27, 0).a == 0, "36 pt orb leaves 2 pt above and below")
        #expect(px(7, 20).a == 0)   // beyond the 1 pt halo
        let glow = px(27, 4), edge = px(11, 20), gloss = px(27, 35)
        #expect(glow.g >= 170 && glow.b >= 200 && glow.r < 120, "glow \(glow)")
        #expect(edge.b > edge.r + 50 && edge.r < 60 && edge.b < 160, "body \(edge)")
        #expect(gloss.r >= 150 && gloss.g >= 170, "gloss \(gloss)")
    }

    @Test func menuHighlightFill() {
        let px = render(width: 100, height: 22) { W7DrawMenuHighlight($0, CGRect(x: 0, y: 0, width: 100, height: 22)) }
        let p = px(50, 11)
        #expect(abs(p.r - 0xE7) <= 10 && abs(p.g - 0xF1) <= 10 && abs(p.b - 0xFC) <= 10)
    }

    @Test func navButtonNormalIsGlossyBlue() {
        let px = render(width: 28, height: 28) { W7DrawNavButton($0, CGRect(x: 0, y: 0, width: 28, height: 28), false, .normal) }
        let body = px(5, 12)   // left of centre, below the gloss cap, clear of the arrow
        #expect(body.b >= 150 && body.b - body.r >= 90, "body \(body)")
        let gloss = px(14, 22)  // inside the gloss cap: lighter than the body
        #expect(gloss.r > body.r + 40, "gloss \(gloss)")
        #expect(px(0, 0).a == 0)   // outside the circle
        let c = px(14, 14)         // the white arrow
        #expect(c.r >= 220 && c.g >= 220 && c.b >= 220)
    }

    @Test func navButtonDisabledIsGrey() {
        let px = render(width: 28, height: 28) { W7DrawNavButton($0, CGRect(x: 0, y: 0, width: 28, height: 28), true, .disabled) }
        let p = px(5, 12)
        #expect(abs(p.r - p.b) <= 30 && abs(p.r - p.g) <= 15, "disabled \(p)")
        #expect(p.r >= 140)
    }

    @Test func navButtonHoverIsBrighterThanNormal() {
        let normal = render(width: 28, height: 28) { W7DrawNavButton($0, CGRect(x: 0, y: 0, width: 28, height: 28), false, .normal) }(5, 12)
        let hover = render(width: 28, height: 28) { W7DrawNavButton($0, CGRect(x: 0, y: 0, width: 28, height: 28), false, .hover) }(5, 12)
        #expect(hover.r + hover.g + hover.b > normal.r + normal.g + normal.b + 30)
    }

    @Test func addressBarIsWhiteWithBorder() {
        let px = render(width: 200, height: 24) { W7DrawAddressBar($0, CGRect(x: 0, y: 0, width: 200, height: 24), false) }
        let inside = px(100, 12)
        #expect(inside.r == 255 && inside.g == 255 && inside.b == 255 && inside.a == 255)
        let border = px(100, 0)
        #expect(abs(border.r - 0x8E) <= 6 && abs(border.g - 0x9A) <= 6 && abs(border.b - 0xAF) <= 6)
        let focused = render(width: 200, height: 24) { W7DrawAddressBar($0, CGRect(x: 0, y: 0, width: 200, height: 24), true) }(100, 0)
        #expect(abs(focused.r - 0x3C) <= 6 && abs(focused.g - 0x7F) <= 6 && abs(focused.b - 0xB1) <= 6)
    }

    @Test func commandBarGradientAndBottomLine() {
        let px = render(width: 100, height: 32) { W7DrawCommandBar($0, CGRect(x: 0, y: 0, width: 100, height: 32)) }
        let top = px(50, 30)
        #expect(abs(top.r - 0xF5) <= 6 && abs(top.g - 0xF9) <= 6 && abs(top.b - 0xFD) <= 6)
        let lower = px(50, 8)
        #expect(abs(lower.r - 0xDC) <= 6 && abs(lower.g - 0xE7) <= 6 && abs(lower.b - 0xF4) <= 6)
        let line = px(50, 0)
        #expect(abs(line.r - 0xA0) <= 6 && abs(line.g - 0xAF) <= 6 && abs(line.b - 0xC3) <= 6)
    }

    @Test func commandButtonHighlightOnlyWhenHoveredOrPressed() {
        let normal = render(width: 60, height: 24) { W7DrawCommandButton($0, CGRect(x: 0, y: 0, width: 60, height: 24), .normal) }
        #expect(normal(30, 12).a == 0)
        let hover = render(width: 60, height: 24) { W7DrawCommandButton($0, CGRect(x: 0, y: 0, width: 60, height: 24), .hover) }
        let border = hover(30, 0)
        #expect(abs(border.r - 0x95) <= 8 && abs(border.g - 0xAF) <= 8 && abs(border.b - 0xD3) <= 8)
        #expect(hover(30, 12).a >= 230)
        #expect(W7ExplorerTextHex == 0x1E395B && W7ColumnHeaderTextHex == 0x4C607A)
    }

    @Test func navPaneRowColors() {
        let hover = render(width: 120, height: 22) { W7DrawNavPaneRow($0, CGRect(x: 0, y: 0, width: 120, height: 22), false, true) }
        let h = hover(60, 11), hb = hover(60, 0)
        #expect(abs(h.r - 0xE5) <= 3 && abs(h.g - 0xF3) <= 3 && abs(h.b - 0xFB) <= 3)
        #expect(abs(hb.r - 0x70) <= 6 && abs(hb.g - 0xC0) <= 6 && abs(hb.b - 0xE7) <= 6)
        let sel = render(width: 120, height: 22) { W7DrawNavPaneRow($0, CGRect(x: 0, y: 0, width: 120, height: 22), true, false) }
        let s = sel(60, 11), sb = sel(60, 0)
        #expect(abs(s.r - 0xCC) <= 3 && abs(s.g - 0xE8) <= 3 && abs(s.b - 0xFF) <= 3)
        #expect(abs(sb.r - 0x99) <= 6 && abs(sb.g - 0xD1) <= 6 && abs(sb.b - 0xFF) <= 6)
        let none = render(width: 120, height: 22) { W7DrawNavPaneRow($0, CGRect(x: 0, y: 0, width: 120, height: 22), false, false) }
        #expect(none(60, 11).a == 0)
    }

    @Test func columnHeaderGradient() {
        let px = render(width: 100, height: 24) { W7DrawColumnHeader($0, CGRect(x: 0, y: 0, width: 100, height: 24)) }
        let top = px(50, 23), low = px(50, 2), line = px(50, 0)
        #expect(top.r >= 252 && top.g >= 252 && top.b >= 252)
        #expect(abs(low.r - 0xF2) <= 4 && abs(low.b - 0xF2) <= 4)
        #expect(abs(line.r - 0xD5) <= 4)
    }

    @Test func detailsPaneGradientAndTopLine() {
        let px = render(width: 100, height: 40) { W7DrawDetailsPane($0, CGRect(x: 0, y: 0, width: 100, height: 40)) }
        let line = px(50, 39), top = px(50, 37), bottom = px(50, 0)
        #expect(abs(line.r - 0xD5) <= 4 && abs(line.g - 0xDF) <= 4 && abs(line.b - 0xE5) <= 4)
        #expect(top.r >= 0xF8 && top.b >= 0xFC)
        #expect(abs(bottom.r - 0xE6) <= 4 && abs(bottom.g - 0xEE) <= 4 && abs(bottom.b - 0xF7) <= 4)
    }

    @Test func fontFallback() {
        let f = W7UIFont(12)
        #expect(f.pointSize == 12)
        #expect(f.familyName == "Segoe UI" || f.familyName == NSFont.systemFont(ofSize: 12).familyName)
    }

    @Test func metrics() {
        #expect(W7TaskbarHeight == 40 && W7TitlebarHeight == 30 && W7CaptionCloseWidth == 43)
        #expect(W7CaptionSmallWidth == 26 && W7CaptionHeight == 18 && W7MenuStripHeight == 20)
        #expect(W7MenuItemHeight == 22 && W7MenuSeparatorHeight == 7 && W7MenuGutterWidth == 28)
        #expect(W7MenuMinWidth == 160 && W7SnapPreviewInset == 8)
        #expect(W7CaptionKind.close.rawValue == 3 && W7ControlState.normal.rawValue == 0)
    }
}
