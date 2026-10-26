import Testing
import AppKit
import Win7Theme

/// Whether `p` is within `tol` of the sRGB colour `hex` on every channel.
private func near(_ p: Pixel, _ hex: Int, _ tol: Int = 6) -> Bool {
    abs(p.r - (hex >> 16 & 0xFF)) <= tol && abs(p.g - (hex >> 8 & 0xFF)) <= tol && abs(p.b - (hex & 0xFF)) <= tol
}

/// Whether every channel of `p` lies between the channels of `a` and `b` (a gradient's two ends), ± `tol`.
private func between(_ p: Pixel, _ a: Int, _ b: Int, _ tol: Int = 4) -> Bool {
    func ok(_ v: Int, _ x: Int, _ y: Int) -> Bool { v >= min(x, y) - tol && v <= max(x, y) + tol }
    return ok(p.r, a >> 16 & 0xFF, b >> 16 & 0xFF) && ok(p.g, a >> 8 & 0xFF, b >> 8 & 0xFF) && ok(p.b, a & 0xFF, b & 0xFF)
}

/// Windows 7 Aero push button: radius 3, 1 px border, two bands split at half height.
@Suite struct PushButtonDrawingTests {
    let rect = CGRect(x: 0, y: 0, width: 80, height: 24)
    func draw(_ state: W7ControlState, isDefault: Bool = false) -> (Int, Int) -> Pixel {
        render(width: 80, height: 24) { W7DrawPushButton($0, rect, state, isDefault) }
    }

    @Test func normal() {
        let px = draw(.normal)
        #expect(near(px(40, 0), 0x707070), "bottom border \(px(40, 0))")
        #expect(near(px(0, 12), 0x707070), "left border \(px(0, 12))")
        #expect(between(px(40, 18), 0xF2F2F2, 0xEBEBEB), "top band \(px(40, 18))")
        #expect(between(px(40, 6), 0xDDDDDD, 0xCFCFCF), "bottom band \(px(40, 6))")
        #expect(px(40, 22).r >= 0xF9, "inner white highlight \(px(40, 22))")
        #expect(px(0, 0).a < 128, "rounded corner \(px(0, 0))")
    }

    @Test func hover() {
        let px = draw(.hover)
        #expect(near(px(40, 0), 0x3C7FB1), "border \(px(40, 0))")
        #expect(between(px(40, 18), 0xEAF6FD, 0xD9F0FC), "top band \(px(40, 18))")
        #expect(between(px(40, 6), 0xBEE6FD, 0xA7D9F5), "bottom band \(px(40, 6))")
    }

    @Test func pressedHasNoHighlight() {
        let px = draw(.pressed)
        #expect(near(px(40, 0), 0x2C628B), "border \(px(40, 0))")
        #expect(between(px(40, 18), 0xE5F4FC, 0xC4E5F6), "top band \(px(40, 18))")
        #expect(between(px(40, 6), 0x98D1EF, 0x68B3DB), "bottom band \(px(40, 6))")
        #expect(between(px(40, 22), 0xE5F4FC, 0xC4E5F6), "no inner highlight \(px(40, 22))")
    }

    @Test func defaultButtonHasBlueBorderAndInnerRing() {
        let px = draw(.normal, isDefault: true)
        #expect(near(px(40, 0), 0x3C7FB1), "border \(px(40, 0))")
        #expect(between(px(40, 18), 0xF2F2F2, 0xEBEBEB), "normal fill \(px(40, 18))")
        let ring = px(40, 1)
        #expect(ring.b > ring.r + 40, "inner #3399FF ring \(ring)")
        // Hovered, the default button looks like any hovered button.
        #expect(near(draw(.hover, isDefault: true)(40, 0), 0x3C7FB1))
        #expect(between(draw(.hover, isDefault: true)(40, 6), 0xBEE6FD, 0xA7D9F5))
    }

