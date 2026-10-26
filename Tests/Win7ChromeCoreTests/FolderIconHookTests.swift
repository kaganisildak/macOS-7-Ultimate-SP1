import AppKit
import Foundation
import ObjectiveC
import Testing
import Win7ChromeCore

/// Stands in for DesktopServicesPriv's FINode: `+nodeFromNodeRef:` looks the ref up in a registry.
@objc final class FakeFINode: NSObject {
    nonisolated(unsafe) static var registry: [UnsafeMutableRawPointer: FakeFINode] = [:]
    @objc let isFolder: Bool
    @objc let isPackage: Bool
    @objc let fileURL: URL?
    @objc let downloadProgress: Progress?

    init(folder: Bool, package: Bool = false, url: URL?, downloading: Bool = false) {
        isFolder = folder
        isPackage = package
        fileURL = url
        downloadProgress = downloading ? Progress(totalUnitCount: 10) : nil
    }

    @objc class func nodeFromNodeRef(_ ref: UnsafeMutableRawPointer?) -> FakeFINode? {
        ref.flatMap { registry[$0] }
    }
}

let nodeTypes = "@24@0:8r^{TFENode=^{OpaqueNodeRef}}16"
let iconSelector = NSSelectorFromString("iconImageForNode:")
typealias IconIMP = @convention(c) (AnyObject, Selector, UnsafeRawPointer?) -> NSImage?

/// A TFENode: a struct holding one OpaqueNodeRef pointer, here a registry key.
final class FakeTFENode {
    let storage = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 1)
    init(_ node: FakeFINode?) {
        let key = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        storage.pointee = node == nil ? nil : key
        if let node { FakeFINode.registry[key] = node }
    }
    deinit {
        if let key = storage.pointee { FakeFINode.registry[key] = nil }
        storage.deallocate()
    }
    var pointer: UnsafeRawPointer { UnsafeRawPointer(storage) }
}

private func uniqueName(_ prefix: String) -> String {
    "\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
}

/// A browser view controller class with its own -iconImageForNode:, returning `original` and counting
/// calls. With `callsSuper`, it returns what its superclass's current implementation returns, as
/// Finder's TBrowserViewController calls super (TBaseBrowserViewController); with `wraps` too, a new
/// image of that size instead, as TGalleryCollectionViewController wraps super's image.
final class FakeBrowser {
    let cls: AnyClass
    let original: NSImage
    nonisolated(unsafe) var calls = 0
    /// What the superclass's implementation returned on the last call.
    nonisolated(unsafe) var fromSuper: NSImage?

    init(types: String = nodeTypes, originalSize: NSSize = NSSize(width: 64, height: 64), name: String? = nil,
         superclass: AnyClass = NSObject.self, callsSuper: Bool = false, wraps: Bool = false) {
        cls = objc_allocateClassPair(superclass, name ?? uniqueName("W7FakeBrowserVC"), 0)!
        let image = NSImage(size: originalSize)
        original = image
        let block: @convention(block) (AnyObject, UnsafeRawPointer?) -> NSImage? = { [unowned self] receiver, node in
            self.calls += 1
            guard callsSuper else { return image }
            let imp = unsafeBitCast(class_getMethodImplementation(superclass, iconSelector), to: IconIMP.self)
            let result = imp(receiver, iconSelector, node)
            self.fromSuper = result
            return wraps ? result.map { NSImage(size: $0.size) } : result
        }
        class_addMethod(cls, iconSelector, imp_implementationWithBlock(block), types)
        objc_registerClassPair(cls)
    }

    func icon(_ node: FakeTFENode?, receiver: AnyObject? = nil) -> NSImage? {
        let target = receiver ?? (cls as! NSObject.Type).init()
        let imp = unsafeBitCast(class_getMethodImplementation(object_getClass(target), iconSelector), to: IconIMP.self)
        return imp(target, iconSelector, node?.pointer)
    }
}

private func tempDir(_ name: String = "plain") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("w7folder-\(UUID().uuidString)")
        .appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Sets FinderInfo flags (big-endian, at byte 8) on `url`.
private func setFinderFlags(_ url: URL, _ flags: UInt16) {
    var info = [UInt8](repeating: 0, count: 32)
    info[8] = UInt8(flags >> 8)
    info[9] = UInt8(flags & 0xFF)
    let r = setxattr(url.path, "com.apple.FinderInfo", info, 32, 0, 0)
    #expect(r == 0)
}

