import Testing
import AppKit
import Win7Theme

// The Windows Live Messenger pieces Win7Theme draws for the Messages window's chrome —
// the status orbs, the pale blue header band, the picture tile (the user's picture or a drawn silhouette) and the
// header's contents (name, status line, the disabled Messenger toolbar row). No Messenger artwork exists to import.

private func near(_ p: Pixel, _ hex: UInt32, _ tolerance: Int = 6) -> Bool {
    let r = Int((hex >> 16) & 0xFF), g = Int((hex >> 8) & 0xFF), b = Int(hex & 0xFF)
    return p.a > 240 && abs(p.r - r) <= tolerance && abs(p.g - g) <= tolerance && abs(p.b - b) <= tolerance
}

/// A solid sRGB square image `px` wide.
private func solidImage(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, px: Int = 96) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
    return ctx.makeImage()!
}

private func commands(_ l: W7MessengerHeaderLayout) -> [CGRect] {
    let all = [l.commands.0, l.commands.1, l.commands.2, l.commands.3]
    return Array(all.prefix(Int(l.commandCount)))
}

/// Pixels in `rect` (inclusive of its integer grid) matching `test`.
private func count(_ px: (Int, Int) -> Pixel, _ rect: CGRect, _ test: (Pixel) -> Bool) -> Int {
    var n = 0
    for y in Int(rect.minY)..<Int(rect.maxY) { for x in Int(rect.minX)..<Int(rect.maxX) where test(px(x, y)) { n += 1 } }
    return n
}

@Suite struct MessengerDrawingTests {
    @Test func metrics() {
        #expect(W7MessengerBandHeight == 64)
        #expect(W7MessengerCompactBandHeight == 32)
        #expect(W7MessengerTileSide == 48)
        #expect(W7MessengerCompactTileSide == 24)
        #expect(W7MessengerStatusOrbSide == 12)
    }

    @Test func statusColoursAndTitles() {
        #expect(W7MessengerStatusColor(.available) == 0x5BCB3A)
        let colours = [W7MessengerStatus.available, .busy, .away, .offline].map(W7MessengerStatusColor)
        #expect(Set(colours).count == 4, "four different orbs")
        // Busy is red, away yellow, offline grey.
        let busy = W7MessengerStatusColor(.busy), away = W7MessengerStatusColor(.away), off = W7MessengerStatusColor(.offline)
        #expect(busy >> 16 > 0xC0 && (busy >> 8) & 0xFF < 0x70)
        #expect(away >> 16 > 0xC0 && (away >> 8) & 0xFF > 0xA0 && away & 0xFF < 0x70)
        #expect(off >> 16 == (off >> 8) & 0xFF && off & 0xFF == off >> 16)
        #expect(W7MessengerStatusTitle(.available) == "Available")
        #expect(W7MessengerStatusTitle(.busy) == "Busy")
        #expect(W7MessengerStatusTitle(.away) == "Away")
        #expect(W7MessengerStatusTitle(.offline) == "Appear offline")
        #expect(W7MessengerToolbarLabels() == ["Send an instant message", "Send a file", "Video call", "Add a contact"])
    }

    /// A 12 pt orb: its body in the status colour (below the gloss), a darker rim, nothing outside the circle.
    @Test func statusOrbsAreTheirColourWithADarkerRim() {
        for status in [W7MessengerStatus.available, .busy, .away, .offline] {
            let hex = W7MessengerStatusColor(status)
            let px = render(width: 24, height: 24) { W7DrawMessengerStatusOrb($0, CGRect(x: 6, y: 6, width: 12, height: 12), status) }
            #expect(near(px(12, 9), hex, 10), "\(status.rawValue) body \(px(12, 9))")
            let rim = px(6, 12)   // the left edge of the circle
            #expect(rim.a > 60 && rim.r + rim.g + rim.b < px(12, 9).r + px(12, 9).g + px(12, 9).b, "\(status.rawValue) rim \(rim)")
            #expect(px(6, 6).a == 0 && px(17, 17).a < 40 && px(2, 12).a == 0 && px(21, 12).a == 0, "a circle in its 12 pt square")
            // The gloss: the upper half is lighter than the body.
            let top = px(12, 15)
            #expect(top.r + top.g + top.b > px(12, 9).r + px(12, 9).g + px(12, 9).b, "\(status.rawValue) gloss \(top)")
        }
    }

