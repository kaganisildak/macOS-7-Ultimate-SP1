import AppKit
import Foundation
import ObjectiveC
import Testing
import Win7ChromeCore

// the Windows 7 navigation pane tree — row icons by target, section header icons, the
// expander, the child indent, and the hooks on (fake) Finder sidebar cells.

private let home = NSHomeDirectory()
private let special: [String: NSNumber] = [
    home: NSNumber(value: W7FolderIconKind.user.rawValue),
    home + "/Desktop": NSNumber(value: W7FolderIconKind.desktop.rawValue),
    home + "/Documents": NSNumber(value: W7FolderIconKind.documents.rawValue),
    home + "/Downloads": NSNumber(value: W7FolderIconKind.downloads.rawValue),
    home + "/Pictures": NSNumber(value: W7FolderIconKind.pictures.rawValue),
    home + "/Music": NSNumber(value: W7FolderIconKind.music.rawValue),
    home + "/Movies": NSNumber(value: W7FolderIconKind.videos.rawValue),
]

// MARK: - Mapping

@Test func targetsMapToWindows7IconNames() {
    func name(_ path: String?, cls: String? = "FIDSNode", volume: Bool = false) -> String? {
        W7NavPaneIconNameForTarget(cls, path, volume, special)
    }
    #expect(name(home) == "user")
    #expect(name(home + "/") == "user")   // compared standardized
    #expect(name(home + "/Desktop") == "folder-desktop")
    #expect(name(home + "/Documents") == "folder-documents")
    #expect(name(home + "/Downloads") == "folder-downloads")
    #expect(name(home + "/Pictures") == "folder-pictures")
    #expect(name(home + "/Music") == "folder-music")
    #expect(name(home + "/Movies") == "folder-videos")
    #expect(name("/Applications") == "applications")
    #expect(name("/System/Applications") == "applications")
    #expect(name("/", volume: true) == "drive-system")
    #expect(name("/Volumes/USB", volume: true) == "drive")
    #expect(name(home + "/.Trash") == "recycle-bin")
    // Finder's own node classes decide first.
    #expect(name(nil, cls: "FIDSNode_Trash") == "recycle-bin")
    #expect(name(nil, cls: "FIDSNode_NetworkSidebar") == "network")
    #expect(name("/Network", cls: "FIDSNode_NetworkNearby") == "network")
    #expect(name(nil, cls: "FIDSNode_Computer") == "computer")
    // Kept as Finder draws them.
    #expect(name(nil, cls: "FIDSNode_AirDrop") == nil)
    #expect(name(home + "/Library/Mobile Documents/com~apple~CloudDocs", cls: "FIDSNode_ICloudContainer") == nil)
    #expect(name(nil, cls: "FINode_AllCloudLibraries") == nil)
    #expect(name(home + "/Library/CloudStorage/Dropbox", cls: "FIDSNode_FPProvider") == nil)
    #expect(name(nil, cls: "FIAllTagsNode") == nil)
    #expect(name(home + "/Projects") == nil)   // a plain favourite folder: Finder's icon
    #expect(name(nil, cls: nil) == nil)
}

/// Recents ("Son Kullanılanlar") and Shared ("Paylaşılan"), the sidebar's last macOS icons: by Finder's node
/// class, by the canned search the row stands for (in Finder's own MyLibraries folder only), then by title.
@Test func recentsAndSharedMapToTheirWindows7Names() {
    func name(_ path: String?, cls: String? = "FIDSNode") -> String? { W7NavPaneIconNameForTarget(cls, path, false, special) }
    #expect(name(nil, cls: "FIDSNode_RecentDocuments") == "recent-places")
    // No real node class contains "Shared"; a future one (iCloud, a file provider) keeps Finder's icon.
    #expect(name(nil, cls: "FIDSNode_SharedItems") == nil)
    let library = "/System/Library/CoreServices/Finder.app/Contents/Resources/MyLibraries/"
    #expect(name(library + "myDocuments.cannedSearch", cls: "FIDSNode_QueryAlias") == "recent-places")
    for search in ["SharedDocuments", "SharedWithMe", "SharedByMe"] {
        #expect(name(library + search + ".cannedSearch", cls: "FIDSNode_QueryAlias") == "shared", "\(search)")
    }
    // The same file names anywhere else are the user's own files: Finder's icon.
    #expect(name(home + "/Searches/myDocuments.cannedSearch") == nil)
    #expect(name(home + "/MyLibraries/SharedDocuments.cannedSearch") == nil)
    #expect(name("/Users/Shared") == nil)   // a favourite folder called Shared keeps Finder's icon
    #expect(!W7NavPaneNodeClassKeepsFinderIcon("FIDSNode_RecentDocuments"))

    let titles = W7NavPaneTitleIconNames(special)
    #expect(W7NavPaneIconNameForTitle("Recents", titles) == "recent-places")
    #expect(W7NavPaneIconNameForTitle("Son Kullanılanlar", titles) == "recent-places")
    #expect(W7NavPaneIconNameForTitle("son kullanılanlar", titles) == "recent-places")
    #expect(W7NavPaneIconNameForTitle("Shared", titles) == "shared")
    #expect(W7NavPaneIconNameForTitle("Paylaşılan", titles) == "shared")
    #expect(W7NavPaneIconNameForTitle("PAYLAŞILAN", titles) == "shared")
}

@Test func titlesMapWhenTheTargetIsUnknown() {
    let titles = W7NavPaneTitleIconNames(special)
    // English and Turkish built-ins.
    #expect(W7NavPaneIconNameForTitle("Applications", titles) == "applications")
    #expect(W7NavPaneIconNameForTitle("Uygulamalar", titles) == "applications")
    #expect(W7NavPaneIconNameForTitle("Çöp Sepeti", titles) == "recycle-bin")
    #expect(W7NavPaneIconNameForTitle("çöp sepeti", titles) == "recycle-bin")   // case
    #expect(W7NavPaneIconNameForTitle("Trash", titles) == "recycle-bin")
    #expect(W7NavPaneIconNameForTitle("Ağ", titles) == "network")
    #expect(W7NavPaneIconNameForTitle("Network", titles) == "network")
    #expect(W7NavPaneIconNameForTitle("Macintosh HD", titles) == "drive-system")
    // The special folders by their display names in this process's language.
    let fm = FileManager.default
    #expect(W7NavPaneIconNameForTitle(fm.displayName(atPath: home + "/Desktop"), titles) == "folder-desktop")
    #expect(W7NavPaneIconNameForTitle(fm.displayName(atPath: home + "/Downloads"), titles) == "folder-downloads")
    #expect(W7NavPaneIconNameForTitle(fm.displayName(atPath: home), titles) == "user")
    #expect(W7NavPaneIconNameForTitle("AirDrop", titles) == nil)
    #expect(W7NavPaneIconNameForTitle(nil, titles) == nil)
    #expect(W7NavPaneIconNameForTitle("", titles) == nil)
}

