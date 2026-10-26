import CoreGraphics
import Foundation
import Testing
@testable import Win7Core

// The Screen Resolution window's pure parts — the Resolution list built from the modes CoreGraphics
// reports, applying and reverting a mode through a configuration (faked here: no test ever changes a real display),
// and the 15 s "Keep changes?" countdown.

/// A display that only remembers its mode; `failing` makes every change throw, as CGConfigureDisplayWithDisplayMode
/// or CGCompleteDisplayConfiguration would; `changesDespiteFailure` makes the change happen and then throw at the
/// complete stage. `events` records every change and persist, in order.
private final class FakeDisplays: DisplayConfiguring {
    enum Event: Equatable {
        case set(Int32, DisplayChangeScope)
        case persist(CGDirectDisplayID)
    }
    var modesByDisplay: [CGDirectDisplayID: [DisplayModeInfo]]
    var current: [CGDirectDisplayID: DisplayModeInfo]
    var failing = false
    var changesDespiteFailure = false
    var persistFails = false
    var calls: [(DisplayModeInfo, CGDirectDisplayID)] = []
    var events: [Event] = []

    init(_ modes: [DisplayModeInfo], currentID: Int32?, display: CGDirectDisplayID = 1) {
        modesByDisplay = [display: modes]
        current = modes.first { $0.id == currentID }.map { [display: $0] } ?? [:]
    }

    func modes(for display: CGDirectDisplayID) -> [DisplayModeInfo] { modesByDisplay[display] ?? [] }
    func currentMode(for display: CGDirectDisplayID) -> DisplayModeInfo? { current[display] }
    func setMode(_ mode: DisplayModeInfo, for display: CGDirectDisplayID, scope: DisplayChangeScope) throws {
        calls.append((mode, display))
        events.append(.set(mode.id, scope))
        if changesDespiteFailure {
            current[display] = mode
            throw DisplayConfigurationError(stage: .complete, code: 1004)
        }
        if failing { throw DisplayConfigurationError(stage: .configure, code: 1001) }
        current[display] = mode
    }
    func persist(display: CGDirectDisplayID) throws {
        events.append(.persist(display))
        if persistFails { throw DisplayConfigurationError(stage: .complete, code: 1004) }
    }
}

private func mode(_ id: Int32, _ w: Int, _ h: Int, scaled: Bool = false, refresh: Double = 60, native: Bool = false,
                  isDefault: Bool = false, usable: Bool = true, pixels: (Int, Int)? = nil) -> DisplayModeInfo {
    DisplayModeInfo(id: id, width: w, height: h, scaled: scaled, refresh: refresh, isNative: native, isDefault: isDefault,
                    usableForDesktop: usable, pixelWidth: pixels?.0 ?? (scaled ? 2 * w : w),
                    pixelHeight: pixels?.1 ?? (scaled ? 2 * h : h))
}

/// The list with the mode of id `currentID` (from `raw`) as the display's current mode.
private func listOf(_ raw: [DisplayModeInfo], currentID: Int32?) -> [DisplayModeEntry] {
    DisplayModes.list(raw, current: raw.first { $0.id == currentID })
}

@Suite struct DisplayModeListTests {
    @Test func modesAreDeduplicatedAndSortedLargestFirst() {
        let raw = [
            mode(1, 1280, 800), mode(2, 1920, 1080), mode(3, 1920, 1080, refresh: 50), mode(4, 1024, 768),
            mode(5, 1920, 1200), mode(6, 1280, 1024), mode(7, 640, 480, usable: false),
        ]
        let list = listOf(raw, currentID: 1)
        #expect(list.map { "\($0.mode.width)x\($0.mode.height)" } == ["1920x1200", "1920x1080", "1280x1024", "1280x800", "1024x768"])
        // Of the two 1920 × 1080 modes the higher refresh rate stands for the size.
        #expect(list[1].mode.id == 2)
        // A mode macOS does not offer for the desktop is left out.
        #expect(!list.contains { $0.mode.id == 7 })
        #expect(list.filter(\.isCurrent).map(\.mode.id) == [1])
    }

