import Testing
import AppKit
import Win7Theme

/// the grouped (stacked) look and the icon-tinted hover glow.
@Suite struct TaskbarButtonDrawingTests {
    private let rect = CGRect(x: 0, y: 0, width: 60, height: 40)

    private func button(windows: Int, hover: Bool = false, glow: CGColor? = nil) -> (Int, Int) -> Pixel {
        render(width: 60, height: 40) { W7DrawTaskbarGroupButton($0, self.rect, true, false, hover, windows, glow) }
    }

    private func same(_ a: (Int, Int) -> Pixel, _ b: (Int, Int) -> Pixel) -> Bool {
        for x in 0..<60 { for y in 0..<40 where a(x, y) != b(x, y) { return false } }
        return true
    }

    /// One window (or none) draws exactly the plain button.
    @Test func singleWindowIsThePlainButton() {
        let plain = render(width: 60, height: 40) { W7DrawTaskbarButton($0, self.rect, true, false, false) }
        #expect(same(button(windows: 1), plain))
        #expect(same(button(windows: 0), plain))
    }

    /// Two windows: the button narrows by 3 pt and one more edge shows 3 pt to its right; three or
    /// more: two edges (3 and 6 pt).
    @Test func stackedEdgesShowToTheRight() {
        let one = button(windows: 1), two = button(windows: 2), three = button(windows: 5)
        // The front button's dark outer line moves in: x 56 (two) and x 53 (three) are on it.
        #expect(two(56, 20).a > one(56, 20).a + 40)
        #expect(three(53, 20).a > one(53, 20).a + 40)
        // An edge's outer line sits at the far right column, like the plain button's.
        #expect(two(59, 20).a >= 90)
        #expect(three(59, 20).a >= 90)
        // Two edges for three or more windows: one more line between the front button and the last edge.
        #expect(three(56, 20).a > one(56, 20).a + 40)
        // The edges sit behind the button: its left side is unchanged.
        #expect(two(10, 20) == one(10, 20) && three(10, 20) == one(10, 20))
    }

    /// Edges are drawn only for running buttons.
    @Test func idleButtonHasNoEdges() {
        let px = render(width: 60, height: 40) { W7DrawTaskbarGroupButton($0, self.rect, false, false, false, 3, nil) }
        #expect(px(59, 20).a == 0 && px(30, 20).a == 0)
    }

    /// Hover with a glow colour: the lower middle of the button takes the icon's tint.
    @Test func hoverGlowIsTinted() throws {
        let red = CGColor(srgbRed: 1, green: 0.1, blue: 0.1, alpha: 1)
        let plain = button(windows: 1, hover: true), tinted = button(windows: 1, hover: true, glow: red)
        let p = plain(30, 5), t = tinted(30, 5)
        #expect(abs(p.r - p.b) <= 3)          // the plain hover is a white gloss
        #expect(t.r - t.b >= 60)              // tinted red
        #expect(t.a > p.a)
        // The glow comes from the bottom: the top of the button is barely tinted.
        let top = tinted(30, 36)
        #expect(top.r - top.b < t.r - t.b)
    }

    /// No glow without hover, even when a colour is passed.
    @Test func glowOnlyOnHover() {
        let red = CGColor(srgbRed: 1, green: 0.1, blue: 0.1, alpha: 1)
        #expect(same(button(windows: 1, hover: false, glow: red), button(windows: 1, hover: false)))
    }
}
