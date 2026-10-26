import Testing
import AppKit
import Win7Theme

/// the 8 pt Aero frame round decorated windows and the Windows 7 message box background.
@Suite struct FrameBorderDrawingTests {
    // An overlay for a 200 × 150 window: 8 pt more on the left, right and bottom, none on top.
    let bounds = CGRect(x: 0, y: 0, width: 216, height: 158)
    let hole = CGRect(x: 8, y: 8, width: 200, height: 150)

    @Test func metrics() {
        #expect(W7FrameBorderWidth == 8)
        #expect(W7FrameOuterRadius == 6)
    }

    func drawBorder(active: Bool) -> (Int, Int) -> Pixel {
        render(width: 216, height: 158) { W7DrawFrameBorder($0, bounds, hole, 16, 10, 30, active) }
    }

    @Test func borderGlassMatchesTheCaptionRowForRow() {
        let px = drawBorder(active: true)
        let band = CGRect(x: 0, y: 158 - 30, width: 216, height: 30)
        // The glass is opaque (over white, as the caption's is).
        let caption = render(width: 216, height: 158) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(band)
            W7DrawGlassFill(ctx, band, true)
        }
        for y in [130, 140, 150] {
            let a = px(4, y), b = caption(4, y)
            #expect(abs(a.r - b.r) <= 3 && abs(a.g - b.g) <= 3 && abs(a.b - b.b) <= 3, "y=\(y) \(a) \(b)")
        }
        // Below the caption the glass is the caption's bottom colour, flat (no gloss, no seam).
        let below = px(4, 60), low = px(4, 20), seam = caption(4, 128)
        #expect(abs(below.r - low.r) <= 1 && abs(below.g - low.g) <= 1 && abs(below.b - low.b) <= 1, "\(below) \(low)")
        #expect(abs(below.r - seam.r) <= 3 && abs(below.g - seam.g) <= 3 && abs(below.b - seam.b) <= 3, "\(below) \(seam)")
        // the IE8 reference's side frame glass, #658AC1.
        #expect(abs(below.r - 0x65) <= 8 && abs(below.g - 0x8A) <= 8 && abs(below.b - 0xC1) <= 8 && below.a >= 225, "\(below)")
    }

    @Test func borderLinesAndHole() {
        let px = drawBorder(active: true)
        func isOuterLine(_ p: Pixel) -> Bool { abs(p.r - 0x15) <= 8 && abs(p.g - 0x1C) <= 8 && abs(p.b - 0x27) <= 8 && p.a >= 240 }
        #expect(isOuterLine(px(0, 60)), "left edge \(px(0, 60))")
        #expect(isOuterLine(px(215, 60)), "right edge \(px(215, 60))")
        #expect(isOuterLine(px(108, 0)), "bottom edge \(px(108, 0))")
        // The outer line runs on along the window's top edge (the caption has no line of its own there).
        #expect(isOuterLine(px(108, 157)), "top edge over the window \(px(108, 157))")
        // Nothing else is drawn over the window.
        #expect(px(108, 156).a == 0 && px(108, 80).a == 0 && px(9, 80).a == 0)
        // The window's rounded top-left corner is filled with glass; the overlay's own corner is rounded.
        #expect(px(9, 154).a >= 225, "corner wedge \(px(9, 154))")
        #expect(px(0, 157).a < 128, "rounded outer corner \(px(0, 157))")
        #expect(px(0, 0).a >= 240, "square bottom corner \(px(0, 0))")
        // Light inner line just inside the outer one.
        #expect(px(1, 60).r > px(4, 60).r + 15, "inner line \(px(1, 60)) vs glass \(px(4, 60))")
    }

    @Test func inactiveBorderIsGreyBlue() {
        let p = drawBorder(active: false)(4, 60)
        #expect(abs(p.r - 0xB9) <= 12 && abs(p.g - 0xC9) <= 12 && abs(p.b - 0xDB) <= 12 && p.a >= 225, "\(p)")
    }

    /// Bordered caption (W7DrawGlassCaption): the glass fill over white (opaque since ), square, with
    /// only the light inner line along its top (the frame overlay draws the outer line and the sides).
    @Test func borderedCaptionHasNoSideLines() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 30)
        let px = render(width: 100, height: 30) { W7DrawGlassCaption($0, rect, true) }
        let fill = render(width: 100, height: 30) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(rect)
            W7DrawGlassFill(ctx, rect, true)
        }
        #expect(px(0, 10) == fill(0, 10) && px(99, 10) == fill(99, 10), "no side lines")
        #expect(px(0, 0) == fill(0, 0) && px(0, 29).a >= 225, "square corners")
        #expect(px(50, 28).r > fill(50, 28).r + 10, "top inner line \(px(50, 28)) vs \(fill(50, 28))")
    }

    // MARK: Message box

    /// White message area, a #F0F0F0 button strip with a #DFDFDF line along its top, and with a caption
    /// height the glass caption band along the top.
    @Test func messageBoxBackground() {
        let b = CGRect(x: 0, y: 0, width: 260, height: 300)
        let px = render(width: 260, height: 300) { W7DrawMessageBoxBackground($0, b, 60, 24, true) }
        #expect(px(5, 5) == (0xF0, 0xF0, 0xF0, 255), "strip \(px(5, 5))")
        #expect(px(5, 59) == (0xF0, 0xF0, 0xF0, 255), "strip top row \(px(5, 59))")
        #expect(px(5, 60) == (0xDF, 0xDF, 0xDF, 255), "line \(px(5, 60))")
        #expect(px(5, 61) == (0xFF, 0xFF, 0xFF, 255) && px(130, 200) == (0xFF, 0xFF, 0xFF, 255), "message area")
        let glass = px(130, 285), white = px(130, 270)
        #expect(glass.b > glass.r + 40 && glass.a >= 225, "caption glass \(glass)")
        #expect(white == (0xFF, 0xFF, 0xFF, 255), "under the caption \(white)")
        let none = render(width: 260, height: 300) { W7DrawMessageBoxBackground($0, b, 60, 0, true) }
        #expect(none(130, 295) == (0xFF, 0xFF, 0xFF, 255), "no caption band")
    }
}
