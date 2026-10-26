import CoreGraphics
import Foundation
import Testing
@testable import Win7Core

/// the caches and invalidation rules behind the rendering and responsiveness pass.
@Suite struct SnapshotCacheTests {
    @Test func firstRequestRefreshesAndStores() {
        var c = SnapshotCache<Int32, String>(minInterval: 0.25)
        #expect(c.value(1, now: 0, maxAge: 1) == nil)
        let t = c.beginRefresh(1, now: 10)
        #expect(t != nil)
        let stored = c.complete(t!, with: "a")
        #expect(stored)
        #expect(c.value(1, now: 10.5, maxAge: 1) == "a")
    }

    /// At most one refresh per key every `minInterval`, and none while one is in flight.
    @Test func refreshesAreThrottled() {
        var c = SnapshotCache<Int32, String>(minInterval: 0.25)
        let t = c.beginRefresh(1, now: 10)!
        let inFlight = c.beginRefresh(1, now: 10.1)
        #expect(inFlight == nil)   // in flight
        c.complete(t, with: "a")
        let tooSoon = c.beginRefresh(1, now: 10.2)
        #expect(tooSoon == nil)   // younger than 250 ms
        let due = c.beginRefresh(1, now: 10.25)
        #expect(due != nil)
        let other = c.beginRefresh(2, now: 10.1)
        #expect(other != nil)   // keys are independent
    }

    /// Values are aged from when their query started.
    @Test func valuesExpire() {
        var c = SnapshotCache<Int32, String>(minInterval: 0.25)
        c.complete(c.beginRefresh(1, now: 10)!, with: "a")
        #expect(c.value(1, now: 11, maxAge: 1) == "a")
        #expect(c.value(1, now: 11.01, maxAge: 1) == nil)
        #expect(c.value(1, now: 10.2, maxAge: 0.25) == "a")
    }

    /// An invalidation drops the value, allows an immediate refresh even with one in flight, and
    /// discards the in-flight result, which may predate the change.
    @Test func invalidationDropsValueAndStaleResults() {
        var c = SnapshotCache<Int32, String>(minInterval: 0.25)
        c.complete(c.beginRefresh(1, now: 10)!, with: "a")
        let stale = c.beginRefresh(1, now: 10.3)!
        c.invalidate(1)
        #expect(c.value(1, now: 10.31, maxAge: 1) == nil)
        let fresh = c.beginRefresh(1, now: 10.31)
        #expect(fresh != nil)
        let staleStored = c.complete(stale, with: "old")
        #expect(!staleStored)
        #expect(c.value(1, now: 10.32, maxAge: 1) == nil)
        let freshStored = c.complete(fresh!, with: "new")
        #expect(freshStored)
        #expect(c.value(1, now: 10.32, maxAge: 1) == "new")
    }

    @Test func invalidateAllCoversEveryKey() {
        var c = SnapshotCache<Int32, String>(minInterval: 0.25)
        c.complete(c.beginRefresh(1, now: 10)!, with: "a")
        c.complete(c.beginRefresh(2, now: 10)!, with: "b")
        let pending = c.beginRefresh(3, now: 10)!
        c.invalidateAll()
        #expect(c.value(1, now: 10, maxAge: 1) == nil && c.value(2, now: 10, maxAge: 1) == nil)
        let pendingStored = c.complete(pending, with: "c")
        #expect(!pendingStored)
        let again = c.beginRefresh(1, now: 10.01)
        #expect(again != nil)
    }

    /// A synchronous fresh query stores its result like a finished refresh.
    @Test func storeRecordsAFreshQuery() {
        var c = SnapshotCache<Int32, String>(minInterval: 0.25)
        c.store(1, "a", takenAt: 5)
        #expect(c.value(1, now: 5.5, maxAge: 1) == "a")
        let throttled = c.beginRefresh(1, now: 5.1)
        #expect(throttled == nil)
    }

    /// After an action on an app's windows (unminimize, close, raise), its cached value
    /// goes away, so the next click queries afresh and gets the new state.
    @Test func storeThenInvalidateGivesAFreshValue() {
        var c = SnapshotCache<Int32, String>(minInterval: 0.25)
        c.store(1, "two windows", takenAt: 5)
        c.invalidate(1)
        #expect(c.value(1, now: 5.1, maxAge: 1) == nil)
        let refresh = c.beginRefresh(1, now: 5.1)
        #expect(refresh != nil)   // not throttled by the dropped value
        c.store(1, "one window", takenAt: 5.1)
        #expect(c.value(1, now: 5.2, maxAge: 1) == "one window")
    }

