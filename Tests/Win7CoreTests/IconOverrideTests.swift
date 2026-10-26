import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Win7Core

// the user's icon packs (imageres-#N.ico, and named .ico files). Pure mapping logic only; the import
// script has its own sandboxed test in scripts/test_install.sh.

@Suite struct IconMapParseTests {
    @Test func parsesIdsAndNamesSkippingCommentsAndBlankLines() throws {
        let text = """
        # imageres.dll ICON group id -> Assets/icons/<name>
        3   folder.png
           2 file.png   # trailing comment

        27\tcontrol-panel.png
        """
        let map = try IconOverrideNames.parseMap(text)
        #expect(map.ids == [IconKey(dll: "imageres", id: 3): "folder.png", IconKey(dll: "imageres", id: 2): "file.png",
                            IconKey(dll: "imageres", id: 27): "control-panel.png"])
        #expect(map.files.isEmpty)
    }

    @Test func parsesFileNameEntriesCaseInsensitively() throws {
        let map = try IconOverrideNames.parseMap("""
        explorer.ico   app-com.apple.finder.png
        TaskMgr.ICO    app-com.apple.ActivityMonitor.png
        trashbin1.ico  recycle-bin-empty.png
        55             recycle-bin-empty.png
        """)
        #expect(map.files == ["explorer.ico": "app-com.apple.finder.png", "taskmgr.ico": "app-com.apple.ActivityMonitor.png",
                              "trashbin1.ico": "recycle-bin-empty.png"])
        #expect(map.ids == [IconKey(dll: "imageres", id: 55): "recycle-bin-empty.png"])
    }

    @Test func looksUpFileNamesFirstThenImageresIds() throws {
        let map = try IconOverrideNames.parseMap(
            "explorer.ico app-com.apple.finder.png\nimageres-#3.ico special.png\n3 folder.png\n2 file.png")
        #expect(map.lookup(fileName: "Explorer.ico") == IconMapHit(key: "explorer", target: "app-com.apple.finder.png"))
        #expect(map.lookup(fileName: "pack/explorer.ico") == IconMapHit(key: "explorer", target: "app-com.apple.finder.png"))
        #expect(map.lookup(fileName: "imageres-#3.ico") == IconMapHit(key: "imageres-#3", target: "special.png"))
        #expect(map.lookup(fileName: "imageres-3.ico") == IconMapHit(key: "imageres-3", target: "folder.png"))
        #expect(map.lookup(fileName: "imageres-#2.ico") == IconMapHit(key: "imageres-2", target: "file.png"))
        // An imageres id not in the map: a key, but no target (it goes to the contact sheet).
        #expect(map.lookup(fileName: "imageres-#5.ico") == IconMapHit(key: "imageres-5", target: nil))
        // Neither listed by name nor an imageres export.
        #expect(map.lookup(fileName: "photoshop1.ico") == nil)
        #expect(map.lookup(fileName: "readme.txt") == nil)
    }

    @Test func parsesDllPrefixedIds() throws {
        let map = try IconOverrideNames.parseMap("shell32:24 help.png\n3 folder.png\nUSER32:103 msgbox-error.png")
        #expect(map.ids == [IconKey(dll: "shell32", id: 24): "help.png", IconKey(dll: "imageres", id: 3): "folder.png",
                            IconKey(dll: "user32", id: 103): "msgbox-error.png"])
        #expect(IconOverrideNames.iconKey(fileName: "Shell32-#24.ico") == IconKey(dll: "shell32", id: 24))
        #expect(IconOverrideNames.iconKey(fileName: "#3.ico") == IconKey(dll: "imageres", id: 3))
        #expect(map.lookup(fileName: "user32-103.ico") == IconMapHit(key: "user32-103", target: "msgbox-error.png"))
        #expect(throws: IconMapError.self) { try IconOverrideNames.parseMap("shell32:0 x.png") }
    }

    @Test func dllPrefixedIdsAreStrict() throws {
        // `imageres:3` and a bare `3` are the same key.
        #expect(throws: IconMapError.duplicate("3", line: 2)) { try IconOverrideNames.parseMap("3 a.png\nimageres:3 b.png") }
        #expect(throws: IconMapError.duplicate("shell32:24", line: 2)) {
            try IconOverrideNames.parseMap("shell32:24 a.png\nShell32:24 b.png")
        }
        for bad in [":3", "shell32:", "shell32:x", "shell32:-3", "shell_32:3", "../x:3", "shell32:3:4", "shell32:1234567"] {
            #expect(throws: IconMapError.self, "\(bad)") { try IconOverrideNames.parseMap("\(bad) x.png") }
        }
        let map = try IconOverrideNames.parseMap("shell32:24 help.png")
        #expect(map.lookup(fileName: "pack/SHELL32-24.ICO") == IconMapHit(key: "shell32-24", target: "help.png"))
        // Ids the map doesn't list go to the contact sheet, whatever the DLL; a name without an id is skipped.
        #expect(map.lookup(fileName: "imageres-#25.ico") == IconMapHit(key: "imageres-25", target: nil))
        #expect(map.lookup(fileName: "shell32-#25.ico") == IconMapHit(key: "shell32-25", target: nil))
        #expect(map.lookup(fileName: "unknown-#5.ico") == IconMapHit(key: "unknown-5", target: nil))
        #expect(map.lookup(fileName: "unknown.dll-#5.ico") == nil)
        #expect(map.lookup(fileName: "photoshop1.ico") == nil)
    }

    @Test func rejectsMalformedLinesWithTheirLineNumber() {
        #expect(throws: IconMapError.badLine(2, "3")) { try IconOverrideNames.parseMap("2 file.png\n3\n") }
        #expect(throws: IconMapError.badLine(1, "x folder.png")) { try IconOverrideNames.parseMap("x folder.png") }
        #expect(throws: IconMapError.badLine(1, "3 folder.png extra")) { try IconOverrideNames.parseMap("3 folder.png extra") }
        #expect(throws: IconMapError.badLine(1, "-3 folder.png")) { try IconOverrideNames.parseMap("-3 folder.png") }
        #expect(throws: IconMapError.badLine(1, "../x.ico folder.png")) { try IconOverrideNames.parseMap("../x.ico folder.png") }
        #expect(throws: IconMapError.badLine(1, ".ico folder.png")) { try IconOverrideNames.parseMap(".ico folder.png") }
    }

    @Test func rejectsNamesThatCouldLeaveIconsFolder() {
        for bad in ["../folder.png", "sub/folder.png", "folder.ico", ".png", ".hidden.png", "a b.png", "-x.png", "a\\b.png"] {
            #expect(throws: IconMapError.self) { try IconOverrideNames.parseMap("3 \(bad)") }
        }
        // Bundle ids keep their case and dots.
        #expect((try? IconOverrideNames.parseMap("3 app-com.apple.ActivityMonitor.png")) != nil)
    }

    @Test func rejectsDuplicateKeys() {
        #expect(throws: IconMapError.duplicate("3", line: 2)) {
            try IconOverrideNames.parseMap("3 folder.png\n3 file.png")
        }
        #expect(throws: IconMapError.duplicate("explorer.ico", line: 3)) {
            try IconOverrideNames.parseMap("explorer.ico a.png\n\nEXPLORER.ico b.png")
        }
    }

    @Test func theShippedMapParsesWithTheBriefsEntries() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/win7-icon-map.txt")
        let map = try IconOverrideNames.parseMap(String(contentsOf: url, encoding: .utf8))
        let expected: [Int: String] = [
            3: "folder.png", 2: "file.png", 19: "file-text.png", 21: "file-image.png", 22: "file-audio.png",
            23: "file-video.png", 15: "file-app.png", 27: "control-panel.png", 26: "devices.png", 25: "network.png",
            32: "drive.png", 36: "drive-system.png", 35: "drive-removable.png", 37: "drive-optical.png", 14: "games.png",
            // Later parts of the pack (same ids as win7-asset-map.txt).
            55: "recycle-bin-empty.png", 54: "recycle-bin-full.png", 112: "folder-documents.png",
            113: "folder-pictures.png", 108: "folder-music.png", 109: "computer.png",
            // Control Panel.
            24: "cp-default-programs.png", 114: "cp-administrative-tools.png",
        ]
        for (id, name) in expected { #expect(map.ids[IconKey(dll: "imageres", id: id)] == name, "id \(id)") }
        // Ids of this pack that stay unmapped (they go to the contact sheet only).
        for id in [5, 6, 8, 9, 10, 18, 20, 28, 29, 30, 31, 38, 39, 40, 41] {
            #expect(map.ids[IconKey(dll: "imageres", id: id)] == nil, "id \(id)")
        }
        // The utilities pack, by file name.
        #expect(map.files == ["explorer.ico": "app-com.apple.finder.png", "taskmgr.ico": "app-com.apple.ActivityMonitor.png",
                              "trashbin1.ico": "recycle-bin-empty.png", "trashbin2.ico": "recycle-bin-full.png"])
    }
}

