import Foundation
import Testing
@testable import Win7Core

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("w7desk30-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

/// shortcuts, Rich Text documents, moving into folders and undo, against a throwaway folder.
@Suite struct DesktopFilesTask30Tests {
    @Test func shortcutIsAFinderAliasNamedWindowsStyle() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let files = DesktopFiles(directory: dir)
        let target = dir.appendingPathComponent("report.txt")
        try Data("hi".utf8).write(to: target)
        #expect(try files.createShortcut(to: target) == "report.txt - Shortcut")
        #expect(try files.createShortcut(to: target) == "report.txt - Shortcut (2)")
        let alias = dir.appendingPathComponent("report.txt - Shortcut")
        #expect(try alias.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true)
        #expect(try URL(resolvingAliasFileAt: alias).resolvingSymlinksInPath().path == target.path)
    }

    @Test func richTextDocument() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let files = DesktopFiles(directory: dir)
        #expect(try files.createRichTextDocument() == "New Rich Text Document.rtf")
        #expect(try files.createRichTextDocument() == "New Rich Text Document (2).rtf")
        let text = try String(contentsOf: dir.appendingPathComponent("New Rich Text Document.rtf"), encoding: .utf8)
        #expect(text.hasPrefix("{\\rtf1"))
    }

    @Test func moveIntoFolderAndUndo() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let files = DesktopFiles(directory: dir)
        let folder = dir.appendingPathComponent("Box")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data().write(to: folder.appendingPathComponent("a.txt"))
        try Data("a".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data().write(to: dir.appendingPathComponent("b.txt"))
        // The folder itself is skipped; a collision inside the folder gets a "(2)" name.
        let r = files.moveIntoFolder(["a.txt", "b.txt", "Box"], folder: "Box")
        #expect(r.error == nil)
        #expect(r.moves == [FileMove(from: dir.appendingPathComponent("a.txt"), to: folder.appendingPathComponent("a (2).txt")),
                            FileMove(from: dir.appendingPathComponent("b.txt"), to: folder.appendingPathComponent("b.txt"))])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["Box"])
        let back = try files.undo(.move(r.moves))
        #expect(back.sorted() == ["a.txt", "b.txt"])
        #expect(try Data(contentsOf: dir.appendingPathComponent("a.txt")) == Data("a".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["a.txt"])
    }

    @Test func undoRename() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let files = DesktopFiles(directory: dir)
        try Data().write(to: dir.appendingPathComponent("old.txt"))
        let new = try files.rename("old.txt", to: "new.txt")
        #expect(try files.undo(.rename(from: "old.txt", to: new)) == ["old.txt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["old.txt"])
    }
}

@Suite struct DesktopUndoStackTests {
    @Test func lastInFirstOutWithLabels() {
        var s = DesktopUndoStack(limit: 2)
        #expect(s.label == nil)
        do { let r = s.pop(); #expect(r == nil) }
        s.push(.rename(from: "a", to: "b"))
        #expect(s.label == "Undo Rename")
        let m = FileMove(from: URL(fileURLWithPath: "/d/x"), to: URL(fileURLWithPath: "/d/f/x"))
        s.push(.move([m]))
        #expect(s.label == "Undo Move")
        s.push(.rename(from: "c", to: "d"))   // over the limit: the oldest goes
        do { let r = s.pop(); #expect(r == .rename(from: "c", to: "d")) }
        do { let r = s.pop(); #expect(r == .move([m])) }
        do { let r = s.pop(); #expect(r == nil) }
        s.push(.move([]))                       // nothing moved: not recorded
        #expect(s.label == nil)
    }
}

/// When the desktop draws the Windows 7 folder art instead of the file's own icon.
@Suite struct DesktopFolderArtTests {
    private let home = "/Users/u"
    private func traits(_ path: String, dir: Bool = true, package: Bool = false, symlink: Bool = false,
                        alias: Bool = false, custom: Bool = false) -> DesktopItemTraits {
        DesktopItemTraits(path: path, isDirectory: dir, isPackage: package, isSymlink: symlink, isAlias: alias, hasCustomIcon: custom)
    }

    @Test func decisions() {
        #expect(DesktopFolderArt.art(for: traits("/Users/u/Desktop/adsız klasör"), home: home) == .plain)
        #expect(DesktopFolderArt.art(for: traits("/Users/u/Documents"), home: home) == .documents)
        #expect(DesktopFolderArt.art(for: traits("/Users/u/Pictures/"), home: home) == .pictures)
        #expect(DesktopFolderArt.art(for: traits("/Users/u/Music"), home: home) == .music)
        #expect(DesktopFolderArt.art(for: traits("/Users/u/Movies"), home: home) == .videos)
        #expect(DesktopFolderArt.art(for: traits("/Users/u/Downloads"), home: home) == .downloads)
        #expect(DesktopFolderArt.art(for: traits("/Users/u/Desktop"), home: home) == .desktop)
        #expect(DesktopFolderArt.art(for: traits("/Users/u"), home: home) == .user)
        // Files, packages, apps, custom icons, symlinks and aliases keep their own icon.
        #expect(DesktopFolderArt.art(for: traits("/Users/u/Desktop/a.txt", dir: false), home: home) == nil)
        #expect(DesktopFolderArt.art(for: traits("/Users/u/Desktop/X.app", package: true), home: home) == nil)
        #expect(DesktopFolderArt.art(for: traits("/Users/u/Desktop/X.app"), home: home) == nil)
        #expect(DesktopFolderArt.art(for: traits("/Users/u/Desktop/f", custom: true), home: home) == nil)
        #expect(DesktopFolderArt.art(for: traits("/Users/u/Desktop/l", symlink: true), home: home) == nil)
        #expect(DesktopFolderArt.art(for: traits("/Users/u/Desktop/a", alias: true), home: home) == nil)
    }

    /// kHasCustomIcon is bit 0x0400 of the big-endian Finder flags at bytes 8-9 of FinderInfo.
    @Test func customIconFlag() {
        var info = Data(count: 32)
        #expect(!DesktopFolderArt.hasCustomIcon(finderInfo: info))
        info[8] = 0x04
        #expect(DesktopFolderArt.hasCustomIcon(finderInfo: info))
        #expect(!DesktopFolderArt.hasCustomIcon(finderInfo: nil))
        #expect(!DesktopFolderArt.hasCustomIcon(finderInfo: Data([0, 1])))
    }

    @Test func traitsFromDisk() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("F")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let link = dir.appendingPathComponent("L")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let file = dir.appendingPathComponent("t.txt")
        try Data().write(to: file)
        let f = DesktopFolderArt.traits(of: folder)
        #expect(f.isDirectory && !f.isPackage && !f.isSymlink && !f.isAlias && !f.hasCustomIcon)
        #expect(DesktopFolderArt.traits(of: link).isSymlink)
        #expect(!DesktopFolderArt.traits(of: file).isDirectory)
        var info = [UInt8](repeating: 0, count: 32)
        info[8] = 0x04
        #expect(setxattr(folder.path, "com.apple.FinderInfo", info, 32, 0, 0) == 0)
        #expect(DesktopFolderArt.traits(of: folder).hasCustomIcon)
    }
}
