import Foundation

/// One entry of the Start menu's All Programs list.
public enum ProgramNode: Equatable, Sendable {
    case app(AppEntry)
    /// Programs from a subfolder of an applications folder (Utilities, or a vendor's folder). Folders
    /// of the same name in several applications folders are one folder, as /Applications/Utilities and
    /// /System/Applications/Utilities are.
    case folder(name: String, apps: [AppEntry])
}

/// All Programs as Windows 7 shows it: programs first, then folders, each sorted by name. A folder's
/// programs are listed under it, one level in, while it is expanded.
public enum ProgramTree {
    public struct Row: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case app(AppEntry)
            case folder(String, expanded: Bool)
        }
        public var kind: Kind
        public var depth: Int
        public init(kind: Kind, depth: Int) { self.kind = kind; self.depth = depth }
    }

    /// `roots` are the applications folders the catalog scanned. An app directly in a root is a
    /// top-level program; one in a subfolder of a root goes into that subfolder's folder. Apps outside
    /// every root are top-level programs.
    public static func build(_ apps: [AppEntry], roots: [String]) -> [ProgramNode] {
        let rootSet = Set(roots.map(normalized))
        var top: [AppEntry] = []
        var folders: [String: [AppEntry]] = [:]
        for app in apps {
            let parent = (normalized(app.path) as NSString).deletingLastPathComponent
            let grandparent = (parent as NSString).deletingLastPathComponent
            if !rootSet.contains(parent), rootSet.contains(grandparent) {
                folders[folderName(parent), default: []].append(app)
            } else {
                top.append(app)
            }
        }
        let byName: (AppEntry, AppEntry) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let folderNodes = folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ProgramNode.folder(name: $0, apps: folders[$0]!.sorted(by: byName)) }
        return top.sorted(by: byName).map(ProgramNode.app) + folderNodes
    }

    /// The visible rows: every node, plus the programs of each folder named in `expanded`.
    public static func rows(_ nodes: [ProgramNode], expanded: Set<String>) -> [Row] {
        var rows: [Row] = []
        for node in nodes {
            switch node {
            case .app(let app):
                rows.append(Row(kind: .app(app), depth: 0))
            case .folder(let name, let apps):
                let open = expanded.contains(name)
                rows.append(Row(kind: .folder(name, expanded: open), depth: 0))
                if open { rows += apps.map { Row(kind: .app($0), depth: 1) } }
            }
        }
        return rows
    }

    /// A click on a folder opens it, or closes it if open.
    public static func toggle(_ folder: String, in expanded: inout Set<String>) {
        if expanded.remove(folder) == nil { expanded.insert(folder) }
    }

    /// The folder's name as Finder shows it: without a `.localized` suffix.
    private static func folderName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix(".localized") ? String(name.dropLast(".localized".count)) : name
    }

    private static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
