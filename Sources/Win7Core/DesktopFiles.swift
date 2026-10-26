import Foundation

public enum DesktopFileError: Error, Equatable, LocalizedError {
    case invalidName
    case nameExists(String)
    /// The source is the desktop folder or a folder containing it; copying it in would recurse.
    case containsDesktop(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: "A file name can't be empty, contain a slash or a colon, or start with a dot."
        case .nameExists(let n): "There is already a file with the name \"\(n)\" on the desktop."
        case .containsDesktop(let n): "\"\(n)\" contains the desktop, so it can't be put on the desktop."
        }
    }
}

/// One source for `DesktopFiles.transfer`: moved, or copied when `copy`.
public struct DesktopTransfer: Equatable, Sendable {
    public var url: URL
    public var copy: Bool
    public init(url: URL, copy: Bool) {
        self.url = url
        self.copy = copy
    }
}

/// The names that arrived on the desktop, in order, and the first error (the failed sources are skipped).
public struct DesktopTransferResult: Sendable {
    public var names: [String]
    public var error: Error?
}

public enum DesktopDropAction: Equatable, Sendable { case reposition, move, copy, trash }

/// What a drop on the desktop does with file URLs.
public enum DesktopDropPolicy {
    /// Recycle Bin always trashes. Files already on the desktop just move on the grid. Otherwise move,
    /// or copy when Option is held or the source is on another volume.
    public static func action(fromDesktop: Bool, sameVolume: Bool, optionHeld: Bool, ontoRecycleBin: Bool) -> DesktopDropAction {
        if ontoRecycleBin { return .trash }
        if fromDesktop { return .reposition }
        return optionHeld || !sameVolume ? .copy : .move
    }
}

/// File operations on the desktop folder. Synchronous; the shell runs them off the main thread.
/// The directory is injectable so tests use a temporary folder.
public struct DesktopFiles: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    private var fm: FileManager { .default }

    /// Non-hidden entries with size (0 for folders), type description and modification date.
    public func scan() throws -> [DesktopEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .localizedTypeDescriptionKey, .contentModificationDateKey]
        let urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        return urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return DesktopEntry(name: url.lastPathComponent,
                                size: v?.isDirectory == true ? 0 : Int64(v?.fileSize ?? 0),
                                type: v?.localizedTypeDescription ?? "",
                                modified: v?.contentModificationDate ?? .distantPast)
        }
    }

    private func existingNames() -> Set<String> {
        Set((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    /// Creates "New folder" (or "New folder (n)") and returns its name.
    public func createFolder() throws -> String {
        let name = FileNaming.unique("New folder", ext: nil, existing: existingNames())
        try fm.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: false)
        return name
    }

    /// Creates an empty "New Text Document.txt" (or "… (n).txt") and returns its name.
    public func createTextDocument() throws -> String {
        let name = FileNaming.unique("New Text Document", ext: "txt", existing: existingNames())
        try Data().write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
        return name
    }

    /// Renames `name` to the trimmed `newName` and returns the final name. A case-only change goes through
    /// a temporary name so it works on case-insensitive volumes.
    public func rename(_ name: String, to newName: String) throws -> String {
        let target = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !target.contains("/"), !target.contains(":"), !target.hasPrefix(".") else { throw DesktopFileError.invalidName }
        if target == name { return name }
        let src = directory.appendingPathComponent(name)
        let dst = directory.appendingPathComponent(target)
        if target.lowercased() == name.lowercased() {
            let temp = directory.appendingPathComponent(".w7rename-\(UUID().uuidString)")
            try fm.moveItem(at: src, to: temp)
            do { try fm.moveItem(at: temp, to: dst) } catch {
                try? fm.moveItem(at: temp, to: src)
                throw error
            }
            return target
        }
        if existingNames().contains(where: { $0.lowercased() == target.lowercased() }) {
            throw DesktopFileError.nameExists(target)
        }
        try fm.moveItem(at: src, to: dst)
        return target
    }

    /// Whether `url` sits directly in the desktop folder.
    public func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == directory.path
    }

    /// Moves or copies the sources into the desktop folder in order, renaming on collision ("x (2).txt").
    /// Moving an item already in the folder leaves it alone; copying it duplicates it, as Copy then Paste
    /// does on the Windows desktop. The desktop folder itself and any folder containing it are refused
    /// (copying them in would recurse). A failed source is skipped; the rest still go through.
    public func transfer(_ items: [DesktopTransfer]) -> DesktopTransferResult {
        var result = DesktopTransferResult(names: [], error: nil)
        let desk = directory.resolvingSymlinksInPath().path
        for item in items {
            let url = item.url.standardizedFileURL
            let src = url.resolvingSymlinksInPath().path
            if src == desk || desk.hasPrefix(src.hasSuffix("/") ? src : src + "/") {
                result.error = result.error ?? DesktopFileError.containsDesktop(url.lastPathComponent)
                continue
            }
            if !item.copy, contains(url) {
                result.names.append(url.lastPathComponent)
                continue
            }
            do {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map {
                    $0.isDirectory == true && $0.isPackage != true
                } ?? false
                let parts = FileNaming.split(url.lastPathComponent, isDirectory: isDir)
                let name = FileNaming.unique(parts.base, ext: parts.ext, existing: existingNames())
                let dst = directory.appendingPathComponent(name)
                if item.copy { try fm.copyItem(at: url, to: dst) } else { try fm.moveItem(at: url, to: dst) }
                result.names.append(name)
            } catch {
                result.error = result.error ?? error
            }
        }
        return result
    }

    /// `transfer` with one mode for every URL.
    public func transfer(_ urls: [URL], copy: Bool) -> DesktopTransferResult {
        transfer(urls.map { DesktopTransfer(url: $0, copy: copy) })
    }

    /// Whether `a` and `b` are on the same volume (unknown counts as different, so drops copy).
    public static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let va = (try? a.resourceValues(forKeys: [key]))?.volumeIdentifier as? NSObject,
              let vb = (try? b.resourceValues(forKeys: [key]))?.volumeIdentifier as? NSObject else { return false }
        return va.isEqual(vb)
    }
}
