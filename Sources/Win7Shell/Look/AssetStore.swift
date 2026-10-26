import AppKit
import Foundation

/// Finds optional imported Windows 7 artwork (see Assets/README.md). Looks in
/// ~/Library/Application Support/Win7Mac/Assets/ first, then in the repo's Assets/ when the
/// executable runs from <repo>/build/ or <repo>/.build/. A missing file returns nil so callers
/// fall back to their procedural drawing; nothing is logged.
@MainActor
final class AssetStore {
    static let shared = AssetStore()

    private var cache: [String: NSImage?] = [:]
    private var cgCache: [String: CGImage?] = [:]

    private lazy var roots: [URL] = {
        var r = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Win7Mac/Assets")]
        // build/Win7Shell.app/Contents/MacOS/Win7Shell and .build/<arch>/<cfg>/Win7Shell both sit below the repo root.
        var dir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<7 {
            let candidate = dir.appendingPathComponent("Assets")
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                r.append(candidate)
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        return r
    }()

    /// Where an asset at a path relative to Assets/ would be, in the order the roots are searched.
    func candidates(_ relativePath: String) -> [URL] { roots.map { $0.appendingPathComponent(relativePath) } }

    /// File URL of an asset at a path relative to Assets/, or nil when no root has it.
    func url(_ relativePath: String) -> URL? {
        roots.map { $0.appendingPathComponent(relativePath) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Image at a path relative to Assets/, for example "icons/user.png".
    func image(_ relativePath: String) -> NSImage? {
        if let hit = cache[relativePath] { return hit }
        var found: NSImage?
        for root in roots {
            let url = root.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: url.path), let img = NSImage(contentsOf: url) {
                found = img
                break
            }
        }
        cache[relativePath] = .some(found)
        return found
    }

    func cgImage(_ relativePath: String) -> CGImage? {
        if let hit = cgCache[relativePath] { return hit }
        let cg = image(relativePath)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        cgCache[relativePath] = .some(cg)
        return cg
    }
}