    @Test func disabledIsFlat() {
        let px = draw(.disabled)
        #expect(near(px(40, 0), 0xADB2B5), "border \(px(40, 0))")
        #expect(near(px(40, 18), 0xF4F4F4, 2) && near(px(40, 6), 0xF4F4F4, 2), "flat fill \(px(40, 18)) \(px(40, 6))")
        #expect(near(draw(.disabled, isDefault: true)(40, 0), 0xADB2B5), "disabled default keeps the grey border")
    }
}

/// 13×13 check box and radio button. Pixels are in the box's bottom-left-origin coordinates.
@Suite struct CheckRadioDrawingTests {
    func box(_ state: W7ControlState, _ value: W7CheckValue) -> (Int, Int) -> Pixel {
        render(width: 13, height: 13) { W7DrawCheckBox($0, CGRect(x: 0, y: 0, width: 13, height: 13), state, value) }
    }
    func radio(_ state: W7ControlState, _ selected: Bool) -> (Int, Int) -> Pixel {
        render(width: 13, height: 13) { W7DrawRadioButton($0, CGRect(x: 0, y: 0, width: 13, height: 13), state, selected) }
    }

    @Test func checkBoxOff() {
        let px = box(.normal, .off)
        #expect(near(px(6, 0), 0x8E8F8F) && near(px(0, 6), 0x8E8F8F) && near(px(12, 6), 0x8E8F8F), "border")
        let topLeft = px(3, 9), bottomRight = px(9, 3)
        #expect(between(topLeft, 0xDFDFDF, 0xFFFFFF) && between(bottomRight, 0xDFDFDF, 0xFFFFFF))
        #expect(topLeft.r + 8 < bottomRight.r, "well darkens to the top-left: \(topLeft) \(bottomRight)")
        #expect(px(5, 3).r > 0xD0 && px(8, 7).r > 0xD0, "no glyph")
    }

    /// The check runs from the left down to the bottom vertex and up to the top right.
    @Test func checkBoxOnDrawsTheGlyph() {
        let px = box(.normal, .on)
        for (x, y) in [(5, 3), (8, 7), (3, 5)] {
            let p = px(x, y)
            #expect(p.r < 0x90 && p.b > p.r, "glyph at (\(x),\(y)) \(p)")
        }
        #expect(px(9, 3).r > 0xD0, "bottom right of the well stays clear \(px(9, 3))")
        #expect(px(3, 9).r > 0xC8, "top left of the well stays clear \(px(3, 9))")
    }

    @Test func checkBoxMixedIsACentredSquare() {
        let px = box(.normal, .mixed)
        let c = px(6, 6)
        #expect(c.r < 0x80 && c.b > c.r, "square \(c)")
        #expect(px(3, 3).r < 0x80 && px(9, 9).r < 0x80, "7×7 square corners")
        #expect(px(2, 6).r > 0xC8, "outside the square \(px(2, 6))")
    }

    @Test func checkBoxHoverPressedDisabled() {
        let hover = box(.hover, .off)
        #expect(near(hover(6, 0), 0x3C7FB1), "hover border \(hover(6, 0))")
        #expect(between(hover(6, 6), 0xDEF9FA, 0xBFEBFF), "hover well \(hover(6, 6))")
        let pressed = box(.pressed, .off)
        #expect(between(pressed(6, 6), 0xC2E4F6, 0x9CD6F2), "pressed well \(pressed(6, 6))")
        let disabled = box(.disabled, .on)
        #expect(near(disabled(6, 0), 0xB1B1B1), "disabled border \(disabled(6, 0))")
        #expect(near(disabled(9, 3), 0xF4F4F4, 2), "disabled well \(disabled(9, 3))")
        let g = disabled(5, 3)
        #expect(abs(g.r - g.b) <= 6 && g.r < 0xC0, "grey glyph \(g)")
    }

