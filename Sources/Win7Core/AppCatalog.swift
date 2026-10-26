import Foundation

public struct AppEntry: Equatable, Hashable, Sendable {
    public var name: String
    public var path: String
    public var bundleID: String?
    public init(name: String, path: String, bundleID: String?) { self.name = name; self.path = path; self.bundleID = bundleID }
}

public enum AppCatalog {
    public static let defaultDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]

    /// `*.app` at depth 0 and 1 of each directory. Never descends into an `.app`.
    public static func scan(directories: [URL], fileManager: FileManager = .default) -> [AppEntry] {
        var seen = Set<String>()
        var result: [AppEntry] = []
        func add(_ url: URL) {
            guard seen.insert(url.path).inserted else { return }
            let name = url.deletingPathExtension().lastPathComponent
            result.append(AppEntry(name: name, path: url.path, bundleID: Bundle(url: url)?.bundleIdentifier))
        }
        func list(_ dir: URL) -> [URL] {
            (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        }
        for dir in directories {
            for item in list(dir) {
                if item.pathExtension == "app" { add(item); continue }
                guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                for sub in list(item) where sub.pathExtension == "app" { add(sub) }
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Case- and diacritic-insensitive in en_US_POSIX (so tr_TR never lowercases "I" to a dotless "ı"), then "ı" -> "i".
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "ı", with: "i")
    }

    /// Rank 0 prefix, 1 word-start, 2 substring. Ties keep catalog order. `extraTerms` are other names a program
    /// answers to (ProgramNames.searchTerms: its macOS name, "cmd"); a match there ranks as a word-start at best.
    public static func search(_ query: String, in apps: [AppEntry],
                              extraTerms: (AppEntry) -> [String] = { _ in [] }) -> [AppEntry] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return [] }
        func rank(_ name: String) -> Int? {
            let n = fold(name)
            if n.hasPrefix(q) { return 0 }
            if n.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." }).contains(where: { $0.hasPrefix(q) }) { return 1 }
            return n.contains(q) ? 2 : nil
        }
        var ranked: [(rank: Int, index: Int, app: AppEntry)] = []
        for (i, app) in apps.enumerated() {
            let alias = extraTerms(app).compactMap(rank).min().map { max($0, 1) }
            guard let r = [rank(app.name), alias].compactMap({ $0 }).min() else { continue }
            ranked.append((r, i, app))
        }
        ranked.sort { ($0.rank, $0.index) < ($1.rank, $1.index) }
        return ranked.map(\.app)
    }
}

public struct RecentApps: Codable, Equatable, Sendable {
    public private(set) var paths: [String] = []
    public init() {}
    public mutating func record(_ path: String) {
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > 10 { paths.removeLast(paths.count - 10) }
    }
}