    /// #DFEFFC at the top to #C4DDF5 at the bottom.
    @Test func bandBackgroundIsThePaleBlueGradient() {
        let px = render(width: 40, height: 64) { W7DrawMessengerBandBackground($0, CGRect(x: 0, y: 0, width: 40, height: 64)) }
        #expect(near(px(20, 63), 0xDFEFFC, 3), "top \(px(20, 63))")
        #expect(near(px(20, 0), 0xC4DDF5, 3), "bottom \(px(20, 0))")
        let mid = px(20, 32)
        #expect(mid.r < 0xDF && mid.r > 0xC4, "between \(mid)")
        #expect(px(5, 30).g == px(35, 30).g, "vertical only")
    }

    /// The tile: a pale frame with a #8EAACC border and the picture filling the inside.
    @Test func pictureTileShowsThePictureInsideAFrame() {
        let px = render(width: 48, height: 48) { W7DrawMessengerPictureTile($0, CGRect(x: 0, y: 0, width: 48, height: 48), solidImage(1, 0, 0)) }
        #expect(near(px(24, 24), 0xFF0000, 4), "picture \(px(24, 24))")
        #expect(near(px(6, 6), 0xFF0000, 4), "the picture fills the inside \(px(6, 6))")
        #expect(near(px(0, 24), 0x8EAACC, 12), "left border \(px(0, 24))")
        #expect(near(px(24, 47), 0x8EAACC, 12), "top border \(px(24, 47))")
        let pad = px(1, 24)
        #expect(pad.a > 240 && pad.r > 0xE0 && pad.g > 0xE0, "a light frame between the border and the picture \(pad)")
    }

    /// No picture: a drawn head-and-shoulders silhouette in #7F9FC7 on a pale background.
    @Test func pictureTileWithoutAPictureIsASilhouette() {
        let px = render(width: 48, height: 48) { W7DrawMessengerPictureTile($0, CGRect(x: 0, y: 0, width: 48, height: 48), nil) }
        #expect(near(px(24, 29), 0x7F9FC7, 8), "head \(px(24, 29))")
        #expect(near(px(24, 6), 0x7F9FC7, 8), "shoulders \(px(24, 6))")
        let corner = px(6, 41)
        #expect(corner.a > 240 && corner.b > 0xE8 && corner.r > 0xE0, "pale background \(corner)")
        #expect(near(px(0, 24), 0x8EAACC, 12), "the same frame")
        // Compact: the same at 24 pt.
        let small = render(width: 24, height: 24) { W7DrawMessengerPictureTile($0, CGRect(x: 0, y: 0, width: 24, height: 24), nil) }
        #expect(near(small(12, 14), 0x7F9FC7, 10), "compact head \(small(12, 14))")
    }

    // MARK: Header layout

