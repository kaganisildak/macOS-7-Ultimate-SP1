import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Win7Core

@Suite struct DesktopLayoutTests {
    private let layout = DesktopLayout(bounds: CGSize(width: 1440, height: 860), size: .medium)

    @Test func iconSizes() {
        #expect(DesktopIconSize.large.iconSide == 96 && DesktopIconSize.large.cell == CGSize(width: 120, height: 128))
        #expect(DesktopIconSize.medium.iconSide == 48 && DesktopIconSize.medium.cell == CGSize(width: 76, height: 86))
        #expect(DesktopIconSize.small.iconSide == 32 && DesktopIconSize.small.cell == CGSize(width: 68, height: 70))
    }

    @Test func gridMetrics() {
        #expect(layout.rows == 9)
        #expect(layout.origin(col: 1, row: 2) == CGPoint(x: 86, y: 182))
        let c = layout.cell(at: CGPoint(x: 100, y: 200))
        #expect(c.col == 1 && c.row == 2)
        let clamped = layout.cell(at: CGPoint(x: -50, y: -50))
        #expect(clamped.col == 0 && clamped.row == 0)
        let bottom = layout.cell(at: CGPoint(x: 20, y: 5000))
        #expect(bottom.row == layout.rows - 1)
        #expect(layout.columns == 18)
        let right = layout.cell(at: CGPoint(x: 100_000, y: 20))
        #expect(right.col == layout.columns - 1 && right.row == 0)
        #expect(DesktopLayout(bounds: CGSize(width: 100, height: 50), size: .large).rows == 1)
    }

    @Test func firstFreeCellIsColumnMajor() {
        let a = layout.firstFreeCell(occupied: [[0, 0], [0, 1]])
        #expect(a.col == 0 && a.row == 2)
        let fullColumn = Set((0..<layout.rows).map { [0, $0] })
        let b = layout.firstFreeCell(occupied: fullColumn)
        #expect(b.col == 1 && b.row == 0)
        let from = layout.firstFreeCell(occupied: [[2, 3]], from: (col: 2, row: 3))
        #expect(from.col == 2 && from.row == 4)
        // From the last cells of the grid the search wraps to the top-left.
        let wrap = layout.firstFreeCell(occupied: [[17, 7], [17, 8]], from: (col: 17, row: 7))
        #expect(wrap.col == 0 && wrap.row == 0)
    }

    @Test func rubberBandUsesCellRects() {
        let positions = ["a": [0, 0], "b": [0, 1], "c": [1, 0]]
        #expect(layout.itemsIntersecting(CGRect(x: 0, y: 0, width: 80, height: 100), positions: positions) == ["a", "b"])
        #expect(layout.itemsIntersecting(CGRect(x: 500, y: 500, width: 10, height: 10), positions: positions).isEmpty)
    }

    @Test func arrangeKeepsStoredFillsNewAndPrunes() {
        let stored = ["b": [3, 3], "gone": [0, 0], "dup": [3, 3], "off": [0, 99]]
        let r = layout.arrange(["bin", "b", "new", "dup", "off"], stored: stored, autoArrange: false)
        #expect(r.display["b"] == [3, 3])
        #expect(r.display["bin"] == [0, 0])
        #expect(r.display["new"] == [0, 1])
        #expect(r.display["dup"] == [0, 2])        // its stored cell is taken by "b"
        #expect(r.display["off"] == [0, 3])        // stored row is off-screen
        #expect(r.display["gone"] == nil)
        // Stored: vanished pruned, newly placed recorded, an off-screen manual position kept.
        #expect(r.stored == ["b": [3, 3], "bin": [0, 0], "new": [0, 1], "dup": [0, 2], "off": [0, 99]])
    }

    @Test func autoArrangeIgnoresStored() {
        let small = DesktopLayout(bounds: CGSize(width: 1440, height: 20 + 86 * 2), size: .medium)
        let r = small.arrange(["a", "b", "c"], stored: ["a": [5, 1], "zap": [1, 1]], autoArrange: true)
        #expect(r.display == ["a": [0, 0], "b": [0, 1], "c": [1, 0]])
        #expect(r.stored == ["a": [5, 1]])
    }