@Test func sectionHeadersMapToTreeNodes() {
    #expect(W7NavPaneGroupKindFor("Favoriler", []) == .favorites)
    #expect(W7NavPaneGroupKindFor("Favorites", []) == .favorites)
    #expect(W7NavPaneGroupKindFor("Konumlar", []) == .locations)
    #expect(W7NavPaneGroupKindFor("Locations", []) == .locations)
    #expect(W7NavPaneGroupKindFor("Etiketler", []) == .tags)
    #expect(W7NavPaneGroupKindFor("Tags", []) == .tags)
    #expect(W7NavPaneGroupKindFor("iCloud", []) == .cloud)
    #expect(W7NavPaneGroupKindFor("FAVORİLER", []) == .favorites)   // Turkish capital İ
    // Unknown titles: by the children.
    #expect(W7NavPaneGroupKindFor("Orte", ["drive-system", "network"]) == .locations)
    #expect(W7NavPaneGroupKindFor("Favoris", ["applications", "folder-desktop"]) == .favorites)
    #expect(W7NavPaneGroupKindFor("Favoris", []) == .unknown)
    #expect(W7NavPaneGroupKindFor(nil, []) == .unknown)
}

@Test func childLayoutIndentsAndTightensTheIconGap() {
    #expect(W7NavPaneIconSize == 16 && W7NavPaneIconGap == 4 && W7NavPaneChildIndent == 12)
    let cell = W7NavPaneIndentedCellFrame(NSRect(x: 16, y: 0, width: 180, height: 24), 12)
    #expect(cell == NSRect(x: 28, y: 0, width: 168, height: 24))
    #expect(W7NavPaneIndentedCellFrame(NSRect(x: 0, y: 0, width: 5, height: 24), 12).width == 0)
    // A 20 pt image view: the 16 pt icon's right edge is at 2 + 18 = 20, the text starts at 24.
    let text = W7NavPaneTextFrame(NSRect(x: 27, y: 4, width: 120, height: 16), NSRect(x: 2, y: 2, width: 20, height: 20), 16, 4)
    #expect(text == NSRect(x: 24, y: 4, width: 123, height: 16))
    // Another coordinate space (too far off) or no image: unchanged.
    let far = NSRect(x: 200, y: 4, width: 40, height: 16)
    #expect(W7NavPaneTextFrame(far, NSRect(x: 2, y: 2, width: 20, height: 20), 16, 4) == far)
    #expect(W7NavPaneTextFrame(far, .zero, 16, 4) == far)
}

@Test func trashFullnessReadsTheFolder() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w7trash-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(!W7NavPaneTrashIsFull(dir.path))
    FileManager.default.createFile(atPath: dir.appendingPathComponent(".DS_Store").path, contents: Data())
    #expect(!W7NavPaneTrashIsFull(dir.path))
    FileManager.default.createFile(atPath: dir.appendingPathComponent("old.txt").path, contents: Data())
    #expect(W7NavPaneTrashIsFull(dir.path))
    #expect(!W7NavPaneTrashIsFull(dir.appendingPathComponent("missing").path))
}

@Test func installOnlyInFinderAndNotWhenDisabled() {
    #expect(W7NavPaneHooksShouldInstall("com.apple.finder", false))
    #expect(!W7NavPaneHooksShouldInstall("com.apple.finder", true))
    #expect(!W7NavPaneHooksShouldInstall("com.apple.Safari", false))
    #expect(!W7NavPaneHooksShouldInstall(nil, false))
}

// MARK: - Images (asset root is shared with the folder icon tests: serialized with them)

/// A `px` square sRGB PNG filled with (`red`, 0, 0).
private func pngData(_ px: Int, red: CGFloat) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: red, green: 0, blue: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

/// Red within colour-management rounding.
private func isRed(_ c: (Int, Int, Int, Int)) -> Bool { c.0 > 230 && c.1 < 60 && c.2 < 40 && c.3 > 230 }

private func centre(_ image: NSImage, scale: Int) -> (Int, Int, Int, Int) {
    let rep = image.representations.compactMap { $0 as? NSBitmapImageRep }.first { $0.pixelsWide == 16 * scale }!
    let c = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
    return (Int(c.redComponent * 255 + 0.5), Int(c.greenComponent * 255 + 0.5), Int(c.blueComponent * 255 + 0.5),
            Int(c.alphaComponent * 255 + 0.5))
}

extension FolderIconHookTests {
    /// On the main actor: the Trash state and its vnode source's handler live on the main thread.
    @MainActor @Test func navPaneIconsComeFromThePNGsThenTheDrawing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("w7nav-\(UUID().uuidString)")
        let icons = root.appendingPathComponent("icons")
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        W7FolderIconUseAssetRoot(root.path)
        defer { W7FolderIconUseAssetRoot(nil) }
        #expect(W7FolderIconAssetRootPath() == root.path)

        // No PNGs: drawn drive, network, computer, user folder, applications; no recycle bin.
        for name in ["drive", "drive-system", "network", "computer", "user", "applications", "folder-desktop"] {
            let image = try #require(W7NavPaneIconImage(name, 16), "\(name)")
            #expect(image.size == NSSize(width: 16, height: 16))
            #expect(Set(image.representations.map { $0.pixelsWide }) == [16, 32], "\(name)")
        }
        #expect(W7NavPaneIconImage("recycle-bin", 16) == nil)
        #expect(W7NavPaneIconImage("no-such-icon", 16) == nil)