@Suite struct IconFileNameTests {
    @Test func readsTheResourceIdFromImageresFileNames() {
        #expect(IconOverrideNames.iconID(fileName: "imageres-#3.ico") == 3)
        #expect(IconOverrideNames.iconID(fileName: "imageres-#41.ICO") == 41)
        #expect(IconOverrideNames.iconID(fileName: "imageres-27.ico") == 27)
        #expect(IconOverrideNames.iconID(fileName: "#112.ico") == 112)
        #expect(IconOverrideNames.iconID(fileName: "19.ico") == 19)
        #expect(IconOverrideNames.iconID(fileName: "some/dir/imageres-#2.ico") == 2)
    }

    @Test func readsTheDllAndIdFromExportedFileNames() {
        #expect(IconOverrideNames.iconKey(fileName: "imageres-#3.ico") == IconKey(dll: "imageres", id: 3))
        #expect(IconOverrideNames.iconKey(fileName: "shell32-24.ico") == IconKey(dll: "shell32", id: 24))
        #expect(IconOverrideNames.iconKey(fileName: "dir/DeviceCenter-#1.ICO") == IconKey(dll: "devicecenter", id: 1))
        #expect(IconOverrideNames.iconKey(fileName: "19.ico") == IconKey(dll: "imageres", id: 19))
        for name in ["shell32-#.ico", "shell32-#0.ico", "-#3.ico", "shell_32-#3.ico", "shell32-#3a.ico", "shell32#3.ico",
                     "trashbin1.ico", "readme.txt", "shell32-#3.png", "a-b-#3.ico"] {
            #expect(IconOverrideNames.iconKey(fileName: name) == nil, "\(name)")
        }
        // iconID stays the imageres-only wrapper.
        #expect(IconOverrideNames.iconID(fileName: "shell32-#3.ico") == nil)
        #expect(IconOverrideNames.iconID(fileName: "imageres-#3.ico") == 3)
    }

