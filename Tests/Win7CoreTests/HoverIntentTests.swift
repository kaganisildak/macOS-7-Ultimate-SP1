import Testing
@testable import Win7Core

@Suite struct HoverIntentTests {
    @Test func firesAfterDelay() {
        var h = HoverIntent(delay: 0.5)
        h.enter(at: 0)
        #expect(!h.shouldFire(now: 0.4))
        #expect(h.shouldFire(now: 0.5))
    }
    @Test func exitCancels() {
        var h = HoverIntent(delay: 0.5)
        h.enter(at: 0)
        h.exit()
        #expect(!h.shouldFire(now: 9))
    }
    @Test func reenterRestartsClock() {
        var h = HoverIntent(delay: 0.5)
        h.enter(at: 0)
        h.exit()
        h.enter(at: 10)
        #expect(!h.shouldFire(now: 10.2))
        #expect(h.shouldFire(now: 10.5))
    }
}

@Suite struct PeekHoverStateTests {
    @Test func beginsAfterDelayThenEndsOnExit() {
        var s = PeekHoverState(delay: 0.5)
        s.enter(at: 0)
        #expect(s.tick(now: 0.4) == nil)
        #expect(s.tick(now: 0.5) == .begin)
        #expect(s.tick(now: 0.6) == nil)
        #expect(s.exit() == .end)
    }
    @Test func clickBeforeDelayNeverBegins() {
        var s = PeekHoverState(delay: 0.5)
        s.enter(at: 0)
        #expect(s.click() == nil)
        #expect(s.tick(now: 0.6) == nil)
    }
    @Test func clickAfterBeginEnds() {
        var s = PeekHoverState(delay: 0.5)
        s.enter(at: 0)
        _ = s.tick(now: 0.5)
        #expect(s.click() == .end)
        #expect(s.exit() == nil)
    }
}