    @Test func moveSnapsByDeltaAndAvoidsCollisions() {
        let positions = ["a": [0, 0], "b": [0, 1], "c": [2, 0]]
        let r = layout.move(["a", "b"], primary: "a", to: (col: 2, row: 0), positions: positions)
        #expect(r["c"] == [2, 0])
        #expect(r["b"] == [2, 1])
        #expect(r["a"] == [2, 2])                  // target held by "c" → next free cell after it
        let down = layout.move(["a"], primary: "a", to: (col: 0, row: 50), positions: positions)
        #expect(down["a"] == [0, layout.rows - 1])
        // A drop past the right edge lands in the last column, trailing items included.
        let right = layout.move(["a", "c"], primary: "a", to: (col: 40, row: 0), positions: positions)
        #expect(right["a"] == [layout.columns - 1, 0])
        #expect(right["c"] == [layout.columns - 1, 1])   // wanted [19, 0], clamped and then bumped
        #expect(right.values.allSatisfy(layout.isOnGrid))
    }

    @Test func arrowNavigationPicksNearestInDirection() {
        let positions = ["a": [0, 0], "b": [0, 1], "c": [1, 0], "d": [2, 3]]
        #expect(DesktopLayout.neighbor(of: "a", .down, positions: positions) == "b")
        #expect(DesktopLayout.neighbor(of: "a", .right, positions: positions) == "c")
        #expect(DesktopLayout.neighbor(of: "c", .right, positions: positions) == "d")
        #expect(DesktopLayout.neighbor(of: "a", .up, positions: positions) == nil)
        #expect(DesktopLayout.neighbor(of: "b", .left, positions: positions) == nil)
        #expect(DesktopLayout.layoutOrder(positions) == ["a", "b", "c", "d"])
    }

    @Test func desktopWindowLevelSitsBelowShellWindows() {
        let desktop = Int(CGWindowLevelForKey(.desktopIconWindow))
        #expect(desktop < NSWindow.Level.normal.rawValue)
        #expect(desktop < ShellWindowLevels.taskbar(legacy: false))   // taskbar
        #expect(desktop < NSWindow.Level.popUpMenu.rawValue)   // Start menu
    }
}

@Suite struct DesktopOrderingTests {
    private func e(_ name: String, size: Int64 = 0, type: String = "", modified: TimeInterval = 0) -> DesktopEntry {
        DesktopEntry(name: name, size: size, type: type, modified: Date(timeIntervalSince1970: modified))
    }

    @Test func byNameIsFinderStyle() {
        let r = DesktopOrdering.sorted([e("file10"), e("File2"), e("alpha")], by: .name)
        #expect(r.map(\.name) == ["alpha", "File2", "file10"])
    }

    @Test func bySizeDescendingWithNameTies() {
        let r = DesktopOrdering.sorted([e("b", size: 5), e("c", size: 9), e("a", size: 5)], by: .size)
        #expect(r.map(\.name) == ["c", "a", "b"])
    }

    @Test func byDateDescendingWithNameTies() {
        let r = DesktopOrdering.sorted([e("b", modified: 1), e("z", modified: 1), e("a", modified: 7)], by: .dateModified)
        #expect(r.map(\.name) == ["a", "b", "z"])
    }

    @Test func byTypeThenName() {
        let r = DesktopOrdering.sorted([e("b", type: "Text"), e("a", type: "Text"), e("c", type: "Folder")], by: .type)
        #expect(r.map(\.name) == ["c", "a", "b"])
    }
}

@Suite struct DesktopSelectionTests {
    @Test func clickCommandShiftSequence() {
        let order = ["a", "b", "c", "d", "e"]
        var s = DesktopSelection()
        s.click("a", order: order)
        #expect(s.selected == ["a"])
        s.commandClick("c")
        #expect(s.selected == ["a", "c"])
        s.anchor = "a"
        s.shiftClick("e", order: order)
        #expect(s.selected == ["a", "b", "c", "d", "e"])
        s.click("b", order: order)
        #expect(s.selected == ["b"])
        #expect(s.anchor == "b")
    }

    @Test func commandClickTogglesOff() {
        var s = DesktopSelection()
        s.click("a", order: ["a"])
        s.commandClick("a")
        #expect(s.selected.isEmpty)
    }

    @Test func shiftClickWithoutAnchorActsAsClick() {
        var s = DesktopSelection()
        s.shiftClick("c", order: ["a", "b", "c"])
        #expect(s.selected == ["c"] && s.anchor == "c")
    }

