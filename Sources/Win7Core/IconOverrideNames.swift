import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum IconMapError: Error, Equatable {
    /// A line that isn't `<id | name.ico> <name>.png` (1-based line number, the line without its comment).
    case badLine(Int, String)
    /// An id or file name mapped twice; `line` is the second mapping.
    case duplicate(String, line: Int)
}

/// An icon group in a Windows DLL: `dll` is the lower-cased file name without `.dll` (`imageres`, `shell32`),
/// `id` the positive ICON group id.
public struct IconKey: Hashable, Sendable {
    public var dll: String
    public var id: Int

    public init(dll: String, id: Int) {
        self.dll = dll
        self.id = id
    }
}

/// What an icon file in a pack maps to: `key` names it (the lower-cased file name without `.ico` for a
/// by-name entry, `<dll>-<id>` otherwise, so `imageres-<id>` for imageres); `target` is the `Assets/icons/`
/// file name, nil for an id the map doesn't list (it goes to the contact sheet).
public struct IconMapHit: Equatable, Sendable {
    public var key: String
    public var target: String?

    public init(key: String, target: String?) {
        self.key = key
        self.target = target
    }
}

/// scripts/win7-icon-map.txt: DLL icon ids, and .ico file names (lower-cased), to `Assets/icons/` names.
public struct IconMap: Equatable, Sendable {
    public var ids: [IconKey: String] = [:]
    public var files: [String: String] = [:]

    public init(ids: [IconKey: String] = [:], files: [String: String] = [:]) {
        self.ids = ids
        self.files = files
    }

    /// A by-name entry first, then the DLL and id in the name. An id the map doesn't list, whatever its DLL, is a
    /// hit without a target (the contact sheet); a file name without a DLL id that isn't listed is nil (skipped).
    public func lookup(fileName: String) -> IconMapHit? {
        let base = (fileName as NSString).lastPathComponent.lowercased()
        if let target = files[base] { return IconMapHit(key: String(base.dropLast(4)), target: target) }
        guard let key = IconOverrideNames.iconKey(fileName: base) else { return nil }
        return IconMapHit(key: "\(key.dll)-\(key.id)", target: ids[key])
    }
}

/// How a desktop item is drawn.
public enum DesktopIconChoice: Equatable, Sendable {
    /// Its own icon: a user-set custom icon, an application, or the system icon when no override exists.
    case own
    /// `Assets/icons/<name>.png`.
    case override(String)
    /// The procedural Windows 7 folder art.
    case drawn(DesktopFolderArt)
}

/// Names of the user's icon overrides (`Assets/icons/<name>.png`) and the imageres icon map
/// (scripts/win7-icon-map.txt) that `make import-icons` fills them from.
public enum IconOverrideNames {
    // MARK: The import map

    /// The DLL a bare id, or an exported icon name without a DLL part, refers to.
    static let defaultDLL = "imageres"

    /// Parses `<id> <name>.png`, `<dll>:<id> <name>.png` and `<file>.ico <name>.png` lines; a bare id is
    /// `imageres:<id>`, and the dll (letters and digits, without `.dll`) matches case-insensitively. `#`
    /// followed by a space, a tab or the line end starts a comment (so `imageres-#3.ico` stays a file name).
    /// File names match case-insensitively. Target names are plain file names (letters, digits, `.`, `-`,
    /// `_`), so a map entry can never write outside Assets/icons/.
    public static func parseMap(_ text: String) throws -> IconMap {
        var map = IconMap()
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = stripComment(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2, isSafeName(fields[1], ext: ".png") else { throw IconMapError.badLine(i + 1, line) }
            let target = String(fields[1])
            if let key = idKey(fields[0]) {
                guard map.ids[key] == nil else {
                    let shown = key.dll == defaultDLL ? String(key.id) : "\(key.dll):\(key.id)"
                    throw IconMapError.duplicate(shown, line: i + 1)
                }
                map.ids[key] = target
            } else if isSafeName(fields[0], ext: ".ico") {
                let file = fields[0].lowercased()
                guard map.files[file] == nil else { throw IconMapError.duplicate(file, line: i + 1) }
                map.files[file] = target
            } else {
                throw IconMapError.badLine(i + 1, line)
            }
        }
        return map
    }

    static func stripComment(_ line: String) -> String {
        var prev: Character = " "
        for (offset, c) in line.enumerated() {
            if c == "#", prev == " " || prev == "\t" {
                return String(line.prefix(offset))
            }
            prev = c
        }
        return line
    }

    /// A map line's first field as an icon key: `<id>` (imageres) or `<dll>:<id>`; nil for anything else.
    private static func idKey(_ field: Substring) -> IconKey? {
        guard let colon = field.firstIndex(of: ":") else { return positiveID(field).map { IconKey(dll: defaultDLL, id: $0) } }
        let dll = field[..<colon], rest = field[field.index(after: colon)...]
        guard isDLLName(dll), let id = positiveID(rest) else { return nil }
        return IconKey(dll: dll.lowercased(), id: id)
    }

