import Testing
import Foundation
@testable import Win7Core

private func input(pinned: Bool = true, running: Bool = true, windows: Int = 1, ax: Bool = true,
                   recent: [RecentDocument]? = []) -> JumpListInput {
    JumpListInput(appName: "TextEdit", isPinned: pinned, isRunning: running, windowCount: windows,
                  accessibility: ax, recent: recent)
}

private func doc(_ n: Int) -> RecentDocument { RecentDocument(name: "Doc \(n)", path: "/tmp/doc\(n).txt") }

/// Counts decodes: a hostile archive's class must never get this far.
final class InertCoding: NSObject, NSCoding {
    nonisolated(unsafe) static var initCount = 0
    override init() { super.init() }
    init?(coder: NSCoder) { InertCoding.initCount += 1; super.init() }
    func encode(with coder: NSCoder) { coder.encode(1, forKey: "x") }
}

final class InertSecureCoding: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true
    nonisolated(unsafe) static var initCount = 0
    override init() { super.init() }
    init?(coder: NSCoder) { InertSecureCoding.initCount += 1; super.init() }
    func encode(with coder: NSCoder) { coder.encode(1, forKey: "x") }
}

@Suite struct JumpListModelTests {
    @Test func tasksForAPinnedRunningAppWithOneWindow() {
        let s = JumpList.sections(input())
        #expect(s.count == 1)
        #expect(s[0].kind == .tasks && s[0].title == "Tasks")
        #expect(s[0].items == [
            JumpListItem(title: "TextEdit", action: .launch),
            JumpListItem(title: "Unpin this program from taskbar", action: .unpin),
            JumpListItem(title: "Close window", action: .closeWindow),
        ])
    }

    @Test func notRunningOffersNoClose() {
        let s = JumpList.sections(input(pinned: false, running: false, windows: 0))
        #expect(s.flatMap(\.items).map(\.action) == [.launch, .pin])
        #expect(s[0].items[1].title == "Pin this program to taskbar")
    }

    /// One window: "Close window", with or without Accessibility (hid it without
    /// Accessibility). No window: no close item.
    @Test func closeWindowForExactlyOneWindow() {
        for ax in [true, false] {
            #expect(JumpList.sections(input(windows: 1, ax: ax)).flatMap(\.items).map(\.action)
                    == [.launch, .unpin, .closeWindow])
            #expect(JumpList.sections(input(windows: 0, ax: ax)).flatMap(\.items).map(\.action) == [.launch, .unpin])
        }
    }

    /// Two or more windows: only "Close all windows", as in Windows 7, with or without Accessibility
    /// (then it quits the app after asking).
    @Test func closeAllForSeveralWindows() {
        for ax in [true, false] {
            let items = JumpList.sections(input(windows: 3, ax: ax)).flatMap(\.items)
            #expect(items.map(\.action) == [.launch, .unpin, .closeAllWindows])
            #expect(items.last?.title == "Close all windows")
        }
        #expect(JumpList.closeAllNeedsConfirmation(accessibility: false))
        #expect(!JumpList.closeAllNeedsConfirmation(accessibility: true))
    }

    /// Every combination of running × Accessibility × window count: which close items appear and
    /// what each one does.
    @Test func closeItemsTable() {
        typealias Row = (running: Bool, ax: Bool, windows: Int, close: [JumpListCloseEffect])
        let table: [Row] = [
            (false, false, 0, []), (false, true, 0, []),
            (true, false, 0, []), (true, true, 0, []),
            (true, false, 1, [.hintAccessibility]), (true, true, 1, [.closeFrontWindow]),
            (true, false, 2, [.confirmQuit]), (true, true, 2, [.closeEachWindow]),
            (true, false, 5, [.confirmQuit]), (true, true, 5, [.closeEachWindow]),
        ]
        for row in table {
            let items = JumpList.sections(input(running: row.running, windows: row.windows, ax: row.ax)).flatMap(\.items)
            let effects = items.compactMap { JumpList.closeEffect($0.action, accessibility: row.ax) }
            #expect(effects == row.close, "running \(row.running), ax \(row.ax), windows \(row.windows)")
            // The app's name and pin/unpin are always there, first.
            #expect(Array(items.prefix(2).map(\.action)) == [.launch, .unpin])
        }
        #expect(JumpList.closeEffect(.launch, accessibility: true) == nil)
        #expect(JumpList.closeEffect(.openFolder(path: "/x"), accessibility: false) == nil)
    }

    @Test func recentSectionComesFirstAndIsCapped() {
        let s = JumpList.sections(input(recent: (1...14).map(doc)))
        #expect(s.map(\.kind) == [.recent, .tasks])
        #expect(s[0].title == "Recent")
        #expect(s[0].items.count == JumpList.maxRecent && JumpList.maxRecent == 10)
        #expect(s[0].items.first == JumpListItem(title: "Doc 1", action: .openRecent(path: "/tmp/doc1.txt")))
    }

    @Test func recentSectionOmittedWhenEmptyOrUnreadable() {
        #expect(JumpList.sections(input(recent: [])).map(\.kind) == [.tasks])
        #expect(JumpList.sections(input(recent: nil)).map(\.kind) == [.tasks])
    }

    /// Choices that open something hand focus to that app, and the quit confirmation takes it too;
    /// the others leave the previous app to be given focus back.
    @Test func whichChoicesTakeFocus() {
        for ax in [true, false] {
            #expect(JumpList.choiceTakesFocus(.openRecent(path: "/x"), accessibility: ax))
            #expect(JumpList.choiceTakesFocus(.launch, accessibility: ax))
            #expect(JumpList.choiceTakesFocus(.openFolder(path: "/x"), accessibility: ax))
            // Without Accessibility "Close window" only shows the (non-activating) balloon.
            for a in [JumpListAction.pin, .unpin, .closeWindow] { #expect(!JumpList.choiceTakesFocus(a, accessibility: ax)) }
        }
        #expect(!JumpList.choiceTakesFocus(.closeAllWindows, accessibility: true))
        #expect(JumpList.choiceTakesFocus(.closeAllWindows, accessibility: false))
    }

    @Test func keyboardSelectionWraps() {
        #expect(JumpList.moveSelection(nil, by: 1, count: 4) == 0)
        #expect(JumpList.moveSelection(nil, by: -1, count: 4) == 3)
        #expect(JumpList.moveSelection(3, by: 1, count: 4) == 0)
        #expect(JumpList.moveSelection(0, by: -1, count: 4) == 3)
        #expect(JumpList.moveSelection(1, by: 1, count: 4) == 2)
        #expect(JumpList.moveSelection(nil, by: 1, count: 0) == nil)
    }
}