    @Test func rejectsOtherFiles() {
        for name in ["readme.txt", "imageres-#3.png", "shell32-#3.ico", "imageres-#.ico", "imageres-#3a.ico",
                     "imageres-#99999999999999999999.ico", "imageres-#0.ico", ".ico", "trashbin1.ico"] {
            #expect(IconOverrideNames.iconID(fileName: name) == nil, "\(name)")
        }
    }
}

@Suite struct IconOverrideNameTests {
    private func traits(_ path: String, dir: Bool = false, package: Bool = false, symlink: Bool = false,
                        alias: Bool = false, custom: Bool = false) -> DesktopItemTraits {
        DesktopItemTraits(path: path, isDirectory: dir, isPackage: package, isSymlink: symlink, isAlias: alias,
                          hasCustomIcon: custom)
    }

    @Test func folderNamesMatchFinders() {
        #expect(IconOverrideNames.folder(.plain) == "folder")
        #expect(IconOverrideNames.folder(.documents) == "folder-documents")
        #expect(IconOverrideNames.folder(.videos) == "folder-videos")
        #expect(IconOverrideNames.folder(.user) == "folder-user")
        #expect(Set(DesktopFolderArt.allCases.map(IconOverrideNames.folder)).count == DesktopFolderArt.allCases.count)
    }

    @Test func appNamesUseTheBundleID() {
        #expect(IconOverrideNames.app(bundleID: "com.apple.finder") == "app-com.apple.finder")
        #expect(IconOverrideNames.app(bundleID: "com.apple.ActivityMonitor") == "app-com.apple.ActivityMonitor")
        #expect(IconOverrideNames.app(bundleID: "org.some_vendor.App-2") == "app-org.some_vendor.App-2")
        for bad in [nil, "", "../x", "a/b", ".hidden", "a b"] as [String?] {
            #expect(IconOverrideNames.app(bundleID: bad) == nil, "\(bad ?? "nil")")
        }
    }