/// A class compiled into the test image; the test gives it an own -iconImageForNode: with Finder's
/// encoding at run time, so the image scan has something to find.
@objc final class W7ImageScanBrowser: NSObject {}

/// Stands in for Finder's browser view controllers (TBaseBrowserViewController) for the refresh.
@MainActor class FakeBrowserViewController: NSViewController, NSCollectionViewDelegate, NSTableViewDataSource {
    var reloads = 0
    init() {
        super.init(nibName: nil, bundle: nil)
        view = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
    }
    required init?(coder: NSCoder) { nil }
    @objc func reloadIconsInView() { reloads += 1 }
}

/// Stands in for TDesktopViewController, a browser controller subclass that is never touched.
@MainActor final class FakeDesktopViewController: FakeBrowserViewController {}

/// A folder with Finder's "Locked" (UF_IMMUTABLE); unlocked again when the test ends.
private final class LockedDir {
    let url: URL
    init() throws {
        url = try tempDir("locked")
        #expect(chflags(url.path, UInt32(UF_IMMUTABLE)) == 0)
    }
    deinit { chflags(url.path, 0) }
}

/// A folder the user can write into but not read (a drop box); readable again when the test ends.
private final class UnreadableDir {
    let url: URL
    init() throws {
        url = try tempDir("dropbox")
        #expect(chmod(url.path, 0o333) == 0)
    }
    deinit { chmod(url.path, 0o755) }
}

/// The image's best (largest) bitmap's bytes, for comparing two icons.
private func pixelData(_ image: NSImage?) -> Data? {
    let reps = image?.representations.compactMap { $0 as? NSBitmapImageRep } ?? []
    guard let rep = reps.max(by: { $0.pixelsWide < $1.pixelsWide }), let cg = rep.cgImage else { return nil }
    return cg.dataProvider?.data as Data?
}

@Suite(.serialized) struct FolderIconHookTests {
    // MARK: Pure decisions

    @Test func replacesOnlyPlainFolders() {
        #expect(W7ShouldReplaceFolderIcon(.isFolder))
        #expect(!W7ShouldReplaceFolderIcon([]))
        let others: [W7FolderNodeTraits] = [.isPackage, .isVolume, .isAlias, .isSymlink, .hasCustomIcon, .isCustomized, .inProgress,
                                            .isLocked, .isUnreadable]
        for t in others {
            #expect(!W7ShouldReplaceFolderIcon([.isFolder, t]), "\(t)")
            #expect(!W7ShouldReplaceFolderIcon(t))
        }
    }

    @Test func kindFromPath() {
        let map: [String: NSNumber] = ["/Users/u": NSNumber(value: W7FolderIconKind.user.rawValue),
                                       "/Users/u/Documents": NSNumber(value: W7FolderIconKind.documents.rawValue),
                                       "/Users/u/Movies": NSNumber(value: W7FolderIconKind.videos.rawValue)]
        #expect(W7FolderIconKindForPath("/Users/u", map) == .user)
        #expect(W7FolderIconKindForPath("/Users/u/", map) == .user)
        #expect(W7FolderIconKindForPath("/Users/u/Documents/", map) == .documents)
        #expect(W7FolderIconKindForPath("/Users/u/./Documents", map) == .documents)
        #expect(W7FolderIconKindForPath("/Users/u/Movies", map) == .videos)
        #expect(W7FolderIconKindForPath("/Users/u/Documents/Work", map) == .plain)
        #expect(W7FolderIconKindForPath("/Users/other/Documents", map) == .plain)
        #expect(W7FolderIconKindForPath("", map) == .plain)
    }

    @Test func specialPathsCoverHomeAndItsFolders() {
        let map = W7FolderIconSpecialPaths()
        let home = (NSHomeDirectory() as NSString).standardizingPath
        let expected: [(String, W7FolderIconKind)] = [("", .user), ("/Desktop", .desktop), ("/Documents", .documents),
                                                     ("/Downloads", .downloads), ("/Music", .music),
                                                     ("/Pictures", .pictures), ("/Movies", .videos)]
        for (suffix, kind) in expected {
            #expect(map[home + suffix]?.intValue == kind.rawValue, "\(suffix)")
        }
        #expect(map.count == expected.count)
    }