    @Test func theCurrentModeStandsForItsSizeAndIsKeptEvenWhenNotForTheDesktop() {
        let raw = [mode(1, 1920, 1080, refresh: 60), mode(2, 1920, 1080, refresh: 50), mode(3, 800, 600, usable: false)]
        #expect(listOf(raw, currentID: 2).first { $0.mode.width == 1920 }?.mode.id == 2)
        let odd = listOf(raw, currentID: 3)
        #expect(odd.map(\.mode.id) == [1, 3] && odd.last?.isCurrent == true)
    }

    @Test func modesAreTheSameByIdSizeAndScale() {
        // CoreGraphics reports a HiDPI mode and its 1× duplicate; the current mode is matched on all of id, size and
        // scale, never on the id alone.
        let a = mode(5, 1512, 982, scaled: true)
        #expect(a.isSameMode(as: mode(5, 1512, 982, scaled: true, refresh: 120, native: true)))
        #expect(!a.isSameMode(as: mode(5, 1512, 982)))
        #expect(!a.isSameMode(as: mode(6, 1512, 982, scaled: true)))
        let list = DisplayModes.list([mode(5, 1512, 982), a], current: mode(5, 1512, 982))
        #expect(list.map(\.isCurrent) == [false, true] && list[1].mode.scaled == false)
    }

    @Test func hiDPIAndLowResolutionModesOfOneSizeAreBothListedScaledFirst() {
        // A Retina panel with kCGDisplayShowDuplicateLowResolutionModes: 1512 × 982 at 2× and at 1×.
        let raw = [mode(10, 1512, 982), mode(11, 1512, 982, scaled: true, isDefault: true), mode(12, 1800, 1169, scaled: true),
                   mode(13, 3024, 1964, native: true)]
        let list = listOf(raw, currentID: 11)
        #expect(list.map(\.mode.id) == [13, 12, 11, 10])
        #expect(list.map(\.title) == ["3024 × 1964", "1800 × 1169", "1512 × 982 (recommended)", "1512 × 982 (low resolution)"])
    }

    @Test func recommendedIsMacOSDefaultThenTheNativeModeThenTheLargest() {
        // The default flag wins over the native one; only one entry is recommended.
        let both = listOf([mode(1, 2560, 1440, native: true), mode(2, 1920, 1080, isDefault: true)], currentID: 1)
        #expect(both.filter(\.isRecommended).map(\.mode.id) == [2])
        #expect(both.first?.title == "2560 × 1440")
        // No default mode: the native one.
        let native = listOf([mode(1, 2560, 1440), mode(2, 1920, 1080, native: true)], currentID: 1)
        #expect(native.filter(\.isRecommended).map(\.mode.id) == [2])
        #expect(native[1].title == "1920 × 1080 (recommended)")
        // Neither flag (some external displays): the largest mode.
        let plain = listOf([mode(1, 1024, 768), mode(2, 1280, 1024)], currentID: 1)
        #expect(plain.filter(\.isRecommended).map(\.mode.id) == [2])
        // Within one size a flagged mode stands for it over a higher refresh rate; when the current mode stands for
        // it instead, the size is still the recommended one.
        let pair = [mode(1, 1920, 1080, refresh: 60), mode(2, 1920, 1080, refresh: 30, native: true)]
        let flagged = listOf(pair, currentID: nil)
        #expect(flagged.count == 1 && flagged[0].isRecommended && flagged[0].mode.id == 2 && !flagged[0].isCurrent)
        let dup = listOf(pair, currentID: 1)
        #expect(dup.count == 1 && dup[0].isRecommended && dup[0].mode.id == 1 && dup[0].isCurrent)
    }

    @Test func noModesGiveAnEmptyList() {
        #expect(listOf([], currentID: nil).isEmpty)
        #expect(listOf([mode(1, 640, 480, usable: false)], currentID: nil).isEmpty)
    }

