import Testing
import AppKit
import Win7Theme

/// the overlay paints over macOS's rounded window corners and the window's own 1 pt edge, with the
/// caption's own glass at the top (no tone seam) and frame glass at the bottom.
@Suite struct FrameCornerDrawingTests {
    // An overlay for a 200 × 150 window (the hole): 8 pt more on the left, right and bottom, none on top.
    let bounds = CGRect(x: 0, y: 0, width: 216, height: 158)
    let hole = CGRect(x: 8, y: 8, width: 200, height: 150)
    var caption: CGRect { CGRect(x: hole.minX, y: hole.maxY - 30, width: hole.width, height: 30) }

    func close(_ a: Pixel, _ b: Pixel, _ tolerance: Int = 1) -> Bool {
        abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance && abs(a.a - b.a) <= tolerance
    }

    // MARK: Geometry

    /// One box per corner of the window, the window's radius plus the 1 pt edge on a side; none where the
    /// window's corner is square.
    @Test func wedgeRectsAtTwoSizes() {
        #expect(W7FrameEdgeCover == 1)
        let w = W7FrameCornerWedgeRects(hole, 16, 16, false)
        #expect(w.topLeft == CGRect(x: 8, y: 141, width: 17, height: 17))
        #expect(w.topRight == CGRect(x: 191, y: 141, width: 17, height: 17))
        #expect(w.bottomLeft == CGRect(x: 8, y: 8, width: 17, height: 17))
        #expect(w.bottomRight == CGRect(x: 191, y: 8, width: 17, height: 17))
        // A large window with the Windows 7 radii (the radius path): small top wedges, no bottom ones.
        let big = CGRect(x: 8, y: 8, width: 1200, height: 800)
        let r = W7FrameCornerWedgeRects(big, 6, 0, false)
        #expect(r.topLeft == CGRect(x: 8, y: 801, width: 7, height: 7))
        #expect(r.topRight == CGRect(x: 1201, y: 801, width: 7, height: 7))
        #expect(r.bottomLeft.isEmpty && r.bottomRight.isEmpty)
        // A radius larger than half the window is clamped like the window's own shape.
        let tiny = W7FrameCornerWedgeRects(CGRect(x: 0, y: 0, width: 20, height: 12), 16, 16, false)
        #expect(tiny.topLeft == CGRect(x: 0, y: 5, width: 7, height: 7))
    }

    /// Maximized (no side frame): only the top corners get wedges; the bottom stays the window's.
    @Test func maximizedWedgeRects() {
        let w = W7FrameCornerWedgeRects(hole, 16, 16, true)
        #expect(w.topLeft == CGRect(x: 8, y: 141, width: 17, height: 17))
        #expect(w.topRight == CGRect(x: 191, y: 141, width: 17, height: 17))
        #expect(w.bottomLeft.isEmpty && w.bottomRight.isEmpty)
    }

    /// The cover: the window's outer 1 pt all round and the wedges outside an arc concentric with the
    /// window's corner, 2 pt inside it (so the window's own arc and its rim are under glass); the rest of the window is not.
    @Test func coverPath() {
        let p = W7CreateFrameCoverPath(hole, 16, 16, false)
        #expect(p.contains(CGPoint(x: 8.5, y: 80)) && p.contains(CGPoint(x: 207.5, y: 80)))   // left, right edge
        #expect(p.contains(CGPoint(x: 108, y: 8.5)) && p.contains(CGPoint(x: 108, y: 157.5))) // bottom, top edge
        #expect(!p.contains(CGPoint(x: 9.5, y: 80)) && !p.contains(CGPoint(x: 108, y: 80)))
        #expect(p.contains(CGPoint(x: 10, y: 156)))                       // the window's transparent corner
        // The window's arc (radius 16 round (24, 142)) is covered 2 pt in: at 14.5 from the centre, not at 13.5.
        let c = CGPoint(x: 24, y: 142), d = 1 / 2.0.squareRoot()
        #expect(p.contains(CGPoint(x: c.x - 14.5 * d, y: c.y + 14.5 * d)))
        #expect(!p.contains(CGPoint(x: c.x - 13.5 * d, y: c.y + 13.5 * d)))
        #expect(p.contains(CGPoint(x: 9, y: 9)))                          // bottom wedge
        let m = W7CreateFrameCoverPath(hole, 16, 16, true)
        #expect(m.contains(CGPoint(x: 10, y: 156)) && m.contains(CGPoint(x: 108, y: 157.5)))
        #expect(!m.contains(CGPoint(x: 9, y: 9)) && !m.contains(CGPoint(x: 8.5, y: 80)), "maximized: top only")
    }

