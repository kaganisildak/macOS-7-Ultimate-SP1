import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Win7Core

// Synthetic icon bytes, built here: no real Windows files are involved.

private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
private func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16((v >> 16) & 0xFFFF) }

/// Builds an icon/cursor file with a single entry. `a`/`b` are planes/bitCount (.ico) or hotspot x/y (.cur).
private func singleEntry(type: Int, width: Int, height: Int, a: Int, b: Int, payload: [UInt8]) -> Data {
    var d = le16(0) + le16(type) + le16(1)
    d += [UInt8(width & 0xFF), UInt8(height & 0xFF), 0, 0] + le16(a) + le16(b) + le32(payload.count) + le32(22)
    return Data(d + payload)
}

/// A BITMAPINFOHEADER DIB. `pixels` are rows top to bottom, each pixel (b, g, r, a); written bottom-up.
private func dib(width: Int, height: Int, bpp: Int, pixels: [[UInt8]], maskBits: [Bool]? = nil) -> [UInt8] {
    var out = le32(40) + le32(width) + le32(height * 2) + le16(1) + le16(bpp) + le32(0) + le32(0)
        + le32(0) + le32(0) + le32(0) + le32(0)
    let bytesPP = bpp / 8
    let rowBytes = (width * bytesPP + 3) / 4 * 4
    for y in stride(from: height - 1, through: 0, by: -1) {
        var row: [UInt8] = []
        for x in 0..<width {
            let p = pixels[y * width + x]
            row += bpp == 32 ? p : Array(p[0..<3])
        }
        out += row + [UInt8](repeating: 0, count: rowBytes - row.count)
    }
    let maskRow = (width + 31) / 32 * 4
    for y in stride(from: height - 1, through: 0, by: -1) {
        var row = [UInt8](repeating: 0, count: maskRow)
        for x in 0..<width where maskBits?[y * width + x] == true { row[x / 8] |= UInt8(0x80 >> (x % 8)) }
        out += row
    }
    return out
}

