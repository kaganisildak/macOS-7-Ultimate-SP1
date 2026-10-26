import Testing
import Foundation
@testable import Win7Core

// Windows 7 jump list parity (Frequent folders, headings, focus) and the restore
// activation retry.

private func folder(_ n: Int) -> RecentDocument { RecentDocument(name: "Folder \(n)", path: "/tmp/f\(n)") }

@Suite struct JumpListSectionsTests {
    private func input(frequent: [RecentDocument]?, recent: [RecentDocument]?) -> JumpListInput {
        JumpListInput(appName: "Finder", isPinned: true, isRunning: true, windowCount: 1, accessibility: true,
                      recent: recent, frequent: frequent)
    }

    /// Frequent, then Recent, then Tasks at the bottom, each under its heading.
    @Test func frequentThenRecentThenTasks() {
        let s = JumpList.sections(input(frequent: [folder(1)], recent: [RecentDocument(name: "Doc", path: "/tmp/d.txt")]))
        #expect(s.map(\.kind) == [.frequent, .recent, .tasks])
        #expect(s.map(\.title) == ["Frequent", "Recent", "Tasks"])
        #expect(s[0].items == [JumpListItem(title: "Folder 1", action: .openFolder(path: "/tmp/f1"))])
    }

    @Test func frequentIsCappedAndOmittedWhenEmpty() {
        let s = JumpList.sections(input(frequent: (1...14).map(folder), recent: nil))
        #expect(s.map(\.kind) == [.frequent, .tasks])
        #expect(s[0].items.count == JumpList.maxRecent)
        #expect(JumpList.sections(input(frequent: [], recent: nil)).map(\.kind) == [.tasks])
        #expect(JumpList.sections(input(frequent: nil, recent: nil)).map(\.kind) == [.tasks])
    }

    /// The headings' small caps: the first letter full size, the rest as smaller capitals.
    @Test func headingSmallCapsRuns() {
        #expect(JumpList.smallCapsRuns("Frequent") == [SmallCapsRun(text: "F", small: false), SmallCapsRun(text: "REQUENT", small: true)])
        #expect(JumpList.smallCapsRuns("Tasks") == [SmallCapsRun(text: "T", small: false), SmallCapsRun(text: "ASKS", small: true)])
        // Uppercasing is locale independent: tr_TR would turn "i" into "İ", the headings keep "I".
        #expect("items".uppercased(with: Locale(identifier: "tr_TR")) == "İTEMS")
        #expect(JumpList.smallCapsRuns("Recent items") == [SmallCapsRun(text: "R", small: false), SmallCapsRun(text: "ECENT ITEMS", small: true)])
        #expect(!JumpList.smallCapsRuns("Recent items").map(\.text).joined().contains("İ"))
        #expect(JumpList.smallCapsRuns("") == [])
    }
}

@Suite struct FrequentFoldersTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("w7ff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        guard let real = realpath(d.path, nil) else { return d }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }

    /// Finder's `FXRecentFolders` preference: an array of {"file-bookmark": data, "name": string}.
    @Test func readsFinderRecentFoldersAndSkipsMissingOnes() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("Projects"), b = dir.appendingPathComponent("Gone"),
            c = dir.appendingPathComponent("Photos.2026")
        for f in [a, b, c] { try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true) }
        let marks = try [a, b, c].map { try $0.bookmarkData() }
        try FileManager.default.removeItem(at: b)
        let pref: [Any] = [
            ["file-bookmark": marks[0], "name": "Projeler"] as [String: Any],
            ["file-bookmark": marks[1], "name": "Gone"],
            ["file-bookmark": marks[2]],                       // no name: the folder's own, extension kept
        ]
        let folders = FrequentFolders.load(preference: pref, home: "/nonexistent-home")
        #expect(folders?.map(\.name) == ["Projeler", "Photos.2026"])
        #expect(folders?.map(\.path) == [a.path, c.path])
    }

    @Test func capsAtTenAndDropsDuplicates() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var pref: [Any] = []
        for i in 0..<12 {
            let f = dir.appendingPathComponent("d\(i)")
            try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
            let mark = try f.bookmarkData()
            pref.append(["file-bookmark": mark, "name": "d\(i)"] as [String: Any])
            if i == 0 { pref.append(["file-bookmark": mark, "name": "again"] as [String: Any]) }
        }
        let folders = FrequentFolders.load(preference: pref, home: "/nonexistent-home")
        #expect(folders?.count == 10)
        #expect(folders?.prefix(2).map(\.name) == ["d0", "d1"])
    }

    /// Missing or malformed preference: no section. Entries of another shape are skipped.
    @Test func malformedPreference() {
        #expect(FrequentFolders.load(preference: nil, home: "/h") == nil)
        #expect(FrequentFolders.load(preference: "x", home: "/h") == nil)
        #expect(FrequentFolders.load(preference: [Any](), home: "/h") == [])
        let odd: [Any] = [42, ["file-bookmark": "not data"] as [String: Any], ["name": "no bookmark"] as [String: Any],
                          ["file-bookmark": Data("garbage".utf8)] as [String: Any]]
        #expect(FrequentFolders.load(preference: odd, home: "/h") == [])
    }

    /// Protected folders (Downloads, Documents...) are listed by the path stored in the bookmark,
    /// never resolved or checked, so no privacy prompt can appear.
    @Test func protectedFoldersAreListedByStoredPath() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloads = dir.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let mark = try downloads.bookmarkData()
        try FileManager.default.removeItem(at: downloads)
        var checked: [String] = []
        let folders = FrequentFolders.load(preference: [["file-bookmark": mark, "name": "İndirilenler"] as [String: Any]],
                                           home: dir.path, fileExists: { checked.append($0); return false })
        #expect(folders?.map(\.name) == ["İndirilenler"])
        #expect(folders?.first?.path.hasSuffix("/Downloads") == true)
        #expect(checked.isEmpty)
    }
}

