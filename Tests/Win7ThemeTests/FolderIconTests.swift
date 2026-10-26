import Testing
import AppKit
import Win7Theme

/// The icon decoded through `render` (sRGB, un-premultiplied, origin bottom-left) and its pixel size.
private func folder(_ kind: W7FolderIconKind, _ points: CGFloat, scale: CGFloat = 1) -> (px: (Int, Int) -> Pixel, w: Int, h: Int) {
    let img = W7CreateFolderIconImage(kind, points, scale)!
    let w = img.width, h = img.height
    return (render(width: w, height: h) { $0.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)) }, w, h)
}

private func count(_ f: (px: (Int, Int) -> Pixel, w: Int, h: Int), _ test: (Pixel) -> Bool) -> Int {
    var n = 0
    for y in 0..<f.h { for x in 0..<f.w where test(f.px(x, y)) { n += 1 } }
    return n
}

/// Manila: an opaque warm yellow (red high, blue well below green).
private func manila(_ p: Pixel) -> Bool { p.a > 200 && p.r > 200 && p.g > 150 && p.b < 170 && p.r > p.b + 70 }
private func blue(_ p: Pixel) -> Bool { p.a > 160 && p.b > 140 && p.b > p.r + 50 && p.b > p.g + 15 }
private func green(_ p: Pixel) -> Bool { p.a > 160 && p.g > 110 && p.g > p.r + 40 && p.g > p.b + 40 }

private let allKinds: [W7FolderIconKind] = [.plain, .documents, .pictures, .music, .videos, .downloads, .desktop, .user]

@Suite struct FolderIconTests {
    @Test func dimensionsArePointsTimesScale() {
        for (points, scale) in [(16.0, 1.0), (16.0, 2.0), (48.0, 2.0), (256.0, 1.0), (37.0, 2.0)] {
            let img = W7CreateFolderIconImage(.plain, CGFloat(points), CGFloat(scale))!
            #expect(img.width == Int(points * scale) && img.height == Int(points * scale), "\(points)@\(scale)")
        }
        #expect(W7CreateFolderIconImage(.plain, 0, 2) == nil)
        #expect(W7FolderIconKindCount == allKinds.count)
    }

    /// The middle of the front panel is manila at every size class (closed flat, closed with papers, open).
    @Test(arguments: [16.0, 32.0, 48.0, 256.0])
    func plainFrontPanelIsManila(points: Double) {
        let f = folder(.plain, CGFloat(points), scale: 2)
        let p = f.px(f.w / 2, f.h * 33 / 100)
        #expect(manila(p), "\(points) pt: \(p)")
    }

    /// The tab sits top-left: above the front panel on the left there is folder, on the right there is not.
    @Test func tabIsTopLeft() {
        let f = folder(.plain, 48, scale: 2)
        let y = f.h * 89 / 100
        #expect(f.px(f.w * 20 / 100, y).a > 200)
        #expect(f.px(f.w * 80 / 100, y).a < 60)
    }

    /// From 32 pt the paper sheets show above the front panel; at 16 pt the folder is closed and plain.
    @Test func papersPeekOutFromMediumSizes() {
        func paper(_ p: Pixel) -> Bool { p.a > 200 && p.r > 225 && p.g > 220 && p.b > 200 }
        let small = folder(.plain, 16, scale: 1), large = folder(.plain, 256, scale: 1), medium = folder(.plain, 32, scale: 2)
        #expect(count(small, paper) == 0)
        #expect(count(medium, paper) > 20)
        #expect(count(large, paper) > 500)
    }

    /// A plain folder has no blue or green; documents (blue lines), music (blue note) and downloads
    /// (green arrow) carry their emblem colour on the front panel.
    @Test(arguments: [16.0, 48.0, 256.0])
    func emblemColours(points: Double) {
        let pts = CGFloat(points)
        let plain = folder(.plain, pts, scale: 2)
        #expect(count(plain, blue) == 0 && count(plain, green) == 0)
        let minimum = Int(points * points) * 4 / 400   // at least 1% of the pixels
        #expect(count(folder(.documents, pts, scale: 2), blue) >= minimum, "documents \(points)")
        #expect(count(folder(.music, pts, scale: 2), blue) >= minimum, "music \(points)")
        #expect(count(folder(.downloads, pts, scale: 2), green) >= minimum, "downloads \(points)")
    }

    /// Every kind draws a folder (manila present) and the special kinds differ from the plain one.
    @Test func everyKindDrawsAndSpecialsDiffer() {
        let plain = folder(.plain, 48, scale: 1)
        for kind in allKinds {
            let f = folder(kind, 48, scale: 1)
            #expect(count(f, manila) > 200, "\(kind.rawValue) manila")
            guard kind != .plain else { continue }
            var differing = 0
            for y in 0..<f.h { for x in 0..<f.w where f.px(x, y) != plain.px(x, y) { differing += 1 } }
            #expect(differing > 40, "\(kind.rawValue) emblem")
        }
    }

    /// Transparent corners: the icon is a shape, not a filled square.
    @Test func cornersAreTransparent() {
        for points in [16.0, 48.0, 256.0] {
            let f = folder(.plain, CGFloat(points), scale: 1)
            #expect(f.px(f.w - 1, f.h - 1).a == 0 && f.px(0, f.h - 1).a < 40, "\(points)")
        }
    }
}