    @Test func filesMapByContentType() {
        let f = traits("/Users/u/Desktop/x")
        #expect(IconOverrideNames.file(f, type: .plainText) == "file-text")
        #expect(IconOverrideNames.file(f, type: .swiftSource) == "file-text")
        #expect(IconOverrideNames.file(f, type: .png) == "file-image")
        #expect(IconOverrideNames.file(f, type: .jpeg) == "file-image")
        #expect(IconOverrideNames.file(f, type: .mp3) == "file-audio")
        #expect(IconOverrideNames.file(f, type: .wav) == "file-audio")
        #expect(IconOverrideNames.file(f, type: .mpeg4Movie) == "file-video")
        #expect(IconOverrideNames.file(f, type: .quickTimeMovie) == "file-video")
        #expect(IconOverrideNames.file(f, type: .pdf) == "file")
        #expect(IconOverrideNames.file(f, type: .zip) == "file")
        #expect(IconOverrideNames.file(f, type: nil) == "file")
    }

    @Test func fileTypeNames() {
        #expect(IconOverrideNames.fileType(.png) == "file-image"); #expect(IconOverrideNames.fileType(.mpeg4Movie) == "file-video")
        #expect(IconOverrideNames.fileType(.mp3) == "file-audio"); #expect(IconOverrideNames.fileType(.swiftSource) == "file-text")
        #expect(IconOverrideNames.fileType(.zip) == "file"); #expect(IconOverrideNames.fileType(nil) == "file")
    }

    @Test func typeIconsForSearchHitsAndRecentItems() {
        // Folders get the folder icon, not a document's; applications and packages keep their own (nil).
        #expect(IconOverrideNames.typeIcon(.folder) == "folder")
        #expect(IconOverrideNames.typeIcon(.volume) == "folder")
        #expect(IconOverrideNames.typeIcon(.applicationBundle) == nil)
        #expect(IconOverrideNames.typeIcon(.application) == nil)
        #expect(IconOverrideNames.typeIcon(.package) == nil)
        #expect(IconOverrideNames.typeIcon(.rtfd) == nil)
        #expect(IconOverrideNames.typeIcon(.bundle) == nil)
        #expect(IconOverrideNames.typeIcon(.framework) == nil)
        // Every other file type as fileType(_:); an unknown type is a plain file.
        #expect(IconOverrideNames.typeIcon(.png) == "file-image")
        #expect(IconOverrideNames.typeIcon(.plainText) == "file-text")
        #expect(IconOverrideNames.typeIcon(.zip) == "file")
        #expect(IconOverrideNames.typeIcon(nil) == "file")
    }

    @Test func applicationsFoldersAndCustomisedFilesKeepTheirOwnIcon() {
        #expect(IconOverrideNames.file(traits("/A.app", dir: true, package: true), type: .applicationBundle) == nil)
        #expect(IconOverrideNames.file(traits("/tool"), type: .application) == nil)
        #expect(IconOverrideNames.file(traits("/d", dir: true), type: .folder) == nil)
        #expect(IconOverrideNames.file(traits("/x.rtfd", dir: true, package: true), type: .rtfd) == nil)
        #expect(IconOverrideNames.file(traits("/x.txt", custom: true), type: .plainText) == nil)
        #expect(IconOverrideNames.file(traits("/x.txt", symlink: true), type: .plainText) == nil)
        #expect(IconOverrideNames.file(traits("/x.txt", alias: true), type: .plainText) == nil)
    }