    @Test func shiftClickBackwardsAndClearAndSet() {
        var s = DesktopSelection()
        s.click("d", order: ["a", "b", "c", "d"])
        s.shiftClick("b", order: ["a", "b", "c", "d"])
        #expect(s.selected == ["b", "c", "d"] && s.anchor == "d")
        s.clear()
        #expect(s.selected.isEmpty && s.anchor == nil)
        s.set(["x", "y"])
        #expect(s.selected == ["x", "y"])
    }

    @Test func retainDropsVanishedIDs() {
        var s = DesktopSelection()
        s.set(["a", "b"]); s.anchor = "b"
        s.retain(["a"])
        #expect(s.selected == ["a"] && s.anchor == nil)
    }
}

@Suite struct DesktopMenuModelTests {
    @Test func itemMenus() {
        #expect(DesktopMenuModel.titles(for: .items(count: 1))
                == ["Open", "Open with ▸", "—", "Send to ▸", "—", "Cut", "Copy", "—",
                    "Create shortcut", "Delete", "Rename", "—", "Properties"])
        // Several items: no Open with, no Rename.
        #expect(DesktopMenuModel.titles(for: .items(count: 3))
                == ["Open", "—", "Send to ▸", "—", "Cut", "Copy", "—", "Create shortcut", "Delete", "—", "Properties"])
        #expect(DesktopMenuModel.titles(for: .recycleBin) == ["Open", "—", "Empty Recycle Bin", "—", "Properties"])
    }

    @Test func emptySpaceMenuWithDisabledPaste() {
        let ctx = DesktopMenuContext.empty(canPaste: false)
        #expect(DesktopMenuModel.titles(for: ctx)
                == ["View ▸", "Sort by ▸", "Refresh", "—", "Paste", "Paste shortcut", "—", "New ▸", "—",
                    "Screen resolution", "Gadgets", "Personalize"])
        #expect(!DesktopMenuModel.isEnabled(title: "Paste", context: ctx))
        #expect(!DesktopMenuModel.isEnabled(title: "Paste shortcut", context: ctx))
        #expect(DesktopMenuModel.isEnabled(title: "Paste", context: .empty(canPaste: true)))
        #expect(DesktopMenuModel.isEnabled(title: "Paste shortcut", context: .empty(canPaste: true)))
        #expect(DesktopMenuModel.isEnabled(title: "Refresh", context: ctx))
        #expect(DesktopMenuModel.isEnabled(title: "Gadgets", context: ctx))
    }

    /// Undo shows only with something to undo, labelled with what it undoes ("Undo Rename").
    @Test func undoItem() {
        let ctx = DesktopMenuContext.empty(canPaste: true, undo: "Undo Rename")
        #expect(DesktopMenuModel.titles(for: ctx)
                == ["View ▸", "Sort by ▸", "Refresh", "—", "Paste", "Paste shortcut", "Undo", "—", "New ▸", "—",
                    "Screen resolution", "Gadgets", "Personalize"])
        #expect(DesktopMenuModel.displayTitle("Undo", context: ctx) == "Undo Rename")
        #expect(DesktopMenuModel.displayTitle("Paste", context: ctx) == "Paste")
        #expect(DesktopMenuModel.isEnabled(title: "Undo", context: ctx))
    }

    @Test func submenus() {
        #expect(DesktopMenuModel.viewTitles == ["Large icons", "Medium icons", "Small icons", "—",
                                                "Auto arrange icons", "Align icons to grid", "—", "Show desktop icons"])
        #expect(DesktopMenuModel.sortTitles == ["Name", "Size", "Item type", "Date modified"])
        #expect(DesktopMenuModel.newTitles == ["Folder", "Shortcut…", "—", "Text Document", "Rich Text Document"])
        #expect(DesktopMenuModel.newDisabled == ["Shortcut…"])
        #expect(DesktopMenuModel.sendToTitles == ["Compressed (zipped) folder", "Desktop (create shortcut)", "Mail recipient"])
        #expect(DesktopMenuModel.openWithLimit == 8)
        #expect(DesktopMenuModel.chooseDefaultProgram == "Choose default program…")
    }

    @Test func deleteConfirmationTexts() {
        let file = DesktopMenuModel.deleteConfirmation(count: 1, isFolder: false)
        #expect(file.title == "Delete File")
        #expect(file.message == "Are you sure you want to move this file to the Recycle Bin?")
        let folder = DesktopMenuModel.deleteConfirmation(count: 1, isFolder: true)
        #expect(folder.title == "Delete Folder")
        #expect(folder.message == "Are you sure you want to move this folder to the Recycle Bin?")
        let many = DesktopMenuModel.deleteConfirmation(count: 4, isFolder: false)
        #expect(many.title == "Delete Multiple Items")
        #expect(many.message == "Are you sure you want to move these 4 items to the Recycle Bin?")
    }
}

