import Foundation
import Testing
@testable import Win7Core

/// Runs `events` through a fresh machine; returns each event's effects and the final phase.
private func run(_ events: [PowerSplashEvent]) -> (effects: [[PowerSplashEffect]], phase: PowerSplashPhase) {
    var m = PowerSplashMachine()
    let effects = events.map { m.handle($0) }
    return (effects, m.phase)
}

/// The power splash must not hide loginwindow's confirmation, "Save changes?" sheets or TCC prompts.
@Suite struct PowerSplashMachineTests {
    private let active = PowerSplashEvent.otherAppActivated(terminated: false)

    @Test func coversOnlyBeforeTheCommand() {
        let r = run([.start, active, .minimumElapsed])
        #expect(r.effects[0] == [.show(.top), .armTimeout])
        // Activations during the first 1.2 s change nothing: the command hasn't been sent.
        #expect(r.effects[1] == [])
        #expect(r.effects[2] == [.show(.belowAlerts), .runCommand])
        #expect(r.phase == .waiting)
        #expect(run([.start]).phase == .covering)
    }

    @Test func anotherAppActivatingClosesItUntilPowerOff() {
        let r = run([.start, .minimumElapsed, active, active, .willPowerOff])
        #expect(r.effects[2] == [.hide, .armLinger])
        #expect(r.effects[3] == [])
        // The logout really proceeds: shown again below normal windows, with a fresh 10 s cap.
        #expect(r.effects[4] == [.show(.belowWindows), .armTimeout])
        #expect(r.phase == .poweringOff)
    }

    /// While powering off, sheets of quitting apps ("Save changes?", Terminal's terminate sheet) sit at
    /// level 0: the splash is below them, and a live app activating closes it; a terminated one doesn't.
    @Test func activationWhilePoweringOff() {
        let base: [PowerSplashEvent] = [.start, .minimumElapsed, .willPowerOff]
        let live = run(base + [active])
        #expect(live.effects.last == [.hide, .armLinger])
        #expect(live.phase == .dismissed)
        let gone = run(base + [.otherAppActivated(terminated: true)])
        #expect(gone.effects.last == [])
        #expect(gone.phase == .poweringOff)
        // Shown again on a second willPowerOff after the user dealt with the sheet.
        #expect(run(base + [active, .willPowerOff]).effects.last == [.show(.belowWindows), .armTimeout])
        #expect(run(base + [.timeout]).effects.last == [.hide, .armLinger])
    }

    /// After a dismissal the observers linger (15 s) for willPowerOff, then stop for good, so a later
    /// Apple-menu shutdown doesn't bring back a stale splash.
    @Test func lingerThenFinish() {
        let r = run([.start, .minimumElapsed, active, .timeout, .willPowerOff, active])
        #expect(r.effects[3] == [.stopObserving])
        #expect(r.effects[4] == [] && r.effects[5] == [])
        #expect(r.phase == .finished)
        #expect(SessionSplashKind.lingerAfterDismiss == 15)
    }

    @Test func failureAndTimeoutClose() {
        #expect(run([.start, .minimumElapsed, .commandFailed]).effects.last == [.hide, .armLinger])
        let t = run([.start, .minimumElapsed, .timeout])
        #expect(t.effects[2] == [.hide, .armLinger] && t.phase == .dismissed)
        #expect(run([.start, .minimumElapsed, .willPowerOff, .commandFailed]).effects.last == [.hide, .armLinger])
        // Nothing before start; a second start is ignored.
        let idle = run([.willPowerOff, .timeout, active])
        #expect(idle.effects.allSatisfy(\.isEmpty) && idle.phase == .idle)
        #expect(run([.start, .start]).effects[1] == [])
    }
}

@Suite struct UISoundSettingTests {
    /// com.apple.systemsound first, then the global domain.
    @Test func lookupOrder() {
        var asked: [String] = []
        var keys: Set<String> = []
        let both = SoundScheme.uiSoundsSetting { key, domain in
            asked.append(domain)
            keys.insert(key)
            return domain == SoundScheme.systemSoundDomain ? 0 : 1
        }
        #expect((both as? Int) == 0)
        #expect(asked == ["com.apple.systemsound"])
        #expect(keys == ["com.apple.sound.uiaudio.enabled"])
        asked = []
        let globalOnly = SoundScheme.uiSoundsSetting { _, domain in
            asked.append(domain)
            return domain == SoundScheme.globalDomain ? 0 : nil
        }
        #expect((globalOnly as? Int) == 0)
        #expect(asked == ["com.apple.systemsound", SoundScheme.globalDomain])
        #expect(SoundScheme.uiSoundsSetting { _, _ in nil } == nil)
    }
}

@Suite struct DeviceSoundGateTests {
    /// Devices re-enumerate on wake: no sounds for 5 s after it, and the debounce still applies.
    @Test func quietAfterWake() {
        var g = DeviceSoundGate()
        let t = Date(timeIntervalSince1970: 5000)
        g.didWake(at: t)
        let plays = [(SoundEvent.deviceConnect, 1.0), (.deviceConnect, 4.5), (.deviceDisconnect, 7.0), (.deviceConnect, 7.2),
                     (.deviceConnect, 9.0)].map { g.shouldPlay($0.0, at: t.addingTimeInterval($0.1)) }
        // 4.5 s is still quiet; at 7.2 s the connect from 4.5 s is 2.7 s old, so it plays; 9.0 s is 1.8 s later.
        #expect(plays == [false, false, true, true, true])
        #expect(DeviceSoundGate.wakeQuiet == 5)
    }
}

@Suite struct DesktopUndoPeekTests {
    @Test func lastDoesNotPop() {
        var s = DesktopUndoStack()
        s.push(.rename(from: "a", to: "b"))
        #expect(s.last == .rename(from: "a", to: "b"))
        #expect(s.label == "Undo Rename")
        let popped = s.pop()
        #expect(popped == .rename(from: "a", to: "b"))
        #expect(s.last == nil)
    }

    /// The undone action leaves the history even when a newer one was pushed while it ran.
    @Test func removeTheUndoneAction() {
        var s = DesktopUndoStack()
        s.push(.rename(from: "a", to: "b"))
        let undone = s.last!
        s.push(.rename(from: "c", to: "d"))
        s.remove(undone)
        #expect(s.last == .rename(from: "c", to: "d"))
        s.remove(.rename(from: "c", to: "d"))
        #expect(s.label == nil)
        s.remove(.rename(from: "x", to: "y"))   // not there: nothing happens
        #expect(s.last == nil)
    }
}
