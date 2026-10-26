import AppKit
import Foundation
import Testing
import Win7ChromeCore

// (plan "icons everywhere" ): the decorated app's own icon from the user's `app-<bundle id>.png` (the
// asset file, else the `__w7icons` section, which sandboxed apps rely on). The test process's own application icon is
// never changed: the install step is not run here, only its decision and the image it would apply. Every PNG is a
// coloured square made here.

private func squarePNG(px: Int, r: CGFloat, g: CGFloat, b: CGFloat) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

@Suite(.serialized) struct AppIconTests {
    private func withIcons(files: [String: Data] = [:], embedded: [String: Data] = [:], _ body: () throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("w7appicon-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("icons"), withIntermediateDirectories: true)
        for (name, png) in files { try? png.write(to: root.appendingPathComponent("icons/\(name).png")) }
        W7UserIconsUseEmbedded(embedded)
        W7FolderIconUseAssetRoot(root.path)
        defer {
            W7UserIconsUseEmbedded(nil)
            W7FolderIconUseAssetRoot(nil)
            try? FileManager.default.removeItem(at: root)
        }
        try body()
    }

    @Test func appIconDecision() {
        #expect(W7AppIconOverrideShouldApply("com.apple.TextEdit", false))
        #expect(!W7AppIconOverrideShouldApply("com.apple.TextEdit", true))   // W7AppIconDisabled
        #expect(!W7AppIconOverrideShouldApply("../x", false))
        #expect(!W7AppIconOverrideShouldApply("", false))
        #expect(!W7AppIconOverrideShouldApply(nil, false))
        #expect(!W7AppIconOverrideShouldApply("com.win7mac.shell", false))   // never the shell itself
    }

    /// Only an `.app` process looks its icon up; an extension, an XPC service or a view
    /// service (which may share an app's bundle id prefix) never does.
    @Test func appIconOnlyForAppBundles() {
        #expect(W7AppIconOverrideAppliesToProcess("com.apple.TextEdit", "/System/Applications/TextEdit.app"))
        #expect(W7AppIconOverrideAppliesToProcess("com.apple.Safari", "/Applications/Safari.APP"))
        #expect(!W7AppIconOverrideAppliesToProcess("com.apple.Safari.SafeBrowsing",
                                                  "/Applications/Safari.app/Contents/PlugIns/SafeBrowsing.appex"))
        #expect(!W7AppIconOverrideAppliesToProcess("com.apple.TextEdit.service",
                                                  "/System/Library/Frameworks/X.framework/XPCServices/Service.xpc"))
        #expect(!W7AppIconOverrideAppliesToProcess("com.apple.TextEdit", nil))
        #expect(!W7AppIconOverrideAppliesToProcess("com.apple.TextEdit", "/usr/bin"))
        #expect(!W7AppIconOverrideAppliesToProcess("com.win7mac.shell", "/Users/x/Applications/Win7Shell.app"))
        #expect(!W7AppIconOverrideAppliesToProcess(nil, "/Applications/Safari.app"))
        #expect(!W7AppIconOverrideAppliesToProcess("../x", "/Applications/X.app"))
    }

    @Test func appIconName() {
        #expect(W7AppIconOverrideName("com.apple.TextEdit") == "app-com.apple.TextEdit")
        #expect(W7AppIconOverrideName("com.apple.calculator") == "app-com.apple.calculator")
        #expect(W7AppIconOverrideName(".hidden") == nil)
        #expect(W7AppIconOverrideName("a/b") == nil)
        #expect(W7AppIconOverrideName("com.ex ample") == nil)
        #expect(W7AppIconOverrideName(nil) == nil)
        for id in ["com.apple.Safari", "com.apple.TextEdit", "com.apple.finder", "com.apple.Music", "com.apple.Terminal",
                   "com.apple.ActivityMonitor", "com.apple.systempreferences", "com.apple.calculator", "com.apple.Preview"] {
            #expect(W7UserIconNames().contains(W7AppIconOverrideName(id) ?? ""), "\(id) is in the chrome catalogue")
        }
    }

    /// 128 pt with 1x and 2x bitmaps, a new image (never the loader's shared one); nil when disabled or absent; the
    /// embedded section serves sandboxed apps.
    @Test func appIconImageFromTheUserSet() throws {
        try withIcons(files: ["app-com.apple.TextEdit": squarePNG(px: 256, r: 0, g: 1, b: 0)]) {
            let image = try #require(W7AppIconOverrideImage("com.apple.TextEdit", false))
            #expect(image.size == NSSize(width: 128, height: 128))
            #expect(image.representations.map(\.pixelsWide).sorted() == [128, 256])
            #expect(image !== W7UserIconImage("app-com.apple.TextEdit", 128))
            #expect(W7AppIconOverrideImage("com.apple.TextEdit", true) == nil)
            #expect(W7AppIconOverrideImage("com.apple.Notes", false) == nil)   // no icon on this media: AppKit's stays
            #expect(W7AppIconOverrideImage("com.win7mac.shell", false) == nil)
        }
        try withIcons(embedded: ["app-com.apple.Safari": squarePNG(px: 128, r: 0, g: 0, b: 1)]) {
            let image = try #require(W7AppIconOverrideImage("com.apple.Safari", false))
            #expect(image.size == NSSize(width: 128, height: 128))
        }
    }

    @Test func nothingAppliedInTheTestProcess() {
        #expect(W7AppIconOverrideAppliedImage() == nil)   // the install step never ran here
    }
}