    private static func isDLLName(_ s: Substring) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The DLL and icon group id in an exported icon's file name: `<dll>-#N.ico`, `<dll>-N.ico`, `#N.ico` or
    /// `N.ico` (any directory part is ignored; the dll is letters and digits, lower-cased, `imageres` when
    /// absent). Nil for anything else.
    public static func iconKey(fileName: String) -> IconKey? {
        let base = (fileName as NSString).lastPathComponent
        guard base.lowercased().hasSuffix(".ico") else { return nil }
        var stem = Substring(base.dropLast(4))
        var dll = defaultDLL
        if let dash = stem.firstIndex(of: "-") {
            let prefix = stem[..<dash]
            guard isDLLName(prefix) else { return nil }
            dll = prefix.lowercased()
            stem = stem[stem.index(after: dash)...]
        }
        if stem.hasPrefix("#") { stem = stem.dropFirst() }
        return positiveID(stem).map { IconKey(dll: dll, id: $0) }
    }

    /// The imageres icon group id in an exported icon's file name (see `iconKey(fileName:)`); nil for anything
    /// else, including other DLLs' icons.
    public static func iconID(fileName: String) -> Int? {
        guard let key = iconKey(fileName: fileName), key.dll == defaultDLL else { return nil }
        return key.id
    }

    private static func positiveID(_ s: Substring) -> Int? {
        guard !s.isEmpty, s.count <= 6, s.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Int(s), v > 0 else { return nil }
        return v
    }

    /// A plain file name ending in `ext` (case-insensitive): an ASCII letter or digit, then letters, digits,
    /// `.`, `-` and `_` (and `#` in .ico names, as in `imageres-#3.ico`). No separators, so it can't name a
    /// path; no leading dot, so never hidden or `..`.
    static func isSafeName(_ s: Substring, ext: String) -> Bool {
        guard s.count > ext.count, s.lowercased().hasSuffix(ext), let first = s.first, first.isASCII,
              first.isLetter || first.isNumber else { return false }
        return s.allSatisfy { isNameCharacter($0) || (ext == ".ico" && $0 == "#") }
    }

