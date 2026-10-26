import AppKit
import Testing
import Win7ChromeCore

// MARK: - Model

@Test func breadcrumbsUnderHomeStartAtHomeFolder() {
    let segs = W7BreadcrumbSegments(URL(fileURLWithPath: "/Users/k/Documents/Work"), "/Users/k")
    #expect(segs.map { $0["title"] } == ["k", "Documents", "Work"])
    #expect(segs.map { $0["path"] } == ["/Users/k", "/Users/k/Documents", "/Users/k/Documents/Work"])
}

@Test func breadcrumbsOutsideHomeStartAtComputer() {
    let segs = W7BreadcrumbSegments(URL(fileURLWithPath: "/Applications/Utilities"), "/Users/k")
    #expect(segs.map { $0["title"] } == ["Computer", "Applications", "Utilities"])
    #expect(segs.map { $0["path"] } == ["/", "/Applications", "/Applications/Utilities"])
}

@Test func breadcrumbsForNilFolderAreComputerOnly() {
    let segs = W7BreadcrumbSegments(nil, "/Users/k")
    #expect(segs.map { $0["title"] } == ["Computer"])
    #expect(segs.map { $0["path"] } == ["/"])
}

@Test func breadcrumbsEdgeCases() {
    // The home folder itself, a sibling whose name only starts with the home name, and the root.
    #expect(W7BreadcrumbSegments(URL(fileURLWithPath: "/Users/k"), "/Users/k").map { $0["title"] } == ["k"])
    #expect(W7BreadcrumbSegments(URL(fileURLWithPath: "/Users/kk/x"), "/Users/k").map { $0["title"] }
            == ["Computer", "Users", "kk", "x"])
    #expect(W7BreadcrumbSegments(URL(fileURLWithPath: "/"), "/Users/k").map { $0["title"] } == ["Computer"])
    #expect(W7BreadcrumbSegments(URL(fileURLWithPath: "/Users/k/Documents"), "/Users/k/").map { $0["path"] }
            == ["/Users/k", "/Users/k/Documents"])
}

@MainActor func explorerTestMenu() -> (root: NSMenu, back: NSMenuItem, newFolder: NSMenuItem, copy: NSMenuItem) {
    let root = NSMenu()
    func top(_ title: String, _ items: [NSMenuItem]) {
        let sub = NSMenu(title: title)
        items.forEach(sub.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        root.addItem(item)
    }
    let back = NSMenuItem(title: "Back", action: nil, keyEquivalent: "[")
    back.keyEquivalentModifierMask = .command
    let newFolder = NSMenuItem(title: "New Folder", action: nil, keyEquivalent: "N")
    newFolder.keyEquivalentModifierMask = .command
    let copy = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "c")
    copy.keyEquivalentModifierMask = .command
    top("Go", [back])
    top("File", [newFolder])
    top("Edit", [.separator(), copy])
    return (root, back, newFolder, copy)
}

@MainActor @Test func findMenuItemByKeyEquivalent() {
    let m = explorerTestMenu()
    #expect(W7FindMenuItem(m.root, "[", .command) === m.back)
    #expect(W7FindMenuItem(m.root, "n", [.shift, .command]) === m.newFolder)
    #expect(W7FindMenuItem(m.root, "N", .command) === m.newFolder)
    #expect(W7FindMenuItem(m.root, "c", .command) === m.copy)
    #expect(W7FindMenuItem(m.root, "c", [.command, .option]) == nil)
    #expect(W7FindMenuItem(m.root, "n", .command) == nil)
    #expect(W7FindMenuItem(m.root, "", .command) == nil)
}

@Test func finderGoScriptEscapesQuotesOnce() {
    let s = W7FinderGoScript("/tmp/a \"b\"")
    #expect(s.contains("POSIX file \"/tmp/a \\\"b\\\"\""))
    #expect(!s.contains("\\\\\""))
    #expect(s == "tell application \"Finder\" to set target of Finder window 1 to (POSIX file \"/tmp/a \\\"b\\\"\" as alias)")
    #expect(W7FinderGoScript("/x\\y").contains("POSIX file \"/x\\\\y\""))
}

