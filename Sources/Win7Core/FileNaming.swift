/// Windows-style collision names: "New folder (2)", "New Text Document (3).txt".
public enum FileNaming {
    /// `base[.ext]`, or the first free `base (n)[.ext]` for n ≥ 2. Compared case-insensitively because
    /// the default macOS volume is case-insensitive.
    public static func unique(_ base: String, ext: String?, existing: Set<String>) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        func full(_ stem: String) -> String {
            if let ext, !ext.isEmpty { return "\(stem).\(ext)" }
            return stem
        }
        if !taken.contains(full(base).lowercased()) { return full(base) }
        var n = 2
        while taken.contains(full("\(base) (\(n))").lowercased()) { n += 1 }
        return full("\(base) (\(n))")
    }

    /// UTF-16 length of the part of `name` that rename pre-selects: everything before the last dot when
    /// `keepExtension` (files), the whole name otherwise (folders). A leading dot isn't an extension.
    public static func baseLength(of name: String, keepExtension: Bool) -> Int {
        guard keepExtension, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name.utf16.count }
        return name[..<dot].utf16.count
    }

    /// Windows 7's name for a shortcut to `name` (extension included): "x - Shortcut", then "x - Shortcut (2)".
    public static func shortcutName(for name: String, existing: Set<String>) -> String {
        unique("\(name) - Shortcut", ext: nil, existing: existing)
    }

    /// Send to ▸ Compressed (zipped) folder: the item's stem (a folder's whole name) plus ".zip", made unique.
    public static func archiveName(for name: String, isDirectory: Bool, existing: Set<String>) -> String {
        unique(split(name, isDirectory: isDirectory).base, ext: "zip", existing: existing)
    }

    /// Splits a file name into the stem and extension that `unique` takes. Folders have no extension.
    public static func split(_ name: String, isDirectory: Bool) -> (base: String, ext: String?) {
        guard !isDirectory, let dot = name.lastIndex(of: "."), dot != name.startIndex,
              name.index(after: dot) != name.endIndex else { return (name, nil) }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }
}
