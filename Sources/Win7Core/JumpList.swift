import Foundation

// MARK: - Jump list model

/// A document the app opened recently, as its jump list shows it.
public struct RecentDocument: Equatable, Sendable {
    /// The file name without its extension (Windows 7 hides known extensions).
    public var name: String
    public var path: String
    public init(name: String, path: String) { self.name = name; self.path = path }
}

public enum JumpListAction: Equatable, Sendable {
    /// Open the document with the button's app.
    case openRecent(path: String)
    /// Open a frequent folder in Finder.
    case openFolder(path: String)
    /// The app's name: launch it, or ask a running app for a new window.
    case launch
    case pin, unpin
    /// Close the app's front window: through the app when the dylib is in it, else with
    /// Accessibility; without either, explain why it cannot.
    case closeWindow
    /// Close each window: through the app when the dylib is in it, else with Accessibility,
    /// else quit the app after asking.
    case closeAllWindows
}

/// What a jump list's close item does, given the Accessibility permission and whether the dylib is in the app.
public enum JumpListCloseEffect: Equatable, Sendable {
    /// The dylib is in the app: post `com.win7mac.closeWindow.<pid>` /
    /// `com.win7mac.closeAllWindows.<pid>`; the app closes its windows itself (`performClose:`) and
    /// exits when none is left. No permission needed.
    case askApp
    /// "Close window" with Accessibility: press the front window's close button.
    case closeFrontWindow
    /// "Close window" without Accessibility: the system prompt and the Accessibility balloon (at most
    /// once per 60 s).
    case hintAccessibility
    /// "Close all windows" with Accessibility: press each window's close button.
    case closeEachWindow
    /// "Close all windows" without Accessibility: ask, then quit the app.
    case confirmQuit
}

/// A piece of a heading drawn in small caps: `small` pieces are capitals at a smaller size.
public struct SmallCapsRun: Equatable, Sendable {
    public var text: String
    public var small: Bool
    public init(text: String, small: Bool) { self.text = text; self.small = small }
}

public struct JumpListItem: Equatable, Sendable {
    public var title: String
    public var action: JumpListAction
    public init(title: String, action: JumpListAction) { self.title = title; self.action = action }
}

public enum JumpListSectionKind: Equatable, Sendable {
    /// Finder's recent folders, under a "Frequent" heading.
    case frequent
    /// The app's recent documents, under a "Recent" heading.
    case recent
    /// The fixed tasks at the bottom, under a "Tasks" heading: the app, pin/unpin, close.
    case tasks
}

public struct JumpListSection: Equatable, Sendable {
    public var kind: JumpListSectionKind
    public var title: String?
    public var items: [JumpListItem]
    public init(kind: JumpListSectionKind, title: String?, items: [JumpListItem]) {
        self.kind = kind; self.title = title; self.items = items
    }
}

/// What a jump list is built from.
public struct JumpListInput: Sendable {
    public var appName: String
    public var isPinned: Bool
    public var isRunning: Bool
    /// The app's windows (with Accessibility, minimized ones too).
    public var windowCount: Int
    public var accessibility: Bool
    /// nil when the recent-documents list could not be read.
    public var recent: [RecentDocument]?
    /// Frequent folders (Finder only); nil when there are none to read.
    public var frequent: [RecentDocument]?
    public init(appName: String, isPinned: Bool, isRunning: Bool, windowCount: Int, accessibility: Bool,
                recent: [RecentDocument]?, frequent: [RecentDocument]? = nil) {
        self.appName = appName; self.isPinned = isPinned; self.isRunning = isRunning
        self.windowCount = windowCount; self.accessibility = accessibility; self.recent = recent
        self.frequent = frequent
    }
}

/// Windows 7's jump list for a taskbar button.
public enum JumpList {
    public static let maxRecent = 10