        // The same image object every time (a cell's image view is not reset needlessly).
        #expect(W7NavPaneIconImage("network", 16) === W7NavPaneIconImage("network", 16))

        // Another asset root with PNGs: they override the drawing, scaled to 16 and 32 px; the first
        // root's cached icons are not mixed up with them.
        let root2 = FileManager.default.temporaryDirectory.appendingPathComponent("w7nav-\(UUID().uuidString)")
        let icons2 = root2.appendingPathComponent("icons")
        try FileManager.default.createDirectory(at: icons2, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root2) }
        try pngData(256, red: 1).write(to: icons2.appendingPathComponent("drive.png"))
        try pngData(64, red: 0.5).write(to: icons2.appendingPathComponent("recycle-bin-empty.png"))
        try pngData(64, red: 0.25).write(to: icons2.appendingPathComponent("recycle-bin-full.png"))
        try pngData(32, red: 1).write(to: icons2.appendingPathComponent("user.png"))
        W7FolderIconUseAssetRoot(root2.path)
        let drive = try #require(W7NavPaneIconImage("drive", 16))
        #expect(isRed(centre(drive, scale: 1)), "\(centre(drive, scale: 1))")
        #expect(isRed(centre(drive, scale: 2)), "\(centre(drive, scale: 2))")
        // Empty is the brighter red (0.5), full the darker (0.25), give or take colour management.
        let trash = root2.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        W7NavPaneUseTrashDirectory(trash.path)
        defer { W7NavPaneUseTrashDirectory(nil) }
        var clock = 1000.0
        W7NavPaneUseClock { clock }
        defer { W7NavPaneUseClock(nil) }
        let empty = centre(try #require(W7NavPaneIconImage("recycle-bin", 16)), scale: 1).0
        #expect(empty > 110, "empty bin red \(empty)")
        FileManager.default.createFile(atPath: trash.appendingPathComponent("old.txt").path, contents: Data())
        // The fullness is remembered for 1.5 s on the (injected, monotonic) clock: no directory read per
        // -image call... (The vnode source's reset runs on the main run loop, which this test holds.)
        let cached = centre(try #require(W7NavPaneIconImage("recycle-bin", 16)), scale: 1).0
        #expect(cached > 110, "still the remembered empty bin \(cached)")
        // ...and read again once it is older than that.
        clock += 2
        let full = centre(try #require(W7NavPaneIconImage("recycle-bin", 16)), scale: 1).0
        #expect(full < 110, "full bin red \(full)")
        // user.png wins over the drawn user folder.
        #expect(isRed(centre(try #require(W7NavPaneIconImage("user", 16)), scale: 2)))
        W7FolderIconUseAssetRoot(root.path)
        #expect(!isRed(centre(try #require(W7NavPaneIconImage("drive", 16)), scale: 1)))

        // Section header icons: drawn star, computer, tag, cloud; none for unknown.
        for kind in [W7NavPaneGroupKind.favorites, .locations, .tags, .cloud] {
            #expect(W7NavPaneGroupIconImage(kind, 16)?.size == NSSize(width: 16, height: 16), "\(kind)")
        }
        #expect(W7NavPaneGroupIconImage(.unknown, 16) == nil)
    }

    /// Recents and Shared come from the user's PNGs only; without one Finder's icon stays (nothing drawn).
    @MainActor @Test func recentsAndSharedIconsComeOnlyFromThePNGs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("w7nav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("icons"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        W7UserIconsUseEmbedded([:])
        W7FolderIconUseAssetRoot(root.path)
        defer {
            W7FolderIconUseAssetRoot(nil)
            W7UserIconsUseEmbedded(nil)
        }
        #expect(W7NavPaneIconImage("recent-places", 16) == nil)
        #expect(W7NavPaneIconImage("shared", 16) == nil)

        let root2 = FileManager.default.temporaryDirectory.appendingPathComponent("w7nav-\(UUID().uuidString)")
        let icons2 = root2.appendingPathComponent("icons")
        try FileManager.default.createDirectory(at: icons2, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root2) }
        try pngData(64, red: 1).write(to: icons2.appendingPathComponent("recent-places.png"))
        try pngData(64, red: 1).write(to: icons2.appendingPathComponent("shared.png"))
        W7FolderIconUseAssetRoot(root2.path)
        for name in ["recent-places", "shared"] {
            let image = try #require(W7NavPaneIconImage(name, 16), "\(name)")
            #expect(Set(image.representations.map { $0.pixelsWide }) == [16, 32], "\(name)")
            #expect(isRed(centre(image, scale: 2)), "\(name)")
        }
    }
}

// MARK: - Hooks on fake sidebar cells

/// Stands in for FINode: `+nodeFromNodeRef:` looks the ref up in this test's own registry.
@objc final class FakeNavNode: NSObject {
    nonisolated(unsafe) static var registry: [UnsafeMutableRawPointer: FakeNavNode] = [:]
    @objc let fileURL: URL?
    /// What an alias node stands for (FINode -original).
    @objc let original: FakeNavNode?
    init(_ url: URL?, original: FakeNavNode? = nil) {
        fileURL = url
        self.original = original
    }
    /// This class with `+nodeFromNodeRef:` added under FINode's exact encoding (`@24@0:8^{OpaqueNodeRef=}16`;
    /// a Swift @objc method would encode its pointer as `^v`, which the hook refuses).
    static let finderClass: AnyClass = {
        let lookup: @convention(block) (AnyObject, UnsafeMutableRawPointer?) -> FakeNavNode? = { _, ref in
            ref.flatMap { FakeNavNode.registry[$0] }
        }
        class_addMethod(object_getClass(FakeNavNode.self), NSSelectorFromString("nodeFromNodeRef:"),
                        imp_implementationWithBlock(lookup), "@24@0:8^{OpaqueNodeRef=}16")
        return FakeNavNode.self
    }()

    /// A new ref registered for `node`.
    @MainActor static func ref(_ node: FakeNavNode) -> UnsafeMutableRawPointer {
        let key = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        registry[key] = node
        return key
    }
}

private let tfeNodeIvarTypes = "{TFENode=\"fNodeRef\"^{OpaqueNodeRef}}"
private let rectTypes = "{CGRect={CGPoint=dd}{CGSize=dd}}16@0:8"