    private static func isNameCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "-" || c == "_")
    }

    // MARK: Applications

    /// The override for an application, `app-<bundle id>`, or nil for a missing or malformed bundle id.
    public static func app(bundleID: String?) -> String? {
        guard let id = bundleID, let first = id.first, first.isASCII, first.isLetter || first.isNumber,
              id.allSatisfy(isNameCharacter) else { return nil }
        return "app-" + id
    }

    // MARK: Desktop

    /// The override for a folder art kind: `folder`, or `folder-<kind>` (the names Finder reads).
    public static func folder(_ art: DesktopFolderArt) -> String {
        art == .plain ? "folder" : "folder-\(art.rawValue)"
    }

    /// The override for a desktop file by its content type, or nil when it keeps its own icon: folders and
    /// packages (folders are DesktopFolderArt's), applications, symlinks, aliases and files with a custom icon.
    public static func file(_ t: DesktopItemTraits, type: UTType?) -> String? {
        guard !t.isDirectory, !t.isPackage, !t.isSymlink, !t.isAlias, !t.hasCustomIcon else { return nil }
        if let type, type.conforms(to: .application) || type.conforms(to: .package) || type.conforms(to: .folder) {
            return nil
        }
        return fileType(type)
    }

    /// The override for any desktop item but a folder: `app-<bundle id>` for an application bundle (nil, its own
    /// icon, without a usable bundle id or with a custom icon), else `file(_:type:)`. Symlinks and aliases to an
    /// application keep their own icon too.
    public static func desktop(_ t: DesktopItemTraits, type: UTType?, bundleID: String?) -> String? {
        guard t.isApplication else { return file(t, type: type) }
        guard !t.isSymlink, !t.isAlias, !t.hasCustomIcon else { return nil }
        return app(bundleID: bundleID)
    }

    /// The override for a plain file of this content type: `file-image`, `file-video`, `file-audio`,
    /// `file-text`, else (an unknown type included) `file`.
    public static func fileType(_ type: UTType?) -> String {
        guard let type else { return "file" }
        if type.conforms(to: .image) { return "file-image" }
        if type.conforms(to: .movie) { return "file-video" }
        if type.conforms(to: .audio) { return "file-audio" }
        if type.conforms(to: .text) { return "file-text" }
        return "file"
    }

    /// The override for an item known only by its content type (a Start menu search hit, a jump list's recent
    /// item), or nil to keep the system icon for the type: `folder` for folders (volumes included), nil for
    /// applications, packages and other bundles (`.rtfd`, `.pages`, frameworks), else `fileType(_:)`. A nil type
    /// is a plain file.
    public static func typeIcon(_ type: UTType?) -> String? {
        guard let type else { return fileType(nil) }
        if type.conforms(to: .application) || type.conforms(to: .package) { return nil }
        if type.conforms(to: .folder) { return "folder" }
        if type.conforms(to: .directory) { return nil }
        return fileType(type)
    }

    /// Precedence: an item's own custom icon (art and file are then nil) > the override PNG, when
    /// `available` says it exists > the drawn folder art, or the item's own (system) icon.
    public static func choice(art: DesktopFolderArt?, file: String?, available: (String) -> Bool) -> DesktopIconChoice {
        if let art {
            let name = folder(art)
            return available(name) ? .override(name) : .drawn(art)
        }
        if let file, available(file) { return .override(file) }
        return .own
    }

    // MARK: Start menu

    /// Stand-ins for a Start menu place's icon when its own PNG is missing: the system drive for Computer, and
    /// the special-folder icons an icon pack provides for Documents, Pictures and Music.
    static let placeFallbacks: [String: [String]] = [
        "computer": ["drive-system"],
        "documents": ["folder-documents"], "pictures": ["folder-pictures"], "music": ["folder-music"],
    ]

    /// The override shown for a Start menu place's `icon`, or nil when neither it nor a stand-in exists.
    public static func placeIcon(_ icon: String, available: (String) -> Bool) -> String? {
        ([icon] + (placeFallbacks[icon] ?? [])).first(where: available)
    }

    // MARK: Untrusted files

    /// The largest `Assets/icons/*.png` file the shell reads, in bytes; a larger one counts as absent.
    public static let maxIconFileBytes = 2 * 1024 * 1024
    /// The largest width or height, in pixels, of an icon image the shell decodes; a larger one counts as absent.
    public static let maxIconPixels = 1024

    /// Whether an icon file of this size may be read (nil, an unknown size, may not).
    public static func acceptsIconFile(bytes: Int?) -> Bool {
        guard let bytes else { return false }
        return bytes >= 0 && bytes <= maxIconFileBytes
    }

    /// Whether an icon image of these pixel dimensions may be decoded.
    public static func acceptsIconPixels(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maxIconPixels && height <= maxIconPixels
    }

    /// The largest application Info.plist `bundleIdentifier(ofApp:)` reads, in bytes.
    public static let maxInfoPlistBytes = 1024 * 1024

    /// An application bundle's `CFBundleIdentifier`, read from `Contents/Info.plist` (a regular file of at most
    /// 1 MB, binary or XML), or nil. Reads the file each call: unlike `Bundle(url:)`, whose instances are cached
    /// per path for the process, an application replaced at the same path reads its new id.
    public static func bundleIdentifier(ofApp app: URL) -> String? {
        let url = app.appendingPathComponent("Contents/Info.plist")
        guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true,
              let size = v.fileSize, size <= maxInfoPlistBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // The size is checked again on what was read, in case the file grew after the check.
        guard let data = try? handle.read(upToCount: maxInfoPlistBytes + 1), data.count <= maxInfoPlistBytes,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    /// An `Assets/icons/*.png` file's largest image (of the first 8), or nil when it isn't a regular file directly
    /// in its folder (a symlink out of it, a FIFO, a directory), is over 2 MB, isn't a complete PNG (a truncated
    /// file), has any image over 1024 px (checked from the header, before decoding) or doesn't decode. The bytes
    /// checked are the bytes decoded (read once, at most 2 MB).
    public static func decodeIcon(at url: URL) -> CGImage? {
        let file = url.resolvingSymlinksInPath()
        guard file.deletingLastPathComponent().path == url.deletingLastPathComponent().resolvingSymlinksInPath().path,
              let v = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true,
              acceptsIconFile(bytes: v.fileSize),
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxIconFileBytes + 1), acceptsIconFile(bytes: data.count),
              pngIsComplete(data),
              let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        var best: (index: Int, width: Int)?
        for i in 0..<min(CGImageSourceGetCount(src), 8) {
            guard let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
                  acceptsIconPixels(width: w, height: h) else { return nil }
            if w > (best?.width ?? 0) { best = (i, w) }
        }
        // ImageIO decodes lazily and reports a cut-short image as complete when its data is final, so the
        // chunk walk above is what catches a truncated file; the status check rejects whatever ImageIO itself
        // flags as incomplete or invalid.
        guard let best, CGImageSourceGetStatusAtIndex(src, best.index) == .statusComplete else { return nil }
        return CGImageSourceCreateImageAtIndex(src, best.index, nil)
    }

    /// Whether `data` is a whole PNG: the signature, then chunks (length, type, data, CRC) each wholly present,
    /// up to and including IEND. A file cut short anywhere fails; bytes after IEND are ignored. CRCs aren't checked.
    public static func pngIsComplete(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count >= signature.count, Array(bytes[0..<8]) == signature else { return false }
        var offset = 8
        while offset + 12 <= bytes.count {
            let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length <= Int(Int32.max) else { return false }
            let next = offset + 12 + length
            guard next <= bytes.count else { return false }
            if bytes[offset + 4..<offset + 8].elementsEqual([0x49, 0x45, 0x4E, 0x44]) { return true }  // "IEND"
            offset = next
        }
        return false
    }
}
