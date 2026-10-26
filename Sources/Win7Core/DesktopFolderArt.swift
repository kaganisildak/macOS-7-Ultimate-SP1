import Darwin
import Foundation

/// What decides whether a desktop item is drawn with the Windows 7 folder art.
public struct DesktopItemTraits: Equatable, Sendable {
    public var path: String
    public var isDirectory: Bool
    public var isPackage: Bool
    public var isSymlink: Bool
    public var isAlias: Bool
    public var hasCustomIcon: Bool

    public init(path: String, isDirectory: Bool, isPackage: Bool, isSymlink: Bool, isAlias: Bool, hasCustomIcon: Bool) {
        self.path = path
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymlink = isSymlink
        self.isAlias = isAlias
        self.hasCustomIcon = hasCustomIcon
    }

    /// An application bundle: a package whose name ends in `.app` (any case).
    public var isApplication: Bool {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return isPackage && (p as NSString).pathExtension.lowercased() == "app"
    }
}

/// The Windows 7 folder art kinds (Win7Theme's W7FolderIconKind; the shell maps one to the other).
public enum DesktopFolderArt: String, Sendable, CaseIterable {
    case plain, documents, pictures, music, videos, downloads, desktop, user

    /// The art for a desktop item, or nil to keep its own icon: plain folders get the plain folder,
    /// the home folder and its Documents, Pictures, Music, Movies, Downloads and Desktop their special
    /// kinds. Files, packages and .app bundles, folders with a custom icon, symlinks and aliases keep theirs.
    public static func art(for t: DesktopItemTraits, home: String) -> DesktopFolderArt? {
        guard t.isDirectory, !t.isPackage, !t.isSymlink, !t.isAlias, !t.hasCustomIcon else { return nil }
        let path = normalized(t.path)
        if (path as NSString).pathExtension.lowercased() == "app" { return nil }
        let h = normalized(home)
        if path == h { return .user }
        let special: [String: DesktopFolderArt] = ["Documents": .documents, "Pictures": .pictures, "Music": .music,
                                                   "Movies": .videos, "Downloads": .downloads, "Desktop": .desktop]
        for (name, kind) in special where path == h + "/" + name { return kind }
        return .plain
    }

    private static func normalized(_ p: String) -> String {
        var s = p
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Finder's kHasCustomIcon: bit 0x0400 of the big-endian Finder flags at bytes 8-9 of FinderInfo.
    public static func hasCustomIcon(finderInfo: Data?) -> Bool {
        guard let info = finderInfo, info.count >= 10 else { return false }
        return info[info.startIndex + 8] & 0x04 != 0
    }

    /// Reads the traits of `url` from disk without following a final symlink.
    public static func traits(of url: URL) -> DesktopItemTraits {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey]
        let v = try? url.resourceValues(forKeys: keys)
        let symlink = v?.isSymbolicLink == true
        return DesktopItemTraits(path: url.path,
                                 isDirectory: v?.isDirectory == true,
                                 isPackage: v?.isPackage == true,
                                 isSymlink: symlink,
                                 // isAliasFile is also true for symlinks; count only real Finder aliases here.
                                 isAlias: v?.isAliasFile == true && !symlink,
                                 hasCustomIcon: hasCustomIcon(finderInfo: finderInfo(url.path)))
    }

    private static func finderInfo(_ path: String) -> Data? {
        var buf = [UInt8](repeating: 0, count: 32)
        let n = getxattr(path, "com.apple.FinderInfo", &buf, 32, 0, XATTR_NOFOLLOW)
        return n >= 10 ? Data(buf[0..<n]) : nil
    }
}