/// A TSidebarItemCell: an NSTableCellView with a `_node` ivar, -image answering `sentinel`, -imageSize
/// 20 and -_textFieldFrame (27, 4, 120, 16).
@MainActor private final class FakeCellClass {
    let cls: AnyClass
    let sentinel = NSImage(size: NSSize(width: 18, height: 18))
    init(nodeIvar: Bool = true, imageTypes: String = "@16@0:8") {
        cls = objc_allocateClassPair(NSTableCellView.self, "W7FakeSidebarCell_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))", 0)!
        if nodeIvar { _ = class_addIvar(cls, "_node", 8, 3, tfeNodeIvarTypes) }
        let image = sentinel
        let imageBlock: @convention(block) (AnyObject) -> NSImage = { _ in image }
        class_addMethod(cls, NSSelectorFromString("image"), imp_implementationWithBlock(imageBlock), imageTypes)
        let sizeBlock: @convention(block) (AnyObject) -> Double = { _ in 20 }
        class_addMethod(cls, NSSelectorFromString("imageSize"), imp_implementationWithBlock(sizeBlock), "d16@0:8")
        let textBlock: @convention(block) (AnyObject) -> NSRect = { _ in NSRect(x: 27, y: 4, width: 120, height: 16) }
        class_addMethod(cls, NSSelectorFromString("_textFieldFrame"), imp_implementationWithBlock(textBlock), rectTypes)
        // As Finder's: the image view shows -image (through the runtime, so the hooked one).
        let updateBlock: @convention(block) (NSTableCellView) -> Void = { [unowned self] cell in
            self.updates += 1
            let sel = NSSelectorFromString("image")
            let imp = unsafeBitCast(class_getMethodImplementation(object_getClass(cell), sel), to: (@convention(c) (AnyObject, Selector) -> NSImage?).self)
            cell.imageView?.image = imp(cell, sel)
            cell.imageView?.contentTintColor = .secondaryLabelColor
        }
        class_addMethod(cls, NSSelectorFromString("updateNameAndIcon"), imp_implementationWithBlock(updateBlock), "v16@0:8")
        objc_registerClassPair(cls)
    }

    /// -updateNameAndIcon calls.
    var updates = 0

    func make(node: URL? = nil, title: String = "") -> NSTableCellView {
        make(nodeObject: node.map { FakeNavNode($0) }, title: title)
    }

    func make(nodeObject: FakeNavNode?, title: String = "") -> NSTableCellView {
        let node = nodeObject
        let cell = (cls as! NSTableCellView.Type).init(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        let tf = NSTextField(labelWithString: title)
        cell.addSubview(tf)
        cell.textField = tf
        let iv = NSImageView(frame: NSRect(x: 2, y: 2, width: 20, height: 20))
        cell.addSubview(iv)
        cell.imageView = iv
        if let node, let ivar = class_getInstanceVariable(cls, "_node") {
            let base = Unmanaged.passUnretained(cell).toOpaque()
            base.advanced(by: ivar_getOffset(ivar)).storeBytes(of: FakeNavNode.ref(node), as: UnsafeMutableRawPointer.self)
            cell.imageView!.image = sentinel   // Finder's icon, as -finishMakingWithNode: leaves it
        }
        return cell
    }
}

private typealias ImageIMP = @convention(c) (AnyObject, Selector) -> NSImage?
private typealias SizeIMP = @convention(c) (AnyObject, Selector) -> Double
private typealias RectIMP = @convention(c) (AnyObject, Selector) -> NSRect

@MainActor private func callImage(_ o: AnyObject) -> NSImage? {
    let sel = NSSelectorFromString("image")
    return unsafeBitCast(class_getMethodImplementation(object_getClass(o), sel), to: ImageIMP.self)(o, sel)
}
@MainActor private func callSize(_ o: AnyObject) -> Double {
    let sel = NSSelectorFromString("imageSize")
    return unsafeBitCast(class_getMethodImplementation(object_getClass(o), sel), to: SizeIMP.self)(o, sel)
}
@MainActor private func callText(_ o: AnyObject) -> NSRect {
    let sel = NSSelectorFromString("_textFieldFrame")
    return unsafeBitCast(class_getMethodImplementation(object_getClass(o), sel), to: RectIMP.self)(o, sel)
}

/// A light window holding `view`, so the hooks see a light appearance whatever the Mac is set to.
@MainActor private func host(_ view: NSView, dark: Bool = false) -> NSWindow {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    w.contentView!.addSubview(view)
    return w
}

@MainActor @Test func cellHookAnswersTheWindows7IconForTheTarget() throws {
    let fake = FakeCellClass()
    #expect(W7NavPaneHookCellClass(fake.cls, FakeNavNode.finderClass))
    #expect(W7NavPaneHookCellClass(fake.cls, FakeNavNode.finderClass))   // idempotent

    let homeCell = fake.make(node: URL(fileURLWithPath: home))
    let w = host(homeCell)
    defer { w.close() }
    let icon = try #require(callImage(homeCell))
    #expect(icon !== fake.sentinel && icon.size == NSSize(width: 16, height: 16))
    #expect(W7NavPaneCellIconName(homeCell) == "user")
    #expect(callSize(homeCell) == 16)
    homeCell.imageView!.image = nil
    #expect(callText(homeCell) == NSRect(x: 27, y: 4, width: 120, height: 16))   // no image shown: Finder's
    homeCell.imageView!.image = icon                                            // as -updateNameAndIcon does
    #expect(callText(homeCell) == NSRect(x: 24, y: 4, width: 123, height: 16))

    // A target without a Windows 7 icon keeps Finder's.
    let plain = fake.make(node: FileManager.default.temporaryDirectory)
    w.contentView!.addSubview(plain)
    #expect(callImage(plain) === fake.sentinel)
    #expect(W7NavPaneCellIconName(plain) == nil)

    // Dark appearance: Finder's values throughout.
    let dark = fake.make(node: URL(fileURLWithPath: home))
    let dw = host(dark, dark: true)
    defer { dw.close() }
    #expect(callImage(dark) === fake.sentinel)
    #expect(callSize(dark) == 20)
    #expect(callText(dark) == NSRect(x: 27, y: 4, width: 120, height: 16))
}

@MainActor @Test func cellHookFallsBackToTheTitleWithoutANode() throws {
    let fake = FakeCellClass(nodeIvar: false)
    #expect(W7NavPaneHookCellClass(fake.cls, FakeNavNode.finderClass))
    let cell = fake.make(title: "Uygulamalar")
    let w = host(cell)
    defer { w.close() }
    #expect(W7NavPaneCellIconName(cell) == "applications")
    #expect(callImage(cell) !== fake.sentinel)
    // The cached name follows a new title.
    cell.textField!.stringValue = "AirDrop"
    #expect(W7NavPaneCellIconName(cell) == nil)
    #expect(callImage(cell) === fake.sentinel)
}

@MainActor @Test func cellHookChecksEncodings() {
    #expect(!W7NavPaneHookCellClass(nil, FakeNavNode.finderClass))
    #expect(!W7NavPaneHookCellClass(FakeCellClass().cls, nil))
    // A +nodeFromNodeRef: that takes a void pointer (FakeFINode's Swift @objc method) is not FINode's.
    #expect(!W7NavPaneHookCellClass(FakeCellClass().cls, FakeFINode.self))
    let wrong = FakeCellClass(imageTypes: "@24@0:8@16")
    #expect(!W7NavPaneHookCellClass(wrong.cls, FakeNavNode.finderClass))
    let cell = wrong.make(node: URL(fileURLWithPath: home))
    let w = host(cell)
    defer { w.close() }
    #expect(callSize(cell) == 20)   // nothing hooked when -image is not as expected
}

/// An outline view whose item rows use the fake cell class.
@MainActor final class FakeSidebarSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let groups = ["Favoriler", "Konumlar"]
    let make: (String) -> NSTableCellView
    init(make: @escaping (String) -> NSTableCellView) { self.make = make }
    func kids(_ g: String) -> [String] { g == "Favoriler" ? ["Uygulamalar", "Belgeler"] : ["Macintosh HD"] }
    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? String).map { kids($0).count } ?? groups.count }
    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? String).map { kids($0)[index] } ?? groups[index] }
    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool { groups.contains(item as! String) }
    func outlineView(_ ov: NSOutlineView, isGroupItem item: Any) -> Bool { groups.contains(item as! String) }
    func outlineView(_ ov: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let title = item as! String
        if groups.contains(title) {
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: title)
            cell.addSubview(label)
            cell.textField = label
            return cell
        }
        return make(title)
    }
}