    @Test func precedenceUserIconThenOverrideThenDrawnOrSystem() {
        let home = "/Users/u"
        let all: (String) -> Bool = { _ in true }
        let none: (String) -> Bool = { _ in false }
        func choice(_ t: DesktopItemTraits, _ type: UTType?, _ available: (String) -> Bool) -> DesktopIconChoice {
            IconOverrideNames.choice(art: DesktopFolderArt.art(for: t, home: home),
                                     file: IconOverrideNames.file(t, type: type), available: available)
        }
        // A folder or file with the user's own custom icon keeps it, even with every override present.
        #expect(choice(traits("/Users/u/Desktop/f", dir: true, custom: true), .folder, all) == .own)
        #expect(choice(traits("/Users/u/Desktop/a.txt", custom: true), .plainText, all) == .own)
        // Override when its PNG exists.
        #expect(choice(traits("/Users/u/Desktop/f", dir: true), .folder, all) == .override("folder"))
        #expect(choice(traits("/Users/u/Desktop/a.txt"), .plainText, all) == .override("file-text"))
        // Otherwise the drawn folder art, or the system icon for files.
        #expect(choice(traits("/Users/u/Desktop/f", dir: true), .folder, none) == .drawn(.plain))
        #expect(choice(traits("/Users/u/Desktop/a.txt"), .plainText, none) == .own)
        // Only the matching PNG counts: file.png doesn't stand in for a missing file-text.png.
        #expect(choice(traits("/Users/u/Desktop/a.txt"), .plainText, { $0 == "file" }) == .own)
        // Special folders keep their drawn art unless folder-<kind>.png exists; folder.png doesn't apply.
        #expect(choice(traits("/Users/u/Documents", dir: true), .folder, { $0 == "folder" }) == .drawn(.documents))
        #expect(choice(traits("/Users/u/Documents", dir: true), .folder, { $0 == "folder-documents" })
            == .override("folder-documents"))
    }

    @Test func desktopNameForApplicationsAndFiles() {
        let app = traits("/Applications/TextEdit.app", dir: true, package: true)
        #expect(app.isApplication)
        #expect(IconOverrideNames.desktop(app, type: .applicationBundle, bundleID: "com.apple.TextEdit") == "app-com.apple.TextEdit")
        #expect(IconOverrideNames.desktop(app, type: .applicationBundle, bundleID: nil) == nil)
        #expect(IconOverrideNames.desktop(app, type: .applicationBundle, bundleID: "../x") == nil)
        let txt = traits("/x/a.txt")
        #expect(!txt.isApplication)
        #expect(IconOverrideNames.desktop(txt, type: .plainText, bundleID: nil) == "file-text")
        #expect(IconOverrideNames.desktop(traits("/x/a.txt", alias: true), type: .plainText, bundleID: nil) == nil)
        // An application the user gave a custom icon, an alias or a symlink to one keeps its own icon.
        #expect(IconOverrideNames.desktop(traits("/A.app", dir: true, package: true, custom: true), type: .applicationBundle,
                                          bundleID: "com.apple.TextEdit") == nil)
        #expect(IconOverrideNames.desktop(traits("/A.app", symlink: true), type: .symbolicLink, bundleID: "com.apple.TextEdit") == nil)
        #expect(IconOverrideNames.desktop(traits("/A.app", alias: true), type: .aliasFile, bundleID: "com.apple.TextEdit") == nil)
        // The same with the link's traits as an application package: the symlink/alias guard, not file(), rejects them.
        #expect(IconOverrideNames.desktop(traits("/A.app", dir: true, package: true, symlink: true), type: .applicationBundle,
                                          bundleID: "com.apple.TextEdit") == nil)
        #expect(IconOverrideNames.desktop(traits("/A.app", dir: true, package: true, alias: true), type: .applicationBundle,
                                          bundleID: "com.apple.TextEdit") == nil)
        // Only an .app package counts as an application; a folder named x.app and other packages don't.
        #expect(!traits("/x.app", dir: true).isApplication)
        #expect(!traits("/x.rtfd", dir: true, package: true).isApplication)
        #expect(traits("/X.APP/", dir: true, package: true).isApplication)
        #expect(IconOverrideNames.desktop(traits("/x.rtfd", dir: true, package: true), type: .rtfd, bundleID: "a.b") == nil)
        #expect(IconOverrideNames.desktop(traits("/d", dir: true), type: .folder, bundleID: nil) == nil)
    }

    @Test func choicePrefersAppOverride() {
        #expect(IconOverrideNames.choice(art: nil, file: "app-com.apple.TextEdit", available: { $0 == "app-com.apple.TextEdit" })
            == .override("app-com.apple.TextEdit"))
        #expect(IconOverrideNames.choice(art: nil, file: "app-com.apple.TextEdit", available: { _ in false }) == .own)
    }

    @Test func iconFileLimits() {
        #expect(IconOverrideNames.acceptsIconFile(bytes: 0))
        #expect(IconOverrideNames.acceptsIconFile(bytes: 2 * 1024 * 1024))
        #expect(!IconOverrideNames.acceptsIconFile(bytes: 2 * 1024 * 1024 + 1))
        #expect(!IconOverrideNames.acceptsIconFile(bytes: nil))
        #expect(IconOverrideNames.acceptsIconPixels(width: 256, height: 256))
        #expect(IconOverrideNames.acceptsIconPixels(width: 1024, height: 1024))
        #expect(!IconOverrideNames.acceptsIconPixels(width: 1025, height: 16))
        #expect(!IconOverrideNames.acceptsIconPixels(width: 16, height: 1025))
        #expect(!IconOverrideNames.acceptsIconPixels(width: 0, height: 16))
        #expect(!IconOverrideNames.acceptsIconPixels(width: 16, height: -1))
    }

    @Test func startMenuPlaceIconsFallBack() {
        #expect(IconOverrideNames.placeIcon("computer", available: { _ in true }) == "computer")
        #expect(IconOverrideNames.placeIcon("computer", available: { $0 == "drive-system" }) == "drive-system")
        #expect(IconOverrideNames.placeIcon("computer", available: { _ in false }) == nil)
        #expect(IconOverrideNames.placeIcon("devices", available: { $0 == "devices" }) == "devices")
        #expect(IconOverrideNames.placeIcon("control-panel", available: { $0 == "control-panel" }) == "control-panel")
        #expect(IconOverrideNames.placeIcon("devices", available: { $0 == "drive-system" }) == nil)
        // The special-folder icons an imageres pack provides stand in for the places' own.
        #expect(IconOverrideNames.placeIcon("documents", available: { $0 == "folder-documents" }) == "folder-documents")
        #expect(IconOverrideNames.placeIcon("pictures", available: { $0 == "folder-pictures" }) == "folder-pictures")
        #expect(IconOverrideNames.placeIcon("music", available: { $0 != "folder-documents" }) == "music")
        #expect(IconOverrideNames.placeIcon("music", available: { $0 == "folder-music" }) == "folder-music")
    }
}

