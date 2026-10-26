import Testing
import Foundation
@testable import Win7Core

private func app(_ name: String, _ path: String, _ id: String? = nil) -> AppEntry {
    AppEntry(name: name, path: path, bundleID: id)
}

/// A UserDefaults suite of its own, removed after the test.
private func withTempDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let name = "w7-startmenu-test-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    defer { d.removePersistentDomain(forName: name) }
    try body(d)
}

@Suite struct StartMenuModelTests {
    // MARK: Pins and recents

    @Test func pinnedThenRecentsExcludingPinned() {
        var m = StartMenuModel(pins: ["/A.app", "/B.app"])
        for p in ["/A.app", "/C.app", "/D.app", "/B.app", "/E.app"] { m.recordLaunch(p) }
        let s = m.sections { _ in true }
        #expect(s.pinned == ["/A.app", "/B.app"])
        #expect(s.recent == ["/E.app", "/D.app", "/C.app"])
    }

    @Test func recentsCappedAtTenAfterExcludingPinned() {
        var m = StartMenuModel(pins: ["/P.app"])
        for i in 0..<15 { m.recordLaunch("/R\(i).app") }
        m.recordLaunch("/P.app")
        let s = m.sections { _ in true }
        #expect(s.recent.count == StartMenuModel.maxRecents)
        #expect(s.recent.first == "/R14.app" && s.recent.last == "/R5.app")
        #expect(!s.recent.contains("/P.app"))
    }

    @Test func missingAppsAreHidden() {
        var m = StartMenuModel(pins: ["/Gone.app", "/A.app"])
        m.recordLaunch("/Gone2.app"); m.recordLaunch("/B.app")
        let s = m.sections { !$0.contains("Gone") }
        #expect(s.pinned == ["/A.app"] && s.recent == ["/B.app"])
    }

    @Test func pinUnpinAndRemoveFromList() {
        var m = StartMenuModel()
        m.recordLaunch("/A.app"); m.recordLaunch("/B.app")
        m.pin("/A.app"); m.pin("/A.app")
        #expect(m.pins == ["/A.app"] && m.isPinned("/A.app"))
        #expect(m.sections { _ in true }.recent == ["/B.app"])
        m.unpin("/A.app")
        #expect(m.pins.isEmpty && !m.isPinned("/A.app"))
        // Unpinned, it is back in the recents at its launch position.
        #expect(m.sections { _ in true }.recent == ["/B.app", "/A.app"])
        m.removeRecent("/B.app")
        #expect(m.sections { _ in true }.recent == ["/A.app"])
    }

    @Test func persistenceRoundTrip() {
        withTempDefaults { d in
            let store = StartMenuStore(defaults: d)
            var first = store.load { ["/Finder.app", "/Safari.app"] }
            #expect(first.pins == ["/Finder.app", "/Safari.app"])
            first.unpin("/Finder.app")
            first.pin("/X.app")
            first.recordLaunch("/R.app")
            store.save(first)
            // The defaults only apply on first run: unpinning a default pin sticks.
            let again = store.load { ["/Finder.app", "/Safari.app"] }
            #expect(again == first)
            #expect(again.pins == ["/Safari.app", "/X.app"])
            #expect(again.sections { _ in true }.recent == ["/R.app"])
        }
    }

    @Test func readsTheOlderRecentAppsFormat() throws {
        try withTempDefaults { d in
            var old = RecentApps()
            old.record("/Old.app")
            d.set(try JSONEncoder().encode(old), forKey: StartMenuStore.recentsKey)
            let m = StartMenuStore(defaults: d).load { [] }
            #expect(m.sections { _ in true }.recent == ["/Old.app"])
        }
    }

    @Test func taskbarPinToggleSharesTheTaskbarList() {
        withTempDefaults { d in
            #expect(TaskbarPinList.load(d) == TaskbarModel.defaultPins)
            var pins = TaskbarPinList.toggled(TaskbarPinList.load(d), bundleID: "com.x", name: "X")
            #expect(pins.last == PinnedApp(bundleID: "com.x", name: "X"))
            TaskbarPinList.save(pins, d)
            #expect(TaskbarPinList.load(d) == pins)
            pins = TaskbarPinList.toggled(pins, bundleID: "com.apple.finder", name: "Finder")
            #expect(!pins.contains { $0.bundleID == "com.apple.finder" })
            #expect(TaskbarPinList.key == "pinnedApps")
        }
    }

