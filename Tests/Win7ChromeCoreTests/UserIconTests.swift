import AppKit
import Foundation
import Testing
import Win7ChromeCore

// The dylib's icon loader: `<asset root>/icons/<name>.png`, then the `__w7icons`
// section `make chrome` embeds (faked here through W7UserIconsUseEmbedded: a SwiftPM test binary has no
// section), then nil. Every PNG is a coloured square made here; no real icon is read.

private func repoURL(_ path: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(path)
}

private struct RGB { let r, g, b: CGFloat }
private let red = RGB(r: 1, g: 0, b: 0)
private let blue = RGB(r: 0, g: 0, b: 1)

private func pngData(_ color: RGB, px: Int) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: color.r, green: color.g, blue: color.b, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

/// A fresh asset root with an empty `icons/` folder.
private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("w7usericons-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("icons"), withIntermediateDirectories: true)
    return root
}

private func iconURL(_ root: URL, _ file: String) -> URL {
    root.appendingPathComponent("icons").appendingPathComponent(file)
}

private func writePNG(_ root: URL, _ name: String, _ color: RGB = red, px: Int = 64) throws {
    try pngData(color, px: px).write(to: iconURL(root, name + ".png"))
}

/// The centre pixel of `image`'s representation `px` wide, as 0...255 components.
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