@Suite struct FileNamingTests {
    @Test func uniqueNames() {
        #expect(FileNaming.unique("New folder", ext: nil, existing: ["New folder"]) == "New folder (2)")
        #expect(FileNaming.unique("New Text Document", ext: "txt",
                                  existing: ["New Text Document.txt", "New Text Document (2).txt"]) == "New Text Document (3).txt")
        #expect(FileNaming.unique("New folder", ext: nil, existing: []) == "New folder")
        #expect(FileNaming.unique("a", ext: "", existing: ["a"]) == "a (2)")
        #expect(FileNaming.unique("New folder", ext: nil, existing: ["new FOLDER"]) == "New folder (2)")  // case-insensitive volume
    }

    @Test func renameSelectionSkipsExtension() {
        #expect(FileNaming.baseLength(of: "report.final.txt", keepExtension: true) == 12)
        #expect(FileNaming.baseLength(of: "New folder", keepExtension: true) == 10)
        #expect(FileNaming.baseLength(of: "a.b", keepExtension: false) == 3)
        #expect(FileNaming.baseLength(of: ".profile", keepExtension: true) == 8)
    }

    /// Windows 7 names a shortcut "<name> - Shortcut", then "<name> - Shortcut (2)" and so on.
    @Test func shortcutNames() {
        #expect(FileNaming.shortcutName(for: "x", existing: []) == "x - Shortcut")
        #expect(FileNaming.shortcutName(for: "report.txt", existing: ["report.txt"]) == "report.txt - Shortcut")
        #expect(FileNaming.shortcutName(for: "x", existing: ["x - Shortcut"]) == "x - Shortcut (2)")
        #expect(FileNaming.shortcutName(for: "x", existing: ["X - SHORTCUT", "x - Shortcut (2)"]) == "x - Shortcut (3)")
    }

    /// A zipped folder takes the item's name without its extension.
    @Test func archiveNames() {
        #expect(FileNaming.archiveName(for: "report.txt", isDirectory: false, existing: []) == "report.zip")
        #expect(FileNaming.archiveName(for: "My.Folder", isDirectory: true, existing: []) == "My.Folder.zip")
        #expect(FileNaming.archiveName(for: "a.txt", isDirectory: false, existing: ["a.zip"]) == "a (2).zip")
    }
}

@Suite struct DesktopDropPolicyTests {
    @Test func decisions() {
        #expect(DesktopDropPolicy.action(fromDesktop: false, sameVolume: true, optionHeld: false, ontoRecycleBin: false) == .move)
        #expect(DesktopDropPolicy.action(fromDesktop: false, sameVolume: false, optionHeld: false, ontoRecycleBin: false) == .copy)
        #expect(DesktopDropPolicy.action(fromDesktop: false, sameVolume: true, optionHeld: true, ontoRecycleBin: false) == .copy)
        #expect(DesktopDropPolicy.action(fromDesktop: true, sameVolume: true, optionHeld: false, ontoRecycleBin: false) == .reposition)
        #expect(DesktopDropPolicy.action(fromDesktop: true, sameVolume: true, optionHeld: true, ontoRecycleBin: true) == .trash)
        #expect(DesktopDropPolicy.action(fromDesktop: false, sameVolume: false, optionHeld: false, ontoRecycleBin: true) == .trash)
    }
}