@MainActor private func outline(_ source: FakeSidebarSource) -> (NSWindow, NSOutlineView, NSScrollView) {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
    let ov = NSOutlineView(frame: scroll.bounds)
    ov.style = .sourceList
    ov.headerView = nil
    let col = NSTableColumn(identifier: .init("c"))
    col.width = 190
    ov.addTableColumn(col)
    ov.outlineTableColumn = col
    ov.dataSource = source
    ov.delegate = source
    scroll.documentView = ov
    let w = host(scroll)
    ov.reloadData()
    source.groups.forEach { ov.expandItem($0) }
    ov.layoutSubtreeIfNeeded()
    return (w, ov, scroll)
}

@MainActor @Test func childCellsAreIndentedOnceAndHeadersNot() throws {
    let fake = FakeCellClass()
    #expect(W7NavPaneHookCellClass(fake.cls, FakeNavNode.finderClass))
    let source = FakeSidebarSource { fake.make(title: $0) }
    let (w, ov, _) = outline(source)
    defer { w.close() }
    for row in 0..<ov.numberOfRows {
        let rv = try #require(ov.rowView(atRow: row, makeIfNecessary: false))
        let cell = try #require(rv.subviews.compactMap { $0 as? NSTableCellView }.first)
        if rv.isGroupRowStyle {
            #expect(!(cell.isKind(of: fake.cls)))
            continue
        }
        let base = ov.frameOfCell(atColumn: 0, row: row).minX - rv.frame.minX
        #expect(cell.frame.minX == base + 12, "row \(row)")
        cell.frame = cell.frame          // AppKit (or anyone) setting the current frame again
        #expect(cell.frame.minX == base + 12, "row \(row) indented twice")
        W7NavPaneRefreshCell(cell)
        #expect(cell.frame.minX == base + 12)
    }
}

// MARK: - Styler: section headers, expander, highlight

@MainActor @Test func sectionHeadersGetTreeIconsAndExpanders() throws {
    let source = FakeSidebarSource { title in
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: title)
        cell.addSubview(label)
        cell.textField = label
        return cell
    }
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
    let ov = NSOutlineView(frame: scroll.bounds)
    ov.style = .sourceList
    ov.headerView = nil
    let col = NSTableColumn(identifier: .init("c"))
    col.width = 190
    ov.addTableColumn(col)
    ov.outlineTableColumn = col
    ov.dataSource = source
    ov.delegate = source
    scroll.documentView = ov
    _ = NSApplication.shared
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.appearance = NSAppearance(named: .aqua)
    w.toolbar = NSToolbar(identifier: "W7NavPaneTreeTestToolbar")
    w.contentView!.addSubview(scroll)
    ov.reloadData()
    source.groups.forEach { ov.expandItem($0) }
    W7ExplorerAdopt(w)
    ov.layoutSubtreeIfNeeded()
    NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: w)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
    defer { w.close() }

    var headers: [String] = []
    ov.enumerateAvailableRowViews { rv, _ in
        guard rv.isGroupRowStyle, let tf = rv.subviews.compactMap({ ($0 as? NSTableCellView)?.textField }).first else { return }
        headers.append(tf.attributedStringValue.string)
        // AppKit's own show/hide chevron is kept (it still works) but not shown.
        for b in rv.subviews.compactMap({ $0 as? NSButton }) where b.identifier == NSOutlineView.showHideButtonIdentifier {
            #expect(b.alphaValue == 0)
        }
    }
    #expect(headers == ["\u{FFFC} Favoriler", "\u{FFFC} Konumlar"])

    // The expander at the left of a header toggles it through AppKit's own button.
    let header = try #require(ov.rowView(atRow: 0, makeIfNecessary: false))
    let hit = try #require(header.subviews.first { String(cString: object_getClassName($0)) == "W7NavPaneExpanderHit" })
    #expect(hit.frame.minX < 16 && hit.frame.width >= 12)
    let favorites = ov.item(atRow: 0)
    #expect(ov.isItemExpanded(favorites))
    _ = hit.perform(NSSelectorFromString("w7Toggle"))
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
    #expect(!ov.isItemExpanded(favorites))

    // The Locations header is Windows 7's Computer node; right of the expander, a click goes to
    // Finder's Computer location (its own Go ▸ Computer). Only that header has one.
    func computerHit(_ rv: NSTableRowView) -> NSView? {
        rv.subviews.first { String(cString: object_getClassName($0)) == "W7NavPaneComputerHit" && !$0.isHidden }
    }
    var locations: NSTableRowView?
    ov.enumerateAvailableRowViews { rv, _ in
        if rv.isGroupRowStyle, rv.subviews.contains(where: { ($0 as? NSTableCellView)?.textField?.stringValue.contains("Konumlar") == true }) {
            locations = rv
        }
    }
    let locationsRow = try #require(locations)
    let go = try #require(computerHit(locationsRow))
    let expander = try #require(locationsRow.subviews.first { String(cString: object_getClassName($0)) == "W7NavPaneExpanderHit" })
    #expect(go.frame.minX >= expander.frame.maxX - 0.5 && go.frame.maxX == locationsRow.bounds.maxX)
    #expect(locationsRow.subviews.last === expander)   // the expander stays in front
    #expect(computerHit(header) == nil)
}