@Suite(.serialized) struct UserIconTests {
    /// Each test starts from an empty temp asset root and no embedded icons, and restores the defaults.
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        W7UserIconsUseEmbedded([:])
        W7FolderIconUseAssetRoot(root.path)
        defer {
            W7UserIconsUseEmbedded(nil)
            W7FolderIconUseAssetRoot(nil)
        }
        try body(root)
    }

    @Test func namesMatchTheChromeNamesFile() throws {
        let text = try String(contentsOf: repoURL("scripts/chrome-icon-names.txt"), encoding: .utf8)
        #expect(W7UserIconNames() == text.split(separator: "\n").map(String.init))
    }

    @Test func fileWinsOverEmbeddedThenEmbeddedThenNil() throws {
        try withRoot { root in
            W7UserIconsUseEmbedded(["help": pngData(red, px: 64)])
            #expect(isRed(centre(W7UserIconImage("help", 16), px: 16)))       // embedded
            try writePNG(root, "help", blue)
            W7FolderIconUseAssetRoot(root.path)
            #expect(isBlue(centre(W7UserIconImage("help", 16), px: 16)))      // the file, after the reset
            #expect(W7UserIconImage("ie-home", 16) == nil)                                  // neither
        }
    }

    @Test func embeddedChangesClearTheCaches() throws {
        try withRoot { _ in
            W7UserIconsUseEmbedded(["help": pngData(red, px: 32)])
            #expect(isRed(centre(W7UserIconImage("help", 16), px: 16)))
            W7UserIconsUseEmbedded(["help": pngData(blue, px: 32)])
            #expect(isBlue(centre(W7UserIconImage("help", 16), px: 16)))
            W7UserIconsUseEmbedded([:])
            #expect(W7UserIconImage("help", 16) == nil)
        }
    }

    @Test func representationsAre1xAnd2x() throws {
        try withRoot { root in
            try writePNG(root, "help", px: 256)
            let image = try #require(W7UserIconImage("help", 16))
            #expect(image.size == NSSize(width: 16, height: 16))
            #expect(image.representations.map { $0.pixelsWide } == [16, 32])
            #expect(image.representations.allSatisfy { $0.size == NSSize(width: 16, height: 16) })
            #expect(isRed(centre(image, px: 32)))
            // The same object every time (cached per name and size).
            #expect(W7UserIconImage("help", 16) === image)
            #expect(W7UserIconImage("help", 24) !== image)
        }
    }

    @Test func nonSquareSourcesAreAspectFit() throws {
        try withRoot { root in
            let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            try NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
                .write(to: iconURL(root, "help.png"))
            let bitmap = try #require(W7UserIconBitmap("help", 32))
            let image = bitmap as! CGImage
            #expect(image.width == 32 && image.height == 32)
            let rep = NSBitmapImageRep(cgImage: image)
            #expect(isRed(rep.colorAt(x: 16, y: 16).flatMap { c in
                c.usingColorSpace(.sRGB).map { (Int($0.redComponent * 255 + 0.5), Int($0.greenComponent * 255 + 0.5),
                                                Int($0.blueComponent * 255 + 0.5), Int($0.alphaComponent * 255 + 0.5)) }
            }))
            // Top and bottom quarters are left clear (64×32 fit into 32×32 is 32×16, centred).
            #expect((rep.colorAt(x: 16, y: 2)?.alphaComponent ?? 1) < 0.05)
            #expect((rep.colorAt(x: 16, y: 29)?.alphaComponent ?? 1) < 0.05)
        }
    }

    @Test func badSizesAndNamesGiveNil() throws {
        try withRoot { root in
            try writePNG(root, "help")
            #expect(W7UserIconImage("help", 0) == nil)
            #expect(W7UserIconImage("help", -16) == nil)
            #expect(W7UserIconImage("help", 513) == nil)
            #expect(W7UserIconImage("help", .nan) == nil)
            #expect(W7UserIconBitmap("help", 0) == nil)
            #expect(W7UserIconBitmap("help", 1025) == nil)
            #expect(W7UserIconImage("", 16) == nil)
            // A name is a plain file name, never a path.
            try writePNG(root, ".hidden")
            for name in ["../icons/help", "icons/help", ".hidden", "-help", "help/"] {
                #expect(W7UserIconImage(name, 16) == nil, "\(name)")
            }
            #expect(W7UserIconImage("help", 16) != nil)
        }
    }

    @Test func hostileFilesCountAsAbsent() throws {
        try withRoot { root in
            try Data(repeating: 0, count: 2_100_000).write(to: iconURL(root, "msgbox-info.png"))   // over 2 MB
            try writePNG(root, "ie-print", px: 1100)                                                // over 1024 px
            try FileManager.default.createSymbolicLink(atPath: iconURL(root, "ie-page.png").path, withDestinationPath: "/etc/hosts")
            // A symlink to a valid PNG out of the folder is refused too.
            let outside = root.appendingPathComponent("outside.png")
            try pngData(red, px: 32).write(to: outside)
            try FileManager.default.createSymbolicLink(atPath: iconURL(root, "ie-home.png").path, withDestinationPath: outside.path)
            try Data("not a png at all".utf8).write(to: iconURL(root, "ie-help.png"))               // not a PNG
            let png = pngData(red, px: 64)
            try png.prefix(png.count / 2).write(to: iconURL(root, "favorites.png"))                 // truncated
            try Data().write(to: iconURL(root, "file.png"))                                         // empty
            try FileManager.default.createDirectory(at: iconURL(root, "folder.png"), withIntermediateDirectories: true)  // a folder
            #expect(mkfifo(iconURL(root, "network.png").path, 0o600) == 0)                         // a FIFO must not stall
            for n in ["msgbox-info", "ie-print", "ie-page", "ie-home", "ie-help", "file", "folder", "network"] {
                #expect(W7UserIconImage(n, 16) == nil, "\(n)")
                #expect(W7UserIconBitmap(n, 16) == nil, "\(n)")
            }
            // A truncated PNG never crashes; it shows nothing or what decoded.
            _ = W7UserIconImage("favorites", 16)
        }
    }

    @Test func aHostileFileFallsBackToTheEmbeddedIcon() throws {
        try withRoot { root in
            try Data("garbage".utf8).write(to: iconURL(root, "help.png"))
            W7UserIconsUseEmbedded(["help": pngData(red, px: 32), "ie-print": pngData(red, px: 1100)])
            #expect(isRed(centre(W7UserIconImage("help", 16), px: 16)))
            #expect(W7UserIconImage("ie-print", 16) == nil)   // the pixel cap applies to embedded data too
        }
    }

    @Test func decodesOnceAndCachesAbsence() throws {
        try withRoot { root in
            try writePNG(root, "help")
            let before = W7UserIconDecodeCount()
            _ = W7UserIconImage("help", 16)
            _ = W7UserIconImage("help", 32)
            _ = W7UserIconBitmap("help", 48)
            _ = W7UserIconImage("nope", 16)
            _ = W7UserIconImage("nope", 16)
            #expect(W7UserIconDecodeCount() - before == 1)
            // An absent icon stays absent until the asset root is set again, even once the file appears.
            try writePNG(root, "nope")
            #expect(W7UserIconImage("nope", 16) == nil)
            W7FolderIconUseAssetRoot(root.path)
            #expect(W7UserIconImage("nope", 16) != nil)
        }
    }

    @Test func plistDecoderDropsUnsafeEntries() throws {
        let png = pngData(red, px: 16)
        let entries: [String: Any] = ["help": png, "../x": png, ".hidden": png, "a/b": png, "": png,
                                      "big": Data(count: 600_000), "empty": Data(), "num": 5]
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        #expect(Array(W7UserIconsFromPlistData(data).keys) == ["help"])
        let xml = try PropertyListSerialization.data(fromPropertyList: ["app-com.apple.Safari": png], format: .xml, options: 0)
        #expect(Array(W7UserIconsFromPlistData(xml).keys) == ["app-com.apple.Safari"])
        #expect(W7UserIconsFromPlistData(Data()).isEmpty)
        #expect(W7UserIconsFromPlistData(Data("garbage".utf8)).isEmpty)
        let array = try PropertyListSerialization.data(fromPropertyList: [png], format: .binary, options: 0)
        #expect(W7UserIconsFromPlistData(array).isEmpty)
    }

    @Test func concurrentReadsAndResetsAreSafe() throws {
        try withRoot { root in
            try writePNG(root, "help", px: 128)
            W7UserIconsUseEmbedded(["ie-home": pngData(blue, px: 32)])
            DispatchQueue.concurrentPerform(iterations: 64) { i in
                if i % 16 == 0 { W7FolderIconUseAssetRoot(root.path) }
                let image = W7UserIconImage(i % 2 == 0 ? "help" : "ie-home", CGFloat(16 + i % 3 * 8))
                #expect(image != nil)
            }
        }
    }
}
