import Testing
import AppKit
import Win7Theme

// The shell's Windows 7 Calculator — key faces per state and the display box with its memory
// indicator. Pixels are in bottom-left-origin coordinates.

private func near(_ p: Pixel, _ hex: Int, _ tol: Int = 6) -> Bool {
    p.a > 240 && abs(p.r - (hex >> 16 & 0xFF)) <= tol && abs(p.g - (hex >> 8 & 0xFF)) <= tol && abs(p.b - (hex & 0xFF)) <= tol
}

private func between(_ p: Pixel, _ a: Int, _ b: Int, _ tol: Int = 3) -> Bool {
    func ok(_ v: Int, _ x: Int, _ y: Int) -> Bool { v >= min(x, y) - tol && v <= max(x, y) + tol }
    return p.a > 240 && ok(p.r, a >> 16 & 0xFF, b >> 16 & 0xFF) && ok(p.g, a >> 8 & 0xFF, b >> 8 & 0xFF) && ok(p.b, a & 0xFF, b & 0xFF)
}

/// Dark text pixels (luminance under 100) inside x0..<x1, y0..<y1.
private func darkPixels(_ px: (Int, Int) -> Pixel, x: Range<Int>, y: Range<Int>) -> Int {
    var n = 0
    for i in x { for j in y { let p = px(i, j); if p.a > 200 && (p.r + p.g + p.b) / 3 < 100 { n += 1 } } }
    return n
}

@Suite struct CalculatorDrawingTests {
    static let w = 34, h = 28
    let rect = CGRect(x: 0, y: 0, width: w, height: h)

    func key(_ label: String, _ state: W7ControlState) -> (Int, Int) -> Pixel {
        render(width: Self.w, height: Self.h) { W7DrawCalculatorKey($0, rect, label, state) }
    }

    @Test func metrics() {
        #expect(W7CalculatorDisplayHeight == 24)
        #expect(W7CalculatorDisplayFontSize == 18)
    }

    /// Normal: grey #F0F0F0 at the top to #E5E5E5 at the bottom, a 1 pt #8E8F8F border, rounded corners.
    @Test func normalKeyFace() {
        let px = key("7", .normal)
        let top = px(4, Self.h - 4), bottom = px(4, 3)
        #expect(between(top, 0xF0F0F0, 0xE5E5E5), "top \(top)")
        #expect(between(bottom, 0xF0F0F0, 0xE5E5E5), "bottom \(bottom)")
        #expect(top.r > bottom.r, "lighter at the top: \(top) \(bottom)")
        #expect(near(px(Self.w / 2, 0), 0x8E8F8F), "bottom border \(px(Self.w / 2, 0))")
        #expect(near(px(0, Self.h / 2), 0x8E8F8F), "left border \(px(0, Self.h / 2))")
        #expect(near(px(Self.w - 1, Self.h / 2), 0x8E8F8F), "right border")
        #expect(px(0, 0).a < 128, "rounded corner \(px(0, 0))")
    }

    @Test func hoverKeyFace() {
        let px = key("7", .hover)
        #expect(near(px(4, Self.h / 2), 0xDDE9F7, 3), "hover \(px(4, Self.h / 2))")
        #expect(near(px(4, Self.h - 4), 0xDDE9F7, 3) && near(px(4, 3), 0xDDE9F7, 3), "flat")
        #expect(near(px(Self.w / 2, 0), 0x8E8F8F), "border")
    }

    @Test func pressedKeyFace() {
        let px = key("7", .pressed)
        #expect(near(px(4, Self.h / 2), 0xC4D8EF, 3), "pressed \(px(4, Self.h / 2))")
        #expect(near(px(Self.w / 2, 0), 0x8E8F8F), "border")
    }

    @Test func disabledKeyIsFlatAndGrey() {
        let px = key("MC", .disabled)
        #expect(near(px(4, Self.h / 2), 0xF4F4F4, 3), "fill \(px(4, Self.h / 2))")
        #expect(near(px(Self.w / 2, 0), 0xADB2B5), "border \(px(Self.w / 2, 0))")
        #expect(darkPixels(px, x: 0..<Self.w, y: 2..<(Self.h - 2)) == 0, "grey label, no black")
    }

    /// The label is black and centred; the `=` key keeps the colour of every other key.
    @Test func labelAndEqualsKey() {
        let seven = key("7", .normal)
        #expect(darkPixels(seven, x: 12..<22, y: 7..<21) > 5, "black label in the middle")
        #expect(darkPixels(seven, x: 2..<8, y: 2..<26) == 0, "nothing at the sides")
        for state in [W7ControlState.normal, .hover, .pressed] {
            let eq = key("=", state), other = key("7", state)
            #expect(eq(4, Self.h - 4) == other(4, Self.h - 4) && eq(4, 3) == other(4, 3), "= face in state \(state.rawValue)")
        }
    }

    /// The display box: white, a 1 pt #8E8F8F border, the number right-aligned; "M" at the left only with memory.
    @Test func displayBox() {
        let dw = 194, dh = 24
        let r = CGRect(x: 0, y: 0, width: dw, height: dh)
        let plain = render(width: dw, height: dh) { W7DrawCalculatorDisplay($0, r, "123", false) }
        #expect(near(plain(dw / 2, 0), 0x8E8F8F), "bottom border \(plain(dw / 2, 0))")
        #expect(near(plain(0, dh / 2), 0x8E8F8F), "left border \(plain(0, dh / 2))")
        #expect(near(plain(dw / 2, dh / 2), 0xFFFFFF, 2), "white \(plain(dw / 2, dh / 2))")
        #expect(darkPixels(plain, x: (dw - 50)..<(dw - 2), y: 2..<(dh - 2)) > 10, "the number at the right")
        #expect(darkPixels(plain, x: 2..<30, y: 2..<(dh - 2)) == 0, "no memory indicator")
        let memory = render(width: dw, height: dh) { W7DrawCalculatorDisplay($0, r, "123", true) }
        #expect(darkPixels(memory, x: 2..<30, y: 2..<(dh - 2)) > 5, "memory indicator M")
        #expect(darkPixels(memory, x: 40..<(dw - 60), y: 2..<(dh - 2)) == 0, "nothing in between")
    }

    /// A text too wide for the box at 18 pt is drawn smaller, still inside the box.
    @Test func longTextShrinksToFit() {
        let dw = 194, dh = 24
        let r = CGRect(x: 0, y: 0, width: dw, height: dh)
        let px = render(width: dw, height: dh) { W7DrawCalculatorDisplay($0, r, "Cannot divide by zero", false) }
        #expect(darkPixels(px, x: 2..<(dw - 2), y: 2..<(dh - 2)) > 30, "the message is drawn")
        #expect(near(px(0, dh / 2), 0x8E8F8F) && near(px(dw - 1, dh / 2), 0x8E8F8F), "borders intact")
        #expect(W7CalculatorDisplayFontSizeFitting("Cannot divide by zero", 120) < 18)
        #expect(W7CalculatorDisplayFontSizeFitting("0", 186) == 18)
        #expect(W7CalculatorDisplayFontSizeFitting(String(repeating: "8", count: 200), 186) == 8)
    }
}