// MARK: - Live-check fixes: alias nodes, title fallback, dark restore, non-hooked cells

@Test func mountPointsAreRecognisedWithoutFileIO() {
    #expect(W7NavPanePathIsMountPoint("/"))
    #expect(W7NavPanePathIsMountPoint("/Volumes/USB"))
    #expect(W7NavPanePathIsMountPoint("/Volumes/USB/"))
    #expect(!W7NavPanePathIsMountPoint("/Volumes"))
    #expect(!W7NavPanePathIsMountPoint("/Volumes/USB/Folder"))
    #expect(!W7NavPanePathIsMountPoint(home))
    #expect(!W7NavPanePathIsMountPoint(nil))
    #expect(W7NavPaneNodeClassKeepsFinderIcon("FIDSNode_AirDrop") && !W7NavPaneNodeClassKeepsFinderIcon("FIDSNode_VirtualAlias"))
}

/// Sidebar entries can be alias nodes: their -original decides; with neither a path nor an original,
/// the title does (unless the class is one whose icon Finder keeps).
@MainActor @Test func aliasNodesResolveThroughTheirOriginalThenTheTitle() {
    let fake = FakeCellClass()
    #expect(W7NavPaneHookCellClass(fake.cls, FakeNavNode.finderClass))
    let before = W7NavPaneHookCallCount(.image)
    let alias = fake.make(nodeObject: FakeNavNode(nil, original: FakeNavNode(URL(fileURLWithPath: home + "/Desktop"))))
    let titled = fake.make(nodeObject: FakeNavNode(nil), title: "Uygulamalar")
    let w = host(alias)
    defer { w.close() }
    w.contentView!.addSubview(titled)
    #expect(W7NavPaneCellIconName(alias) == "folder-desktop")
    #expect(W7NavPaneCellIconName(titled) == "applications")
    #expect(callImage(titled) !== fake.sentinel)
    #expect(W7NavPaneHookCallCount(.image) > before)
    #expect(W7NavPaneHookCallSummary().contains("-image"))
    // The cached name follows the title, not only the node.
    titled.textField!.stringValue = "AirDrop"
    #expect(W7NavPaneCellIconName(titled) == nil)
}

/// Light → dark: RefreshCell gives Finder's image back (through the cell's own -updateNameAndIcon).
@MainActor @Test func refreshRestoresFinderIconsInADarkAppearance() throws {
    let fake = FakeCellClass()
    #expect(W7NavPaneHookCellClass(fake.cls, FakeNavNode.finderClass))
    let cell = fake.make(node: URL(fileURLWithPath: home))
    let w = host(cell)
    defer { w.close() }
    W7NavPaneRefreshCell(cell)
    let ours = try #require(cell.imageView?.image)
    #expect(ours !== fake.sentinel && W7NavPaneImageIsOurs(ours))
    #expect(cell.imageView?.contentTintColor == nil)
    W7NavPaneRefreshCell(cell)                  // nothing to do the second time
    #expect(cell.imageView?.image === ours)

    w.appearance = NSAppearance(named: .darkAqua)
    let updates = fake.updates
    W7NavPaneRefreshCell(cell)
    #expect(fake.updates == updates + 1)
    #expect(cell.imageView?.image === fake.sentinel)
    #expect(cell.imageView?.contentTintColor == .secondaryLabelColor)

    // And back to light: ours again.
    w.appearance = NSAppearance(named: .aqua)
    W7NavPaneRefreshCell(cell)
    #expect(cell.imageView?.image === ours)
}

/// Finder's rows need not be the hooked class, nor its headers table cell views with a textField
/// outlet: the styler keeps row icons by title and styles the first text field of a header.
@MainActor final class PlainSidebarSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let groups = ["Favoriler", "Konumlar"]
    let finderIcon = NSImage(size: NSSize(width: 18, height: 18))
    func kids(_ g: String) -> [String] { g == "Favoriler" ? ["Uygulamalar", "AirDrop"] : ["Macintosh HD"] }
    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? String).map { kids($0).count } ?? groups.count }
    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? String).map { kids($0)[index] } ?? groups[index] }
    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool { groups.contains(item as! String) }
    func outlineView(_ ov: NSOutlineView, isGroupItem item: Any) -> Bool { groups.contains(item as! String) }
    func outlineView(_ ov: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let title = item as! String
        if groups.contains(title) {
            let label = NSTextField(labelWithString: title)   // a bare text field, no cell view
            label.textColor = .secondaryLabelColor
            return label
        }
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        let iv = NSImageView(frame: NSRect(x: 2, y: 2, width: 18, height: 18))
        iv.image = finderIcon
        iv.contentTintColor = .controlAccentColor
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 24, y: 4, width: 150, height: 16)
        cell.addSubview(iv)
        cell.addSubview(label)
        return cell
    }
}