    /// "Frequent" and "Recent" (each when there are any), then "Tasks" at the bottom: the app's name,
    /// pin or unpin, and for a running app one close item, as in Windows 7: "Close window" with
    /// exactly one window, "Close all windows" with two or more (with or without Accessibility).
    public static func sections(_ input: JumpListInput) -> [JumpListSection] {
        var result: [JumpListSection] = []
        if let frequent = input.frequent, !frequent.isEmpty {
            result.append(JumpListSection(kind: .frequent, title: "Frequent", items: frequent.prefix(maxRecent).map {
                JumpListItem(title: $0.name, action: .openFolder(path: $0.path))
            }))
        }
        if let recent = input.recent, !recent.isEmpty {
            result.append(JumpListSection(kind: .recent, title: "Recent", items: recent.prefix(maxRecent).map {
                JumpListItem(title: $0.name, action: .openRecent(path: $0.path))
            }))
        }
        var tasks = [JumpListItem(title: input.appName, action: .launch)]
        tasks.append(input.isPinned ? JumpListItem(title: "Unpin this program from taskbar", action: .unpin)
                                    : JumpListItem(title: "Pin this program to taskbar", action: .pin))
        if input.isRunning {
            if input.windowCount >= 2 {
                tasks.append(JumpListItem(title: "Close all windows", action: .closeAllWindows))
            } else if input.windowCount == 1 {
                tasks.append(JumpListItem(title: "Close window", action: .closeWindow))
            }
        }
        result.append(JumpListSection(kind: .tasks, title: "Tasks", items: tasks))
        return result
    }

    /// Without Accessibility "Close all windows" can only quit the app, so it asks first.
    public static func closeAllNeedsConfirmation(accessibility: Bool) -> Bool { !accessibility }

    /// What a close item does; nil for the other items. `decorated`: the dylib is in the app (the app
    /// is eligible for the chrome and the close channel is not switched off), so the app is asked first.
    public static func closeEffect(_ action: JumpListAction, accessibility: Bool,
                                   decorated: Bool = false) -> JumpListCloseEffect? {
        switch action {
        case .closeWindow:
            return decorated ? .askApp : accessibility ? .closeFrontWindow : .hintAccessibility
        case .closeAllWindows:
            if decorated { return .askApp }
            return closeAllNeedsConfirmation(accessibility: accessibility) ? .confirmQuit : .closeEachWindow
        case .openRecent, .openFolder, .launch, .pin, .unpin: return nil
        }
    }

    /// After `.askApp`: nil when the app answered (its acknowledgement arrived) or one of its
    /// windows went away meanwhile; otherwise the undecorated effect (Accessibility when trusted, else
    /// the hint or the confirmation), as if the dylib were not there.
    public static func closeFallback(_ action: JumpListAction, acknowledged: Bool, windowsBefore: Int,
                                     windowsAfter: Int, accessibility: Bool) -> JumpListCloseEffect? {
        if acknowledged || windowsAfter < windowsBefore { return nil }
        return closeEffect(action, accessibility: accessibility, decorated: false)
    }

    /// Apps that stay running when their last window is closed from the taskbar (Windows Explorer
    /// never exits).
    public static let keepAliveBundleIDs: Set<String> = ["com.apple.finder"]

    /// the global defaults array of bundle ids that also stay running
    /// (`defaults write -g W7CloseKeepAlive -array <bundle id>…`; empty by default, Finder always implied).
    /// The dylib reads the same key (W7CloseKeepAliveDefaultsKey).
    public static let keepAliveDefaultsKey = "W7CloseKeepAlive"