    @Test func radioButton() {
        let off = radio(.normal, false)
        #expect(near(off(6, 0), 0x8E8F8F, 20), "circle border \(off(6, 0))")
        #expect(off(0, 0).a < 40, "outside the circle")
        #expect(off(6, 6).r > 0xE0, "empty well \(off(6, 6))")
        let on = radio(.normal, true)
        let centre = on(6, 6)
        #expect(centre.b > centre.r + 50 && centre.r < 0x70, "dot centre \(centre)")
        #expect(near(on(4, 6), 0x1D5281, 40), "dot ring \(on(4, 6))")
        #expect(on(2, 6).r > 0xC8, "well outside the dot \(on(2, 6))")
        #expect(near(radio(.hover, false)(6, 0), 0x3C7FB1, 20), "hover border")
    }
}

/// Legacy (always visible) scroll bar: track and thumb.
@Suite struct ScrollerDrawingTests {
    @Test func track() {
        let v = render(width: 17, height: 100) { W7DrawScrollerTrack($0, CGRect(x: 0, y: 0, width: 17, height: 100), true) }
        #expect(near(v(0, 50), 0xE3E3E3, 2) && near(v(16, 50), 0xE3E3E3, 2) && near(v(8, 50), 0xF0F0F0, 2))
        let h = render(width: 100, height: 17) { W7DrawScrollerTrack($0, CGRect(x: 0, y: 0, width: 100, height: 17), false) }
        #expect(near(h(50, 0), 0xE3E3E3, 2) && near(h(50, 16), 0xE3E3E3, 2) && near(h(50, 8), 0xF0F0F0, 2))
    }

    func thumb(_ w: Int, _ h: Int, vertical: Bool, _ state: W7ControlState) -> (Int, Int) -> Pixel {
        render(width: w, height: h) { W7DrawScrollerThumb($0, CGRect(x: 0, y: 0, width: w, height: h), vertical, state) }
    }

    @Test func verticalThumb() {
        let px = thumb(17, 60, vertical: true, .normal)
        #expect(px(0, 30).a == 0, "inset 1 pt across")
        #expect(near(px(1, 30), 0x979797) && near(px(15, 30), 0x979797), "border \(px(1, 30)) \(px(15, 30))")
        let left = px(3, 10), right = px(13, 10)
        #expect(between(left, 0xF3F3F3, 0xDBDBDB) && between(right, 0xF3F3F3, 0xDBDBDB))
        #expect(left.r > right.r + 8, "fill runs left to right: \(left) \(right)")
        #expect(near(px(8, 30), 0xB2B2B2, 8), "grip line \(px(8, 30))")
        #expect(px(8, 29).r >= 0xF8, "grip highlight below \(px(8, 29))")
        #expect(near(px(8, 28), 0xB2B2B2, 8) && near(px(8, 32), 0xB2B2B2, 8), "three grip lines")
    }

    @Test func shortThumbHasNoGrip() {
        let px = thumb(17, 14, vertical: true, .normal)
        #expect(px(8, 7).r > 0xD0, "no grip on a 14 pt thumb \(px(8, 7))")
    }

    @Test func horizontalThumb() {
        let px = thumb(60, 17, vertical: false, .normal)
        #expect(near(px(30, 1), 0x979797) && near(px(30, 15), 0x979797), "border")
        let top = px(10, 13), bottom = px(10, 3)
        #expect(top.r > bottom.r + 8, "fill runs top to bottom: \(top) \(bottom)")
        #expect(near(px(30, 8), 0xB2B2B2, 8) && px(31, 8).r >= 0xF8, "grip line with highlight to the right")
    }

    @Test func thumbHoverAndPressed() {
        let hover = thumb(17, 60, vertical: true, .hover)
        #expect(near(hover(1, 30), 0x3C7FB1), "hover border \(hover(1, 30))")
        #expect(between(hover(3, 10), 0xE3F4FC, 0xA9DEF6) && between(hover(13, 10), 0xE3F4FC, 0xA9DEF6))
        let pressed = thumb(17, 60, vertical: true, .pressed)
        #expect(near(pressed(1, 30), 0x3C7FB1), "pressed border")
        #expect(between(pressed(8, 10), 0xCEECF9, 0x86C6E8), "pressed fill \(pressed(8, 10))")
    }
}