    @Test func withinASizeTheCurrentRefreshRateIsKept() {
        // A ProMotion panel at 120 Hz: choosing another size must not drop to the 60 Hz default-flagged mode.
        let raw = [mode(1, 1512, 982, scaled: true, refresh: 120), mode(2, 1800, 1169, scaled: true, refresh: 60, isDefault: true),
                   mode(3, 1800, 1169, scaled: true, refresh: 120), mode(4, 1800, 1169, scaled: true, refresh: 144)]
        #expect(listOf(raw, currentID: 1).first { $0.mode.width == 1800 }?.mode.id == 3)
        // At 60 Hz the default-flagged 60 Hz mode stands for the size again; with no current mode, too.
        let at60 = raw + [mode(5, 1512, 982, scaled: true, refresh: 60)]
        #expect(listOf(at60, currentID: 5).first { $0.mode.width == 1800 }?.mode.id == 2)
        #expect(listOf(raw, currentID: nil).first { $0.mode.width == 1800 }?.mode.id == 2)
        // No mode of the size runs at the current rate: the old order (default, native, highest refresh).
        let other = [mode(1, 1512, 982, scaled: true, refresh: 120), mode(2, 1280, 800, refresh: 50),
                     mode(3, 1280, 800, refresh: 75)]
        #expect(listOf(other, currentID: 1).first { $0.mode.width == 1280 }?.mode.id == 3)
    }

    @Test func aRowIsNeverBothRecommendedAndLowResolution() {
        // Only the 1× twin carries the default flag: "(recommended)" goes to the HiDPI twin of that size.
        let raw = [mode(10, 1512, 982, isDefault: true), mode(11, 1512, 982, scaled: true), mode(12, 1800, 1169, scaled: true)]
        let list = listOf(raw, currentID: 11)
        #expect(list.map(\.title) == ["1800 × 1169", "1512 × 982 (recommended)", "1512 × 982 (low resolution)"])
        #expect(!list.contains { $0.isRecommended && $0.isLowResolution })
        // A native-flagged 1× twin, likewise.
        let native = listOf([mode(20, 1440, 900, native: true), mode(21, 1440, 900, scaled: true)], currentID: 20)
        #expect(native.map(\.title) == ["1440 × 900 (recommended)", "1440 × 900 (low resolution)"])
    }

    @Test func theRevertLookupPrefersTheExactMode() {
        // Two modes share id, size and scale but differ in refresh and pixel size: the exact one is chosen.
        let previous = mode(7, 1920, 1080, scaled: true, refresh: 60, pixels: (3840, 2160))
        let candidates = [mode(7, 1920, 1080, scaled: true, refresh: 120, pixels: (3840, 2160)),
                          mode(7, 1920, 1080, scaled: true, refresh: 60, pixels: (3456, 1944)),
                          mode(7, 1920, 1080, scaled: true, refresh: 60, pixels: (3840, 2160))]
        #expect(DisplayModes.match(previous, in: candidates) == 2)
        // No exact match: the first with the same id, size and scale; none at all: nil.
        #expect(DisplayModes.match(mode(7, 1920, 1080, scaled: true, refresh: 50), in: candidates) == 0)
        #expect(DisplayModes.match(mode(7, 1920, 1080), in: candidates) == nil)
    }

    @Test func theListComesFromTheConfiguration() {
        let fake = FakeDisplays([mode(1, 1280, 800), mode(2, 1440, 900)], currentID: 1)
        let list = DisplayModes.list(for: 1, using: fake)
        #expect(list.map(\.mode.id) == [2, 1] && list[1].isCurrent)
        #expect(DisplayModes.list(for: 99, using: fake).isEmpty)
        #expect(fake.calls.isEmpty)
    }
}

@Suite struct DisplayModeApplyTests {
    let modes = [mode(1, 1280, 800), mode(2, 1440, 900)]

    @Test func applyingAModeRemembersThePreviousOne() {
        let fake = FakeDisplays(modes, currentID: 1)
        #expect(DisplayModes.apply(modes[1], to: 1, using: fake) == .applied(previous: modes[0]))
        #expect(fake.current[1] == modes[1])
        #expect(DisplayModes.revert(to: modes[0], on: 1, using: fake) == .applied(previous: modes[1]))
        #expect(fake.current[1] == modes[0])
        #expect(fake.calls.map(\.1) == [1, 1])
    }

    @Test func theCurrentModeIsNotAppliedAgain() {
        let fake = FakeDisplays(modes, currentID: 1)
        #expect(DisplayModes.apply(modes[0], to: 1, using: fake) == .unchanged)
        #expect(fake.calls.isEmpty)
    }