    @Test func assetNames() {
        let kinds: [W7FolderIconKind] = [.plain, .documents, .pictures, .music, .videos, .downloads, .desktop, .user]
        #expect(kinds.map { W7FolderIconAssetName($0) } == ["folder", "folder-documents", "folder-pictures", "folder-music",
                                                             "folder-videos", "folder-downloads", "folder-desktop", "folder-user"])
    }

    @Test func installsInFinderOnlyAndHonoursTheKillSwitch() {
        #expect(W7FolderIconHookShouldInstall("com.apple.finder", false))
        #expect(!W7FolderIconHookShouldInstall("com.apple.finder", true))
        #expect(!W7FolderIconHookShouldInstall("com.apple.Safari", false))
        #expect(!W7FolderIconHookShouldInstall(nil, false))
    }

    // MARK: File-system traits

    @Test func fileTraits() throws {
        let dir = try tempDir()
        #expect(W7FolderFileTraits(dir.path) == .isFolder)

        let custom = try tempDir("custom")
        setFinderFlags(custom, 0x0400)   // kHasCustomIcon
        #expect(W7FolderFileTraits(custom.path) == [.isFolder, .hasCustomIcon])

        let bundleBit = try tempDir("bundlebit")
        setFinderFlags(bundleBit, 0x2000)   // kHasBundle
        #expect(W7FolderFileTraits(bundleBit.path).contains(.isPackage))

        let customized = try tempDir("customized")
        let plist = Data("{}".utf8)
        #expect(plist.withUnsafeBytes { setxattr(customized.path, "com.apple.icon.folder#S", $0.baseAddress, plist.count, 0, 0) } == 0)
        #expect(W7FolderFileTraits(customized.path) == [.isFolder, .isCustomized])

        let app = try tempDir("Thing.app")
        #expect(W7FolderFileTraits(app.path).contains(.isPackage))

        let link = dir.deletingLastPathComponent().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        #expect(W7FolderFileTraits(link.path) == .isSymlink)

        let file = dir.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)
        #expect(!W7FolderFileTraits(file.path).contains(.isFolder))
        setFinderFlags(file, 0x8000)   // kIsAlias
        #expect(W7FolderFileTraits(file.path).contains(.isAlias))

        #expect(W7FolderFileTraits("/").contains(.isVolume))
        #expect(W7FolderFileTraits(dir.appendingPathComponent("missing").path) == [])
    }

    @Test func lockedFolderTraits() throws {
        let locked = try LockedDir()
        #expect(W7FolderFileTraits(locked.url.path) == [.isFolder, .isLocked])
    }

    @Test func unreadableFolderTraits() throws {
        let dropBox = try UnreadableDir()
        #expect(W7FolderFileTraits(dropBox.url.path) == [.isFolder, .isUnreadable])
    }

    // MARK: Buckets

    @Test func bucketsAboveSixtyFourPoints() {
        let cases: [(CGFloat, CGFloat)] = [(16, 16), (15.2, 16), (32, 32), (63.5, 64), (64, 64), (64.5, 72), (65, 72),
                                           (72, 72), (73, 80), (100, 104), (128, 128), (129, 136), (512, 512)]
        for (points, bucket) in cases { #expect(W7FolderIconBucketPoints(points) == bucket, "\(points)") }
    }

    @Test func slidingSizesShareBucketBitmaps() throws {
        W7FolderIconUseAssetRoot(try tempDir("no-assets").path)
        defer { W7FolderIconUseAssetRoot(nil) }
        let a = try #require(W7FolderIconImage(.plain, NSSize(width: 97, height: 97)))
        let b = try #require(W7FolderIconImage(.plain, NSSize(width: 104, height: 104)))
        #expect(a.size == NSSize(width: 97, height: 97))
        #expect(a.representations.map(\.pixelsWide).sorted() == [104, 208])
        #expect(a.representations.allSatisfy { $0.size == NSSize(width: 97, height: 97) })
        #expect(pixelData(a) == pixelData(b))
    }

    /// A non-square size gets the square icon centred: transparent side columns, manila in the middle.
    @Test func nonSquareSizeIsCentredNotStretched() throws {
        W7FolderIconUseAssetRoot(try tempDir("no-assets").path)
        defer { W7FolderIconUseAssetRoot(nil) }
        let image = try #require(W7FolderIconImage(.plain, NSSize(width: 64, height: 48)))
        #expect(image.size == NSSize(width: 64, height: 48))
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }.sorted { $0.pixelsWide < $1.pixelsWide }
        #expect(reps.map(\.pixelsWide) == [64, 128] && reps.map(\.pixelsHigh) == [48, 96])
        let big = try #require(reps.last)
        func alpha(_ x: Int, _ y: Int) -> CGFloat { big.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
        // The 48 pt square spans x 8...56 pt (16...112 px): nothing left or right of it.
        for y in stride(from: 0, to: 96, by: 8) {
            #expect(alpha(4, y) == 0 && alpha(123, y) == 0, "y \(y)")
        }
        let centre = try #require(big.colorAt(x: 64, y: 96 - 30)?.usingColorSpace(.sRGB))
        #expect(centre.alphaComponent > 0.8 && centre.redComponent > 0.8 && centre.blueComponent < 0.65, "\(centre)")
        // The same square icon as at 48 x 48, not a stretched one.
        let square = try #require(W7FolderIconImage(.plain, NSSize(width: 48, height: 48)))
        let sq = try #require(square.representations.compactMap { $0 as? NSBitmapImageRep }.first { $0.pixelsWide == 96 })
        for (x, y) in [(20, 20), (48, 60), (70, 40)] {
            #expect(big.colorAt(x: x + 16, y: y) == sq.colorAt(x: x, y: y), "\(x),\(y)")
        }
    }

    // MARK: Images

    @Test func imageHasOneAndTwoTimesRepresentations() throws {
        W7FolderIconUseAssetRoot(try tempDir("no-assets").path)
        defer { W7FolderIconUseAssetRoot(nil) }
        let image = try #require(W7FolderIconImage(.plain, NSSize(width: 32, height: 32)))
        #expect(image.size == NSSize(width: 32, height: 32))
        let widths = image.representations.map(\.pixelsWide).sorted()
        #expect(widths == [32, 64])
        #expect(image.representations.allSatisfy { $0.size == NSSize(width: 32, height: 32) })
        // Fresh images, shared bitmaps: Finder may change the NSImage it gets without affecting the cache.
        let again = try #require(W7FolderIconImage(.plain, NSSize(width: 32, height: 32)))
        #expect(again !== image && pixelData(again) == pixelData(image))
        #expect(W7FolderIconImage(.plain, .zero) == nil)
    }

    @Test func overrideAssetReplacesTheDrawnIcon() throws {
        let root = try tempDir("assets")
        let icons = root.appendingPathComponent("icons")
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let red = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try red.representation(using: .png, properties: [:])!.write(to: icons.appendingPathComponent("folder-music.png"))
        W7FolderIconUseAssetRoot(root.path)
        defer { W7FolderIconUseAssetRoot(nil) }

        let music = try #require(W7FolderIconImage(.music, NSSize(width: 16, height: 16)))
        let bitmap = try #require(music.representations.compactMap { $0 as? NSBitmapImageRep }.first { $0.pixelsWide == 32 })
        let c = try #require(bitmap.colorAt(x: 16, y: 16)?.usingColorSpace(.sRGB))
        // Red, not the manila drawn icon (colour management may shift the channels a little).
        #expect(c.redComponent > 0.9 && c.greenComponent < 0.3 && c.blueComponent < 0.1 && c.alphaComponent > 0.9, "\(c)")
        // Kinds without their own asset keep the drawn icon.
        W7FolderIconUseAssetRoot(try tempDir("empty").path)
        #expect(pixelData(W7FolderIconImage(.plain, NSSize(width: 16, height: 16))) != nil)
        W7FolderIconUseAssetRoot(root.path)
        #expect(pixelData(W7FolderIconImage(.plain, NSSize(width: 16, height: 16))) !=
                pixelData(W7FolderIconImage(.music, NSSize(width: 16, height: 16))))
    }

    // MARK: Hook

    @Test func hookReplacesPlainFoldersOnly() throws {
        W7FolderIconUseAssetRoot(try tempDir("no-assets").path)
        defer { W7FolderIconUseAssetRoot(nil) }
        let browser = FakeBrowser()
        #expect(W7FolderIconHookClass(browser.cls, FakeFINode.self))

        let plainDir = try tempDir()
        let plain = FakeTFENode(FakeFINode(folder: true, url: plainDir))
        let replaced = try #require(browser.icon(plain))
        #expect(browser.calls == 1, "original called")
        #expect(replaced !== browser.original)
        #expect(replaced.size == browser.original.size)
        #expect(pixelData(replaced) == pixelData(W7FolderIconImage(.plain, browser.original.size)))

        let customDir = try tempDir("custom")
        setFinderFlags(customDir, 0x0400)
        let appDir = try tempDir("Tool.app")
        let file = plainDir.appendingPathComponent("f.txt")
        try Data("x".utf8).write(to: file)
        let locked = try LockedDir(), dropBox = try UnreadableDir()
        let kept: [(String, FakeTFENode?)] = [
            ("locked", FakeTFENode(FakeFINode(folder: true, url: locked.url))),
            ("unreadable", FakeTFENode(FakeFINode(folder: true, url: dropBox.url))),
            ("package node", FakeTFENode(FakeFINode(folder: true, package: true, url: plainDir))),
            ("package on disk", FakeTFENode(FakeFINode(folder: true, url: appDir))),
            ("custom icon", FakeTFENode(FakeFINode(folder: true, url: customDir))),
            ("file", FakeTFENode(FakeFINode(folder: false, url: file))),
            ("no URL", FakeTFENode(FakeFINode(folder: true, url: nil))),
            ("downloading", FakeTFENode(FakeFINode(folder: true, url: plainDir, downloading: true))),
            ("unknown ref", FakeTFENode(nil)),
            ("no node", nil),
        ]
        for (i, (label, node)) in kept.enumerated() {
            #expect(browser.icon(node) === browser.original, "\(label)")
            #expect(browser.calls == 2 + i, "\(label): original called once")
        }
    }

    @Test func hookIsIdempotentAndUsesTheSpecialFolderKind() throws {
        W7FolderIconUseAssetRoot(try tempDir("no-assets").path)
        let docs = try tempDir("Documents")
        W7FolderIconUseSpecialPaths([docs.path: NSNumber(value: W7FolderIconKind.documents.rawValue)])
        defer {
            W7FolderIconUseSpecialPaths(nil)
            W7FolderIconUseAssetRoot(nil)
        }
        let browser = FakeBrowser(originalSize: NSSize(width: 48, height: 48))
        #expect(W7FolderIconHookClass(browser.cls, FakeFINode.self))
        #expect(W7FolderIconHookClass(browser.cls, FakeFINode.self))
        let node = FakeTFENode(FakeFINode(folder: true, url: docs))
        let icon = browser.icon(node)
        #expect(browser.calls == 1, "not wrapped twice")
        #expect(pixelData(icon) == pixelData(W7FolderIconImage(.documents, NSSize(width: 48, height: 48))))
        #expect(pixelData(icon) != pixelData(W7FolderIconImage(.plain, NSSize(width: 48, height: 48))))
    }

    @Test func wrongEncodingOrInheritedMethodIsNotHooked() throws {
        let wrong = FakeBrowser(types: "@24@0:8^v16")
        let before = class_getMethodImplementation(wrong.cls, iconSelector)
        #expect(!W7FolderIconHookClass(wrong.cls, FakeFINode.self))
        #expect(class_getMethodImplementation(wrong.cls, iconSelector) == before)
        let plain = FakeTFENode(FakeFINode(folder: true, url: try tempDir()))
        #expect(wrong.icon(plain) === wrong.original)

        // A subclass that only inherits the method is left alone (its superclass is hooked instead).
        let base = FakeBrowser()
        let sub: AnyClass = objc_allocateClassPair(base.cls, "W7FakeSub_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))", 0)!
        objc_registerClassPair(sub)
        #expect(!W7FolderIconHookClass(sub, FakeFINode.self))
        #expect(!W7FolderIconHookClass(nil, FakeFINode.self))
        // A node class without +nodeFromNodeRef: is refused.
        #expect(!W7FolderIconHookClass(base.cls, NSObject.self))
        #expect(base.icon(plain) === base.original)
    }

    // MARK: Discovery of every implementing class (live fix)

    @Test func discoveryFindsEveryOwnImplementationWithTheEncoding() {
        let a = FakeBrowser(), b = FakeBrowser()
        let sub = FakeBrowser(superclass: a.cls, callsSuper: true)
        let wrong = FakeBrowser(types: "@24@0:8^v16")
        let inheritsOnly: AnyClass = objc_allocateClassPair(a.cls, uniqueName("W7FakeInherits"), 0)!
        objc_registerClassPair(inheritsOnly)
        let skippedName = uniqueName("W7FakeSkipped")
        let skipped = FakeBrowser(name: skippedName)
        let found = W7FolderIconHookCandidates([a.cls, b.cls, sub.cls, wrong.cls, inheritsOnly, skipped.cls, NSObject.self],
                                               [skippedName])
        #expect(Set(found.map { NSStringFromClass($0) }) == Set([a.cls, b.cls, sub.cls].map { NSStringFromClass($0) }))
        #expect(W7FolderIconSkippedClassNames() == ["TDesktopViewController"])
    }

    @Test func imageScanFindsCompiledClassesOfThatImage() throws {
        let types = nodeTypes
        let block: @convention(block) (AnyObject, UnsafeRawPointer?) -> NSImage? = { _, _ in nil }
        class_addMethod(W7ImageScanBrowser.self, iconSelector, imp_implementationWithBlock(block), types)   // NO on reruns
        let image = String(cString: try #require(class_getImageName(W7ImageScanBrowser.self)))
        let found = W7FolderIconHookCandidatesInImage(image, [])
        #expect(found.contains { $0 == W7ImageScanBrowser.self })
        #expect(!found.contains { $0 == FakeFINode.self })
        #expect(!W7FolderIconHookCandidatesInImage(image, ["Win7ChromeCoreTests.W7ImageScanBrowser", NSStringFromClass(W7ImageScanBrowser.self)])
            .contains { $0 == W7ImageScanBrowser.self })
        #expect(W7FolderIconHookCandidatesInImage("/no/such/image", []).isEmpty)
    }

    /// Finder's chain: each subclass's own method calls super, and every class is hooked; the gallery
    /// wraps super's image in a new one. Only the outermost hooked level replaces: the inner levels hand
    /// Finder's own image up unchanged, each original runs once, and the result is the Windows 7 icon.
    @Test func nestedHookedClassesReplaceOnce() throws {
        W7FolderIconUseAssetRoot(try tempDir("no-assets").path)
        defer { W7FolderIconUseAssetRoot(nil) }
        let base = FakeBrowser()
        let browser = FakeBrowser(superclass: base.cls, callsSuper: true)
        let gallery = FakeBrowser(superclass: browser.cls, callsSuper: true, wraps: true)
        for c in [base.cls, browser.cls, gallery.cls] { #expect(W7FolderIconHookClass(c, FakeFINode.self)) }
        let node = FakeTFENode(FakeFINode(folder: true, url: try tempDir()))
        let receiver = (gallery.cls as! NSObject.Type).init()
        let icon = gallery.icon(node, receiver: receiver)
        #expect(base.calls == 1 && browser.calls == 1 && gallery.calls == 1)
        #expect(browser.fromSuper === base.original, "the base level did not replace")
        #expect(gallery.fromSuper === base.original, "the browser level did not replace")
        #expect(icon !== base.original)
        #expect(pixelData(icon) == pixelData(W7FolderIconImage(.plain, base.original.size)))
        // The next request starts at depth 0 again (nothing left over from the last one).
        #expect(pixelData(base.icon(node)) == pixelData(W7FolderIconImage(.plain, base.original.size)))
        // A class that only inherits a hooked implementation is replaced through its superclass's hook.
        let plainChild: AnyClass = objc_allocateClassPair(browser.cls, uniqueName("W7FakeIconCollection"), 0)!
        objc_registerClassPair(plainChild)
        let viaInheritance = browser.icon(node, receiver: (plainChild as! NSObject.Type).init())
        #expect(pixelData(viaInheritance) == pixelData(W7FolderIconImage(.plain, base.original.size)))
        let file = FakeTFENode(FakeFINode(folder: false, url: nil))
        // Not a folder: the gallery's own wrapper comes back (no bitmaps), not a Windows 7 icon.
        #expect(gallery.icon(file, receiver: receiver)?.representations.isEmpty == true)
    }

    /// TDesktopViewController's own method calls super (the hooked base): a skipped class's receivers keep
    /// Finder's icon even through an inherited or super-called hooked implementation.
    @Test func skippedSubclassCallingSuperKeepsTheOriginal() throws {
        W7FolderIconUseAssetRoot(try tempDir("no-assets").path)
        let base = FakeBrowser()
        let desktop = FakeBrowser(name: uniqueName("W7FakeDesktopVC"), superclass: base.cls, callsSuper: true)
        let inheritsFromDesktop: AnyClass = objc_allocateClassPair(desktop.cls, uniqueName("W7FakeDesktopChild"), 0)!
        objc_registerClassPair(inheritsFromDesktop)
        W7FolderIconUseSkippedClasses([desktop.cls])
        defer {
            W7FolderIconUseSkippedClasses(nil)
            W7FolderIconUseAssetRoot(nil)
        }
        #expect(W7FolderIconHookClass(base.cls, FakeFINode.self))
        let node = FakeTFENode(FakeFINode(folder: true, url: try tempDir()))
        #expect(desktop.icon(node, receiver: (desktop.cls as! NSObject.Type).init()) === base.original)
        #expect(desktop.icon(node, receiver: (inheritsFromDesktop as! NSObject.Type).init()) === base.original)
        #expect(base.calls == 2 && desktop.calls == 2)
        // Other receivers of the same hooked base are still replaced.
        #expect(base.icon(node) !== base.original)
        // Once cleared, the desktop subclass is replaced like any other.
        W7FolderIconUseSkippedClasses(nil)
        #expect(desktop.icon(node, receiver: (desktop.cls as! NSObject.Type).init()) !== base.original)
    }

    @MainActor @Test func refreshLeavesSkippedControllersAlone() {
        let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            W7FolderIconUseSkippedClasses(nil)
        }
        let browser = FakeBrowserViewController(), desktop = FakeDesktopViewController()
        window.contentView!.addSubview(browser.view)
        window.contentView!.addSubview(desktop.view)
        W7FolderIconUseSkippedClasses([FakeDesktopViewController.self])
        #expect(W7FolderIconReloadBrowserViews([window], FakeBrowserViewController.self) == 1)
        #expect(browser.reloads == 1 && desktop.reloads == 0)
    }

    // MARK: Refresh of open views (live fix)

    @MainActor @Test func refreshFindsBrowserControllersOutsideTheContentViewControllerTree() {
        let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = window.contentView!
        let byView = FakeBrowserViewController()
        let wrapper = NSView()
        wrapper.addSubview(byView.view)
        content.addSubview(wrapper)
        let byDelegate = FakeBrowserViewController()
        let collection = NSCollectionView()
        collection.delegate = byDelegate
        content.addSubview(collection)
        let byDataSource = FakeBrowserViewController()
        let table = NSTableView()
        table.dataSource = byDataSource
        content.addSubview(table)
        let unrelated = NSViewController()
        unrelated.view = NSView()
        content.addSubview(unrelated.view)
        // Also reachable twice (view and delegate): still once.
        collection.dataSource = nil
        let twice = FakeBrowserViewController()
        content.addSubview(twice.view)
        let other = NSTableView()
        other.dataSource = twice
        content.addSubview(other)

        let found = W7FolderIconBrowserControllers([window], FakeBrowserViewController.self)
        #expect(found.count == 4)
        for vc in [byView, byDelegate, byDataSource, twice] { #expect(found.contains { ($0 as AnyObject) === vc }) }
        #expect(W7FolderIconReloadBrowserViews([window], FakeBrowserViewController.self) == 4)
        #expect([byView, byDelegate, byDataSource, twice].allSatisfy { $0.reloads == 1 })
        #expect(W7FolderIconBrowserControllers([window], nil).isEmpty)
    }

    @MainActor @Test func refreshFindsChildViewControllers() {
        let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSViewController()
        container.view = NSView()
        let child = FakeBrowserViewController()
        container.addChild(child)   // never put in the view hierarchy
        window.contentViewController = container
        #expect(W7FolderIconReloadBrowserViews([window], FakeBrowserViewController.self) == 1)
        #expect(child.reloads == 1)
    }
}