    /// With a hold-off, nothing taken in the next `holdOff` seconds is served either: the action's
    /// effect (a window closing, an unminimize animating) may not show yet, and a click then must
    /// query on the spot rather than reuse what a hover fetched meanwhile.
    @Test func holdOffRejectsValuesTakenTooSoonAfterAnAction() {
        var c = SnapshotCache<Int32, String>(minInterval: 0.25)
        c.store(1, "before", takenAt: 5)
        c.invalidate(1, holdOff: 1, now: 10)
        #expect(c.value(1, now: 10, maxAge: 1) == nil)
        c.store(1, "during", takenAt: 10.5)
        #expect(c.value(1, now: 10.6, maxAge: 1) == nil)
        let t = c.beginRefresh(1, now: 10.6)
        #expect(t != nil)   // a value nobody may use does not throttle a refresh
        c.store(1, "after", takenAt: 11)
        #expect(c.value(1, now: 11.1, maxAge: 1) == "after")
        // Other keys are untouched.
        c.store(2, "other", takenAt: 10.5)
        #expect(c.value(2, now: 10.6, maxAge: 1) == "other")
    }

    /// A refresh started before the invalidation is voided; one started after it is accepted.
    @Test func completeReportsWhetherTheResultWasAccepted() {
        var c = SnapshotCache<Int32, String>(minInterval: 0.25)
        let early = c.beginRefresh(1, now: 1)!
        c.invalidate(1)
        let late = c.beginRefresh(1, now: 1.01)!
        let earlyAccepted = c.complete(early, with: "early")
        let lateAccepted = c.complete(late, with: "late")
        #expect(!earlyAccepted && lateAccepted)
    }
}

@Suite struct TaskbarInvalidationTests {
    private func rect(_ t: TaskbarHoverTarget) -> CGRect? {
        switch t {
        case .orb: CGRect(x: 0, y: 0, width: 54, height: 40)
        case .button(let i): CGRect(x: 54 + CGFloat(i) * 60, y: 0, width: 60, height: 40)
        case .showDesktop: CGRect(x: 1425, y: 0, width: 15, height: 40)
        case .pageArrow(let a): a == 0 ? CGRect(x: 1000, y: 20, width: 16, height: 20) : nil
        }
    }

    @Test func movingBetweenButtonsRedrawsBoth() {
        let old = TaskbarHover(button: 1), new = TaskbarHover(button: 2)
        let dirty = TaskbarInvalidation.dirtyRects(from: old, to: new, rect: rect)
        #expect(Set(dirty.map(\.minX)) == [114, 174])
        #expect(dirty.allSatisfy { $0.width == 60 })
    }

    @Test func noChangeRedrawsNothing() {
        let h = TaskbarHover(button: 3, orb: false, showDesktop: false, arrow: nil)
        #expect(TaskbarInvalidation.dirtyRects(from: h, to: h, rect: rect).isEmpty)
    }

    @Test func leavingTheBarRedrawsOnlyWhatWasHot() {
        let dirty = TaskbarInvalidation.dirtyRects(from: TaskbarHover(orb: true), to: TaskbarHover(), rect: rect)
        #expect(dirty == [CGRect(x: 0, y: 0, width: 54, height: 40)])
        let sd = TaskbarInvalidation.dirtyRects(from: TaskbarHover(), to: TaskbarHover(showDesktop: true), rect: rect)
        #expect(sd == [CGRect(x: 1425, y: 0, width: 15, height: 40)])
    }

    /// Targets without a rect (a paging arrow that is not shown) are skipped.
    @Test func targetsWithoutRectAreSkipped() {
        let dirty = TaskbarInvalidation.dirtyRects(from: TaskbarHover(arrow: 1), to: TaskbarHover(arrow: 0), rect: rect)
        #expect(dirty == [CGRect(x: 1000, y: 20, width: 16, height: 20)])
    }

    @Test func changedTargetsIsTheSymmetricDifference() {
        let changed = TaskbarHover.changedTargets(from: TaskbarHover(button: 0, orb: true), to: TaskbarHover(button: 0, showDesktop: true))
        #expect(changed == [.orb, .showDesktop])
    }
}

@Suite struct TaskbarButtonLookTests {
    private let size = CGSize(width: 60, height: 40)

