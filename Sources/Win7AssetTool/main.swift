import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Win7Core

// Win7AssetTool ico2png <in.ico|in.cur|in.bmp> <out.png> [--size N]
// Win7AssetTool bmpstrip <in.bmp> <outPrefix> --frames N
// Win7AssetTool iconname <win7-icon-map.txt> <file.ico>   prints "<key> <name>.png", or "<dll>-<id> -" for an
//                                                         unmapped <dll>-#N.ico id; exit 2 for any other file name
//                                                         (used by scripts/import-icons.sh)
// Win7AssetTool groupicon <GROUP_ICON|GROUP_CURSOR file> <ICON|CURSOR dir> <out.ico|out.cur>
//     assembles one multi-image .ico/.cur from 7-Zip's extraction of a PE group: each image id the group names is
//     read from <dir>/<id>.ico, <dir>/<id>.cur or the raw <dir>/<id>. Prints "entries <n>"; exit 2 when no image
//     of the group is found.
// Win7AssetTool montage <dir> <out.png> [--cell 48] [--columns 12] [--prefix <dll>-]
//     a labelled contact sheet: one cell per <prefix><label>.png in <dir> (every .png without --prefix, labelled
//     with its whole name), sorted by label (numbers in numeric order), the icon at --cell px over its label in
//     10 pt white on #333333. Exit 1 when no PNG matches.
// Win7AssetTool icon-names
//     prints IconCatalog.all, one name per line (sorted, no `.png`): every icon name the shell and the chrome read
//     (scripts/setup.sh's preflight counts the user's icons against it, so the list is never retyped).
// Used by scripts/import-win7-assets.sh and scripts/import-icons.sh on files from the user's own Windows 7 media.

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func option(_ name: String, in args: [String]) -> Int? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count, let v = Int(args[i + 1]), v > 0, v <= 1024 else { fail("bad value for \(name)") }
    return v
}

func decodeImage(_ data: Data) -> CGImage? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func png(_ image: CGImage) -> Data? {
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest) ? out as Data : nil
}

func resized(_ image: CGImage, to size: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()
}

func ico2png(_ args: [String]) {
    guard args.count >= 2 else { fail("usage: Win7AssetTool ico2png <in> <out.png> [--size N]") }
    guard let data = FileManager.default.contents(atPath: args[0]) else { fail("cannot read \(args[0])") }
    let size = option("--size", in: args)
    var outPNG: Data
    var hotspot: CGPoint?
    do {
        let images = try IconFile.parse(data)
        guard let pick = IconFile.best(images, target: size ?? 1024) else { fail("no images in \(args[0])") }
        outPNG = pick.pngData
        hotspot = pick.hotspot
        if let size, pick.width != size, let img = decodeImage(pick.pngData), let scaled = resized(img, to: size),
           let scaledPNG = png(scaled) {
            if let h = hotspot { hotspot = CGPoint(x: h.x * CGFloat(size) / CGFloat(pick.width), y: h.y * CGFloat(size) / CGFloat(pick.height)) }
            outPNG = scaledPNG
        }
    } catch IconFileError.notAnIcon {
        // Plain bitmap (for example a user account picture): decode with ImageIO.
        guard var img = decodeImage(data) else { fail("not an icon or image: \(args[0])") }
        if let size, let scaled = resized(img, to: size) { img = scaled }
        guard let p = png(img) else { fail("cannot encode PNG") }
        outPNG = p
    } catch {
        fail("\(args[0]): \(error)")
    }
    do { try outPNG.write(to: URL(fileURLWithPath: args[1])) } catch { fail("cannot write \(args[1])") }
    if let h = hotspot { print("hotspot \(Int(h.x.rounded())) \(Int(h.y.rounded()))") }
}

func bmpstrip(_ args: [String]) {
    guard args.count >= 2, let frames = option("--frames", in: args) else {
        fail("usage: Win7AssetTool bmpstrip <in.bmp> <outPrefix> --frames N")
    }
    guard let data = FileManager.default.contents(atPath: args[0]), let img = decodeImage(data) else {
        fail("cannot decode \(args[0])")
    }
    let h = img.height / frames
    guard h > 0 else { fail("strip too short for \(frames) frames") }
    for i in 0..<frames {
        guard let frame = img.cropping(to: CGRect(x: 0, y: i * h, width: img.width, height: h)), let p = png(frame) else {
            fail("cannot crop frame \(i)")
        }
        do { try p.write(to: URL(fileURLWithPath: "\(args[1])-\(i).png")) } catch { fail("cannot write frame \(i)") }
    }
}

func iconname(_ args: [String]) {
    guard args.count == 2 else { fail("usage: Win7AssetTool iconname <map.txt> <file.ico>", code: 64) }
    guard let text = try? String(contentsOfFile: args[0], encoding: .utf8) else { fail("cannot read \(args[0])") }
    let map: IconMap
    do { map = try IconOverrideNames.parseMap(text) } catch IconMapError.badLine(let n, let line) {
        fail("\(args[0]):\(n): expected '<id | dll:id | file.ico> <name>.png', got '\(line)'")
    } catch IconMapError.duplicate(let key, let n) {
        fail("\(args[0]):\(n): \(key) is mapped twice")
    } catch { fail("\(args[0]): \(error)") }
    guard let hit = map.lookup(fileName: args[1]) else { fail("not in the map and not a <dll>-#N.ico name", code: 2) }
    print("\(hit.key) \(hit.target ?? "-")")
}

