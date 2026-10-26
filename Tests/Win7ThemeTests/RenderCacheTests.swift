import AppKit
import Testing
import Win7Theme

/// cached fonts and pre-rendered taskbar buttons. Their micro-benchmarks are in Win7PerfTests.
@Suite struct RenderCacheTests {
    /// W7UIFont no longer lists ~/Library/Fonts on every call (it is called from draw methods): the
    /// same size gives the same cached font.
    @Test func uiFontIsCached() {
        let first = W7UIFont(12)
        #expect(W7UIFont(12) === first)
        #expect(W7UIFont(11).pointSize == 11)
        #expect(W7UIFont(12).pointSize == 12)
    }

    /// The pre-rendered button is the button W7DrawTaskbarGroupButton draws, pixel for pixel (±2).
    @Test func cachedButtonImageMatchesDirectDrawing() {
        let glow = CGColor(srgbRed: 0.9, green: 0.3, blue: 0.1, alpha: 1)
        let cases: [(Bool, Bool, Bool, Int, CGColor?)] = [
            (true, false, false, 1, nil), (true, true, false, 3, nil), (true, false, true, 2, glow), (false, false, true, 1, nil),
        ]
        for (running, active, hover, windows, g) in cases {
            let rect = CGRect(x: 0, y: 0, width: 60, height: 40)
            let direct = render(width: 120, height: 80) { ctx in
                ctx.scaleBy(x: 2, y: 2)
                W7DrawTaskbarGroupButton(ctx, rect, running, active, hover, windows, g)
            }
            guard let image = W7CreateTaskbarButtonImage(rect.size, 2, running, active, hover, windows, g) else {
                Issue.record("no image"); continue
            }
            #expect(image.width == 120 && image.height == 80)
            let cached = render(width: 120, height: 80) { $0.draw(image, in: CGRect(x: 0, y: 0, width: 120, height: 80)) }
            var worst = 0
            for x in 0..<120 {
                for y in 0..<80 {
                    let a = direct(x, y), b = cached(x, y)
                    worst = max(worst, abs(a.a - b.a))
                    if a.a > 8 { worst = max(worst, abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b)) }
                }
            }
            #expect(worst <= 2, "running \(running) active \(active) hover \(hover) windows \(windows): off by \(worst)")
        }
    }

    @Test func emptyButtonImageIsNil() {
        #expect(W7CreateTaskbarButtonImage(.zero, 2, true, false, false, 1, nil) == nil)
        #expect(W7CreateTaskbarButtonImage(CGSize(width: 60, height: 40), 0, true, false, false, 1, nil) == nil)
    }
}