/// The jump list reuses the window popup's dismissal model; these are the jump list's
/// own event sequences, checked again after .
@Suite struct JumpListDismissalTests {
    private func opened() -> WindowPopupDismissal {
        var s = WindowPopupDismissal()
        #expect(s.handle(.buttonClicked(pid: 1)) == .show(.pinned))
        return s
    }

    @Test func escapeOrAnEmptyTaskbarClickRestoresFocus() {
        var s = opened()
        #expect(s.handle(.escape) == .close(.restore))
        s = opened()
        #expect(s.handle(.clickedInTaskbar(.empty)) == .close(.restore))
    }

    @Test func outsideClicksLetTheClickedAppKeepFocus() {
        var s = opened()
        #expect(s.handle(.clickedInOtherApp) == .close(.release))
        s = opened()
        #expect(s.handle(.clickedInTaskbar(.control)) == .close(.keep))
    }

    /// A choice that brings nothing forward closes like Esc (restore); one that does releases.
    @Test func choices() {
        var s = opened()
        #expect(s.handle(JumpList.choiceTakesFocus(.pin, accessibility: true) ? .selected : .escape) == .close(.restore))
        s = opened()
        #expect(s.handle(JumpList.choiceTakesFocus(.openFolder(path: "/x"), accessibility: true) ? .selected : .escape) == .close(.release))
    }
}

@Suite struct RestoreActivationTests {
    private let shell: Int32 = 10, target: Set<Int32> = [20], terminal: Int32 = 30

    @Test func timing() {
        #expect(RestoreActivation.checkDelay == 0.3)
        #expect(RestoreActivation.maxAttempts == 2)
    }

    /// Checked 300 ms after each attempt: frontmost → done; still the app from before the click, the
    /// shell or nobody → one retry; another app the user switched to → stop, never steal it back.
    @Test func retryDecision() {
        #expect(RestoreActivation.verdict(frontmost: 20, target: target, shell: shell, before: terminal, attemptsMade: 1) == .done)
        #expect(RestoreActivation.verdict(frontmost: terminal, target: target, shell: shell, before: terminal, attemptsMade: 1) == .retry)
        #expect(RestoreActivation.verdict(frontmost: shell, target: target, shell: shell, before: terminal, attemptsMade: 1) == .retry)
        #expect(RestoreActivation.verdict(frontmost: nil, target: target, shell: shell, before: terminal, attemptsMade: 1) == .retry)
        #expect(RestoreActivation.verdict(frontmost: 99, target: target, shell: shell, before: terminal, attemptsMade: 1) == .stop)
        // Retried once already: give up.
        #expect(RestoreActivation.verdict(frontmost: terminal, target: target, shell: shell, before: terminal, attemptsMade: 2) == .stop)
        #expect(RestoreActivation.verdict(frontmost: 20, target: target, shell: shell, before: terminal, attemptsMade: 2) == .done)
        // The app quit meanwhile.
        #expect(RestoreActivation.verdict(frontmost: terminal, target: [], shell: shell, before: terminal, attemptsMade: 1) == .stop)
    }

    /// The first attempt is the cooperative hand-off; the retry escalates to Accessibility's
    /// AXFrontmost when trusted, else the shell activates itself first and hands activation over.
    @Test func escalation() {
        #expect(RestoreActivation.method(attempt: 0, accessibility: true) == .cooperative)
        #expect(RestoreActivation.method(attempt: 0, accessibility: false) == .cooperative)
        #expect(RestoreActivation.method(attempt: 1, accessibility: true) == .accessibilityFrontmost)
        #expect(RestoreActivation.method(attempt: 1, accessibility: false) == .shellHandOff)
    }
}
