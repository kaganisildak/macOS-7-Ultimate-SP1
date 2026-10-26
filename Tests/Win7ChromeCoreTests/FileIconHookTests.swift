import AppKit
import Foundation
import ObjectiveC
import Testing
import Win7ChromeCore

// Finder file icons by type and the Explorer sites that read the user's icons (= plan "icons
// everywhere" ). Every PNG is a coloured square made here in a temp asset root; no real icon is read.
// FakeFINode, FakeTFENode and FakeBrowser come from FolderIconHookTests.swift.

private func squarePNG(_ px: Int, red: CGFloat, green: CGFloat = 0, blue: CGFloat = 0) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: red, green: green, blue: blue, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

private let redPNG = squarePNG(64, red: 1)
private let bluePNG = squarePNG(64, red: 0, blue: 1)

/// A temp folder for test items, removed with the object.
private final class Scratch {
    let url: URL
    init(_ label: String = "items") throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("w7fileicons-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit {
        // Undo what the tests did to make items unreadable or locked, so they can be removed.
        if let e = FileManager.default.enumerator(atPath: url.path) {
            for case let p as String in e {
                let full = url.appendingPathComponent(p).path
                chflags(full, 0)
                chmod(full, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }
    func file(_ name: String, _ contents: String = "x") throws -> URL {
        let f = url.appendingPathComponent(name)
        try Data(contents.utf8).write(to: f)
        return f
    }
    func dir(_ name: String) throws -> URL {
        let d = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

/// Sets FinderInfo flags (big-endian, at byte 8) on `url`.
private func finderFlags(_ url: URL, _ flags: UInt16) {
    var info = [UInt8](repeating: 0, count: 32)
    info[8] = UInt8(flags >> 8)
    info[9] = UInt8(flags & 0xFF)
    #expect(setxattr(url.path, "com.apple.FinderInfo", info, 32, 0, 0) == 0)
}

/// The centre pixel of `image`'s bitmap `px` wide, 0...255.
private func centre(_ image: NSImage?, px: Int) -> (r: Int, g: Int, b: Int, a: Int)? {
    guard let image, let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first(where: { $0.pixelsWide == px }),
          let c = rep.colorAt(x: px / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB) else { return nil }
    return (Int(c.redComponent * 255 + 0.5), Int(c.greenComponent * 255 + 0.5), Int(c.blueComponent * 255 + 0.5),
            Int(c.alphaComponent * 255 + 0.5))
}

private func isRed(_ c: (r: Int, g: Int, b: Int, a: Int)?) -> Bool {
    guard let c else { return false }
    return c.r > 230 && c.g < 60 && c.b < 60 && c.a > 230
}

private func isBlue(_ c: (r: Int, g: Int, b: Int, a: Int)?) -> Bool {
    guard let c else { return false }
    return c.r < 60 && c.g < 80 && c.b > 200 && c.a > 230
}

/// The largest bitmap's bytes, for comparing two icons.
private func pixels(_ image: NSImage?) -> Data? {
    let reps = image?.representations.compactMap { $0 as? NSBitmapImageRep } ?? []
    guard let rep = reps.max(by: { $0.pixelsWide < $1.pixelsWide }), let cg = rep.cgImage else { return nil }
    return cg.dataProvider?.data as Data?
}

@Suite(.serialized) struct FileIconHookTests {
    /// Runs `body` with a fresh asset root holding `icons` (name → PNG), no embedded icons, and the defaults
    /// restored afterwards.
    private func withIcons(_ icons: [String: Data], _ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("w7fileicons-root-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("icons")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, png) in icons { try png.write(to: dir.appendingPathComponent(name + ".png")) }
        W7UserIconsUseEmbedded([:])
        W7FolderIconUseAssetRoot(root.path)
        defer {
            W7UserIconsUseEmbedded(nil)
            W7FolderIconUseAssetRoot(nil)
        }
        try body(root)
    }

    // MARK: Decisions

    @Test func typeNameFromTheExtension() {
        let cases: [(String, String)] = [
            ("/tmp/a.txt", "file-text"), ("/tmp/A.TXT", "file-text"), ("/tmp/a.jpeg", "file-image"), ("/tmp/a.png", "file-image"),
            ("/tmp/a.mp3", "file-audio"), ("/tmp/a.wav", "file-audio"), ("/tmp/a.mov", "file-video"), ("/tmp/a.mp4", "file-video"),
            ("/tmp/noext", "file"), ("/tmp/a.pdf", "file"), ("/tmp/a.zzqqxw", "file"),
        ]
        for (path, name) in cases { #expect(W7FileIconOverrideName(.isPlainFile, path) == name, "\(path)") }
        #expect(W7FileIconOverrideName(.isPlainFile, nil) == "file")
        let others: [W7FolderNodeTraits] = [[], .isFolder, .isPackage, .isSymlink, [.isPlainFile, .isAlias], [.isPlainFile, .hasCustomIcon],
                                            [.isPlainFile, .inProgress], [.isPlainFile, .isPackage], [.isPlainFile, .isLocked],
                                            [.isPlainFile, .isUnreadable]]
        for t in others { #expect(W7FileIconOverrideName(t, "/tmp/a.txt") == nil, "\(t)") }
        // A plain file is never a plain folder.
        #expect(!W7ShouldReplaceFolderIcon(.isPlainFile))
    }

    @Test func plainFileTraits() throws {
        let s = try Scratch()
        #expect(W7FolderFileTraits(try s.file("a.txt").path) == .isPlainFile)
        #expect(W7FolderFileTraits(try s.file("noext").path) == .isPlainFile)
        #expect(!W7FolderFileTraits(try s.dir("d").path).contains(.isPlainFile))
        let alias = try s.file("alias.txt")
        finderFlags(alias, 0x8000)
        #expect(W7FolderFileTraits(alias.path) == .isAlias)
        let custom = try s.file("custom.txt")
        finderFlags(custom, 0x0400)
        #expect(W7FolderFileTraits(custom.path) == .hasCustomIcon)
        let link = s.url.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: try s.file("target.txt"))
        #expect(W7FolderFileTraits(link.path) == .isSymlink)
        let unreadable = try s.file("secret.txt")
        #expect(chmod(unreadable.path, 0) == 0)
        #expect(W7FolderFileTraits(unreadable.path) == .isUnreadable)
        let locked = try s.file("locked.txt")
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        #expect(W7FolderFileTraits(locked.path) == .isLocked)
        let fifo = s.url.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(!W7FolderFileTraits(fifo.path).contains(.isPlainFile))
    }

    /// Windows 7 shows thumbnails from Medium icons (48) up: pictures, videos, audio and generic files keep Finder's
    /// image (its Quick Look thumbnail, album art, PDF page) at 48 pt and more; text files are replaced at every size.
    @Test func thumbnailTypesAreReplacedOnlyBelowMediumIcons() {
        func at(_ name: String?, _ w: CGFloat, _ h: CGFloat? = nil) -> Bool {
            W7FileIconOverrideAppliesAtSize(name, NSSize(width: w, height: h ?? w))
        }
        for name in ["file-image", "file-video", "file-audio", "file"] {
            #expect(at(name, 16) && at(name, 32) && at(name, 47.5), "\(name) below 48")
            #expect(!at(name, 48) && !at(name, 64) && !at(name, 256), "\(name) at 48 and up")
            #expect(at(name, 64, 32), "\(name): the shorter side counts")
        }
        for side: CGFloat in [16, 32, 48, 64, 256, 512] { #expect(at("file-text", side), "file-text at \(side)") }
        #expect(!at("file-text", 0) && !at("file-image", 0) && !at("file-text", 16, 0))
        #expect(!at(nil, 16))
    }

    // MARK: Hook

    @Test func findersThumbnailStaysAtMediumIconsAndUp() throws {
        try withIcons(["file-image": redPNG, "file-text": redPNG, "file": bluePNG]) { _ in
            let s = try Scratch()
            let jpeg = FakeTFENode(FakeFINode(folder: false, url: try s.file("photo.jpeg")))
            let text = FakeTFENode(FakeFINode(folder: false, url: try s.file("notes.txt")))
            let zip = FakeTFENode(FakeFINode(folder: false, url: try s.file("archive.zip")))
            func browser(_ side: CGFloat) -> FakeBrowser {
                let b = FakeBrowser(originalSize: NSSize(width: side, height: side))
                #expect(W7FolderIconHookClass(b.cls, FakeFINode.self))
                return b
            }
            let small = browser(32), medium = browser(48), large = browser(64)
            #expect(isRed(centre(small.icon(jpeg), px: 64)), ".jpeg at 32 pt: ours")
            #expect(large.icon(jpeg) === large.original, ".jpeg at 64 pt: Finder's thumbnail")
            #expect(isRed(centre(large.icon(text), px: 128)), ".txt at 64 pt: ours")
            #expect(medium.icon(zip) === medium.original, ".zip at 48 pt: Finder's")
            #expect(isBlue(centre(small.icon(zip), px: 64)), ".zip at 32 pt: ours")
            #expect(small.calls == 2 && medium.calls == 1 && large.calls == 2, "the original runs once per request")
        }
    }

    @Test func plainFilesGetTheTypeIconWhenItsPNGExists() throws {
        try withIcons(["file-text": redPNG]) { root in
            let s = try Scratch()
            let browser = FakeBrowser()
            #expect(W7FolderIconHookClass(browser.cls, FakeFINode.self))
            let text = FakeTFENode(FakeFINode(folder: false, url: try s.file("a.txt")))
            let icon = try #require(browser.icon(text))
            #expect(icon !== browser.original)
            #expect(icon.size == browser.original.size)
            #expect(icon.representations.map(\.pixelsWide).sorted() == [64, 128])
            #expect(isRed(centre(icon, px: 128)))
            // No file-image.png and no file.png: Finder's icon stays (no drawn stand-in for files).
            let jpeg = FakeTFENode(FakeFINode(folder: false, url: try s.file("b.jpeg")))
            #expect(browser.icon(jpeg) === browser.original)
            let bare = FakeTFENode(FakeFINode(folder: false, url: try s.file("noext")))
            #expect(browser.icon(bare) === browser.original)
            #expect(browser.calls == 3, "the original runs once per request")
            // Once file.png is there (and the root set again), the file without an extension gets it below 48 pt
            // (at 64 pt Finder's image stays: generic files may show a Quick Look thumbnail).
            try bluePNG.write(to: root.appendingPathComponent("icons/file.png"))
            W7FolderIconUseAssetRoot(root.path)
            let small = FakeBrowser(originalSize: NSSize(width: 32, height: 32))
            #expect(W7FolderIconHookClass(small.cls, FakeFINode.self))
            #expect(isBlue(centre(small.icon(bare), px: 64)))
            #expect(browser.icon(bare) === browser.original)
            #expect(browser.icon(jpeg) === browser.original)
        }
    }

    @Test func specialFilesKeepFindersIcon() throws {
        try withIcons(["file-text": redPNG, "file": redPNG]) { _ in
            let s = try Scratch()
            let browser = FakeBrowser()
            #expect(W7FolderIconHookClass(browser.cls, FakeFINode.self))
            let alias = try s.file("alias.txt")
            finderFlags(alias, 0x8000)
            let custom = try s.file("custom.txt")
            finderFlags(custom, 0x0400)
            let link = s.url.appendingPathComponent("link.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: try s.file("target.txt"))
            let unreadable = try s.file("secret.txt")
            #expect(chmod(unreadable.path, 0) == 0)
            let locked = try s.file("locked.txt")
            #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
            let app = try s.dir("Tool.app")
            let plain = try s.file("plain.txt")
            let kept: [(String, FakeTFENode?)] = [
                ("alias", FakeTFENode(FakeFINode(folder: false, url: alias))),
                ("custom icon", FakeTFENode(FakeFINode(folder: false, url: custom))),
                ("symlink", FakeTFENode(FakeFINode(folder: false, url: link))),
                ("unreadable", FakeTFENode(FakeFINode(folder: false, url: unreadable))),
                ("locked", FakeTFENode(FakeFINode(folder: false, url: locked))),
                ("package node", FakeTFENode(FakeFINode(folder: false, package: true, url: plain))),
                ("application", FakeTFENode(FakeFINode(folder: true, package: true, url: app))),
                ("downloading", FakeTFENode(FakeFINode(folder: false, url: plain, downloading: true))),
                ("missing", FakeTFENode(FakeFINode(folder: false, url: s.url.appendingPathComponent("gone.txt")))),
                ("no URL", FakeTFENode(FakeFINode(folder: false, url: nil))),
                ("unknown ref", FakeTFENode(nil)),
            ]
            for (i, (label, node)) in kept.enumerated() {
                #expect(browser.icon(node) === browser.original, "\(label)")
                #expect(browser.calls == 1 + i, "\(label): original called once")
            }
            // The plain one next to them is replaced.
            #expect(isRed(centre(browser.icon(FakeTFENode(FakeFINode(folder: false, url: plain))), px: 128)))
        }
    }

    /// Finder's slider asks for every size: the shared image comes from the bucket (W7FolderIconBucketPoints)
    /// and Finder gets its own NSImage of the size it asked for, so resizing it never touches the cache.
    @Test func findersSizeIsBucketedAndTheSharedImageStaysUntouched() throws {
        try withIcons(["file-text": redPNG]) { _ in
            let s = try Scratch()
            let browser = FakeBrowser(originalSize: NSSize(width: 97, height: 97))
            #expect(W7FolderIconHookClass(browser.cls, FakeFINode.self))
            let node = FakeTFENode(FakeFINode(folder: false, url: try s.file("a.txt")))
            let icon = try #require(browser.icon(node))
            #expect(icon.size == NSSize(width: 97, height: 97))
            #expect(icon.representations.map(\.pixelsWide).sorted() == [104, 208])
            let shared = try #require(W7UserIconImage("file-text", 104))
            #expect(icon !== shared)
            icon.size = NSSize(width: 10, height: 10)
            #expect(shared.size == NSSize(width: 104, height: 104))
            #expect(W7UserIconImage("file-text", 104)?.size == NSSize(width: 104, height: 104))

            // A non-square size gets the square icon centred, not stretched.
            let wide = try #require(W7UserIconImageSized("file-text", NSSize(width: 64, height: 48)))
            #expect(wide.size == NSSize(width: 64, height: 48))
            let reps = wide.representations.compactMap { $0 as? NSBitmapImageRep }.sorted { $0.pixelsWide < $1.pixelsWide }
            #expect(reps.map(\.pixelsWide) == [64, 128] && reps.map(\.pixelsHigh) == [48, 96])
            let big = try #require(reps.last)
            #expect((big.colorAt(x: 4, y: 48)?.alphaComponent ?? 1) == 0 && (big.colorAt(x: 123, y: 48)?.alphaComponent ?? 1) == 0)
            #expect(isRed(centre(wide, px: 128)))
            #expect(W7UserIconImageSized("file-image", NSSize(width: 16, height: 16)) == nil)
            #expect(W7UserIconImageSized("file-text", .zero) == nil)
        }
    }

    // MARK: Explorer sites

    @Test func explorerIconForPath() throws {
        try withIcons(["file-text": redPNG]) { root in
            let s = try Scratch()
            #expect(W7ExplorerIconForPath(NSHomeDirectory() + "/Documents", 16) != nil)   // the folder art, always
            let dir = try s.dir("plain")
            let folder = try #require(W7ExplorerIconForPath(dir.path, 16))
            #expect(folder.size == NSSize(width: 16, height: 16))
            #expect(pixels(folder) == pixels(W7FolderIconImage(.plain, NSSize(width: 16, height: 16))))
            #expect(W7ExplorerIconForPath(dir.path, 48)?.size == NSSize(width: 48, height: 48))
            let docs = try s.dir("Documents")
            W7FolderIconUseSpecialPaths([docs.path: NSNumber(value: W7FolderIconKind.documents.rawValue)])
            defer { W7FolderIconUseSpecialPaths(nil) }
            #expect(pixels(W7ExplorerIconForPath(docs.path, 16)) == pixels(W7FolderIconImage(.documents, NSSize(width: 16, height: 16))))
            #expect(isRed(centre(W7ExplorerIconForPath(try s.file("a.txt").path, 16), px: 32)))   // file-text.png present
            #expect(W7ExplorerIconForPath(try s.file("a.jpeg").path, 16) == nil)                  // no file-image.png
            #expect(W7ExplorerIconForPath(s.url.appendingPathComponent("missing").path, 16) == nil)
            #expect(W7ExplorerIconForPath(try s.dir("Tool.app").path, 16) == nil)                 // packages keep theirs
            #expect(W7ExplorerIconForPath("", 16) == nil)
            // A volume root shows the drive icon when there is one, else the caller's (Finder's) icon.
            #expect(W7ExplorerIconForPath("/", 16) == nil)
            try bluePNG.write(to: root.appendingPathComponent("icons/drive-system.png"))
            W7FolderIconUseAssetRoot(root.path)
            #expect(isBlue(centre(W7ExplorerIconForPath("/", 16), px: 32)))
            // A fresh image each time: callers may resize it.
            #expect(W7ExplorerIconForPath(dir.path, 16) !== W7ExplorerIconForPath(dir.path, 16))
        }
    }

    @Test func dropDownMenuIconIsTheWindowsFolder() throws {
        try withIcons([:]) { _ in
            let s = try Scratch()
            let dir = try s.dir("sub")
            let icon = W7ExplorerMenuIconForPath(dir.path)
            #expect(icon.size == NSSize(width: 16, height: 16))
            #expect(pixels(icon) == pixels(W7FolderIconImage(.plain, NSSize(width: 16, height: 16))))
            let docs = try s.dir("Documents")
            W7FolderIconUseSpecialPaths([docs.path: NSNumber(value: W7FolderIconKind.documents.rawValue)])
            defer { W7FolderIconUseSpecialPaths(nil) }
            #expect(pixels(W7ExplorerMenuIconForPath(docs.path)) == pixels(W7FolderIconImage(.documents, NSSize(width: 16, height: 16))))
        }
        try withIcons(["folder": redPNG]) { _ in
            #expect(isRed(centre(W7ExplorerMenuIconForPath("/nowhere/x"), px: 32)))
            // A package row (judged by its extension, no file access) keeps the macOS folder.
            let app = W7ExplorerMenuIconForPath("/nowhere/Tool.app")
            #expect(app.size == NSSize(width: 16, height: 16))
            #expect(!isRed(centre(app, px: 32)))
            #expect(!isRed(centre(W7ExplorerMenuIconForPath("/nowhere/Library.photoslibrary"), px: 32)))
            // Without drive PNGs, volume rows show the Windows folder as before.
            #expect(isRed(centre(W7ExplorerMenuIconForPath("/"), px: 32)))
            #expect(isRed(centre(W7ExplorerMenuIconForPath("/Volumes/Data"), px: 32)))
        }
        // Volume rows (by path): `/` → drive-system, another mount point → drive.
        try withIcons(["folder": redPNG, "drive-system": bluePNG, "drive": squarePNG(64, red: 0, green: 1)]) { _ in
            #expect(isBlue(centre(W7ExplorerMenuIconForPath("/"), px: 32)))
            let volume = centre(W7ExplorerMenuIconForPath("/Volumes/Data/"), px: 32)
            #expect(volume.map { $0.g > 200 && $0.r < 60 && $0.b < 60 } == true)
            #expect(W7ExplorerMenuIconForPath("/Volumes/Data").size == NSSize(width: 16, height: 16))
            #expect(isRed(centre(W7ExplorerMenuIconForPath("/Volumes/Data/sub"), px: 32)), "a folder inside a volume")
            #expect(isRed(centre(W7ExplorerMenuIconForPath("/Volumes"), px: 32)))
        }
    }

    /// Every loader reset (embedded icons too) empties the rendered folder bitmaps, as an asset root change does.
    @Test func everyLoaderResetEmptiesTheFolderBitmapCache() throws {
        try withIcons([:]) { _ in
            _ = W7FolderIconImage(.plain, NSSize(width: 16, height: 16))
            #expect(W7FolderIconCachedBitmapCount() >= 2)
            W7UserIconsUseEmbedded(["help": redPNG])
            #expect(W7FolderIconCachedBitmapCount() == 0)
            _ = W7FolderIconImage(.documents, NSSize(width: 20, height: 20))
            #expect(W7FolderIconCachedBitmapCount() == 2)
            W7UserIconsClearCaches()
            #expect(W7FolderIconCachedBitmapCount() == 0)
            _ = W7FolderIconImage(.plain, NSSize(width: 16, height: 16))
            W7FolderIconUseAssetRoot(nil)
            #expect(W7FolderIconCachedBitmapCount() == 0)
        }
    }

    @MainActor @Test func helpButtonUsesHelpPNGAndCachesIt() throws {
        try withIcons([:]) { _ in #expect(W7ExplorerCommandHelpIcon() == nil) }
        try withIcons(["help": redPNG]) { _ in
            let icon = try #require(W7ExplorerCommandHelpIcon())
            #expect(icon.size == NSSize(width: 16, height: 16))
            #expect(isRed(centre(icon, px: 32)))
            #expect(W7ExplorerCommandHelpIcon() === icon, "the same image on every draw")
            W7UserIconsUseEmbedded(["help": bluePNG])   // a reset: looked at again
            #expect(W7ExplorerCommandHelpIcon() !== icon)
        }
        try withIcons([:]) { _ in #expect(W7ExplorerCommandHelpIcon() == nil) }
    }

    @Test func favoritesStarUsesFavoritesPNG() throws {
        try withIcons([:]) { _ in
            let drawn = try #require(W7NavPaneGroupIconImage(.favorites, 16))
            #expect(!isRed(centre(drawn, px: 32)))
        }
        try withIcons(["favorites": redPNG]) { _ in
            #expect(isRed(centre(W7NavPaneGroupIconImage(.favorites, 16), px: 32)))
            // The navigation pane's cache follows the loader's resets (embedded icons too).
            W7UserIconsUseEmbedded(["computer": bluePNG])
            #expect(isBlue(centre(W7NavPaneGroupIconImage(.locations, 16), px: 32)))
            W7UserIconsUseEmbedded([:])
            #expect(!isBlue(centre(W7NavPaneGroupIconImage(.locations, 16), px: 32)))
        }
    }

    // MARK: Loader (review 54)

    /// Folder overrides are read through the user-icon loader: its caps apply, and the embedded section too.
    @Test func folderOverridesGoThroughTheLoader() throws {
        let drawn = try withDrawnPlainFolder()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("w7fileicons-out-\(UUID().uuidString).png")
        try redPNG.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try withIcons([:]) { root in
            let folderPNG = root.appendingPathComponent("icons/folder.png")
            try FileManager.default.createSymbolicLink(at: folderPNG, withDestinationURL: outside)
            W7FolderIconUseAssetRoot(root.path)
            #expect(pixels(W7FolderIconImage(.plain, NSSize(width: 16, height: 16))) == drawn, "a symlink is refused")
            try FileManager.default.removeItem(at: folderPNG)
            try squarePNG(1100, red: 1).write(to: folderPNG)
            W7FolderIconUseAssetRoot(root.path)
            #expect(pixels(W7FolderIconImage(.plain, NSSize(width: 16, height: 16))) == drawn, "over 1024 px is refused")
            try FileManager.default.removeItem(at: folderPNG)
            W7UserIconsUseEmbedded(["folder": redPNG])
            #expect(isRed(centre(W7FolderIconImage(.plain, NSSize(width: 16, height: 16)), px: 32)), "the embedded folder icon")
        }
    }

    private func withDrawnPlainFolder() throws -> Data? {
        var data: Data?
        try withIcons([:]) { _ in data = pixels(W7FolderIconImage(.plain, NSSize(width: 16, height: 16))) }
        return data
    }

    @Test func generationChangesOnEveryReset() throws {
        let a = W7UserIconsGeneration()
        W7UserIconsClearCaches()
        let b = W7UserIconsGeneration()
        W7UserIconsUseEmbedded(nil)
        let c = W7UserIconsGeneration()
        W7FolderIconUseAssetRoot(nil)
        let d = W7UserIconsGeneration()
        #expect(a != b && b != c && c != d)
    }
}