func decodePlist(_ data: Data) -> [String: Any] {
    (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
}

@Test func savedSearchPlist() {
    let p = decodePlist(W7SavedSearchPlist("rep", "/Users/k"))
    #expect(p["RawQuery"] as? String == "(kMDItemDisplayName == \"*rep*\"cd)")
    #expect((p["SearchCriteria"] as? [String: Any])?["FXScopeArrayOfPaths"] as? [String] == ["/Users/k"])
    #expect(p["CompatibleVersion"] as? Int == 1)
}

@Test func savedSearchPlistEscapesQuery() {
    let p = decodePlist(W7SavedSearchPlist("a\"b\\c", "/"))
    #expect(p["RawQuery"] as? String == "(kMDItemDisplayName == \"*a\\\"b\\\\c*\"cd)")
}

@Test func explorerAdoptionGate() {
    #expect(W7ExplorerShouldAdopt("com.apple.finder", "TBrowserWindow", true))
    #expect(W7ExplorerShouldAdopt("com.apple.finder", "TBrowserWindow", false))
    #expect(W7ExplorerShouldAdopt("com.apple.finder", "SomeFutureWindow", true))
    #expect(!W7ExplorerShouldAdopt("com.apple.finder", "NSPanel", false))
    #expect(!W7ExplorerShouldAdopt("com.apple.TextEdit", "TBrowserWindow", true))
    #expect(!W7ExplorerShouldAdopt(nil, "TBrowserWindow", true))
}

@Test func explorerMetrics() {
    #expect(W7ExplorerNavBarHeight == 34 && W7ExplorerCommandBarHeight == 32)
}

// MARK: - Adoption

@MainActor func finderLikeWindow() -> NSWindow {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                     backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.titlebarAppearsTransparent = true
    w.toolbar = NSToolbar(identifier: "W7ExplorerTestToolbar")
    return w
}

@MainActor @Test func explorerAdoptIsIdempotent() {
    let w = finderLikeWindow()
    #expect(!W7IsExplorerWindow(w))
    W7ExplorerAdopt(w)
    W7ExplorerAdopt(w)
    #expect(W7IsExplorerWindow(w))
    let acc = w.titlebarAccessoryViewControllers
    #expect(acc.count == 2)
    #expect(acc.allSatisfy { $0.layoutAttribute == .bottom })
    #expect(acc.map { $0.view.frame.height } == [34, 32])
    #expect(!w.styleMask.contains(.fullSizeContentView))
    #expect(!w.titlebarAppearsTransparent)
    #expect(w.toolbar?.isVisible == false)
    // Now eligible for the Aero title bar.
    #expect(W7ShouldDecorateWindow(w.styleMask, false, w.titlebarAppearsTransparent, false))
}

@MainActor @Test func explorerWindowGetsTitlebarButNoMenuStrip() {
    _ = NSApplication.shared   // NSApp is nil until something creates it; test order isn't fixed
    let saved = NSApp.mainMenu
    defer { NSApp.mainMenu = saved }
    let main = NSMenu()
    let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    file.submenu = NSMenu(title: "File")
    main.addItem(file)
    NSApp.mainMenu = main

    let w = finderLikeWindow()
    W7ExplorerAdopt(w)
    W7ChromeController.decorateWindow(w)
    let bar = w.standardWindowButton(.closeButton)!.superview!
    #expect(bar.subviews.filter { $0 is W7TitlebarView }.count == 1)
    #expect(!w.titlebarAccessoryViewControllers.contains { $0 is W7MenuStripController })
    #expect(w.titlebarAccessoryViewControllers.count == 2)
}

@MainActor @Test func explorerWindowDoesNotLeak() {
    weak var weakWindow: NSWindow?
    autoreleasepool {
        let w = finderLikeWindow()
        W7ExplorerAdopt(w)
        W7ChromeController.decorateWindow(w)
        weakWindow = w
    }
    #expect(weakWindow == nil)
}

/// Key paths currently observed on `object`, read from its KVO observation info's description
/// (AppKit itself observes windows too, so the info is never simply nil).
func observedKeyPathsDescription(_ object: NSObject) -> String {
    guard let info = object.observationInfo else { return "" }
    return String(describing: Unmanaged<AnyObject>.fromOpaque(info).takeUnretainedValue())
}

@MainActor @Test func explorerWindowCloseRemovesObservers() {
    let w = finderLikeWindow()
    #expect(!observedKeyPathsDescription(w).contains("representedURL"))
    W7ExplorerAdopt(w)
    #expect(observedKeyPathsDescription(w).contains("Key path: representedURL"))
    w.close()
    #expect(!observedKeyPathsDescription(w).contains("representedURL"))
}

@MainActor @Test func explorerWindowCloseShowsToolbarAgain() {
    // Finder saves per-folder window state on close; it must not be saved with the toolbar hidden.
    let w = finderLikeWindow()
    W7ExplorerAdopt(w)
    #expect(w.toolbar?.isVisible == false)
    w.close()
    #expect(w.toolbar?.isVisible == true)
}

@Test func savedSearchPlistMatchesWildcardsLiterally() {
    let p = decodePlist(W7SavedSearchPlist("a*b?", "/"))
    #expect(p["RawQuery"] as? String == "(kMDItemDisplayName == \"*a\\*b\\?*\"cd)")
}

@Test func folderURLAcceptsOnlyDirectories() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("W7FolderURL-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("a.txt")
    try Data("x".utf8).write(to: file)
    #expect(W7ExplorerFolderURL(URL(fileURLWithPath: dir.path)) != nil)
    #expect(W7ExplorerFolderURL(URL(fileURLWithPath: file.path)) == nil)
    #expect(W7ExplorerFolderURL(URL(string: "https://example.com/")) == nil)
    #expect(W7ExplorerFolderURL(nil) == nil)
}

@Test func staleSavedSearchesAreRemoved() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("W7Stale-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let now = Date()
    func make(_ name: String, age: TimeInterval) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: u)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: u.path)
        return u
    }
    let old = try make("Win7Search-old.savedSearch", age: 25 * 3600)
    let fresh = try make("Win7Search-new.savedSearch", age: 3600)
    let other = try make("Other-old.savedSearch", age: 25 * 3600)
    #expect(W7RemoveStaleSavedSearches(dir.path, now) == 1)
    #expect(!fm.fileExists(atPath: old.path))
    #expect(fm.fileExists(atPath: fresh.path))
    #expect(fm.fileExists(atPath: other.path))
}

