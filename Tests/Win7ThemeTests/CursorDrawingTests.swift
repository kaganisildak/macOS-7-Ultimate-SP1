import AppKit
import Testing
import Win7Theme

/// A cursor rendered at `scale` (32 × scale pixels square), read with top-left pixel coordinates.
private func cursor(_ kind: W7CursorKind, scale: Int = 1, frame: Int = 0) -> (Int, Int) -> Pixel {
    let side = 32 * scale
    let px = render(width: side, height: side) { W7DrawCursor($0, CGRect(x: 0, y: 0, width: side, height: side), kind, frame) }
    return { x, y in px(x, side - 1 - y) }
}

private func isWhite(_ p: Pixel) -> Bool { p.a > 230 && p.r > 235 && p.g > 235 && p.b > 235 }
private func isBlack(_ p: Pixel) -> Bool { p.a > 200 && p.r < 70 && p.g < 70 && p.b < 70 }
/// The soft shadow: dark and translucent.
private func isShadow(_ p: Pixel) -> Bool { p.a > 8 && p.a < 170 && p.r < 90 && p.g < 90 && p.b < 90 }

@Suite struct CursorDrawingTests {
    @Test func kindsAndNames() {
        #expect(W7CursorKindCount == 13)
        #expect(W7CursorSize == 32)
        #expect(W7CursorBusyFrameCount == 18)
        #expect(W7CursorKindName(.arrow) == "arrow" && W7CursorKindName(.ibeam) == "ibeam" && W7CursorKindName(.hand) == "hand")
        #expect(W7CursorKindName(.busy) == "busy" && W7CursorKindName(.notAllowed) == "unavailable")
    }

    /// The Aero arrow: white body, a 1 px black outline outside it, a soft shadow below right.
    @Test func arrowBodyOutlineShadow() {
        let px = cursor(.arrow)
        #expect(isWhite(px(3, 9)))          // inside the body, near the left edge
        #expect(isWhite(px(6, 12)))
        #expect(isBlack(px(0, 9)))          // the outline left of the body's left edge (x = 1)
        #expect(isBlack(px(2, 1)) || isBlack(px(1, 1)))
        #expect(isShadow(px(10, 22)))       // under the tail
        #expect(px(26, 4).a == 0)           // far from the shape: transparent
        #expect(px(1, 26).a < 40)           // under the left edge only the faint shadow
    }

    /// Hot spots, in points from the top-left; the arrow's is its tip.
    @Test func hotSpots() {
        #expect(W7CursorHotSpot(.arrow) == CGPoint(x: 1, y: 1))
        #expect(W7CursorHotSpot(.working) == CGPoint(x: 1, y: 1))
        #expect(W7CursorHotSpot(.help) == CGPoint(x: 1, y: 1))
        #expect(W7CursorHotSpot(.ibeam) == CGPoint(x: 16, y: 16))
        #expect(W7CursorHotSpot(.busy) == CGPoint(x: 16, y: 16))
        #expect(W7CursorHotSpot(.crosshair) == CGPoint(x: 16, y: 16))
        #expect(W7CursorHotSpot(.hand) == CGPoint(x: 10, y: 1))
        // The tip pixel is drawn (opaque), right where the hot spot is.
        #expect(cursor(.arrow)(1, 2).a > 150)
        #expect(cursor(.hand)(10, 2).a > 150)
        #expect(isWhite(cursor(.hand)(10, 6)))     // the raised index finger
        #expect(isWhite(cursor(.crosshair)(16, 10)))
        #expect(isWhite(cursor(.ibeam)(16, 16)))
    }

    /// @2x is the same drawing at twice the pixels, still crisp: the outline is 2 px.
    @Test func retina() {
        let px = cursor(.arrow, scale: 2)
        #expect(isWhite(px(6, 18)))
        #expect(isBlack(px(0, 18)) && isBlack(px(1, 18)))
        let img = W7CreateCursorImage(.arrow, 2, 0)
        #expect(img?.width == 64 && img?.height == 64)
        #expect(W7CreateCursorImage(.arrow, 0, 0) == nil)
    }

    @Test func everyKindDraws() {
        for raw in 0..<W7CursorKindCount {
            let kind = W7CursorKind(rawValue: raw)!
            let px = cursor(kind)
            var opaque = 0
            for y in 0..<32 { for x in 0..<32 where px(x, y).a > 200 { opaque += 1 } }
            #expect(opaque > 25, "cursor \(raw) draws almost nothing")
        }
    }

    /// The busy ring spins: frames differ; the bright segment is blue.
    @Test func busyRingAnimates() {
        let a = cursor(.busy, frame: 0), b = cursor(.busy, frame: 9)
        var differ = 0, blue = 0
        for y in 0..<32 {
            for x in 0..<32 {
                let p = a(x, y), q = b(x, y)
                if abs(p.r - q.r) + abs(p.g - q.g) + abs(p.b - q.b) > 60 { differ += 1 }
                if p.a > 200 && p.b > 180 && p.b > p.r + 60 { blue += 1 }
            }
        }
        #expect(differ > 20)
        #expect(blue > 10)
    }

    @MainActor @Test func nsCursorHasBothScales() {
        let c = W7ProceduralCursor(.ibeam, 0)
        #expect(c.hotSpot == NSPoint(x: 16, y: 16))
        #expect(c.image.size == NSSize(width: 32, height: 32))
        let widths = Set(c.image.representations.map(\.pixelsWide))
        #expect(widths == [32, 64])
        #expect(W7ProceduralCursor(.ibeam, 0) === c)          // cached
        #expect(W7ProceduralCursor(.busy, 3) !== W7ProceduralCursor(.busy, 4))
    }
}
