import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct IconImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var hotspot: CGPoint?
    public var pngData: Data
    /// The entry's colour depth: the DIB's bit count (1, 4, 8, 24 or 32); a PNG entry counts as 32.
    public var bitsPerPixel: Int

    public init(width: Int, height: Int, hotspot: CGPoint?, pngData: Data, bitsPerPixel: Int = 32) {
        self.width = width
        self.height = height
        self.hotspot = hotspot
        self.pngData = pngData
        self.bitsPerPixel = bitsPerPixel
    }
}

public enum IconFileError: Error, Equatable { case notAnIcon, truncated, unsupportedEntry }

/// Why `IconFile.assembleGroup` failed: the directory isn't an icon or cursor group (bad header, no entries or
/// more than 64), or no image it names could be found.
public enum IconGroupError: Error, Equatable { case notAGroup, noImages }

/// Reads .ico and .cur files. The input is untrusted: every offset and size is bounds-checked, and
/// malformed data throws instead of trapping.
public enum IconFile {
    static let maxDimension = 1024

    public static func parse(_ data: Data) throws -> [IconImage] {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, u16(bytes, 0) == 0, u16(bytes, 2) == 1 || u16(bytes, 2) == 2 else { throw IconFileError.notAnIcon }
        let isCursor = u16(bytes, 2) == 2
        guard bytes.count >= 6 else { throw IconFileError.truncated }
        let count = u16(bytes, 4)
        guard count > 0 else { throw IconFileError.notAnIcon }
        guard 6 + count * 16 <= bytes.count else { throw IconFileError.truncated }
        var images: [IconImage] = []
        for i in 0..<count {
            let e = 6 + i * 16
            let size = u32(bytes, e + 8), offset = u32(bytes, e + 12)
            guard size > 0, offset >= 6 + count * 16, offset <= bytes.count, size <= bytes.count - offset else {
                throw IconFileError.truncated
            }
            let payload = Array(bytes[offset..<offset + size])
            let hotspot = isCursor ? CGPoint(x: u16(bytes, e + 4), y: u16(bytes, e + 6)) : nil
            if payload.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
                guard payload.count >= 24 else { throw IconFileError.truncated }
                let w = Int(be32(payload, 16)), h = Int(be32(payload, 20))
                guard w > 0, h > 0, w <= maxDimension, h <= maxDimension else { throw IconFileError.unsupportedEntry }
                images.append(IconImage(width: w, height: h, hotspot: hotspot, pngData: Data(payload), bitsPerPixel: 32))
            } else {
                let (w, h, png) = try pngFromDIB(payload)
                images.append(IconImage(width: w, height: h, hotspot: hotspot, pngData: png, bitsPerPixel: u16(payload, 14)))
            }
        }
        return images
    }

    /// Colour depth first, then size: only the entries of the deepest colour present are candidates (PNG and
    /// 32 bpp, then 24, 8, 4, 1), so a 48 px 4-bpp entry never beats a 32 px 32-bpp one. Among those: the exact
    /// size, else the smallest larger one, else the largest.
    public static func best(_ images: [IconImage], target: Int) -> IconImage? {
        guard let depth = images.map(\.bitsPerPixel).max() else { return nil }
        let pool = images.filter { $0.bitsPerPixel == depth }
        if let exact = pool.first(where: { $0.width == target }) { return exact }
        let larger = pool.filter { $0.width > target }.min { $0.width < $1.width }
        return larger ?? pool.max { $0.width < $1.width }
    }

    // MARK: Icon and cursor groups

    static let maxGroupEntries = 64
    static let maxGroupImageBytes = 16 * 1024 * 1024
    static let maxGroupTotalBytes = 64 * 1024 * 1024

    /// Assembles one standard multi-image .ico (type 1) or .cur (type 2) from a PE icon or cursor group, as 7-Zip
    /// extracts it: `directory` is the bare group resource (`.rsrc/GROUP_ICON/<id>` or `GROUP_CURSOR/<id>`: a
    /// 6-byte header, then 14-byte entries ending in the image id), and `image(id)` returns that image's file
    /// (`.rsrc/ICON/<id>.ico`, a single-image wrapper whose payload is taken at its own entry's offset, or the raw
    /// resource), nil when missing. A cursor image's hotspot comes from its wrapper's entry or from the 4 bytes
    /// in front of a raw cursor's DIB. Untrusted input: at most 64 entries, images over 16 MB count as missing,
    /// images that would take the group past 64 MB in all are dropped, every offset is bounds-checked. Throws
    /// `IconGroupError.noImages` when no image of the group is found.
    public static func assembleGroup(directory: Data, image: (Int) -> Data?) throws -> Data {
        let d = [UInt8](directory)
        guard d.count >= 6, u16(d, 0) == 0, u16(d, 2) == 1 || u16(d, 2) == 2 else { throw IconGroupError.notAGroup }
        let type = u16(d, 2), count = u16(d, 4)
        guard count > 0, count <= maxGroupEntries else { throw IconGroupError.notAGroup }
        guard 6 + count * 14 <= d.count else { throw IconFileError.truncated }

        var entries: [[UInt8]] = [], payloads: [[UInt8]] = [], total = 0
        for i in 0..<count {
            let e = 6 + i * 14
            guard let file = image(u16(d, e + 12)), file.count <= maxGroupImageBytes else { continue }
            var (payload, hotspot) = unwrapSingleImage([UInt8](file))
            if type == 2, !isImagePayload(payload, at: 0), isImagePayload(payload, at: 4) {
                // A CURSOR resource as stored in the PE: hotspot x, y (u16 each), then the DIB or PNG.
                hotspot = (u16(payload, 0), u16(payload, 2))
                payload.removeFirst(4)
            }
            guard !payload.isEmpty, payload.count <= maxGroupTotalBytes - total else { continue }
            total += payload.count
            let (w, h) = payloadSize(payload)
            var entry: [UInt8] = [UInt8(w & 0xFF), UInt8(h & 0xFF)]
            if type == 1 {
                entry += [d[e + 2], d[e + 3]] + Array(d[e + 4..<e + 8])           // colours, reserved, planes, bit count
            } else {
                entry += [0, 0] + le16(hotspot?.0 ?? 0) + le16(hotspot?.1 ?? 0)
            }
            entries.append(entry)
            payloads.append(payload)
        }
        guard !entries.isEmpty else { throw IconGroupError.noImages }

        var out = le16(0) + le16(type) + le16(entries.count)
        var offset = 6 + entries.count * 16
        for (entry, payload) in zip(entries, payloads) {
            out += entry + le32(payload.count) + le32(offset)
            offset += payload.count
        }
        for payload in payloads { out += payload }
        return Data(out)
    }

    /// A single-image .ico/.cur wrapper's payload (and a cursor's hotspot); anything else is returned as is.
    private static func unwrapSingleImage(_ b: [UInt8]) -> ([UInt8], (Int, Int)?) {
        guard b.count >= 22, u16(b, 0) == 0, u16(b, 2) == 1 || u16(b, 2) == 2, u16(b, 4) == 1 else { return (b, nil) }
        let size = u32(b, 14), offset = u32(b, 18)
        guard size > 0, offset >= 22, offset <= b.count, size <= b.count - offset else { return (b, nil) }
        let hotspot = u16(b, 2) == 2 ? (u16(b, 10), u16(b, 12)) : nil
        return (Array(b[offset..<offset + size]), hotspot)
    }

    /// A PNG signature or a BITMAPINFOHEADER (size 40 or more) at `o`.
    private static func isImagePayload(_ b: [UInt8], at o: Int) -> Bool {
        guard b.count >= o + 8 else { return false }
        if b[o] == 0x89, b[o + 1] == 0x50, b[o + 2] == 0x4E, b[o + 3] == 0x47 { return true }
        let header = u32(b, o)
        return header >= 40 && header <= 124
    }

    /// Width and height from a PNG's IHDR or a DIB header (whose height covers the AND mask); 0 when unknown or
    /// 256 and over, as an icon directory writes them.
    private static func payloadSize(_ b: [UInt8]) -> (Int, Int) {
        func clamp(_ v: Int) -> Int { v > 0 && v < 256 ? v : 0 }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]), b.count >= 24 {
            return (clamp(Int(be32(b, 16))), clamp(Int(be32(b, 20))))
        }
        guard b.count >= 12 else { return (0, 0) }
        return (clamp(Int(Int32(truncatingIfNeeded: u32(b, 4)))), clamp(Int(Int32(truncatingIfNeeded: u32(b, 8))) / 2))
    }

    private static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private static func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16((v >> 16) & 0xFFFF) }

    // MARK: DIB

    private static func pngFromDIB(_ b: [UInt8]) throws -> (Int, Int, Data) {
        guard b.count >= 40 else { throw IconFileError.truncated }
        let headerSize = u32(b, 0)
        guard headerSize >= 40, headerSize <= b.count else { throw IconFileError.unsupportedEntry }
        let w = Int(Int32(truncatingIfNeeded: u32(b, 4)))
        let rawH = Int(Int32(truncatingIfNeeded: u32(b, 8)))
        let bpp = u16(b, 14), compression = u32(b, 16)
        guard w > 0, w <= maxDimension, rawH > 0, rawH <= maxDimension * 2 else { throw IconFileError.unsupportedEntry }
        guard compression == 0 else { throw IconFileError.unsupportedEntry }
        guard [1, 4, 8, 24, 32].contains(bpp) else { throw IconFileError.unsupportedEntry }
        // The stored height covers the colour image and the AND mask.
        let h = rawH / 2
        guard h > 0 else { throw IconFileError.unsupportedEntry }
        var colors = 0
        if bpp <= 8 {
            colors = u32(b, 32)
            if colors == 0 { colors = 1 << bpp }
            guard colors <= 256 else { throw IconFileError.unsupportedEntry }
        }
        let paletteStart = headerSize
        let pixelStart = paletteStart + colors * 4
        let rowBytes = (w * bpp + 31) / 32 * 4
        guard pixelStart <= b.count, rowBytes * h <= b.count - pixelStart else { throw IconFileError.truncated }
        let maskStart = pixelStart + rowBytes * h
        let maskRow = (w + 31) / 32 * 4
        let hasMask = maskRow * h <= b.count - maskStart

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        var anyAlpha = false
        // 1 bpp: which pixels have their XOR (colour) bit set, for the inverting pixels below.
        var xorBit = bpp == 1 ? [Bool](repeating: false, count: w * h) : []
        for y in 0..<h {
            let src = pixelStart + (h - 1 - y) * rowBytes  // DIB rows are bottom-up
            for x in 0..<w {
                var r: UInt8 = 0, g: UInt8 = 0, bl: UInt8 = 0, a: UInt8 = 255
                switch bpp {
                case 32:
                    bl = b[src + x * 4]; g = b[src + x * 4 + 1]; r = b[src + x * 4 + 2]; a = b[src + x * 4 + 3]
                    if a != 0 { anyAlpha = true }
                case 24:
                    bl = b[src + x * 3]; g = b[src + x * 3 + 1]; r = b[src + x * 3 + 2]
                default:
                    let bit = x * bpp
                    let byte = b[src + bit / 8]
                    let shift: Int = 8 - bpp - (bit % 8)
                    let mask: Int = (1 << bpp) - 1
                    let idx: Int = (Int(byte) >> shift) & mask
                    guard idx < colors else { throw IconFileError.unsupportedEntry }
                    let p = paletteStart + idx * 4
                    bl = b[p]; g = b[p + 1]; r = b[p + 2]
                    if bpp == 1, idx != 0 { xorBit[y * w + x] = true }
                }
                let o = (y * w + x) * 4
                rgba[o] = r; rgba[o + 1] = g; rgba[o + 2] = bl; rgba[o + 3] = a
            }
        }
        // 32-bpp icons normally carry their own alpha; otherwise the AND mask decides. A 1-bpp pixel with both
        // bits set inverts the screen under it (the I-beam in user32.dll is drawn only with those): macOS can't
        // invert, so it becomes opaque black, which is what Windows shows on a light background.
        if !(bpp == 32 && anyAlpha) {
            for y in 0..<h {
                let src = maskStart + (h - 1 - y) * maskRow
                for x in 0..<w {
                    let o = (y * w + x) * 4
                    let masked = hasMask && (b[src + x / 8] & UInt8(0x80 >> (x % 8))) != 0
                    if masked, bpp == 1, xorBit[y * w + x] {
                        rgba[o] = 0; rgba[o + 1] = 0; rgba[o + 2] = 0; rgba[o + 3] = 255
                    } else {
                        rgba[o + 3] = masked ? 0 : 255
                    }
                }
            }
        }
        return (w, h, try encodePNG(rgba: rgba, width: w, height: h))
    }

    /// Encodes non-premultiplied RGBA bytes as PNG.
    static func encodePNG(rgba: [UInt8], width: Int, height: Int) throws -> Data {
        guard width > 0, height > 0, rgba.count == width * height * 4,
              let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw IconFileError.unsupportedEntry }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw IconFileError.unsupportedEntry
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw IconFileError.unsupportedEntry }
        return out as Data
    }

    // MARK: Bounds-checked readers (callers have verified the range)

    private static func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ o: Int) -> Int { u16(b, o) | u16(b, o + 2) << 16 }
    private static func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }
}