    @Test func aFailureShowsTheWindowsTextAndKeepsTheOldMode() {
        #expect(DisplayModes.applyErrorText == "The display settings could not be applied.")
        let fake = FakeDisplays(modes, currentID: 1)
        fake.failing = true
        #expect(DisplayModes.apply(modes[1], to: 1, using: fake) == .failed(message: "The display settings could not be applied."))
        #expect(fake.current[1] == modes[0])
        // A mode the display does not offer (it went away after Detect), or a display without a current mode, is
        // refused before anything is configured.
        let ok = FakeDisplays(modes, currentID: 1)
        #expect(DisplayModes.apply(mode(42, 800, 600), to: 1, using: ok) == .failed(message: DisplayModes.applyErrorText))
        let none = FakeDisplays(modes, currentID: nil)
        #expect(DisplayModes.apply(modes[1], to: 1, using: none) == .failed(message: DisplayModes.applyErrorText))
        #expect(ok.calls.isEmpty && none.calls.isEmpty)
    }

    @Test func aChangeIsAppOnlyAndARevertIsPermanent() {
        // While the countdown runs the new mode lasts only as long as the shell (macOS undoes a .forAppOnly change
        // when the process exits, crashes included); going back re-asserts the stored mode permanently.
        let fake = FakeDisplays(modes, currentID: 1)
        _ = DisplayModes.apply(modes[1], to: 1, using: fake)
        _ = DisplayModes.revert(to: modes[0], on: 1, using: fake)
        #expect(fake.events == [.set(2, .untilQuit), .set(1, .permanent)])
    }

    @Test func aFailedCompleteStepIsCheckedAgainstTheDisplay() {
        // CGCompleteDisplayConfiguration reported an error but the display did switch: the countdown still guards it.
        let fake = FakeDisplays(modes, currentID: 1)
        fake.changesDespiteFailure = true
        #expect(DisplayModes.apply(modes[1], to: 1, using: fake) == .applied(previous: modes[0]))
        // An error that left the old mode is a failure.
        let kept = FakeDisplays(modes, currentID: 1)
        kept.failing = true
        #expect(DisplayModes.apply(modes[1], to: 1, using: kept) == .failed(message: DisplayModes.applyErrorText))
    }

    @Test func configurationErrorsNameTheirStage() {
        let e = DisplayConfigurationError(stage: .complete, code: 1004)
        #expect(e.description == "complete failed (CGError 1004)")
    }
}

/// The whole "Keep changes?" sequence against the fake: apply (app-only), then persist on Keep changes, or put the
/// previous mode back on Revert, Esc or the countdown running out — never persisting then.
@Suite struct KeepChangesSequenceTests {
    let modes = [mode(1, 1280, 800), mode(2, 1440, 900)]
    let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    private func applied(_ fake: FakeDisplays) -> DisplayModeInfo {
        guard case .applied(let previous) = DisplayModes.apply(modes[1], to: 1, using: fake) else {
            Issue.record("not applied")
            return modes[0]
        }
        return previous
    }

    @Test func keepChangesPersistsTheMode() {
        let fake = FakeDisplays(modes, currentID: 1)
        let previous = applied(fake)
        var c = KeepChangesCountdown(now: t0)
        c.tick(now: t0 + 3)
        c.keep()
        #expect(DisplayModes.finish(c, previous: previous, on: 1, using: fake) == .kept)
        #expect(fake.events == [.set(2, .untilQuit), .persist(1)])
        #expect(fake.current[1] == modes[1])
    }

    @Test func runningOutRevertsWithoutPersisting() {
        let fake = FakeDisplays(modes, currentID: 1)
        let previous = applied(fake)
        var c = KeepChangesCountdown(now: t0)
        c.tick(now: t0 + 15)
        #expect(DisplayModes.finish(c, previous: previous, on: 1, using: fake) == .reverted)
        #expect(fake.events == [.set(2, .untilQuit), .set(1, .permanent)])
        #expect(fake.current[1] == modes[0])
    }

    @Test func revertOrEscRevertsWithoutPersisting() {
        let fake = FakeDisplays(modes, currentID: 1)
        let previous = applied(fake)
        var c = KeepChangesCountdown(now: t0)
        c.revert()
        #expect(DisplayModes.finish(c, previous: previous, on: 1, using: fake) == .reverted)
        #expect(!fake.events.contains(.persist(1)))
        #expect(fake.current[1] == modes[0])
    }