// MARK: - location query, counts, subfolders

@Test func finderTargetScriptForFrontWindowAndById() {
    let front = W7FinderTargetScript(0)
    #expect(front.contains("set w to Finder window 1"))
    #expect(front.contains("(id of w as text) & linefeed & (name of w) & linefeed & (POSIX path of (target of w as alias))"))
    #expect(W7FinderTargetScript(4711).contains("set w to Finder window id 4711"))
    #expect(!W7FinderTargetScript(-3).contains("id -3"))
}

@Test func parseFinderTargetOutput() {
    let ok = W7ParseFinderTargetOutput("4711\nBelgeler\n/Users/k/Documents/\n")
    #expect(ok?["id"] as? Int == 4711)
    #expect(ok?["name"] as? String == "Belgeler")
    #expect(ok?["path"] as? String == "/Users/k/Documents")
    #expect(W7ParseFinderTargetOutput("12\nMacintosh HD\n/\n")?["path"] as? String == "/")
    // CRLF, and a folder name with a newline in it (only the path may have one).
    #expect(W7ParseFinderTargetOutput("12\r\na\r\n/tmp/a\r\n")?["path"] as? String == "/tmp/a")
    #expect(W7ParseFinderTargetOutput("12\nb\n/tmp/a\nb/\n")?["path"] as? String == "/tmp/a\nb")
    // Garbage, a missing id, a missing name line, a relative path, an error message.
    #expect(W7ParseFinderTargetOutput("") == nil)
    #expect(W7ParseFinderTargetOutput("abc\nx\n/tmp\n") == nil)
    #expect(W7ParseFinderTargetOutput("0\nx\n/tmp\n") == nil)
    #expect(W7ParseFinderTargetOutput("12\n/tmp") == nil)
    #expect(W7ParseFinderTargetOutput("12\nk\nUsers/k\n") == nil)
    #expect(W7ParseFinderTargetOutput("12\n") == nil)
    #expect(W7ParseFinderTargetOutput("execution error: Finder got an error (-1728)") == nil)
}