@MainActor @Test func stylerKeepsIconsOnPlainRowsAndStylesBareHeaders() throws {
    let source = PlainSidebarSource()
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
    let ov = NSOutlineView(frame: scroll.bounds)
    ov.style = .sourceList
    ov.headerView = nil
    let col = NSTableColumn(identifier: .init("c"))
    col.width = 190
    ov.addTableColumn(col)
    ov.outlineTableColumn = col
    ov.dataSource = source
    ov.delegate = source
    scroll.documentView = ov
    _ = NSApplication.shared
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.appearance = NSAppearance(named: .aqua)
    w.toolbar = NSToolbar(identifier: "W7NavPanePlainTestToolbar")
    w.contentView!.addSubview(scroll)
    ov.reloadData()
    source.groups.forEach { ov.expandItem($0) }
    W7ExplorerAdopt(w)
    ov.layoutSubtreeIfNeeded()
    defer { w.close() }
    // Adoption's own refresh styles the rows (the 10 Hz one is a dispatch_after that can't run here).
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

    /// The row whose text field reads `title` (a header's may carry the icon attachment in front).
    func row(_ title: String) -> NSTableRowView? {
        (0..<ov.numberOfRows).compactMap { ov.rowView(atRow: $0, makeIfNecessary: false) }.first { rv in
            rv.subviews.contains { v in
                (v as? NSTextField)?.stringValue.hasSuffix(title) == true || v.subviews.contains { ($0 as? NSTextField)?.stringValue == title }
            }
        }
    }
    func icon(_ title: String) -> NSImageView? { row(title)?.subviews.flatMap(\.subviews).compactMap { $0 as? NSImageView }.first }

    let apps = try #require(icon("Uygulamalar"))
    #expect(W7NavPaneImageIsOurs(apps.image) && apps.contentTintColor == nil)
    #expect(W7NavPaneImageIsOurs(icon("Macintosh HD")?.image))
    #expect(icon("AirDrop")?.image === source.finderIcon)          // no Windows 7 icon: Finder's kept
    let header = try #require(row("Favoriler")?.subviews.compactMap { $0 as? NSTextField }.first)
    #expect(header.attributedStringValue.string == "\u{FFFC} Favoriler")
    #expect(header.textColor == .black)

    // Dark: Finder's icon and tint come back. (The styler's 0.2 s keeper pass calls exactly this per row;
    // its dispatch_after refresh can't run inside a main-actor test, so the row step is called directly.)
    w.appearance = NSAppearance(named: .darkAqua)
    #expect(!W7NavPaneTreeActive(apps))
    #expect(W7NavPaneSyncRowIcon(apps, apps.superview, "Uygulamalar"))
    #expect(apps.image === source.finderIcon)
    #expect(apps.contentTintColor == .controlAccentColor)
    #expect(!W7NavPaneSyncRowIcon(apps, apps.superview, "Uygulamalar"))   // nothing more to do
    w.appearance = NSAppearance(named: .aqua)
    #expect(W7NavPaneSyncRowIcon(apps, apps.superview, "Uygulamalar") && W7NavPaneImageIsOurs(apps.image))
}

// MARK: - Keeper cost, title fallback scope

/// A node with a real path that has no Windows 7 icon keeps Finder's, whatever its title says.
@MainActor @Test func titleFallbackOnlyWithoutAPath() {
    let fake = FakeCellClass()
    #expect(W7NavPaneHookCellClass(fake.cls, FakeNavNode.finderClass))
    let real = fake.make(nodeObject: FakeNavNode(FileManager.default.temporaryDirectory), title: "Uygulamalar")
    let viaOriginal = fake.make(nodeObject: FakeNavNode(nil, original: FakeNavNode(FileManager.default.temporaryDirectory)),
                                title: "Uygulamalar")
    let pathless = fake.make(nodeObject: FakeNavNode(nil), title: "Uygulamalar")
    let w = host(real)
    defer { w.close() }
    #expect(W7NavPaneCellIconName(real) == nil)
    #expect(W7NavPaneCellIconName(viaOriginal) == nil)
    #expect(W7NavPaneCellIconName(pathless) == "applications")
}

/// The periodic keeper looks only at rows whose cell is not hooked, and not at all with the kill switch
/// on or in a dark appearance.
@MainActor @Test func keeperSkipsHookedCellsAndStopsWhenTheTreeLookIsOff() throws {
    func outline(_ source: NSObject & NSOutlineViewDataSource & NSOutlineViewDelegate, groups: [String]) -> (NSWindow, NSOutlineView) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let ov = NSOutlineView(frame: scroll.bounds)
        ov.style = .sourceList
        ov.headerView = nil
        let col = NSTableColumn(identifier: .init("c"))
        col.width = 190
        ov.addTableColumn(col)
        ov.outlineTableColumn = col
        ov.dataSource = source
        ov.delegate = source
        scroll.documentView = ov
        let w = host(scroll)
        ov.reloadData()
        for r in (0..<ov.numberOfRows).reversed() where groups.contains(ov.item(atRow: r) as? String ?? "") { ov.expandItem(ov.item(atRow: r)) }
        ov.layoutSubtreeIfNeeded()
        return (w, ov)
    }
    let plainSource = PlainSidebarSource()
    let (pw, plain) = outline(plainSource, groups: plainSource.groups)
    defer { pw.close() }
    #expect(plain.numberOfRows == 5)
    #expect(W7NavPaneKeepRowIcons(plain) == 3)       // Uygulamalar, AirDrop, Macintosh HD

    let fake = FakeCellClass()
    #expect(W7NavPaneHookCellClass(fake.cls, FakeNavNode.finderClass))
    let hookedSource = FakeSidebarSource { fake.make(title: $0) }
    let (hw, hooked) = outline(hookedSource, groups: hookedSource.groups)
    defer { hw.close() }
    #expect(hooked.numberOfRows == 5)
    #expect(W7NavPaneKeepRowIcons(hooked) == 0)      // the -image hook looks after those

    W7NavPaneUseTreeDisabled(true)                    // the kill switch
    #expect(!W7NavPaneTreeActive(plain))
    #expect(W7NavPaneKeepRowIcons(plain) == 0)
    W7NavPaneUseTreeDisabled(nil)
    #expect(W7NavPaneTreeActive(plain))
    pw.appearance = NSAppearance(named: .darkAqua)
    #expect(W7NavPaneKeepRowIcons(plain) == 0)
    #expect(W7NavPaneKeepRowIcons(nil) == 0)
}

