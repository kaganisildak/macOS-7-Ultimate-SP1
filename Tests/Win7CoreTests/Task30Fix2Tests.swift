import Foundation
import Testing
@testable import Win7Core

@Suite struct DeviceSoundSleepTests {
    /// Quiet from willSleep until wake + 5 s.
    @Test func quietFromSleepUntilAfterWake() {
        var g = DeviceSoundGate()
        let t = Date(timeIntervalSince1970: 9000)
        g.willSleep(at: t)
        g.didWake(at: t.addingTimeInterval(600))
        let plays = [(SoundEvent.deviceDisconnect, 1.0), (.deviceConnect, 601.0), (.deviceDisconnect, 610.0)]
            .map { g.shouldPlay($0.0, at: t.addingTimeInterval($0.1)) }
        #expect(plays == [false, false, true])
        var asleep = DeviceSoundGate()
        asleep.willSleep(at: t)
        let late = asleep.shouldPlay(.deviceConnect, at: t.addingTimeInterval(86_400))   // no wake yet: still quiet
        #expect(!late)
    }
}

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("w7undo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

/// The desktop's Undo bookkeeping (DesktopActions runs it): peek, one undo at a time, remove only what succeeded.
@Suite struct DesktopUndoControllerTests {
    @Test func oneAtATimeAndRemovedOnSuccess() {
        var c = DesktopUndoController()
        c.record(.rename(from: "a", to: "b"))
        let first = c.begin()
        #expect(first == .rename(from: "a", to: "b"))
        #expect(c.isUndoing && c.label == nil)
        let second = c.begin()                      // a second Undo while the first runs does nothing
        #expect(second == nil)
        c.finish(.rename(from: "a", to: "b"), remaining: nil)
        let third = c.begin()
        #expect(third == nil)
        #expect(c.label == nil)
    }

    @Test func failureKeepsTheAction() {
        var c = DesktopUndoController()
        c.record(.rename(from: "a", to: "b"))
        let a = c.begin()!
        c.finish(a, remaining: a)                   // failed entirely: still there, Undo available again
        #expect(!c.isUndoing && c.label == "Undo Rename")
        let again = c.begin()
        #expect(again == a)
    }

    @Test func actionRecordedDuringUndoSurvives() {
        var c = DesktopUndoController()
        c.record(.rename(from: "a", to: "b"))
        let a = c.begin()!
        c.record(.rename(from: "c", to: "d"))
        c.finish(a, remaining: nil)
        let next = c.begin()
        #expect(next == .rename(from: "c", to: "d"))
    }

    /// A move undo that only partly succeeds keeps the failed moves (and reports the error).
    @Test func partialMoveUndo() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let files = DesktopFiles(directory: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Box"), withIntermediateDirectories: false)
        try Data().write(to: dir.appendingPathComponent("a.txt"))
        try Data().write(to: dir.appendingPathComponent("b.txt"))
        let moved = files.moveIntoFolder(["a.txt", "b.txt"], folder: "Box").moves
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Box/b.txt"))   // b can't come back
        let result = files.undoResult(.move(moved))
        #expect(result.names == ["a.txt"])
        #expect(result.remaining == .move([moved[1]]))
        #expect(result.error != nil)
        var c = DesktopUndoController()
        c.record(.move(moved))
        let a = c.begin()!
        c.finish(a, remaining: result.remaining)
        let rest = c.begin()
        #expect(rest == .move([moved[1]]))
        // A failed rename keeps itself; a full success leaves nothing.
        #expect(files.undoResult(.rename(from: "x", to: "missing")).remaining == .rename(from: "x", to: "missing"))
        try Data().write(to: dir.appendingPathComponent("new.txt"))
        let ok = files.undoResult(.rename(from: "old.txt", to: "new.txt"))
        #expect(ok.remaining == nil && ok.error == nil && ok.names == ["old.txt"])
    }
}