@Suite struct RecentDocumentsTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("w7jl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        // The real path (/private/var/...), as bookmarks store it.
        guard let real = realpath(d.path, nil) else { return d }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }

    /// The same shape as LSSharedFileList's archives: {"items": [{"Bookmark": data, "uuid": ...}], "properties": {}}.
    private func archive(bookmarks: [Data]) throws -> Data {
        let items: [NSDictionary] = bookmarks.map {
            ["Bookmark": $0 as NSData, "uuid": UUID().uuidString as NSString, "visibility": 0 as NSNumber] as NSDictionary
        }
        let root: NSDictionary = ["items": items as NSArray, "properties": NSDictionary()]
        return try NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: false)
    }

    @Test func archivePathIsTheLowercasedBundleID() {
        let dir = URL(fileURLWithPath: "/x")
        #expect(RecentDocuments.archiveURLs(bundleID: "com.Apple.TextEdit", directory: dir).map(\.lastPathComponent)
                == ["com.apple.textedit.sfl4", "com.apple.textedit.sfl3", "com.apple.textedit.sfl2"])
    }

    /// Current macOS writes only `.sfl4` (same shape); it wins over older files left beside it.
    @Test func sfl4IsPickedFirst() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let new = dir.appendingPathComponent("New.txt"), old = dir.appendingPathComponent("Old.txt")
        for f in [new, old] { try Data("x".utf8).write(to: f) }
        try archive(bookmarks: [try old.bookmarkData()]).write(to: dir.appendingPathComponent("com.example.app.sfl3"))
        try archive(bookmarks: [try new.bookmarkData()]).write(to: dir.appendingPathComponent("com.example.app.sfl4"))
        #expect(RecentDocuments.load(bundleID: "com.example.app", directory: dir, home: "/nonexistent-home")?.map(\.name) == ["New"])
    }

    @Test func decodesBookmarksAndSkipsMissingFiles() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("Report.txt"), b = dir.appendingPathComponent("Gone.rtf"),
            c = dir.appendingPathComponent("Notes.md")
        for f in [a, b, c] { try Data("x".utf8).write(to: f) }
        let marks = try [a, b, c].map { try $0.bookmarkData() }
        try FileManager.default.removeItem(at: b)
        try archive(bookmarks: marks).write(to: dir.appendingPathComponent("com.example.app.sfl3"))

        let docs = RecentDocuments.load(bundleID: "com.example.App", directory: dir, home: "/nonexistent-home")
        #expect(docs?.map(\.name) == ["Report", "Notes"])
        #expect(docs?.map(\.path) == [a.path, c.path])
    }

    @Test func fallsBackToSfl2AndCapsAtTen() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var marks: [Data] = []
        for i in 0..<12 {
            let f = dir.appendingPathComponent("f\(i).txt")
            try Data("x".utf8).write(to: f)
            marks.append(try f.bookmarkData())
        }
        try archive(bookmarks: marks).write(to: dir.appendingPathComponent("com.example.app.sfl2"))
        let docs = RecentDocuments.load(bundleID: "com.example.app", directory: dir, home: "/nonexistent-home")
        #expect(docs?.count == 10)
        #expect(docs?.first?.name == "f0")
    }

    /// No archive, an unreadable folder or garbage: no section (nil), never a crash.
    @Test func unreadableOrGarbageGivesNil() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(RecentDocuments.load(bundleID: "com.none", directory: dir, home: "/h") == nil)
        try Data("not an archive".utf8).write(to: dir.appendingPathComponent("com.bad.sfl3"))
        #expect(RecentDocuments.load(bundleID: "com.bad", directory: dir, home: "/h") == nil)
        #expect(RecentDocuments.bookmarks(fromArchive: Data([0, 1, 2])) == nil)
    }

    /// A class outside the allow-list fails the whole decode, wherever it sits (here away from any
    /// Bookmark key, in "properties").
    @Test func refusesAllowListedShapeWithAForeignClassElsewhere() throws {
        let mark = Data("bookmark".utf8) as NSData
        let root: NSDictionary = ["items": [["Bookmark": mark] as NSDictionary] as NSArray,
                                  "properties": ["when": Date() as NSDate] as NSDictionary]
        let data = try NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: false)
        #expect(RecentDocuments.bookmarks(fromArchive: data) == nil)
    }

    /// Custom coding classes in the user-writable archive are never instantiated: not nested in an
    /// item, not as the root, whether they adopt secure coding or not.
    @Test func neverInstantiatesCustomCodingClasses() throws {
        let mark = Data("bookmark".utf8) as NSData
        InertCoding.initCount = 0
        InertSecureCoding.initCount = 0
        for object in [InertCoding(), InertSecureCoding()] as [NSObject] {
            let nested: NSDictionary = ["items": [["Bookmark": mark, "extra": object] as NSDictionary] as NSArray]
            for root in [nested, object] {
                let data = try NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: false)
                #expect(RecentDocuments.bookmarks(fromArchive: data) == nil)
            }
        }
        #expect(InertCoding.initCount == 0)
        #expect(InertSecureCoding.initCount == 0)
    }

    /// Files in folders macOS guards with a privacy prompt are listed from the path stored in the
    /// bookmark, without resolving it or checking the file, so no prompt can appear.
    @Test func protectedFoldersAreNotTouched() throws {
        let home = "/Users/someone"
        for p in ["Desktop/a.txt", "Documents/b.txt", "Downloads/c.txt", "Library/Mobile Documents/x/d.txt",
                  "Library/CloudStorage/e.txt", "Library/Containers/com.apple.TextEdit/Data/f.rtf",
                  "Library/Group Containers/group.x/g.txt"] {
            #expect(RecentDocuments.isPrivacyProtected("\(home)/\(p)", home: home))
        }
        #expect(RecentDocuments.isPrivacyProtected("/Volumes/USB/f.txt", home: home))
        #expect(!RecentDocuments.isPrivacyProtected("\(home)/Projects/g.txt", home: home))
        #expect(!RecentDocuments.isPrivacyProtected("\(home)/DocumentsOld/g.txt", home: home))
        #expect(!RecentDocuments.isPrivacyProtected("\(home)/Library/ContainersOld/g.txt", home: home))
        #expect(!RecentDocuments.isPrivacyProtected("\(home)/Library/Preferences/g.plist", home: home))
        #expect(!RecentDocuments.isPrivacyProtected("/tmp/h.txt", home: home))

        // A bookmark whose file is gone, under a "protected" home: still listed, by its stored path.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let docs = dir.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let f = docs.appendingPathComponent("Letter.pages")
        try Data("x".utf8).write(to: f)
        let mark = try f.bookmarkData()
        try FileManager.default.removeItem(at: f)
        try archive(bookmarks: [mark]).write(to: dir.appendingPathComponent("com.example.app.sfl3"))
        let listed = RecentDocuments.load(bundleID: "com.example.app", directory: dir, home: dir.path)
        #expect(listed?.map(\.name) == ["Letter"])
        #expect(listed?.first?.path.hasSuffix("/Documents/Letter.pages") == true)
    }
}