// the shell's file reads, in Win7Core so they can be tested: an application's bundle id from its
// Info.plist, and the guarded decode of an `Assets/icons/*.png` file. Synthetic files only.
@Suite struct IconFileReadTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w7-iconread-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `<dir>/<name>/Contents/` with `plist` written as its Info.plist (none when nil).
    private func app(_ name: String, in dir: URL, plist: Data?) throws -> URL {
        let app = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        if let plist { try plist.write(to: app.appendingPathComponent("Contents/Info.plist")) }
        return app
    }

    private func plist(_ dict: [String: Any], _ format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: format, options: 0)
    }

    /// A synthetic PNG of noise, so its image data isn't compressed into a few bytes and half of it loses rows.
    private func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        var seed: UInt32 = 12345
        let px = rep.bitmapData!
        for i in 0..<(rep.bytesPerRow * height) {
            seed = seed &* 1664525 &+ 1013904223
            px[i] = UInt8(truncatingIfNeeded: seed >> 24) | (i % 4 == 3 ? 0xFF : 0)
        }
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func bundleIdentifierFromInfoPlist() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try app("Test.app", in: dir, plist: try plist(["CFBundleIdentifier": "com.example.Test"], .binary))
        #expect(IconOverrideNames.bundleIdentifier(ofApp: a) == "com.example.Test")
        try plist(["CFBundleIdentifier": "com.example.Xml"]).write(to: a.appendingPathComponent("Contents/Info.plist"))
        #expect(IconOverrideNames.bundleIdentifier(ofApp: a) == "com.example.Xml")
    }

    @Test func bundleIdentifierMissingOversizedOrMalformed() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // No Info.plist.
        #expect(IconOverrideNames.bundleIdentifier(ofApp: try app("None.app", in: dir, plist: nil)) == nil)
        // A plist over 1 MB, valid otherwise, isn't read.
        let big = try plist(["CFBundleIdentifier": "com.example.Big", "Pad": String(repeating: "x", count: 1024 * 1024)])
        #expect(big.count > IconOverrideNames.maxInfoPlistBytes)
        #expect(IconOverrideNames.bundleIdentifier(ofApp: try app("Big.app", in: dir, plist: big)) == nil)
        // Not a plist, a plist without the key, a non-string value, a top level that isn't a dictionary.
        #expect(IconOverrideNames.bundleIdentifier(ofApp: try app("A.app", in: dir, plist: Data("not a plist".utf8))) == nil)
        #expect(IconOverrideNames.bundleIdentifier(ofApp: try app("B.app", in: dir, plist: try plist(["CFBundleName": "X"]))) == nil)
        #expect(IconOverrideNames.bundleIdentifier(ofApp: try app("C.app", in: dir, plist: try plist(["CFBundleIdentifier": 7]))) == nil)
        let array = try PropertyListSerialization.data(fromPropertyList: ["com.example.X"], format: .xml, options: 0)
        #expect(IconOverrideNames.bundleIdentifier(ofApp: try app("D.app", in: dir, plist: array)) == nil)
        // A directory where the plist should be.
        let e = try app("E.app", in: dir, plist: nil)
        try FileManager.default.createDirectory(at: e.appendingPathComponent("Contents/Info.plist"), withIntermediateDirectories: true)
        #expect(IconOverrideNames.bundleIdentifier(ofApp: e) == nil)
    }

    @Test func iconDecodeAcceptsACompletePNG() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ok.png")
        try png(width: 64, height: 64).write(to: url)
        let image = IconOverrideNames.decodeIcon(at: url)
        #expect(image?.width == 64)
        #expect(image?.height == 64)
    }

    @Test func iconDecodeRejectsATruncatedPNG() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = png(width: 64, height: 64)
        let url = dir.appendingPathComponent("half.png")
        try data.prefix(data.count / 2).write(to: url)
        #expect(IconOverrideNames.decodeIcon(at: url) == nil)
    }

    @Test func pngCompletenessByChunks() {
        let data = png(width: 8, height: 8)
        #expect(IconOverrideNames.pngIsComplete(data))
        // Cut short anywhere, it isn't complete; bytes after IEND don't matter.
        for cut in 0..<data.count { #expect(!IconOverrideNames.pngIsComplete(data.prefix(cut)), "cut at \(cut)") }
        #expect(IconOverrideNames.pngIsComplete(data + Data([1, 2, 3])))
        // Not a PNG; a chunk length past the end.
        #expect(!IconOverrideNames.pngIsComplete(Data("GIF89a.........................".utf8)))
        var bad = data
        bad[8] = 0x7F
        #expect(!IconOverrideNames.pngIsComplete(bad))
    }

    @Test func iconDecodeRejectsOversizedLinkedAndNonPNGFiles() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let icons = dir.appendingPathComponent("icons")
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        // Over 1024 px wide.
        try png(width: 1025, height: 2).write(to: icons.appendingPathComponent("wide.png"))
        #expect(IconOverrideNames.decodeIcon(at: icons.appendingPathComponent("wide.png")) == nil)
        // Not an image.
        try Data("hello".utf8).write(to: icons.appendingPathComponent("text.png"))
        #expect(IconOverrideNames.decodeIcon(at: icons.appendingPathComponent("text.png")) == nil)
        // A symlink out of the icons folder, even to a valid PNG; a link inside the folder is fine.
        try png(width: 16, height: 16).write(to: dir.appendingPathComponent("outside.png"))
        try FileManager.default.createSymbolicLink(at: icons.appendingPathComponent("out.png"),
                                                   withDestinationURL: dir.appendingPathComponent("outside.png"))
        #expect(IconOverrideNames.decodeIcon(at: icons.appendingPathComponent("out.png")) == nil)
        try png(width: 16, height: 16).write(to: icons.appendingPathComponent("in.png"))
        try FileManager.default.createSymbolicLink(at: icons.appendingPathComponent("link.png"),
                                                   withDestinationURL: icons.appendingPathComponent("in.png"))
        #expect(IconOverrideNames.decodeIcon(at: icons.appendingPathComponent("link.png"))?.width == 16)
        // A directory, and a missing file.
        try FileManager.default.createDirectory(at: icons.appendingPathComponent("dir.png"), withIntermediateDirectories: true)
        #expect(IconOverrideNames.decodeIcon(at: icons.appendingPathComponent("dir.png")) == nil)
        #expect(IconOverrideNames.decodeIcon(at: icons.appendingPathComponent("missing.png")) == nil)
    }
}