    @Test func nothingHappensWhileCounting() {
        let fake = FakeDisplays(modes, currentID: 1)
        let previous = applied(fake)
        #expect(DisplayModes.finish(KeepChangesCountdown(now: t0), previous: previous, on: 1, using: fake) == nil)
        #expect(fake.events == [.set(2, .untilQuit)])
    }

    @Test func aFailedPersistKeepsTheModeUntilTheShellQuits() {
        let fake = FakeDisplays(modes, currentID: 1)
        fake.persistFails = true
        let previous = applied(fake)
        var c = KeepChangesCountdown(now: t0)
        c.keep()
        #expect(DisplayModes.finish(c, previous: previous, on: 1, using: fake) == .keptUntilQuit)
        #expect(fake.current[1] == modes[1])
    }

    @Test func aFailedRevertCarriesTheWindowsText() {
        let fake = FakeDisplays(modes, currentID: 1)
        let previous = applied(fake)
        fake.failing = true
        var c = KeepChangesCountdown(now: t0)
        c.revert()
        #expect(DisplayModes.finish(c, previous: previous, on: 1, using: fake) == .revertFailed(message: DisplayModes.applyErrorText))
        #expect(!fake.events.contains(.persist(1)))
    }
}

@Suite struct KeepChangesCountdownTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    @Test func itCountsDownFifteenSecondsThenReverts() {
        var c = KeepChangesCountdown(now: t0)
        #expect(KeepChangesCountdown.seconds == 15)
        #expect(c.deadline == t0 + 15)
        #expect(c.state == .counting(15))
        #expect(c.message == "Reverting to previous display settings in 15 seconds.")
        for elapsed in 1...14 {
            c.tick(now: t0 + Double(elapsed))
            #expect(c.state == .counting(15 - elapsed))
        }
        #expect(c.message == "Reverting to previous display settings in 1 second.")
        c.tick(now: t0 + 15)
        #expect(c.state == .reverted(.expired))
        #expect(c.isFinished && c.shouldRevert)
        // Nothing moves after the end.
        c.tick(now: t0 + 16); c.keep()
        #expect(c.state == .reverted(.expired))
    }

    @Test func theSecondsShownAreTheTimeLeftRoundedUp() {
        var c = KeepChangesCountdown(now: t0)
        c.tick(now: t0 + 0.3)
        #expect(c.state == .counting(15))
        c.tick(now: t0 + 1.05)
        #expect(c.state == .counting(14))
        c.tick(now: t0 + 14.99)
        #expect(c.state == .counting(1))
    }

    @Test func aStalledRunLoopStillRevertsAtTheDeadline() {
        // The main thread was blocked (the switch itself, a modal): one late tick past the deadline ends it.
        var c = KeepChangesCountdown(now: t0)
        c.tick(now: t0 + 2)
        c.tick(now: t0 + 40)
        #expect(c.state == .reverted(.expired))
        // A clock that went backwards never adds time.
        var d = KeepChangesCountdown(now: t0)
        d.tick(now: t0 - 30)
        #expect(d.state == .counting(15))
    }

    @Test func keepEndsItAndNothingReverts() {
        var c = KeepChangesCountdown(now: t0)
        c.tick(now: t0 + 1); c.tick(now: t0 + 2)
        c.keep()
        #expect(c.state == .kept && c.isFinished && !c.shouldRevert)
        c.tick(now: t0 + 30); c.revert()
        #expect(c.state == .kept)
    }

    @Test func revertEscOrClosingRevertsAtOnce() {
        var c = KeepChangesCountdown(now: t0)
        c.tick(now: t0 + 1)
        c.revert()
        #expect(c.state == .reverted(.user) && c.shouldRevert)
        c.keep()
        #expect(c.state == .reverted(.user))
        #expect(!KeepChangesCountdown(now: t0).isFinished)
    }

    @Test func aShortCountdownForOtherCallers() {
        var c = KeepChangesCountdown(seconds: 1, now: t0)
        #expect(c.state == .counting(1))
        c.tick(now: t0 + 1)
        #expect(c.state == .reverted(.expired))
        // A zero or negative length is held to one second.
        #expect(KeepChangesCountdown(seconds: 0, now: t0).state == .counting(1))
        #expect(KeepChangesCountdown(seconds: -5, now: t0).deadline == t0 + 1)
    }
}