    /// The bundle ids in a `W7CloseKeepAlive` defaults value; anything not a string is ignored.
    public static func keepAlive(fromDefaultsValue value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// Whether an app is quit after a taskbar close, as Windows 7 exits a program whose last window
    /// closed: only when no window is left, and never Finder or an app on `keepAlive` (W7CloseKeepAlive).
    public static func shouldTerminate(bundleID: String, windowsLeft: Int, keepAlive: [String] = []) -> Bool {
        windowsLeft <= 0 && !keepAliveBundleIDs.contains(bundleID) && !keepAlive.contains(bundleID)
    }

    /// the windows an app still has for the shell's exit check: the larger of the Accessibility
    /// count (current Space only, minimized windows too) and the CG `.optionAll` count (every Space,
    /// `WindowList.eligibleCount`), so an app that may still have a window anywhere is never quit.
    public static func windowsLeft(ax: Int, cg: Int) -> Int { max(ax, cg) }

    /// Whether the shell itself checks, after `effect`, that the app has no window left and quits it:
    /// after its Accessibility closes. An asked app decides that itself (the dylib); the hint and the
    /// confirmation close nothing.
    public static func shellChecksExit(after effect: JumpListCloseEffect) -> Bool {
        effect == .closeFrontWindow || effect == .closeEachWindow
    }

    /// A heading in small caps: its first character as is, the rest as capitals drawn smaller.
    /// Uppercasing is locale independent, so a Turkish "i" stays "I".
    public static func smallCapsRuns(_ title: String) -> [SmallCapsRun] {
        guard let first = title.first else { return [] }
        let rest = title.dropFirst()
        return [SmallCapsRun(text: String(first), small: false)]
            + (rest.isEmpty ? [] : [SmallCapsRun(text: rest.uppercased(), small: true)])
    }

    /// Whether choosing `action` hands focus to something else: the app (opening a document, the
    /// app's name) or the confirmation box. If not, the jump list gives focus back to the app that was
    /// frontmost before it opened, as when it is dismissed.
    /// Asking the app (`decorated`) shows no confirmation first.
    public static func choiceTakesFocus(_ action: JumpListAction, accessibility: Bool, decorated: Bool = false) -> Bool {
        switch action {
        case .openRecent, .openFolder, .launch: return true
        case .closeAllWindows: return !decorated && closeAllNeedsConfirmation(accessibility: accessibility)
        case .pin, .unpin, .closeWindow: return false
        }
    }

    /// Up/Down over `count` items, wrapping; from no selection Down picks the first, Up the last.
    public static func moveSelection(_ current: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return delta >= 0 ? 0 : count - 1 }
        return ((current + delta) % count + count) % count
    }
}

// MARK: - Recent documents

/// Reads an app's recent documents from LaunchServices' shared file list:
/// `<directory>/<bundle id lowercased>.sfl4` (current macOS; else `.sfl3`, then `.sfl2`), a keyed archive of
/// `{"items": [{"Bookmark": <bookmark data>, ...}], ...}`, most recent first.
public enum RecentDocuments {
    /// `~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments`.
    public static func defaultDirectory(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
            .appendingPathComponent("com.apple.LSSharedFileList.ApplicationRecentDocuments")
    }

    public static func archiveURLs(bundleID: String, directory: URL) -> [URL] {
        let base = bundleID.lowercased()
        return ["sfl4", "sfl3", "sfl2"].map { directory.appendingPathComponent("\(base).\($0)") }
    }

    /// The classes the archive may contain. Anything else fails the decode before it is instantiated.
    static let allowedClasses: [AnyClass] = [NSDictionary.self, NSArray.self, NSData.self, NSString.self,
                                             NSNumber.self, NSUUID.self, NSURL.self]

