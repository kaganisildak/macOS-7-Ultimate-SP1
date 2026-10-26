import AppKit
import Testing
import Win7Theme

private func redDominant(_ p: Pixel) -> Bool { p.a > 128 && p.r > 150 && p.r > p.g * 2 && p.r > p.b * 2 }

@Suite struct GadgetDrawingTests {
    /// 130 × 130 face; the second hand is the red one.
    private func clock(second: CGFloat) -> (Int, Int) -> Pixel {
        render(width: 130, height: 130) { W7DrawGadgetClock($0, CGRect(x: 0, y: 0, width: 130, height: 130), 0, 0, second) }
    }

    @Test func clockSecondHandPointsAtTheSecond() {
        // Second at 90°: the hand runs right of the centre (65, 65).
        #expect(redDominant(clock(second: 90)(100, 65)))
        #expect(!redDominant(clock(second: 270)(100, 65)))
        #expect(redDominant(clock(second: 270)(30, 65)))
        #expect(redDominant(clock(second: 180)(65, 30)))       // bottom-left origin: 180° is down
    }

    @Test func clockFaceIsLightAndRound() {
        let px = clock(second: 0)
        let face = px(40, 90)
        #expect(face.a == 255 && face.r > 200 && face.g > 200 && face.b > 200)
        #expect(px(1, 1).a == 0)                                  // corners outside the round face
        #expect(px(128, 128).a == 0)
    }

    /// The meter needle sweeps from lower left (0) to lower right (1) through the top.
    @Test func meterNeedle() {
        func needle(_ f: CGFloat) -> (Int, Int) -> Pixel {
            render(width: 80, height: 80) { W7DrawGadgetMeterDial($0, CGRect(x: 0, y: 0, width: 80, height: 80), f) }
        }
        func anyRed(_ px: (Int, Int) -> Pixel, _ xs: Range<Int>, _ ys: Range<Int>) -> Bool {
            for y in ys { for x in xs where redDominant(px(x, y)) { return true } }
            return false
        }
        #expect(anyRed(needle(0), 18..<30, 18..<30))
        #expect(!anyRed(needle(0), 50..<62, 18..<30))
        #expect(anyRed(needle(1), 50..<62, 18..<30))
        #expect(anyRed(needle(0.5), 37..<43, 55..<66))           // straight up at half
        let face = needle(0.5)(25, 50)
        #expect(face.a == 255 && face.r < 90)                      // dark dial face
    }

    /// Toolbar: close × first, the disabled options button drawn fainter.
    @Test func toolbar() {
        let px = render(width: 18, height: 60) { W7DrawGadgetToolbar($0, CGRect(x: 0, y: 0, width: 18, height: 60), -1) }
        var closeOpaque = 0, optionsOpaque = 0
        for y in 0..<18 { for x in 0..<18 where px(x, 59 - y).a > 200 { closeOpaque += 1 } }
        for y in 20..<38 { for x in 0..<18 where px(x, 59 - y).a > 200 { optionsOpaque += 1 } }
        #expect(closeOpaque > 20)
        #expect(optionsOpaque < closeOpaque / 2)
        #expect(W7GadgetToolbarButtonRect(CGRect(x: 0, y: 0, width: 18, height: 60), 0) == CGRect(x: 1, y: 43, width: 16, height: 16))
        #expect(W7GadgetToolbarButtonRect(CGRect(x: 0, y: 0, width: 18, height: 60), 1) == CGRect(x: 1, y: 25, width: 16, height: 16))
        // A gadget with options draws the options button as opaque as the close button.
        let on = render(width: 18, height: 60) { W7DrawGadgetToolbarWithOptions($0, CGRect(x: 0, y: 0, width: 18, height: 60), -1, true) }
        var enabledOpaque = 0
        for y in 20..<38 { for x in 0..<18 where on(x, 59 - y).a > 200 { enabledOpaque += 1 } }
        #expect(enabledOpaque > optionsOpaque * 2)
    }
}