    /// Three or more windows draw the same two stacked edges, so they share one cached image.
    @Test func windowCountsCollapseToStackDepth() {
        let three = TaskbarButtonLook(running: true, active: false, hover: false, windows: 3, glow: nil, size: size, scale: 2)
        let seven = TaskbarButtonLook(running: true, active: false, hover: false, windows: 7, glow: nil, size: size, scale: 2)
        let one = TaskbarButtonLook(running: true, active: false, hover: false, windows: 1, glow: nil, size: size, scale: 2)
        let none = TaskbarButtonLook(running: true, active: false, hover: false, windows: 0, glow: nil, size: size, scale: 2)
        #expect(three == seven)
        #expect(one == none)
        #expect(one != three)
        #expect(three.stackDepth == 2 && one.stackDepth == 0)
    }

    /// A pinned (not running) button has no stack.
    @Test func pinnedButtonsHaveNoStack() {
        let look = TaskbarButtonLook(running: false, active: false, hover: true, windows: 4, glow: nil, size: size, scale: 2)
        #expect(look.stackDepth == 0)
    }

    /// The glow colour only shows on hover, so it is only part of a hovered button's key.
    @Test func glowOnlyKeysHoveredButtons() {
        let red = TaskbarButtonLook.RGBA(r: 255, g: 0, b: 0)
        let plain = TaskbarButtonLook(running: true, active: false, hover: false, windows: 1, glow: nil, size: size, scale: 2)
        let tinted = TaskbarButtonLook(running: true, active: false, hover: false, windows: 1, glow: red, size: size, scale: 2)
        #expect(plain == tinted)
        let hovered = TaskbarButtonLook(running: true, active: false, hover: true, windows: 1, glow: red, size: size, scale: 2)
        let hoveredBlue = TaskbarButtonLook(running: true, active: false, hover: true, windows: 1,
                                            glow: .init(r: 0, g: 0, b: 255), size: size, scale: 2)
        #expect(hovered != hoveredBlue)
        #expect(hovered.glow == red)
    }

    @Test func sizeAndScaleArePartOfTheKey() {
        let a = TaskbarButtonLook(running: true, active: true, hover: false, windows: 1, glow: nil, size: size, scale: 2)
        let b = TaskbarButtonLook(running: true, active: true, hover: false, windows: 1, glow: nil, size: size, scale: 1)
        let c = TaskbarButtonLook(running: true, active: true, hover: false, windows: 1, glow: nil,
                                  size: CGSize(width: 60, height: 30), scale: 2)
        #expect(a != b && a != c)
        #expect(a.pixelWidth == 120 && a.pixelHeight == 80)
    }
}

@Suite struct BoundedCacheTests {
    @Test func makesOnceThenReuses() {
        var c = BoundedCache<String, Int>(capacity: 4)
        var made = 0
        let first = c.value(for: "a") { made += 1; return 1 }
        let second = c.value(for: "a") { made += 1; return 2 }
        #expect(first == 1 && second == 1)
        #expect(made == 1)
        #expect(c.count == 1)
    }

    /// Over capacity, the least recently used entry goes.
    @Test func evictsLeastRecentlyUsed() {
        var c = BoundedCache<String, Int>(capacity: 2)
        _ = c.value(for: "a") { 1 }
        _ = c.value(for: "b") { 2 }
        _ = c.value(for: "a") { 9 }   // touches a
        _ = c.value(for: "c") { 3 }   // evicts b
        #expect(c.count == 2)
        #expect(c["a"] == 1 && c["c"] == 3 && c["b"] == nil)
    }

    @Test func removeAllEmpties() {
        var c = BoundedCache<String, Int>(capacity: 2)
        _ = c.value(for: "a") { 1 }
        c.removeAll()
        #expect(c.count == 0 && c["a"] == nil)
    }

    /// `hit` returns a cached value and counts as a use, so a value read that way is not the next
    /// one evicted (the button images were looked up without touching the LRU order).
    @Test func hitBumpsRecency() {
        var c = BoundedCache<String, Int>(capacity: 2)
        _ = c.value(for: "a") { 1 }
        _ = c.value(for: "b") { 2 }
        #expect(c.hit("a") == 1)
        #expect(c.hit("missing") == nil)
        _ = c.value(for: "c") { 3 }   // evicts b, not a
        #expect(c["a"] == 1 && c["b"] == nil && c["c"] == 3)
    }
}