@Test func decideFinderTarget() {
    let docs = W7ParseFinderTargetOutput("12\nBelgeler\n/Users/k/Documents\n")
    let other = W7ParseFinderTargetOutput("13\nMasaüstü\n/Users/k/Desktop\n")
    // A matching answer is shown.
    #expect(W7DecideFinderTarget(docs, "Belgeler", "Belgeler", "İndirilenler", false, true) == .accept)
    // A front-window answer that arrives after another window came forward: the old breadcrumb
    // ("İndirilenler", built for another title) must not stay; title only.
    #expect(W7DecideFinderTarget(docs, "Belgeler", "Belgeler", "İndirilenler", false, false) == .titleOnly)
    // ...but a location already built for this title is kept.
    #expect(W7DecideFinderTarget(docs, "Belgeler", "Belgeler", "Belgeler", false, false) == .keep)
    // The window navigated during the query: ask again, don't drop the id.
    #expect(W7DecideFinderTarget(docs, "Belgeler", "Masaüstü", "Belgeler", true, false) == .requery)
    #expect(W7DecideFinderTarget(nil, "Belgeler", "Masaüstü", "Belgeler", true, false) == .requery)
    // An id that answered with another window's name, the title unchanged: the id is wrong.
    #expect(W7DecideFinderTarget(other, "Belgeler", "Belgeler", "Belgeler", true, false) == .wrongWindow)
    // A failed query (Recents, AirDrop): title only unless the location already fits.
    #expect(W7DecideFinderTarget(nil, "Son Kullanılanlar", "Son Kullanılanlar", "Belgeler", false, true) == .titleOnly)
    #expect(W7DecideFinderTarget(nil, "Belgeler", "Belgeler", "Belgeler", false, true) == .keep)
    #expect(W7DecideFinderTarget(nil, "Belgeler", "Belgeler", nil, true, false) == .titleOnly)
}

@Test func acceptFinderTargetOnlyForThisWindow() {
    let answer = W7ParseFinderTargetOutput("12\nBelgeler\n/Users/k/Documents\n")
    // A "Finder window 1" answer: only while the window is still key, and only with its title.
    #expect(W7AcceptFinderTarget(answer, "Belgeler", false, true))
    #expect(!W7AcceptFinderTarget(answer, "Belgeler", false, false))   // another window came to the front
    #expect(!W7AcceptFinderTarget(answer, "İndirilenler", false, true)) // the name is another window's
    // An answer for a specific window id: key state doesn't matter, the name still does.
    #expect(W7AcceptFinderTarget(answer, "Belgeler", true, false))
    #expect(!W7AcceptFinderTarget(answer, "Masaüstü", true, false))
    #expect(!W7AcceptFinderTarget(nil, "Belgeler", true, true))
}

@Test func selectionScriptAndPathLines() {
    #expect(W7FinderSelectionScript().contains("repeat with i in (get selection)"))
    #expect(W7FinderSelectionScript().contains("POSIX path of (i as alias)"))
    #expect(W7ParsePathLines("/a/b/\r\n/c d\n\nrelative\n/\n") == ["/a/b", "/c d", "/"])
    #expect(W7ParsePathLines("").isEmpty)
}

@Test func itemCountText() {
    #expect(W7ItemCountText(0) == "0 items")
    #expect(W7ItemCountText(1) == "1 item")
    #expect(W7ItemCountText(16) == "16 items")
    #expect(W7ItemCountText(-1) == "")
}

func makeTree(_ names: [String: Bool]) throws -> URL {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("W7Tree-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, isDir) in names {
        let u = dir.appendingPathComponent(name)
        if isDir { try fm.createDirectory(at: u, withIntermediateDirectories: true) }
        else { try Data("x".utf8).write(to: u) }
    }
    return dir
}

@Test func countVisibleItemsSkipsHidden() throws {
    let dir = try makeTree(["a": true, "b.txt": false, ".hidden": false, ".DS_Store": false])
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(W7CountVisibleItems(dir.path) == 2)
    #expect(W7CountVisibleItems(dir.appendingPathComponent("missing").path) == -1)
}

@Test func subfolderEntriesAreSortedVisibleFolders() throws {
    let dir = try makeTree(["b": true, "a10": true, "a9": true, ".hid": true, "f.txt": false, "X.app": true])
    defer { try? FileManager.default.removeItem(at: dir) }
    let entries = W7SubfolderEntries(dir.path, 10)
    #expect(entries.map { $0["title"] } == ["a9", "a10", "b"])
    #expect(entries.first?["path"] == dir.appendingPathComponent("a9").path)
    #expect(W7SubfolderEntries(dir.path, 2).count == 2)
    #expect(W7SubfolderEntries(dir.appendingPathComponent("missing").path, 10).isEmpty)
}