private func pngBytes(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

/// Decodes PNG data to RGBA (premultiplied) and returns size and the pixel at (x, y), y from the top.
private func decode(_ png: Data, x: Int = 0, y: Int = 0) -> (w: Int, h: Int, rgba: [UInt8])? {
    guard let src = CGImageSourceCreateWithData(png as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
    let ctx = CGContext(data: &buf, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let o = (y * img.width + x) * 4
    return (img.width, img.height, Array(buf[o..<o + 4]))
}

@Test func icoWithPNGPayload() throws {
    let file = singleEntry(type: 1, width: 16, height: 16, a: 1, b: 32, payload: [UInt8](pngBytes(size: 16)))
    let images = try IconFile.parse(file)
    #expect(images.count == 1)
    #expect(images[0].width == 16 && images[0].height == 16)
    #expect(images[0].hotspot == nil)
    let d = decode(images[0].pngData)
    #expect(d?.w == 16 && d?.h == 16)
}

@Test func curWithDIBAndHotspot() throws {
    var px = [[UInt8]](repeating: [0, 0, 255, 255], count: 32 * 32)  // red
    px[0] = [10, 200, 30, 255]                                       // top-left: b=10 g=200 r=30
    let file = singleEntry(type: 2, width: 32, height: 32, a: 5, b: 7,
                           payload: dib(width: 32, height: 32, bpp: 32, pixels: px))
    let images = try IconFile.parse(file)
    #expect(images.count == 1)
    #expect(images[0].hotspot == CGPoint(x: 5, y: 7))
    let d = decode(images[0].pngData)
    #expect(d?.w == 32 && d?.h == 32)
    #expect(d?.rgba == [30, 200, 10, 255])
}

@Test func andMaskMakesPixelTransparent() throws {
    let px = [[UInt8]](repeating: [255, 0, 0, 0], count: 8 * 8)  // blue, 24-bpp
    var mask = [Bool](repeating: false, count: 64)
    mask[1] = true  // (1, 0)
    let file = singleEntry(type: 1, width: 8, height: 8, a: 1, b: 24,
                           payload: dib(width: 8, height: 8, bpp: 24, pixels: px, maskBits: mask))
    let images = try IconFile.parse(file)
    #expect(decode(images[0].pngData, x: 1, y: 0)?.rgba[3] == 0)
    #expect(decode(images[0].pngData, x: 0, y: 0)?.rgba == [0, 0, 255, 255])
}

@Test func rejectsNonIconsAndTruncation() {
    #expect(throws: IconFileError.notAnIcon) { try IconFile.parse(Data([0, 0, 3, 0])) }
    #expect(throws: IconFileError.notAnIcon) { try IconFile.parse(Data()) }
    var two = Data(le16(0) + le16(1) + le16(2))
    two.append(contentsOf: [16, 16, 0, 0] + le16(1) + le16(32) + le32(10) + le32(38))  // only one entry present
    #expect(throws: IconFileError.truncated) { try IconFile.parse(two) }
}

@Test func truncatedDIBEntryThrows() {
    // The directory is consistent with the file, but the DIB header promises far more pixels than exist.
    let header = Array(dib(width: 32, height: 32, bpp: 32, pixels: [[UInt8]](repeating: [0, 0, 0, 255], count: 1024))[0..<44])
    let file = singleEntry(type: 1, width: 32, height: 32, a: 1, b: 32, payload: header)
    #expect(throws: IconFileError.truncated) { try IconFile.parse(file) }
}

@Test func rejectsAbsurdDimensionsAndEntryOutOfBounds() {
    var huge = dib(width: 1, height: 1, bpp: 24, pixels: [[0, 0, 0, 0]])
    huge.replaceSubrange(4..<8, with: le32(0x7FFF_FFF0))
    #expect(throws: IconFileError.self) { try IconFile.parse(singleEntry(type: 1, width: 1, height: 1, a: 1, b: 24, payload: huge)) }
    var bad = singleEntry(type: 1, width: 16, height: 16, a: 1, b: 32, payload: [1, 2, 3])
    bad.replaceSubrange(14..<18, with: le32(0x7FFF_FFFF))  // entry size beyond the file
    #expect(throws: IconFileError.truncated) { try IconFile.parse(bad) }
}

@Test func bestPicksSize() {
    func img(_ s: Int) -> IconImage { IconImage(width: s, height: s, hotspot: nil, pngData: Data()) }
    let all = [img(16), img(32), img(48)]
    #expect(IconFile.best(all, target: 32)?.width == 32)
    #expect(IconFile.best(all, target: 24)?.width == 32)
    #expect(IconFile.best(all, target: 64)?.width == 48)
    #expect(IconFile.best([], target: 32) == nil)
}

// MARK: GROUP_ICON / GROUP_CURSOR assembly (icons everywhere)

/// A GRPICONDIR (type 1) or a cursor group directory (type 2): 6-byte header, then 14-byte entries ending in the
/// image id. Icon entries: width, height, colours, reserved, planes, bit count; cursor entries: width u16,
/// height u16 (doubled), planes, bit count.
private func groupDirectory(type: Int, entries: [(size: Int, id: Int)]) -> Data {
    var d = le16(0) + le16(type) + le16(entries.count)
    for e in entries {
        if type == 1 {
            d += [UInt8(e.size & 0xFF), UInt8(e.size & 0xFF), 0, 0] + le16(1) + le16(32)
        } else {
            d += le16(e.size) + le16(e.size * 2) + le16(1) + le16(32)
        }
        d += le32(1234) + le16(e.id)
    }
    return Data(d)
}

private func solid(_ size: Int) -> [UInt8] {
    dib(width: size, height: size, bpp: 32, pixels: [[UInt8]](repeating: [0, 0, 255, 255], count: size * size))
}

@Test func groupIconAssemblesEveryImageOfTheGroup() throws {
    // 7-Zip's layout: GROUP_ICON/<group> names image ids; ICON/<id>.ico is a single-image wrapper (a DIB here),
    // and an image may also be a raw payload (a PNG here).
    let dir = groupDirectory(type: 1, entries: [(32, 7001), (64, 7002)])
    var asked: [Int] = []
    let out = try IconFile.assembleGroup(directory: dir) { id in
        asked.append(id)
        switch id {
        case 7001: return singleEntry(type: 1, width: 32, height: 32, a: 1, b: 32, payload: solid(32))
        case 7002: return pngBytes(size: 64)
        default: return nil
        }
    }
    #expect(asked == [7001, 7002])
    let images = try IconFile.parse(out)
    #expect(images.map(\.width) == [32, 64])
    #expect(IconFile.best(images, target: 1024)?.width == 64)
    #expect(images.allSatisfy { $0.hotspot == nil })
}

@Test func groupIconSkipsMissingImagesAndFailsWhenNoneIsFound() throws {
    let dir = groupDirectory(type: 1, entries: [(16, 1), (32, 2), (48, 3)])
    let out = try IconFile.assembleGroup(directory: dir) { $0 == 2 ? Data(solid(32)) : nil }
    #expect(try IconFile.parse(out).map(\.width) == [32])
    #expect(throws: IconGroupError.noImages) { try IconFile.assembleGroup(directory: dir) { _ in nil } }
    // An image over 16 MB counts as missing.
    let huge = Data(count: 16 * 1024 * 1024 + 1)
    #expect(throws: IconGroupError.noImages) { try IconFile.assembleGroup(directory: dir) { _ in huge } }
}

@Test func groupCursorKeepsTheHotspot() throws {
    let dir = groupDirectory(type: 2, entries: [(32, 7301), (32, 7302)])
    let out = try IconFile.assembleGroup(directory: dir) { id in
        switch id {
        // A .cur wrapper whose entry carries the hotspot.
        case 7301: return singleEntry(type: 2, width: 32, height: 32, a: 5, b: 7, payload: solid(32))
        // A raw CURSOR resource: a 4-byte hotspot (x, y), then the DIB.
        case 7302: return Data(le16(9) + le16(11) + solid(32))
        default: return nil
        }
    }
    let images = try IconFile.parse(out)
    #expect(images.map(\.hotspot) == [CGPoint(x: 5, y: 7), CGPoint(x: 9, y: 11)])
    #expect(images.map(\.width) == [32, 32])
}

@Test func groupDirectoryIsUntrusted() {
    #expect(throws: IconGroupError.notAGroup) { try IconFile.assembleGroup(directory: Data()) { _ in nil } }
    #expect(throws: IconGroupError.notAGroup) { try IconFile.assembleGroup(directory: Data([0, 0, 3, 0, 1, 0])) { _ in nil } }
    #expect(throws: IconGroupError.notAGroup) { try IconFile.assembleGroup(directory: Data(le16(0) + le16(1) + le16(0))) { _ in nil } }
    let tooMany = groupDirectory(type: 1, entries: Array(repeating: (32, 1), count: 65))
    #expect(throws: IconGroupError.notAGroup) { try IconFile.assembleGroup(directory: tooMany) { _ in Data(solid(32)) } }
    // The header promises two entries; only one is present.
    let short = groupDirectory(type: 1, entries: [(32, 1), (32, 2)]).prefix(6 + 14)
    #expect(throws: IconFileError.truncated) { try IconFile.assembleGroup(directory: Data(short)) { _ in Data(solid(32)) } }
}

// MARK: Colour depth before size; inverting pixels; the group's total size

/// A palette DIB (1, 4 or 8 bpp). `indices` are rows top to bottom; `mask` marks AND-mask bits (true = 1).
private func paletteDIB(width: Int, height: Int, bpp: Int, palette: [[UInt8]], indices: [Int], mask: [Bool]) -> [UInt8] {
    var out = le32(40) + le32(width) + le32(height * 2) + le16(1) + le16(bpp) + le32(0) + le32(0)
        + le32(0) + le32(0) + le32(palette.count) + le32(0)
    for p in palette { out += p }                                     // b, g, r, 0
    let rowBytes = (width * bpp + 31) / 32 * 4
    for y in stride(from: height - 1, through: 0, by: -1) {
        var row = [UInt8](repeating: 0, count: rowBytes)
        for x in 0..<width {
            let bit = x * bpp
            row[bit / 8] |= UInt8((indices[y * width + x] << (8 - bpp - bit % 8)) & 0xFF)
        }
        out += row
    }
    let maskRow = (width + 31) / 32 * 4
    for y in stride(from: height - 1, through: 0, by: -1) {
        var row = [UInt8](repeating: 0, count: maskRow)
        for x in 0..<width where mask[y * width + x] { row[x / 8] |= UInt8(0x80 >> (x % 8)) }
        out += row
    }
    return out
}

private func fourBit(_ size: Int) -> [UInt8] {
    paletteDIB(width: size, height: size, bpp: 4, palette: [[UInt8]](repeating: [0, 128, 0, 0], count: 16),
               indices: [Int](repeating: 3, count: size * size), mask: [Bool](repeating: false, count: size * size))
}

@Test func parseRecordsTheColourDepth() throws {
    let dir = groupDirectory(type: 1, entries: [(48, 1), (32, 2), (64, 3)])
    let out = try IconFile.assembleGroup(directory: dir) { id in
        switch id {
        case 1: return Data(fourBit(48))
        case 2: return Data(solid(32))
        default: return pngBytes(size: 64)
        }
    }
    let images = try IconFile.parse(out)
    #expect(images.map(\.bitsPerPixel) == [4, 32, 32])                // a PNG counts as 32
}

@Test func bestPrefersColourDepthOverSize() {
    func img(_ s: Int, _ bpp: Int) -> IconImage { IconImage(width: s, height: s, hotspot: nil, pngData: Data(), bitsPerPixel: bpp) }
    // A 48 px 4-bpp entry no longer beats a 32 px 32-bpp one, at any target.
    #expect(IconFile.best([img(48, 4), img(32, 32), img(256, 32)], target: 1024) == img(256, 32))
    #expect(IconFile.best([img(48, 4), img(32, 32)], target: 1024) == img(32, 32))
    #expect(IconFile.best([img(48, 4), img(32, 32)], target: 48) == img(32, 32))
    #expect(IconFile.best([img(48, 4), img(32, 32)], target: 16) == img(32, 32))
    // Within one depth the size rule applies; 24 beats 8 beats 4 beats 1.
    #expect(IconFile.best([img(16, 4), img(48, 4), img(32, 4)], target: 1024) == img(48, 4))
    #expect(IconFile.best([img(16, 4), img(48, 4), img(32, 4)], target: 32) == img(32, 4))
    #expect(IconFile.best([img(48, 1), img(32, 8), img(16, 24)], target: 48) == img(16, 24))
    #expect(IconFile.best([img(48, 1), img(32, 8), img(16, 4)], target: 48) == img(32, 8))
    #expect(IconFile.best([img(48, 1), img(16, 4)], target: 48) == img(16, 4))
}

@Test func invertingPixelsOfAMonochromeCursorAreOpaqueBlack() throws {
    // A 1-bpp cursor drawn entirely with inverting pixels (AND 1, XOR 1), as the I-beam in user32.dll is:
    // column 1 inverts, column 2 is plain white (AND 0, XOR 1), everything else is transparent (AND 1, XOR 0).
    let w = 8, h = 8
    var indices = [Int](repeating: 0, count: w * h), mask = [Bool](repeating: true, count: w * h)
    for y in 0..<h { indices[y * w + 1] = 1; indices[y * w + 2] = 1; mask[y * w + 2] = false }
    let cur = singleEntry(type: 2, width: w, height: h, a: 1, b: 4,
                          payload: paletteDIB(width: w, height: h, bpp: 1, palette: [[0, 0, 0, 0], [255, 255, 255, 0]],
                                              indices: indices, mask: mask))
    let images = try IconFile.parse(cur)
    #expect(images.count == 1)
    #expect(images[0].hotspot == CGPoint(x: 1, y: 4))
    #expect(images[0].bitsPerPixel == 1)
    #expect(decode(images[0].pngData, x: 1, y: 3)?.rgba == [0, 0, 0, 255])        // inverting → opaque black
    #expect(decode(images[0].pngData, x: 2, y: 3)?.rgba == [255, 255, 255, 255])  // plain white stays white
    #expect(decode(images[0].pngData, x: 0, y: 3)?.rgba[3] == 0)                  // mask only → transparent
    #expect(decode(images[0].pngData, x: 5, y: 0)?.rgba[3] == 0)
}

@Test func groupTotalIsCappedAt64MB() throws {
    // Five 15 MB images: the first four (60 MB) fit under the 64 MB total, the fifth does not.
    let dir = groupDirectory(type: 1, entries: [(32, 1), (32, 2), (32, 3), (32, 4), (32, 5)])
    let big = Data(solid(32) + [UInt8](repeating: 0, count: 15 * 1024 * 1024))
    var asked: [Int] = []
    let out = try IconFile.assembleGroup(directory: dir) { id in asked.append(id); return big }
    #expect(out.count < 64 * 1024 * 1024)
    #expect(Int(out[4]) | Int(out[5]) << 8 == 4)
    #expect(asked.count <= 5)
}