    // MARK: Default pins, launches, jump-list arrows

    /// First run pins the programs that have Windows 7 icons, in this order.
    @Test func defaultPinsOrder() {
        #expect(StartMenuModel.defaultPinBundleIDs == ["com.apple.finder", "com.apple.Safari", "com.apple.calculator",
                                                       "com.apple.Notes", "com.apple.Terminal", "com.apple.Preview"])
        #expect(StartMenuModel.maxRecents == 10)
    }

    /// The new defaults never touch saved pins: an existing user's order comes back as saved.
    @Test func savedPinsKeepTheirOrderWhateverTheDefaults() throws {
        try withTempDefaults { d in
            let saved = ["/Terminal.app", "/Finder.app", "/Calculator.app"]
            d.set(try JSONEncoder().encode(saved), forKey: StartMenuStore.pinsKey)
            let m = StartMenuStore(defaults: d).load { ["/Finder.app", "/Safari.app", "/Notes.app"] }
            #expect(m.pins == saved)
            #expect(StartMenuStore(defaults: d).load { [] }.pins == saved)
        }
    }

    /// Programs started any way (Dock, Finder, Spotlight) join the recent list: regular apps only, never the shell
    /// or Finder's location helpers.
    @Test func launchesFromAnywhereAreRecorded() {
        let shell = "/x/Win7Shell.app"
        #expect(StartMenuModel.recordsLaunch(path: "/Applications/Maps.app", regular: true, shellPath: shell))
        #expect(!StartMenuModel.recordsLaunch(path: "/Applications/Helper.app", regular: false, shellPath: shell))
        #expect(!StartMenuModel.recordsLaunch(path: shell, regular: true, shellPath: shell))
        #expect(!StartMenuModel.recordsLaunch(path: nil, regular: true, shellPath: shell))
        #expect(!StartMenuModel.recordsLaunch(path: "/usr/local/bin/tool", regular: true, shellPath: nil))
        #expect(!StartMenuModel.recordsLaunch(path: StartMenuPlaces.finderComputerHelper, regular: true, shellPath: nil))
    }

    /// A program reached through a symlink (`/Applications/Safari.app` → its Cryptex) is one program: the Start
    /// menu's launch and the system's did-launch path record one history entry, and a pin hides it from Recent.
    @Test func symlinkedProgramIsOneProgram() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w7-symlink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("Cryptexes/App/Fake.app")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("Applications/Fake.app")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let canonical = StartMenuModel.canonicalPath(link.path)
        #expect(canonical == StartMenuModel.canonicalPath(real.path))
        #expect(canonical != link.path)
        #expect(StartMenuModel.canonicalPath("/Nowhere/A.app") == "/Nowhere/A.app")

        var m = StartMenuModel()
        m.recordLaunch(link.path)        // chosen in the Start menu (the catalog's path)
        m.recordLaunch(real.path)        // NSRunningApplication's bundle path
        #expect(m.history == [canonical])
        #expect(m.sections { _ in true }.recent == [canonical])
        // A history saved before canonical paths: the next launch replaces it.
        m = StartMenuModel(history: [link.path, "/B.app"])
        m.recordLaunch(real.path)
        #expect(m.history == [canonical, "/B.app"])
        // Pinned under the symlink: the launch stays out of Recent; unpin and remove find it by either path.
        m = StartMenuModel(pins: [link.path])
        m.recordLaunch(real.path)
        #expect(m.isPinned(real.path))
        #expect(m.sections { _ in true }.recent.isEmpty)
        m.unpin(real.path)
        #expect(m.pins.isEmpty)
        #expect(m.sections { _ in true }.recent == [canonical])
        m.removeRecent(link.path)
        #expect(m.history.isEmpty)
        // Old duplicate entries show once.
        m = StartMenuModel(history: [real.path, link.path])
        #expect(m.sections { _ in true }.recent.count == 1)

        // The recent entry is shown as the catalog's program (its Windows name, its path).
        let entry = AppEntry(name: "Internet Explorer", path: link.path, bundleID: "com.x")
        let other = AppEntry(name: "Other", path: dir.appendingPathComponent("Other.app").path, bundleID: nil)
        #expect(StartMenuModel.catalogEntry(forPath: canonical, in: [other, entry]) == entry)
        #expect(StartMenuModel.catalogEntry(forPath: link.path, in: [other, entry]) == entry)
        #expect(StartMenuModel.catalogEntry(forPath: "/Nowhere/Fake.app", in: [other, entry]) == nil)
    }

    /// The ▸ on a pinned or recent program: only with recent documents (or Finder's frequent folders), with the
    /// taskbar jump list's own rows, without its Tasks.
    @Test func jumpListArrowRows() {
        let docs = [RecentDocument(name: "Report", path: "/u/Report.txt")]
        let folders = [RecentDocument(name: "Work", path: "/u/Work")]
        #expect(StartMenuJumpList.sections(recent: nil, frequent: nil).isEmpty)
        #expect(StartMenuJumpList.sections(recent: [], frequent: []).isEmpty)
        let s = StartMenuJumpList.sections(recent: docs, frequent: folders)
        #expect(s.map(\.kind) == [.frequent, .recent])
        #expect(s[1].items == [JumpListItem(title: "Report", action: .openRecent(path: "/u/Report.txt"))])
        #expect(s[0].items == [JumpListItem(title: "Work", action: .openFolder(path: "/u/Work"))])
        let many = (0..<15).map { RecentDocument(name: "D\($0)", path: "/u/D\($0)") }
        #expect(StartMenuJumpList.sections(recent: many, frequent: nil).first?.items.count == JumpList.maxRecent)
        #expect(StartMenuJumpList.showsArrow(listed: true, sections: s))
        #expect(!StartMenuJumpList.showsArrow(listed: false, sections: s))   // search results, All Programs
        #expect(!StartMenuJumpList.showsArrow(listed: true, sections: []))
        #expect(StartMenuJumpList.arrowWidth == 22)
    }

    /// Hovering the ▸ opens the list after a short dwell (a click opens it at once).
    @Test func jumpListArrowOpensAfterHoverDelay() {
        var h = HoverIntent(delay: StartMenuJumpList.hoverDelay)
        h.enter(at: 10)
        #expect(!h.shouldFire(now: 10.2))
        #expect(h.shouldFire(now: 10.4))
    }

    /// After the list closes (Esc, a click outside) with the pointer still on the ▸, moving on the arrow does not
    /// open it again; leaving the arrow and coming back does.
    @Test func jumpListArrowDoesNotReopenUntilThePointerLeaves() {
        var a = StartMenuJumpList.ArrowHover()
        var armed: Bool
        armed = a.pointer(over: 2); #expect(armed)              // arms the dwell
        #expect(a.row == 2)
        armed = a.pointer(over: 2); #expect(!armed)             // still there: nothing new
        a.open(row: 2)
        a.listClosed(row: 2)
        #expect(a.row == nil)
        armed = a.pointer(over: 2); #expect(!armed)             // a small move on the same arrow: highlighted, not armed
        #expect(a.row == 2)
        armed = a.pointer(over: 2); #expect(!armed)
        armed = a.pointer(over: nil); #expect(!armed)           // left the arrow
        #expect(a.row == nil)
        armed = a.pointer(over: 2); #expect(armed)              // back: arms again
        a.listClosed(row: 2)
        armed = a.pointer(over: 3); #expect(armed)              // another row's arrow arms at once
        a.listClosed(row: 3)
        a.reset()
        armed = a.pointer(over: 3); #expect(armed)              // the menu reopened or the rows changed: forgotten
    }

    /// The right column: Computer opens through Finder's own Computer helper, Default Programs is the Control Panel
    /// item, Help and Support the shell's window.
    @Test func rightColumnTargets() {
        #expect(StartMenuPlaces.finderComputerHelper
            == "/System/Library/CoreServices/Finder.app/Contents/Applications/Computer.app")
        #expect(StartMenuPlaces.defaultProgramsItemID == "default-programs")
        #expect(ControlPanelCatalog.items.contains { $0.id == StartMenuPlaces.defaultProgramsItemID })
        #expect(ShellWindowTarget.help.identifier == "win7.help")
        #expect(ShellWindowTarget.help.title == "Windows Help and Support")
    }

    // MARK: All Programs tree

    @Test func folderTreeGroupsSubfolders() {
        let apps = [
            app("Safari", "/Applications/Safari.app"),
            app("Terminal", "/System/Applications/Utilities/Terminal.app"),
            app("Disk Utility", "/Applications/Utilities/Disk Utility.app"),
            app("Calculator", "/System/Applications/Calculator.app"),
            app("Pages", "/Users/me/Applications/iWork/Pages.app"),
            app("Elsewhere", "/Volumes/X/Elsewhere.app"),
        ]
        let roots = ["/Applications", "/System/Applications", "/Users/me/Applications"]
        let tree = ProgramTree.build(apps, roots: roots)
        #expect(tree == [
            .app(apps[3]), .app(apps[5]), .app(apps[0]),
            .folder(name: "iWork", apps: [apps[4]]),
            .folder(name: "Utilities", apps: [apps[2], apps[1]]),
        ])
    }

    @Test func localizedFolderNamesDropTheirSuffix() {
        let a = app("Docs", "/Users/me/Applications/Chrome Apps.localized/Docs.app")
        #expect(ProgramTree.build([a], roots: ["/Users/me/Applications"]) == [.folder(name: "Chrome Apps", apps: [a])])
    }

    @Test func folderRowsExpandInlineIndented() {
        let a = app("A", "/Applications/A.app"), b = app("B", "/Applications/Utilities/B.app")
        let tree = ProgramTree.build([b, a], roots: ["/Applications"])
        #expect(ProgramTree.rows(tree, expanded: []) == [
            .init(kind: .app(a), depth: 0), .init(kind: .folder("Utilities", expanded: false), depth: 0),
        ])
        #expect(ProgramTree.rows(tree, expanded: ["Utilities"]) == [
            .init(kind: .app(a), depth: 0), .init(kind: .folder("Utilities", expanded: true), depth: 0),
            .init(kind: .app(b), depth: 1),
        ])
        var expanded: Set<String> = []
        ProgramTree.toggle("Utilities", in: &expanded)
        #expect(expanded == ["Utilities"])
        ProgramTree.toggle("Utilities", in: &expanded)
        #expect(expanded.isEmpty)
    }

    // MARK: Search grouping

    private func file(_ name: String, _ kind: FileHitKind) -> FileHit {
        FileHit(name: name, path: "/Users/me/\(name)", kind: kind, contentType: nil)
    }

    @Test func searchGroupsWithCountsAndCaps() {
        let programs = (0..<9).map { app("P\($0)", "/Applications/P\($0).app") }
        let files = [file("a.txt", .document), file("pic.png", .other), file("b.pdf", .document), file("Folder", .other)]
        let sections = StartMenuSearchResults.sections(programs: programs, files: files, limit: 3)
        #expect(sections.map(\.title) == ["Programs (9)", "Documents (2)", "Files (2)"])
        #expect(sections[0].items == programs.prefix(3).map { .program($0) })
        #expect(sections[1].items == [.file(files[0]), .file(files[2])])
        #expect(sections[2].items == [.file(files[1]), .file(files[3])])
    }

    @Test func emptyGroupsAreOmitted() {
        let s = StartMenuSearchResults.sections(programs: [], files: [file("a.txt", .document)], limit: 5)
        #expect(s.map(\.title) == ["Documents (1)"])
        #expect(StartMenuSearchResults.sections(programs: [], files: [], limit: 5).isEmpty)
    }

    @Test func fileKindFromContentTypes() {
        #expect(StartMenuSearchResults.kind(contentTypeTree: ["public.plain-text", "public.text", "public.data"]) == .document)
        #expect(StartMenuSearchResults.kind(contentTypeTree: ["public.png", "public.image", "public.data"]) == .other)
        #expect(StartMenuSearchResults.kind(contentTypeTree: ["public.folder", "public.directory"]) == .other)
        #expect(StartMenuSearchResults.kind(contentTypeTree: []) == .other)
    }

    @Test func packageDocumentsAreDocuments() {
        // Pages, Keynote, Numbers and RTFD documents are packages (directories) that are also content.
        let pages = ["com.apple.iwork.pages.sffpages", "public.composite-content", "public.content",
                     "com.apple.package", "public.directory", "public.item"]
        let rtfd = ["com.apple.rtfd", "public.rtf", "public.text", "public.content", "com.apple.package",
                    "public.directory", "public.item"]
        #expect(StartMenuSearchResults.kind(contentTypeTree: pages) == .document)
        #expect(StartMenuSearchResults.kind(contentTypeTree: rtfd) == .document)
        // A plain package (a bundle) and a library are not documents.
        #expect(StartMenuSearchResults.kind(contentTypeTree: ["com.apple.bundle", "com.apple.package", "public.directory"]) == .other)
        #expect(StartMenuSearchResults.kind(contentTypeTree: ["public.png", "public.image", "public.content"]) == .other)
        #expect(StartMenuSearchResults.isListable(path: "/Users/me/Documents/Report.pages", home: "/Users/me"))
    }

    @Test func fileResultsSkipPackagesHiddenAndLibrary() {
        let home = "/Users/me"
        func ok(_ p: String) -> Bool { StartMenuSearchResults.isListable(path: p, home: home) }
        #expect(ok("/Users/me/Documents/report.pdf"))
        #expect(ok("/Users/me/Projects"))
        #expect(!ok("/Users/me/Applications/X.app"))
        #expect(!ok("/Users/me/Applications/X.app/Contents/Info.plist"))
        #expect(!ok("/Users/me/Pictures/Photos Library.photoslibrary/database/x.db"))
        #expect(!ok("/Users/me/.config/notes.txt"))
        #expect(!ok("/Users/me/Library/Preferences/x.plist"))
        #expect(!ok("/tmp/elsewhere.txt"))
    }

    @Test func spotlightPredicateEscapesWildcards() {
        #expect(StartMenuSearchResults.likePattern("re*port?") == "*re\\*port\\?*")
    }

    // MARK: Run

    private let runApps = [app("Safari", "/Applications/Safari.app", "com.apple.Safari"),
                           app("TextEdit", "/System/Applications/TextEdit.app", "com.apple.TextEdit")]

    private func resolve(_ s: String, exists: Set<String> = []) -> RunTarget {
        RunResolver.resolve(s, apps: runApps, home: "/Users/me") { exists.contains($0) }
    }

    @Test func runResolvesAppNames() {
        #expect(resolve("textedit") == .app(runApps[1]))
        #expect(resolve(" Safari.app ") == .app(runApps[0]))
        #expect(resolve("com.apple.safari") == .app(runApps[0]))
    }

    @Test func runResolvesPaths() {
        #expect(resolve("~/Documents", exists: ["/Users/me/Documents"]) == .file("/Users/me/Documents"))
        #expect(resolve("~", exists: ["/Users/me"]) == .file("/Users/me"))
        #expect(resolve("/etc/hosts", exists: ["/etc/hosts"]) == .file("/etc/hosts"))
        #expect(resolve("/nope") == .notFound("/nope"))
        #expect(resolve("Downloads", exists: ["/Users/me/Downloads"]) == .file("/Users/me/Downloads"))
    }

    @Test func runResolvesURLs() {
        #expect(resolve("https://example.com/a") == .url(URL(string: "https://example.com/a")!))
        #expect(resolve("mailto:me@example.com") == .url(URL(string: "mailto:me@example.com")!))
        #expect(resolve("www.example.com") == .url(URL(string: "https://www.example.com")!))
    }

    @Test func runUnknownAndEmpty() {
        #expect(resolve("frobnicate") == .notFound("frobnicate"))
        #expect(resolve("   ") == .empty)
        #expect(RunResolver.notFoundMessage("frob")
                == "Win7Mac cannot find 'frob'. Make sure you typed the name correctly, and then try again.")
    }

    @Test func runHistoryIsMostRecentFirst() {
        var h = RunHistory()
        h.record("a"); h.record("b"); h.record(" a "); h.record("")
        #expect(h.entries == ["a", "b"])
        for i in 0..<40 { h.record("x\(i)") }
        #expect(h.entries.count == RunHistory.limit && h.entries.first == "x39")
    }

    // MARK: Power

    @Test func switchUserUsesCGSession() {
        #expect(PowerAction.cgSessionPath
                == "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession")
        #expect(PowerAction.switchUser.command == [PowerAction.cgSessionPath, "-suspend"])
    }

    // MARK: Keyboard focus

    private let counts = StartMenuFocus.Counts(programs: 3, places: 4, power: 2)

    @Test func arrowsMoveWithinAZoneAndWrap() {
        var f = StartMenuFocus()
        #expect(f.zone == nil)
        let moved1 = f.handle(.down, counts)
        #expect(moved1)
        #expect(f == StartMenuFocus(zone: .programs, index: 0))
        _ = f.handle(.down, counts); _ = f.handle(.down, counts)
        #expect(f.index == 2)
        _ = f.handle(.down, counts)
        #expect(f.index == 0)
        _ = f.handle(.up, counts)
        #expect(f == StartMenuFocus(zone: .programs, index: 2))
        var g = StartMenuFocus()
        _ = g.handle(.up, counts)
        #expect(g == StartMenuFocus(zone: .programs, index: 2))
    }

    @Test func rightAndLeftSwitchColumns() {
        var f = StartMenuFocus(zone: .programs, index: 1)
        let moved2 = f.handle(.right, counts)
        #expect(moved2)
        #expect(f == StartMenuFocus(zone: .places, index: 0))
        _ = f.handle(.down, counts)
        let moved3 = f.handle(.left, counts)
        #expect(moved3)
        #expect(f == StartMenuFocus(zone: .programs, index: 0))
        // Nothing focused: Left stays in the search box, Right goes to the right column.
        var g = StartMenuFocus()
        let moved4 = g.handle(.left, counts)
        #expect(!moved4)
        let movedR = g.handle(.right, counts)
        #expect(movedR && g.zone == .places)
        var p = StartMenuFocus(zone: .power, index: 0)
        _ = p.handle(.right, counts)
        #expect(p == StartMenuFocus(zone: .power, index: 1))
        _ = p.handle(.left, counts); _ = p.handle(.left, counts)
        #expect(p == StartMenuFocus(zone: .places, index: 0))
    }

    @Test func tabCyclesProgramsPlacesPower() {
        var f = StartMenuFocus()
        _ = f.handle(.tab, counts)
        #expect(f.zone == .programs)
        _ = f.handle(.tab, counts)
        #expect(f.zone == .places)
        _ = f.handle(.tab, counts)
        #expect(f == StartMenuFocus(zone: .power, index: 0))
        _ = f.handle(.tab, counts)
        #expect(f.zone == .programs)
        _ = f.handle(.backTab, counts)
        #expect(f.zone == .power)
    }

    @Test func emptyZonesAreSkippedAndIndexClamped() {
        let noPrograms = StartMenuFocus.Counts(programs: 0, places: 4, power: 2)
        var f = StartMenuFocus()
        _ = f.handle(.down, noPrograms)
        #expect(f.zone == .places)
        var g = StartMenuFocus(zone: .places, index: 3)
        _ = g.handle(.tab, noPrograms)
        _ = g.handle(.tab, noPrograms)
        #expect(g.zone == .places)
        var h = StartMenuFocus(zone: .programs, index: 7)
        h.clamp(counts)
        #expect(h == StartMenuFocus(zone: .programs, index: 2))
        h.clamp(noPrograms)
        #expect(h.zone == nil)
    }
}