/// The contents of a regular file of at most `limit` bytes, nil otherwise. Untrusted paths: a symlink is
/// resolved first and the file it points to is measured and read, and the read itself stops after `limit + 1`
/// bytes, so a file that grows in between is refused too.
func readFile(_ path: String, limit: Int) -> Data? {
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
          values.isRegularFile == true, let size = values.fileSize, size <= limit,
          let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
    return data
}

func groupicon(_ args: [String]) {
    guard args.count == 3 else { fail("usage: Win7AssetTool groupicon <GROUP_ICON file> <ICON dir> <out.ico|out.cur>", code: 64) }
    // A group directory is 6 + 14 bytes per entry (at most 64): anything much larger is not one.
    guard let directory = readFile(args[0], limit: 4096) else { fail("cannot read \(args[0])") }
    let dir = URL(fileURLWithPath: args[1])
    let data: Data
    do {
        data = try IconFile.assembleGroup(directory: directory) { id in
            for name in ["\(id).ico", "\(id).cur", "\(id)"] {
                if let d = readFile(dir.appendingPathComponent(name).path, limit: 16 * 1024 * 1024) { return d }
            }
            return nil
        }
    } catch IconGroupError.noImages {
        fail("no image of the group \(args[0]) found in \(args[1])", code: 2)
    } catch {
        fail("\(args[0]): \(error)")
    }
    do { try data.write(to: URL(fileURLWithPath: args[2])) } catch { fail("cannot write \(args[2])") }
    print("entries \(Int(data[4]) | Int(data[5]) << 8)")
}

func montage(_ args: [String]) {
    guard args.count >= 2 else {
        fail("usage: Win7AssetTool montage <dir> <out.png> [--cell 48] [--columns 12] [--prefix <dll>-]", code: 64)
    }
    let cell = option("--cell", in: args) ?? 48
    let columns = option("--columns", in: args) ?? 12
    var prefix = ""
    if let i = args.firstIndex(of: "--prefix") {
        guard i + 1 < args.count else { fail("bad value for --prefix") }
        prefix = args[i + 1]
    }
    let dir = URL(fileURLWithPath: args[0])
    let output = URL(fileURLWithPath: args[1]).standardizedFileURL
    var cells: [(label: String, path: String)] = []
    for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    where name.lowercased().hasSuffix(".png") && name.hasPrefix(prefix) {
        let url = dir.appendingPathComponent(name)
        let label = String(name.dropFirst(prefix.count).dropLast(4))
        guard !label.isEmpty, url.standardizedFileURL != output else { continue }
        cells.append((label, url.path))
    }
    guard !cells.isEmpty else { fail("no \(prefix)*.png in \(args[0])") }
    cells.sort { $0.label.compare($1.label, options: [.numeric]) == .orderedAscending }

    let pad = 8, labelHeight = 14
    let cols = min(columns, cells.count), rows = (cells.count + cols - 1) / cols
    let width = cols * (cell + pad), height = rows * (cell + labelHeight + pad)
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("cannot draw \(width)x\(height)") }
    ctx.setFillColor(CGColor(red: 0x33 / 255.0, green: 0x33 / 255.0, blue: 0x33 / 255.0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.interpolationQuality = .high
    let font = CTFontCreateUIFontForLanguage(.system, 10, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 10, nil)
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    for (k, c) in cells.enumerated() {
        let x = (k % cols) * (cell + pad) + pad / 2
        let top = (k / cols) * (cell + labelHeight + pad) + pad / 2
        let iconY = height - top - cell  // CoreGraphics' origin is bottom-left
        // Untrusted PNGs: at most 2 MB and 1024 px, as the shell reads them; a bad one is a red cell.
        if let data = readFile(c.path, limit: 2 * 1024 * 1024), let img = decodeImage(data), img.width <= 1024, img.height <= 1024 {
            ctx.draw(img, in: CGRect(x: x, y: iconY, width: cell, height: cell))
        } else {
            ctx.setFillColor(CGColor(red: 0.8, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: x, y: iconY, width: cell, height: cell))
        }
        let text = NSAttributedString(string: c.label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
        ])
        ctx.saveGState()
        ctx.clip(to: CGRect(x: x - pad / 2, y: iconY - labelHeight, width: cell + pad, height: labelHeight))
        ctx.textPosition = CGPoint(x: x, y: iconY - labelHeight + 3)
        CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
        ctx.restoreGState()
    }
    guard let image = ctx.makeImage(), let out = png(image) else { fail("cannot encode PNG") }
    do { try out.write(to: URL(fileURLWithPath: args[1])) } catch { fail("cannot write \(args[1])") }
    print("cells \(cells.count) \(width)x\(height)")
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "ico2png": ico2png(Array(args.dropFirst()))
case "bmpstrip": bmpstrip(Array(args.dropFirst()))
case "iconname": iconname(Array(args.dropFirst()))
case "groupicon": groupicon(Array(args.dropFirst()))
case "montage": montage(Array(args.dropFirst()))
case "icon-names":
    guard args.count == 1 else { fail("usage: Win7AssetTool icon-names", code: 64) }
    print(IconCatalog.all.joined(separator: "\n"))
default: fail("usage: Win7AssetTool ico2png|bmpstrip|iconname|groupicon|montage|icon-names ...", code: 64)
}