// MARK: - Trash watch, quiet diagnostics, end-to-end dark restore

extension FolderIconHookTests {
    /// Putting something in the Trash fires its vnode source: the Recycle Bin row shows the full bin at
    /// once, without the TTL running out (the clock is frozen) and without another -image call.
    @MainActor @Test func trashChangeRefreshesTheRecycleBinRow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("w7trashwatch-\(UUID().uuidString)")
        let icons = root.appendingPathComponent("icons"), trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try pngData(64, red: 0.5).write(to: icons.appendingPathComponent("recycle-bin-empty.png"))
        try pngData(64, red: 0.25).write(to: icons.appendingPathComponent("recycle-bin-full.png"))
        W7FolderIconUseAssetRoot(root.path)
        defer { W7FolderIconUseAssetRoot(nil) }
        W7NavPaneUseTrashDirectory(trash.path)
        defer { W7NavPaneUseTrashDirectory(nil) }
        W7NavPaneUseClock { 5000 }   // the TTL never runs out: only the watch can tell
        defer { W7NavPaneUseClock(nil) }

        let fake = FakeCellClass()
        #expect(W7NavPaneHookCellClass(fake.cls, FakeNavNode.finderClass))
        let cell = fake.make(nodeObject: FakeNavNode(nil), title: "Çöp Sepeti")
        let w = host(cell)
        defer { w.close() }
        #expect(W7NavPaneCellIconName(cell) == "recycle-bin")
        W7NavPaneRefreshCell(cell)
        let iv = try #require(cell.imageView)
        let emptyRed = centre(try #require(iv.image), scale: 1).0
        #expect(emptyRed > 110, "empty bin \(emptyRed)")

        let imageCalls = W7NavPaneHookCallCount(.image), fires = W7NavPaneTrashWatchFireCount()
        FileManager.default.createFile(atPath: trash.appendingPathComponent("old.txt").path, contents: Data())
        let deadline = Date(timeIntervalSinceNow: 3)
        while W7NavPaneTrashWatchFireCount() == fires && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        #expect(W7NavPaneTrashWatchFireCount() > fires)
        let fullRed = centre(try #require(iv.image), scale: 1).0
        #expect(fullRed < 110, "full bin \(fullRed)")
        #expect(W7NavPaneHookCallCount(.image) == imageCalls)
    }
}

/// Without W7ExplorerNavPaneDiagnostics nothing is logged: hooks, node lookups, the styler and the
/// keeper all run without writing a diagnostics line.
@MainActor @Test func diagnosticsStayQuietWithoutTheKey() {
    W7NavPaneUseDiagnosticsEnabled(nil)
    #expect(!W7NavPaneDiagnosticsEnabled())   // the test process has no such default
    let lines = W7NavPaneDiagnosticLineCount()
    let fake = FakeCellClass()
    #expect(W7NavPaneHookCellClass(fake.cls, FakeNavNode.finderClass))
    let cells = [fake.make(node: URL(fileURLWithPath: home)), fake.make(nodeObject: FakeNavNode(nil), title: "Ağ"),
                 fake.make(node: FileManager.default.temporaryDirectory)]
    let w = host(cells[0])
    defer { w.close() }
    for cell in cells {
        w.contentView!.addSubview(cell)
        _ = callImage(cell)
        _ = callSize(cell)
        _ = callText(cell)
        W7NavPaneRefreshCell(cell)
    }
    #expect(W7NavPaneDiagnosticLineCount() == lines)
    W7NavPaneUseDiagnosticsEnabled(true)
    #expect(W7NavPaneDiagnosticsEnabled())
    W7NavPaneUseDiagnosticsEnabled(nil)
}

/// Light → dark end to end for a row the hooks don't cover: the styler's refresh sees the tree look
/// change (w7RowsChanged), restyles the rows (w7StyleRows) and gives Finder's icon and tint back.
@MainActor @Test func darkSwitchRestoresUnhookedRowsThroughTheStyler() throws {
    let source = PlainSidebarSource()
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
    let ov = NSOutlineView(frame: scroll.bounds)
    ov.style = .sourceList
    ov.headerView = nil
    let col = NSTableColumn(identifier: .init("c"))
    col.width = 190
    ov.addTableColumn(col)
    ov.outlineTableColumn = col
    ov.dataSource = source
    ov.delegate = source
    scroll.documentView = ov
    _ = NSApplication.shared
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.appearance = NSAppearance(named: .aqua)
    w.toolbar = NSToolbar(identifier: "W7NavPaneDarkE2EToolbar")
    w.contentView!.addSubview(scroll)
    ov.reloadData()
    source.groups.forEach { ov.expandItem($0) }
    W7ExplorerAdopt(w)
    ov.layoutSubtreeIfNeeded()
    defer { w.close() }
    W7NavPaneRefreshStylerForWindow(w)

    let rows = (0..<ov.numberOfRows).compactMap { ov.rowView(atRow: $0, makeIfNecessary: false) }
    let apps = try #require(rows.lazy.flatMap { $0.subviews.flatMap(\.subviews) }.compactMap { $0 as? NSImageView }.first {
        ($0.superview?.subviews.compactMap { $0 as? NSTextField }.first?.stringValue) == "Uygulamalar"
    })
    #expect(W7NavPaneImageIsOurs(apps.image))

    w.appearance = NSAppearance(named: .darkAqua)
    W7NavPaneRefreshStylerForWindow(w)
    #expect(apps.image === source.finderIcon)
    #expect(apps.contentTintColor == .controlAccentColor)

    w.appearance = NSAppearance(named: .aqua)
    W7NavPaneRefreshStylerForWindow(w)
    #expect(W7NavPaneImageIsOurs(apps.image))
}