    @Test func fullLayoutStacksNameStatusAndCommandsRightOfA48ptTile() throws {
        let content = CGRect(x: 100, y: 10, width: 900, height: 64)
        let l = W7MessengerHeaderLayoutFor(content, false, "Jordan Walker", .available)
        #expect(l.tile == CGRect(x: 108, y: 18, width: 48, height: 48))
        #expect(l.name.minX > l.tile.maxX && l.name.width > 40 && l.name.maxY <= content.maxY)
        #expect(l.orb.width == 12 && l.orb.height == 12 && l.orb.minX == l.name.minX)
        #expect(l.orb.maxY <= l.name.minY + 1, "status line under the name")
        #expect(l.status.minX > l.orb.maxX && l.status.width > 20)
        #expect(l.arrow.minX >= l.status.maxX && l.arrow.width > 0, "the ▾")
        let row = commands(l)
        #expect(row.count == 4, "all four commands fit in 900 pt")
        #expect(row.allSatisfy { $0.maxY <= l.orb.minY && $0.minY >= content.minY && $0.height == 20 }, "a row under the status line")
        for (a, b) in zip(row, row.dropFirst()) { #expect(b.minX > a.maxX) }
        #expect(row.last!.maxX <= content.maxX)
    }

    @Test func compactLayoutPutsEverythingOnOneLineRightOfA24ptTile() {
        let content = CGRect(x: 0, y: 0, width: 900, height: 32)
        let l = W7MessengerHeaderLayoutFor(content, true, "Jordan Walker", .available)
        #expect(l.tile == CGRect(x: 4, y: 4, width: 24, height: 24))
        #expect(abs(l.name.midY - 16) <= 1 && abs(l.orb.midY - 16) <= 1 && abs(l.status.midY - 16) <= 1)
        #expect(l.name.minX > l.tile.maxX && l.orb.minX > l.name.maxX && l.status.minX > l.orb.maxX)
        let row = commands(l)
        #expect(row.count >= 1 && row.first!.minX > l.arrow.maxX, "commands follow the status on the same line")
        #expect(row.allSatisfy { abs($0.midY - 16) <= 1 && $0.maxX <= content.maxX })
    }

    @Test func narrowContentDropsCommandsThenTheStatusAndNeverOverflows() {
        let name = "A Very Long Display Name That Goes On And On"
        for compact in [false, true] {
            for width in [60.0, 120, 200, 320, 480, 700] {
                let content = CGRect(x: 50, y: 0, width: width, height: compact ? 32 : 64)
                let l = W7MessengerHeaderLayoutFor(content, compact, name, .available)
                for r in [l.tile, l.name, l.orb, l.status, l.arrow] + commands(l) where !r.isEmpty {
                    #expect(r.maxX <= content.maxX + 0.01 && r.minX >= content.minX, "\(compact) \(width): \(r) in \(content)")
                }
            }
            let tiny = W7MessengerHeaderLayoutFor(CGRect(x: 0, y: 0, width: 120, height: compact ? 32 : 64), compact, name, .available)
            #expect(tiny.commandCount == 0, "no room for a command")
            if compact { #expect(tiny.status.isEmpty && tiny.orb.isEmpty, "compact: the status goes before the name does") }
        }
    }

    // MARK: Header drawing

    @Test func fullHeaderDrawsTileNameOrbAndGreyCommands() {
        let content = CGRect(x: 0, y: 0, width: 640, height: 64)
        let l = W7MessengerHeaderLayoutFor(content, false, "Jordan Walker", .available)
        let px = render(width: 640, height: 64) { W7DrawMessengerHeader($0, content, false, nil, "Jordan Walker", .available) }
        #expect(near(px(Int(l.tile.midX), Int(l.tile.minY) + 6), 0x7F9FC7, 8), "the silhouette tile")
        #expect(near(px(Int(l.orb.midX), Int(l.orb.midY) - 3), 0x5BCB3A, 12), "green orb")
        let darkBlue = count(px, l.name) { $0.a > 128 && $0.b > $0.r + 40 && $0.r < 0x60 }
        #expect(darkBlue > 30, "the name in #1C4F8C bold (\(darkBlue) px)")
        let statusBlue = count(px, l.status) { $0.a > 128 && $0.b > $0.r + 40 && $0.r < 0x70 }
        #expect(statusBlue > 10, "Available in #1C4F8C (\(statusBlue) px)")
        let first = commands(l)[0]
        let grey = count(px, first) { $0.a > 128 && abs($0.r - $0.g) < 12 && abs($0.g - $0.b) < 12 && $0.r < 0xB0 }
        #expect(grey > 20, "disabled command text is grey (\(grey) px)")
        let face = px(Int(first.minX) + 1, Int(first.midY))
        #expect(face.a == 0, "a disabled flat button has no face \(face)")
    }

    @Test func headerUsesThePictureWhenGiven() {
        let content = CGRect(x: 0, y: 0, width: 400, height: 32)
        let l = W7MessengerHeaderLayoutFor(content, true, "K", .available)
        let px = render(width: 400, height: 32) { W7DrawMessengerHeader($0, content, true, solidImage(0, 0, 1), "K", .available) }
        #expect(near(px(Int(l.tile.midX), Int(l.tile.midY)), 0x0000FF, 6), "picture \(px(Int(l.tile.midX), Int(l.tile.midY)))")
    }

    @Test func disabledCommandIsGreyTextWithoutAFace() {
        let px = render(width: 120, height: 20) { W7DrawMessengerCommand($0, CGRect(x: 0, y: 0, width: 120, height: 20), "Send a file") }
        #expect(px(1, 10).a == 0 && px(118, 10).a == 0 && px(60, 0).a == 0, "flat: no face, no border")
        let grey = count(px, CGRect(x: 0, y: 0, width: 120, height: 20)) { $0.a > 128 && abs($0.r - $0.g) < 12 && $0.r < 0xB0 }
        #expect(grey > 20)
        #expect(W7MessengerCommandWidth("Send a file") > 50 && W7MessengerCommandWidth("Send a file") < 110)
    }
}