@Suite struct TimerToleranceTests {
    @Test func tenPercentByDefault() {
        #expect(TimerTolerance.for(5) == 0.5)
        #expect(abs(TimerTolerance.for(1.5) - 0.15) < 1e-9)
        #expect(TimerTolerance.for(10, fraction: 0.2) == 2)
    }

    @Test func fractionIsClampedToTheAgreedRange() {
        #expect(TimerTolerance.for(10, fraction: 0.5) == 2)
        #expect(TimerTolerance.for(10, fraction: 0.01) == 1)
        #expect(TimerTolerance.for(-3) == 0)
    }
}

@Suite struct PerfBudgetTests {
    @Test func logsOnlySlowMainThreadIntervalsWhenEnabled() {
        #expect(PerfBudget.shouldLog(duration: 0.017, isMainThread: true, enabled: true))
        #expect(!PerfBudget.shouldLog(duration: 0.016, isMainThread: true, enabled: true))
        #expect(!PerfBudget.shouldLog(duration: 0.5, isMainThread: false, enabled: true))
        #expect(!PerfBudget.shouldLog(duration: 0.5, isMainThread: true, enabled: false))
    }
}

@Suite struct ConcurrencyLimiterTests {
    private actor Recorder {
        var current = 0, peak = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }

    @Test func neverRunsMoreThanTheLimit() async {
        let limiter = ConcurrencyLimiter(limit: 2)
        let rec = Recorder()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = await limiter.acquire()
                    await rec.enter()
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    await rec.leave()
                    await limiter.release()
                }
            }
        }
        #expect(await rec.peak == 2)
        #expect(await rec.current == 0)
        #expect(await limiter.inUse == 0)
    }

    /// A task cancelled while waiting for a slot stops waiting at once, gets false and
    /// takes no slot (a closed window popup no longer queues a capture behind others).
    @Test func waitingIsCancellable() async {
        let limiter = ConcurrencyLimiter(limit: 1)
        let first = await limiter.acquire()
        #expect(first)
        let waiter = Task { await limiter.acquire() }
        while await limiter.waiting == 0 { await Task.yield() }
        waiter.cancel()
        let got = await waiter.value
        #expect(!got)
        #expect(await limiter.waiting == 0)
        await limiter.release()
        #expect(await limiter.inUse == 0)
    }

    @Test func alreadyCancelledTaskDoesNotAcquire() async {
        let limiter = ConcurrencyLimiter(limit: 2)
        let t = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await limiter.acquire()
        }
        let got = await t.value
        #expect(!got)
        #expect(await limiter.inUse == 0)
    }
}

@Suite struct PermissionSnapshotTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func hit() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// One shared poll reads each permission once and hands the same answer to every user.
    @Test func snapshotReadsEachProbeOnce() {
        let ax = Counter(), sc = Counter()
        let gate = PermissionGate(isAXTrusted: { ax.hit(); return true }, hasScreenCapture: { sc.hit(); return false })
        let s = gate.snapshot()
        #expect(ax.value == 1 && sc.value == 1)
        #expect(s == PermissionSnapshot(axTrusted: true, screenCapture: false))
        #expect(s.features == [.snap, .switcher])
    }

    @Test func featuresMatchTheGate() {
        for ax in [false, true] {
            for sc in [false, true] {
                let gate = PermissionGate(isAXTrusted: { ax }, hasScreenCapture: { sc })
                #expect(PermissionSnapshot(axTrusted: ax, screenCapture: sc).features == gate.enabled())
            }
        }
    }
}

@Suite struct WindowGroupingTests {
    static func info(windows: Int, apps: Int) -> [[String: Any]] {
        (0..<windows).map { i in
            [kCGWindowOwnerPID as String: Int32(100 + i % apps), kCGWindowNumber as String: UInt32(i + 1),
             kCGWindowLayer as String: i % 7 == 0 ? 25 : 0, kCGWindowIsOnscreen as String: i % 3 != 0,
             kCGWindowName as String: "w\(i)",
             kCGWindowBounds as String: ["X": 0.0, "Y": 0.0, "Width": 400.0, "Height": 300.0]]
        }
    }

    /// One pass gives every pid the same list, in the same order, as `list(from:pid:)`.
    @Test func byPIDMatchesPerPIDLists() {
        let raw = Self.info(windows: 50, apps: 6)
        let grouped = CGWindowInfo.byPID(from: raw)
        #expect(grouped.count == 6)
        for pid in Int32(100)..<106 { #expect(grouped[pid] == CGWindowInfo.list(from: raw, pid: pid)) }
        #expect(grouped[999] == nil)
    }
}