    /// The ring is drawn in four small layers, never one the size of the window: disjoint, on whole
    /// points, covering the frame, the window's edges and its wedges, and far from the window's middle.
    @Test func ringStripsAreSmallAndCoverTheRing() {
        let big = CGRect(x: 0, y: 0, width: 1416, height: 908), window = CGRect(x: 8, y: 8, width: 1400, height: 900)
        for (top, bottom) in [(16.0, 16.0), (6.0, 0.0)] {
            var strips = [CGRect](repeating: .null, count: 4)
            let n = W7FrameRingStrips(big, window, top, bottom, &strips)
            #expect(n == 4)
            let area = strips.prefix(n).reduce(0) { $0 + $1.width * $1.height }
            #expect(area < big.width * big.height * 0.1, "strips cover \(area) of \(big.width * big.height)")
            for (i, a) in strips.prefix(n).enumerated() {
                #expect(a == a.integral, "strip \(a)")
                for b in strips.prefix(n).dropFirst(i + 1) { #expect(a.intersection(b).isEmpty, "\(a) overlaps \(b)") }
                #expect(!a.contains(CGPoint(x: 708, y: 454)))
            }
            // Frame sides, bottom, top corners, the window's edges and its corner wedges: each in exactly one strip.
            let ring = [CGPoint(x: 4, y: 450), CGPoint(x: 1412, y: 450), CGPoint(x: 700, y: 4), CGPoint(x: 1, y: 906),
                        CGPoint(x: 8.5, y: 450), CGPoint(x: 1407.5, y: 450), CGPoint(x: 700, y: 8.5), CGPoint(x: 700, y: 907.5),
                        CGPoint(x: 9, y: 906), CGPoint(x: 8 + top * 0.3, y: 908 - top * 0.3), CGPoint(x: 1406, y: 9),
                        CGPoint(x: 9.5, y: 8 + bottom + 0.5)]
            for p in ring { #expect(strips.prefix(n).filter { $0.contains(p) }.count == 1, "\(p)") }
        }
        // Too small to split: one strip, the whole overlay.
        var strips = [CGRect](repeating: .null, count: 4)
        #expect(W7FrameRingStrips(CGRect(x: 0, y: 0, width: 40, height: 30), CGRect(x: 8, y: 8, width: 24, height: 22), 16, 16, &strips) == 1)
        #expect(strips[0] == CGRect(x: 0, y: 0, width: 40, height: 30))
    }

    // MARK: Pixels

    func border(_ top: CGFloat = 16, _ bottom: CGFloat = 16, active: Bool = true) -> (Int, Int) -> Pixel {
        render(width: 216, height: 158) { W7DrawFrameBorder($0, bounds, hole, top, bottom, 30, active) }
    }

    /// The top wedges are the caption's glass, pixel for pixel: the overlay and the title bar draw the same
    /// slice of the same glass rect, so there is no tone seam where they meet.
    @Test func topWedgesEqualTheCaptionSlice() {
        for active in [true, false] {
            let px = border(active: active)
            let slice = render(width: 216, height: 158) { W7DrawCaptionGlassSlice($0, caption, caption, active) }
            // Row 157 is the frame's outer line, over the window's top edge; below it the glass and its white line.
            for (x, y) in [(8, 156), (9, 155), (10, 152), (12, 154), (8, 145), (8, 135), (8, 130),
                           (207, 156), (206, 152), (203, 154), (207, 140)] {
                #expect(close(px(x, y), slice(x, y)), "active \(active) (\(x), \(y)): \(px(x, y)) vs \(slice(x, y))")
                #expect(px(x, y).a == 255)
            }
        }
    }

    /// The bottom wedges and the bottom and side edges are the frame's glass below the caption, opaque.
    @Test func bottomWedgesAreFrameGlass() {
        let px = border()
        let frame = px(4, 60)
        #expect(frame.a == 255)
        for (x, y) in [(8, 8), (9, 10), (11, 9), (207, 8), (205, 10), (8, 60), (207, 60), (108, 8)] {
            #expect(close(px(x, y), frame), "(\(x), \(y)): \(px(x, y)) vs \(frame)")
        }
    }

    /// The window's 1 pt edge is painted all round; 1 pt further in, the window shows.
    @Test func edgeRingIsCovered() {
        let px = border()
        for (x, y) in [(8, 80), (207, 80), (108, 8), (108, 157)] { #expect(px(x, y).a == 255, "(\(x), \(y))") }
        for (x, y) in [(9, 80), (206, 80), (108, 9), (108, 155), (108, 80), (30, 140), (20, 20)] {
            #expect(px(x, y).a == 0, "(\(x), \(y)) \(px(x, y))")
        }
    }

    /// With the Windows 7 radii (the radius path) only the 1 pt edge and a 6 pt top wedge are painted.
    @Test func radiusPathCoversOnlyTheEdge() {
        let px = border(6, 0)
        #expect(px(8, 156).a == 255 && px(8, 9).a == 255 && px(9, 9).a == 0 && px(10, 10).a == 0)
        #expect(px(13, 150).a == 0, "inside the 6 pt corner")
    }

    /// The frame glass is opaque now (glass over a white backdrop, as the caption is), so the overlay's sides
    /// match the caption over any desktop.
    @Test func frameGlassIsOpaque() {
        let px = border()
        for (x, y) in [(4, 60), (4, 140), (212, 100), (108, 4)] { #expect(px(x, y).a == 255, "(\(x), \(y))") }
    }

    /// The caption slice: opaque glass (the glass fill over white) with the white inner line along its top,
    /// drawn only inside the slice.
    @Test func captionSlice() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 30)
        let whole = render(width: 100, height: 30) { W7DrawCaptionGlassSlice($0, rect, rect, true) }
        let fill = render(width: 100, height: 30) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(rect)
            W7DrawGlassFill(ctx, rect, true)
        }
        #expect(whole(50, 10) == fill(50, 10) && whole(50, 10).a == 255)
        #expect(whole(50, 28).r > fill(50, 28).r + 10, "inner line")
        let part = render(width: 100, height: 30) { W7DrawCaptionGlassSlice($0, CGRect(x: 0, y: 20, width: 10, height: 10), rect, true) }
        #expect(close(part(5, 25), whole(5, 25), 0) && part(5, 15).a == 0 && part(20, 25).a == 0)
    }

    /// Maximized: the top wedges and the top edge row are the caption slice; nothing else is painted.
    @Test func maximizedCorners() {
        let px = render(width: 216, height: 158) { W7DrawMaximizedFrameCorners($0, hole, 16, 30, true) }
        let slice = render(width: 216, height: 158) { W7DrawCaptionGlassSlice($0, caption, caption, true) }
        for (x, y) in [(8, 157), (8, 156), (10, 152), (207, 156), (205, 153), (108, 157)] {
            #expect(close(px(x, y), slice(x, y)), "(\(x), \(y)): \(px(x, y)) vs \(slice(x, y))")
        }
        for (x, y) in [(8, 9), (207, 9), (108, 8), (8, 80), (108, 150), (4, 150)] { #expect(px(x, y).a == 0, "(\(x), \(y))") }
    }
}
