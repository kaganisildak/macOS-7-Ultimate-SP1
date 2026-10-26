import Testing
@testable import Win7Core

@Suite struct SwitcherTests {
    private func win(_ id: UInt32) -> SwitcherWindow {
        SwitcherWindow(windowID: id, pid: 1, title: "w\(id)", appName: "App")
    }

    @Test func threeWindowsCycleAndWrap() {
        var m = SwitcherModel(windows: [win(1), win(2), win(3)])
        #expect(m.index == 1)
        m.next(); #expect(m.index == 2)
        m.next(); #expect(m.index == 0)
        m.previous(); #expect(m.index == 2)
        #expect(m.selected == win(3))
    }

    @Test func reverseStartsOnLastWindow() {
        let m = SwitcherModel(windows: [win(1), win(2), win(3)], reverse: true)
        #expect(m.index == 2)
        #expect(SwitcherModel(windows: [], reverse: true).selected == nil)
    }

    @Test func oneWindowStaysAtZero() {
        var m = SwitcherModel(windows: [win(1)])
        #expect(m.index == 0)
        m.next(); #expect(m.index == 0)
        m.previous(); #expect(m.index == 0)
    }

    @Test func emptyHasNoSelection() {
        var m = SwitcherModel(windows: [])
        #expect(m.selected == nil)
        m.next(); m.previous()
        #expect(m.selected == nil)
    }
}

@Suite struct SwitcherKeyStateTests {
    private let tab: Int64 = 48, esc: Int64 = 53
    private func down(_ c: Int64, option: Bool = true, shift: Bool = false, cmd: Bool = false, ctrl: Bool = false) -> SwitcherKeyEvent {
        .keyDown(code: c, option: option, shift: shift, cmd: cmd, ctrl: ctrl)
    }

    @Test func optionTabOpensAndConsumes() {
        var s = SwitcherKeyState()
        let r = s.handle(down(tab))
        #expect(r.consume && r.action == .open(reverse: false) && s.isOpen)
        #expect(s.handle(down(tab, shift: true)).action == .previous)
        #expect(s.handle(down(tab)).action == .next)
    }

    @Test func shiftOpensReverse() {
        var s = SwitcherKeyState()
        #expect(s.handle(down(tab, shift: true)).action == .open(reverse: true))
    }

    @Test func plainTabAndModifiedTabPassThrough() {
        var s = SwitcherKeyState()
        #expect(!s.handle(down(tab, option: false)).consume)
        #expect(!s.handle(down(tab, cmd: true)).consume)
        #expect(!s.handle(down(tab, ctrl: true)).consume)
        #expect(!s.isOpen)
    }

    @Test func tabKeyUpAfterOptionReleaseIsConsumed() {
        var s = SwitcherKeyState()
        _ = s.handle(down(tab))
        let r = s.handle(.flagsChanged(option: false))
        #expect(r.action == .commit && !r.consume && !s.isOpen)
        #expect(s.handle(.keyUp(code: tab)).consume)
        #expect(!s.handle(.keyUp(code: tab)).consume)
    }

    @Test func escCancelsAndItsKeyUpIsConsumed() {
        var s = SwitcherKeyState()
        _ = s.handle(down(tab))
        let r = s.handle(down(esc))
        #expect(r.consume && r.action == .cancel && !s.isOpen)
        #expect(s.handle(.keyUp(code: esc)).consume)
    }

    @Test func unmatchedKeyUpPassesThrough() {
        var s = SwitcherKeyState()
        #expect(!s.handle(.keyUp(code: tab)).consume)
        #expect(!s.handle(.keyUp(code: esc)).consume)
    }

    @Test func tapDisabledCancelsButKeepsSwallowedKeyUps() {
        var s = SwitcherKeyState()
        _ = s.handle(down(tab))
        let r = s.handle(.tapDisabled)
        #expect(r.action == .cancel && !r.consume && !s.isOpen)
        #expect(s.handle(.keyUp(code: tab)).consume)
        #expect(s.handle(.tapDisabled).action == nil)
    }

    @Test func keyDownWithoutOptionWhileOpenCommitsAndPassesThrough() {
        var s = SwitcherKeyState()
        _ = s.handle(down(tab))
        let r = s.handle(down(tab, option: false))
        #expect(r.action == .commit && !r.consume && !s.isOpen)
    }

    @Test func staleAbortDoesNotCloseNewerOpen() {
        var s = SwitcherKeyState()
        _ = s.handle(down(tab))
        let old = s.generation
        _ = s.handle(.flagsChanged(option: false))
        _ = s.handle(down(tab))
        s.abortOpen(generation: old)
        #expect(s.isOpen)
        s.abortOpen(generation: s.generation)
        #expect(!s.isOpen)
    }
}
