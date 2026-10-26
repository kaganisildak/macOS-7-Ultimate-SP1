import Foundation

/// What the Run dialog opens for the text typed into it.
public enum RunTarget: Equatable, Sendable {
    case app(AppEntry)
    /// An existing file or folder (absolute path).
    case file(String)
    case url(URL)
    /// Nothing matches; the dialog shows `RunResolver.notFoundMessage`.
    case notFound(String)
    case empty
}

public enum RunResolver {
    /// In order: a path (`/…`, `~`, `~/…`), a URL (`scheme:…`, or `www.…` as https), a program by name
    /// or bundle ID (case-insensitive, Turkish-safe, `.app` optional), then a path relative to the home
    /// folder.
    public static func resolve(_ text: String, apps: [AppEntry], home: String,
                               fileExists: (String) -> Bool) -> RunTarget {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .empty }
        if t == "~" || t.hasPrefix("~/") || t.hasPrefix("/") {
            let path = expandTilde(t, home: home)
            return fileExists(path) ? .file(path) : .notFound(t)
        }
        if let url = url(t) { return .url(url) }
        let folded = AppCatalog.fold(t)
        let bare = folded.hasSuffix(".app") ? String(folded.dropLast(4)) : folded
        if let app = apps.first(where: { AppCatalog.fold($0.name) == bare })
            ?? apps.first(where: { $0.bundleID.map(AppCatalog.fold) == folded }) {
            return .app(app)
        }
        let relative = (home as NSString).appendingPathComponent(t)
        if fileExists(relative) { return .file(relative) }
        return .notFound(t)
    }

    /// The Windows 7 Run error, with "Windows" reworded.
    public static func notFoundMessage(_ text: String) -> String {
        "Win7Mac cannot find '\(text)'. Make sure you typed the name correctly, and then try again."
    }

    public static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return (home as NSString).appendingPathComponent(String(path.dropFirst(2))) }
        return path
    }

    private static func url(_ t: String) -> URL? {
        if t.lowercased().hasPrefix("www."), !t.contains(" ") { return URL(string: "https://" + t) }
        // `scheme:` with a scheme of two or more characters and no spaces.
        guard let colon = t.firstIndex(of: ":"), !t.contains(" ") else { return nil }
        let scheme = t[..<colon]
        guard scheme.count >= 2, let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }),
              t.index(after: colon) < t.endIndex,
              let url = URL(string: t), url.scheme != nil else { return nil }
        return url
    }
}

/// The Run dialog's history, most recent first, as Windows 7 keeps 26 entries.
public struct RunHistory: Codable, Equatable, Sendable {
    public static let limit = 26
    public private(set) var entries: [String] = []
    public init() {}
    public mutating func record(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        entries.removeAll { $0 == t }
        entries.insert(t, at: 0)
        if entries.count > RunHistory.limit { entries.removeLast(entries.count - RunHistory.limit) }
    }
}