    /// The items' bookmark data, in order; nil when `data` is not such an archive. The archive is
    /// user-writable and the shell is Accessibility-trusted, so it is decoded with secure coding ON
    /// (the unarchiver's default) and the allow-list: no other class, nested anywhere, is ever
    /// instantiated. The system's own .sfl2/.sfl3/.sfl4 archives decode this way.
    public static func bookmarks(fromArchive data: Data) -> [Data]? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        defer { unarchiver.finishDecoding() }
        guard let root = unarchiver.decodeObject(of: allowedClasses, forKey: NSKeyedArchiveRootObjectKey) as? NSDictionary,
              unarchiver.error == nil,
              let items = root["items"] as? NSArray else { return nil }
        var result: [Data] = []
        for case let item as NSDictionary in items {
            guard let mark = item["Bookmark"] else { continue }
            guard let data = mark as? Data else { return nil }   // not the shape we know: no section
            result.append(data)
        }
        return result
    }

    /// Folders macOS guards with a privacy prompt (Desktop, Documents, Downloads, iCloud Drive, cloud
    /// storage, other apps' containers and group containers, other volumes). Nothing in them is
    /// resolved or checked, so no prompt can appear.
    public static func isPrivacyProtected(_ path: String, home: String) -> Bool {
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        let guarded = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage",
                       "Library/Containers", "Library/Group Containers"]
            .map { "\(h)/\($0)" } + ["/Volumes"]
        return guarded.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Up to `limit` documents for `bundleID`; nil when no archive can be read or decoded (the jump
    /// list then has no Recent section). Files outside the protected folders are resolved (no UI,
    /// no mounting) and skipped when missing; files inside them are listed by their stored path.
    public static func load(bundleID: String, directory: URL, home: String, limit: Int = JumpList.maxRecent,
                            fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [RecentDocument]? {
        guard let marks = archiveURLs(bundleID: bundleID, directory: directory).lazy
            .compactMap({ try? Data(contentsOf: $0) }).first.flatMap(bookmarks(fromArchive:)) else { return nil }
        var docs: [RecentDocument] = []
        var seen = Set<String>()
        for mark in marks where docs.count < limit {
            guard let path = path(of: mark, home: home, fileExists: fileExists), seen.insert(path).inserted else { continue }
            let file = (path as NSString).lastPathComponent
            let name = (file as NSString).deletingPathExtension
            docs.append(RecentDocument(name: name.isEmpty ? file : name, path: path))
        }
        return docs
    }

    /// Known gap (move-then-resolve): a file recorded outside the protected folders and moved into
    /// one afterwards is still resolved, and resolution follows it by file ID into that folder, so
    /// that one lookup touches it. The stored path is all that can be checked without file-system
    /// access; the resolved path is then listed without an existence check.
    /// Shared with `FrequentFolders`, so both follow the same rules.
    static func path(of bookmark: Data, home: String, fileExists: (String) -> Bool) -> String? {
        // The path stored in the bookmark, read without touching the file system. A bookmark without
        // one cannot be placed, so it is skipped rather than resolved blind.
        guard let stored = (URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark))?.path else { return nil }
        if isPrivacyProtected(stored, home: home) { return stored }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale), url.isFileURL else { return nil }
        let path = url.path
        if isPrivacyProtected(path, home: home) { return path }
        return fileExists(path) ? path : nil
    }
}

// MARK: - Frequent folders (Finder)

/// Finder's recent folders, for its jump list's "Frequent" section: the `FXRecentFolders` array in
/// Finder's preferences, most recent first, each `{"file-bookmark": <bookmark data>, "name": <the
/// name Finder shows>}`. It is a property list, so only plist types can be in it, and no archive is
/// unarchived; anything that is not a dictionary with bookmark data is skipped. The bookmarks follow
/// `RecentDocuments`' rules: protected folders are listed by their stored path (never resolved or
/// checked), others are resolved without UI or mounting and skipped when missing.
public enum FrequentFolders {
    public static let domain = "com.apple.finder"
    public static let key = "FXRecentFolders"

    /// Up to `limit` folders; nil when `preference` is missing or not an array (no section).
    public static func load(preference: Any?, home: String, limit: Int = JumpList.maxRecent,
                            fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [RecentDocument]? {
        guard let entries = preference as? [Any] else { return nil }
        var folders: [RecentDocument] = []
        var seen = Set<String>()
        for case let entry as [String: Any] in entries where folders.count < limit {
            guard let mark = entry["file-bookmark"] as? Data,
                  let path = RecentDocuments.path(of: mark, home: home, fileExists: fileExists),
                  seen.insert(path).inserted else { continue }
            let stored = (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            folders.append(RecentDocument(name: stored ?? (path as NSString).lastPathComponent, path: path))
        }
        return folders
    }
}
