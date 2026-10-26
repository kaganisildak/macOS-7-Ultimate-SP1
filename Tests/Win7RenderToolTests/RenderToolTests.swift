import AppKit
import Testing
@testable import Win7RenderTool

/// Every component the fidelity gallery shows is rendered, at 2×, and has visible pixels.
@MainActor @Test func rendersEveryComponent() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("w7render-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let files = try Renderer.renderAll(to: dir)
    let expected = ["taskbar-800x40", "titlebar-active-600x30", "titlebar-inactive-600x30",
                    "caption-min-normal", "caption-min-hover", "caption-min-pressed",
                    "caption-max-normal", "caption-max-hover", "caption-max-pressed",
                    "caption-close-normal", "caption-close-hover", "caption-close-pressed",
                    "menu-popup", "menustrip-600x20", "startmenu-400x535",
                    "explorer-navbar-800x34", "explorer-commandbar-800x32",
                    "ie-tabrow-600x30", "ie-navorbs-60x32", "ie-statusbar-600x22", "snap-preview-300x200", "wallpaper-640x400",
                    "wallpaper-1920x1080", "wallpaper-2880x1800"]
        + ["plain", "documents", "pictures", "music", "videos", "downloads", "desktop", "user"].flatMap { kind in
            [16, 48, 256].map { "folder-\(kind)-\($0)" }
        }
        + ["frame-active-416x268", "frame-inactive-416x268", "messagebox", "controls2-360x220"]
        + ["frame-corners-4x"]
        + ["pushbutton-normal", "pushbutton-hover", "pushbutton-pressed", "pushbutton-default", "pushbutton-disabled",
           "checkbox-off", "checkbox-on", "checkbox-mixed", "checkbox-hover", "checkbox-pressed", "checkbox-disabled",
           "radio-off", "radio-on", "radio-hover", "radio-pressed", "radio-disabled",
           "scrollbar-vertical-normal", "scrollbar-vertical-hover", "scrollbar-vertical-pressed",
           "scrollbar-horizontal"]
    #expect(files.map { $0.deletingPathExtension().lastPathComponent } == expected)
    for (url, c) in zip(files, Renderer.components) {
        let px = try pixels(Data(contentsOf: url))
        #expect(px.width == Int(c.size.width) * 2 && px.height == Int(c.size.height) * 2, "\(c.name) size")
        var opaque = 0
        for y in stride(from: 0, to: px.height, by: max(1, px.height / 20)) {
            for x in stride(from: 0, to: px.width, by: max(1, px.width / 40)) where px.at(x, y).a > 12 { opaque += 1 }
        }
        #expect(opaque > 0, "\(c.name) is fully transparent")
    }
}

/// The 4× corner tile: across the window's top-left corner, row by row, the glass is one tone. The
/// window's own 16 pt arc and its dark edge line (wedge path, top row) and the 6 pt one (radius path, bottom
/// row) are under the overlay, which paints the caption's own glass there.
@MainActor @Test func cornerTileShowsNoArcOrSeam() throws {
    let px = try pixels(Renderer.png(size: FrameCornersRender.cornersSize, FrameCornersRender.drawCorners))
    // drawCorners' scene: overlay (8, 8, 176, 118), window (16, 16, 160, 110); the top-left crop starts at
    // canvas (4, 106), 24 pt square, drawn 4× into the tile at (8, 8 + row × 104) pt from the top-left, at 2×.
    func at(_ cx: Double, _ cy: Double, row: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let lx = cx - 4, ly = cy - 106
        return px.at(Int((8 + lx * 4) * 2), Int((Double(row) * 104 + 8 + (24 - ly) * 4) * 2))
    }
    for row in [0, 1] {
        for cy in [112.5, 118.5, 121.5, 123.5] {
            let inside = at(27.5, cy, row: row)   // the window's caption, clear of its corner
            for cx in stride(from: 16.5, through: 27.5, by: 1) {
                let p = at(cx, cy, row: row)
                #expect(abs(p.r - inside.r) <= 2 && abs(p.g - inside.g) <= 2 && abs(p.b - inside.b) <= 2 && p.a == 255,
                        "row \(row) (\(cx), \(cy)): \(p) vs \(inside)")
            }
        }
    }
}

/// The menu render shows the six sample rows with the last one highlighted (its fill is the light
/// blue highlight, not the plain menu background).
@MainActor @Test func menuRenderHighlightsTheLastRow() throws {
    let px = try pixels(Renderer.png(size: Renderer.menuSize, Renderer.drawMenuPopup))
    let row = px.at(px.width / 2 + 40, px.height - 1 - (4 + 11) * 2)   // middle of the bottom (highlighted) row
    let plain = px.at(px.width / 2 + 40, (4 + 11) * 2)                  // the first row
    #expect(row.b > row.r + 10, "highlight \(row)")
    #expect(plain.r == 0xF0 && plain.g == 0xF0 && plain.b == 0xF0, "background \(plain)")
}

/// Decoded PNG pixels in sRGB, un-premultiplied, origin top-left.
struct Pixels {
    let width: Int, height: Int
    let data: [UInt8]
    func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let i = (y * width + x) * 4, a = Int(data[i + 3])
        func un(_ v: UInt8) -> Int { a == 0 ? 0 : min(255, Int((Double(v) * 255 / Double(a)).rounded())) }
        return (un(data[i]), un(data[i + 1]), un(data[i + 2]), a)
    }
}

func pixels(_ png: Data) throws -> Pixels {
    let src = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    var data = [UInt8](repeating: 0, count: img.width * img.height * 4)
    data.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8,
                            bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    }
    return Pixels(width: img.width, height: img.height, data: data)
}