/// File operations against a throwaway directory (never ~/Desktop).
@Suite struct DesktopFilesTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("w7desk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func scanSkipsHiddenAndReadsMetadata() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("hello".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data().write(to: dir.appendingPathComponent(".DS_Store"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Folder"), withIntermediateDirectories: false)
        let entries = try DesktopFiles(directory: dir).scan()
        #expect(Set(entries.map(\.name)) == ["a.txt", "Folder"])
        #expect(entries.first { $0.name == "a.txt" }?.size == 5)
        #expect(entries.first { $0.name == "Folder" }?.size == 0)
    }

    @Test func newItemsGetWindowsNamesAndCollisionSuffixes() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let files = DesktopFiles(directory: dir)
        #expect(try files.createFolder() == "New folder")
        #expect(try files.createFolder() == "New folder (2)")
        #expect(try files.createTextDocument() == "New Text Document.txt")
        #expect(try files.createTextDocument() == "New Text Document (2).txt")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("New folder (2)").path, isDirectory: &isDir) && isDir.boolValue)
        #expect(try Data(contentsOf: dir.appendingPathComponent("New Text Document.txt")).isEmpty)
    }

    @Test func renameValidatesAndHandlesCaseOnlyChanges() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let files = DesktopFiles(directory: dir)
        try Data().write(to: dir.appendingPathComponent("a.txt"))
        try Data().write(to: dir.appendingPathComponent("b.txt"))
        #expect(try files.rename("a.txt", to: "  c.txt ") == "c.txt")
        #expect(throws: DesktopFileError.nameExists("b.txt")) { try files.rename("c.txt", to: "b.txt") }
        #expect(throws: DesktopFileError.invalidName) { try files.rename("c.txt", to: "x/y") }
        #expect(throws: DesktopFileError.invalidName) { try files.rename("c.txt", to: "   ") }
        #expect(throws: DesktopFileError.invalidName) { try files.rename("c.txt", to: "a:b") }
        #expect(try files.rename("c.txt", to: "c.txt") == "c.txt")
        #expect(try files.rename("c.txt", to: "C.txt") == "C.txt")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["C.txt", "b.txt"])
    }

    @Test func transferMovesOrCopiesWithUniqueNames() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try tempDir(); defer { try? FileManager.default.removeItem(at: src) }
        let files = DesktopFiles(directory: dir)
        try Data("1".utf8).write(to: dir.appendingPathComponent("x.txt"))
        try Data("2".utf8).write(to: src.appendingPathComponent("x.txt"))
        try Data("3".utf8).write(to: src.appendingPathComponent("y.txt"))
        let moved = files.transfer([src.appendingPathComponent("x.txt")], copy: false)
        #expect(moved.names == ["x (2).txt"] && moved.error == nil)
        #expect(!FileManager.default.fileExists(atPath: src.appendingPathComponent("x.txt").path))
        let copied = files.transfer([src.appendingPathComponent("y.txt")], copy: true)
        #expect(copied.names == ["y.txt"])
        #expect(FileManager.default.fileExists(atPath: src.appendingPathComponent("y.txt").path))
        // Already in the directory: a move leaves it alone, a copy duplicates it.
        #expect(files.transfer([dir.appendingPathComponent("x.txt")], copy: false).names == ["x.txt"])
        #expect(files.transfer([dir.appendingPathComponent("x.txt")], copy: true).names == ["x (3).txt"])
        // Moves and copies in one sequential batch.
        try Data().write(to: src.appendingPathComponent("z.txt"))
        let mixed = files.transfer([DesktopTransfer(url: src.appendingPathComponent("z.txt"), copy: false),
                                    DesktopTransfer(url: src.appendingPathComponent("y.txt"), copy: true)])
        #expect(mixed.names == ["z.txt", "y (2).txt"] && mixed.error == nil)
        #expect(files.contains(dir.appendingPathComponent("x.txt")))
        #expect(!files.contains(src.appendingPathComponent("y.txt")))
        #expect(DesktopFiles.sameVolume(src, dir))
    }

    /// Copying the desktop folder, or a folder containing it, into itself would recurse until the path
    /// gets too long. Such sources are refused; the rest of the batch still goes through.
    @Test func refusesDesktopAndItsAncestors() throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let desk = root.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: desk, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: desk)
        try Data("ok".utf8).write(to: root.appendingPathComponent("ok.txt"))
        let files = DesktopFiles(directory: desk)
        let refused = [desk, root, link, desk.appendingPathComponent("..")]
        for url in refused {
            for copy in [true, false] {
                let r = files.transfer([url], copy: copy)
                #expect(r.names.isEmpty)
                #expect(r.error as? DesktopFileError == .containsDesktop(url.standardizedFileURL.lastPathComponent))
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: desk.path).isEmpty)
        let partial = files.transfer([DesktopTransfer(url: root, copy: true),
                                      DesktopTransfer(url: root.appendingPathComponent("ok.txt"), copy: true)])
        #expect(partial.names == ["ok.txt"])
        #expect(partial.error as? DesktopFileError == .containsDesktop(root.lastPathComponent))
        #expect(try FileManager.default.contentsOfDirectory(atPath: desk.path) == ["ok.txt"])
    }
}
