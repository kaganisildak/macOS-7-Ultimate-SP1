import Foundation

// MARK: - Pinned and recent programs

/// The Start menu's left pane, as Windows 7 fills it: the programs the user pinned, a separator, then
/// the most recently launched programs that are not pinned. Programs are identified by bundle path.
public struct StartMenuModel: Equatable, Sendable {
    /// Recent programs shown under the pinned ones.
    public static let maxRecents = 10
    /// Launches remembered, so that pinned programs in the history still leave ten others to show.
    static let storedRecents = 30
    /// Pinned on first run only: the programs that have Windows 7 icons, Windows Explorer and the
    /// browser first. Saved pins are never touched, so an existing user's list and order stay as they are.
    public static let defaultPinBundleIDs = ["com.apple.finder", "com.apple.Safari", "com.apple.calculator",
                                             "com.apple.Notes", "com.apple.Terminal", "com.apple.Preview"]

    /// Whether a launch the shell saw (NSWorkspace's did-launch notification, so from the Dock, Finder, Spotlight
    /// or the Start menu itself) joins the recent list: a regular app bundle, not the shell and not one of Finder's
    /// location helpers (the Start menu's Computer).
    public static func recordsLaunch(path: String?, regular: Bool, shellPath: String?) -> Bool {
        guard regular, let path, path.hasSuffix(".app"), path != shellPath else { return false }
        return !path.hasPrefix(StartMenuPlaces.finderHelpersDirectory + "/")
    }

    public private(set) var pins: [String]
    /// Every remembered launch, most recent first (pinned programs included).
    public private(set) var history: [String]

    public init(pins: [String] = [], history: [String] = []) {
        self.pins = pins
        self.history = history
    }

    /// The path a program is one program by: symlinks resolved. The catalog lists `/Applications/Safari.app`,
    /// a symlink, while NSRunningApplication reports its Cryptex path; both are the same Safari. A path that does not
    /// exist comes back as it is.
    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// The catalog's entry for `path`: the same path, else the entry whose canonical path is the same (a recent
    /// launch recorded by its canonical path shows as the catalog's program). Only entries with the same bundle
    /// name are resolved.
    public static func catalogEntry(forPath path: String, in catalog: [AppEntry]) -> AppEntry? {
        if let e = catalog.first(where: { $0.path == path }) { return e }
        let name = (path as NSString).lastPathComponent
        let canonical = canonicalPath(path)
        return catalog.first { ($0.path as NSString).lastPathComponent == name && canonicalPath($0.path) == canonical }
    }

    private static func same(_ a: String, _ b: String) -> Bool { a == b || canonicalPath(a) == canonicalPath(b) }

    public func isPinned(_ path: String) -> Bool { pins.contains { Self.same($0, path) } }

    /// Appends `path` to the pinned programs (Windows 7 adds new pins at the bottom of the list).
    public mutating func pin(_ path: String) {
        if !isPinned(path) { pins.append(path) }
    }

    public mutating func unpin(_ path: String) { pins.removeAll { Self.same($0, path) } }

    /// Records a start of the program at `path` by its canonical path, replacing earlier entries of the same program
    /// under any path.
    public mutating func recordLaunch(_ path: String) {
        let canonical = Self.canonicalPath(path)
        history.removeAll { $0 == canonical || Self.canonicalPath($0) == canonical }
        history.insert(canonical, at: 0)
        if history.count > StartMenuModel.storedRecents { history.removeLast(history.count - StartMenuModel.storedRecents) }
    }

    /// "Remove from this list": forgets the launch, so the program leaves the recent list.
    public mutating func removeRecent(_ path: String) { history.removeAll { Self.same($0, path) } }

    /// The pinned programs that still exist, then up to `maxRecents` recent ones that exist and are
    /// not pinned (compared by canonical path; a program in the history twice shows once).
    public func sections(exists: (String) -> Bool) -> (pinned: [String], recent: [String]) {
        let pinned = pins.filter(exists)
        var seen = Set(pins.map(Self.canonicalPath))
        var recent: [String] = []
        for path in history where recent.count < StartMenuModel.maxRecents {
            guard seen.insert(Self.canonicalPath(path)).inserted, exists(path) else { continue }
            recent.append(path)
        }
        return (pinned, recent)
    }
}

/// The ▸ a pinned or recent program shows in Windows 7 when it has a jump list: hovering it (or a click) opens the
/// taskbar jump list's document rows next to the menu.
public enum StartMenuJumpList {
    /// The arrow's part at the right end of the row.
    public static let arrowWidth: CGFloat = 22
    /// Hovering the arrow this long opens the list (the taskbar thumbnails' delay).
    public static let hoverDelay: TimeInterval = 0.4

    /// The taskbar jump list's Frequent and Recent sections (JumpList.sections), without its Tasks.
    public static func sections(recent: [RecentDocument]?, frequent: [RecentDocument]?) -> [JumpListSection] {
        JumpList.sections(JumpListInput(appName: "", isPinned: false, isRunning: false, windowCount: 0,
                                        accessibility: false, recent: recent, frequent: frequent))
            .filter { $0.kind != .tasks }
    }

    /// Only rows of the pinned and recent lists (`listed`) have the arrow, and only when there is something in it.
    public static func showsArrow(listed: Bool, sections: [JumpListSection]) -> Bool {
        listed && sections.contains { !$0.items.isEmpty }
    }

    /// Which row's ▸ the pointer is on, and whether resting there may open the list: once a list closed
    /// (Esc, a click outside, a choice) while the pointer stays on its arrow, small moves on that arrow highlight it
    /// without opening the list again; the pointer has to leave the arrow first.
    public struct ArrowHover: Equatable, Sendable {
        /// The row whose ▸ is hot (the pointer is on it, or its list is open).
        public private(set) var row: Int?
        /// The row whose list just closed, until the pointer leaves its arrow.
        private var dismissed: Int?

        public init() {}

        /// The pointer moved; `over` is the row whose ▸ it is on (nil: none). Returns true when the dwell that opens
        /// the list should start now.
        public mutating func pointer(over: Int?) -> Bool {
            if over != dismissed { dismissed = nil }
            guard over != row else { return false }
            row = over
            return over != nil && over != dismissed
        }

        /// Row `i`'s list is opening (by the dwell, a click or the Right key): its arrow stays hot meanwhile.
        public mutating func open(row i: Int) { row = i }

        /// Row `i`'s list closed: it does not open again until the pointer has left the arrow.
        public mutating func listClosed(row i: Int) {
            row = nil
            dismissed = i
        }

        /// The rows changed or the menu closed: nothing is remembered.
        public mutating func reset() { self = ArrowHover() }
    }
}

/// Where the right column's items go.
public enum StartMenuPlaces {
    /// Finder's own location helper apps (Computer, Network, AirDrop, Recents).
    public static let finderHelpersDirectory = "/System/Library/CoreServices/Finder.app/Contents/Applications"
    /// Computer: Finder's helper that opens a Finder window at its Computer location (as Go ▸ Computer), which the
    /// chrome draws as the Windows 7 Computer view. Opened with NSWorkspace; the root folder when it is missing.
    public static let finderComputerHelper = finderHelpersDirectory + "/Computer.app"
    /// Default Programs: the Control Panel item of that name.
    public static let defaultProgramsItemID = "default-programs"
}

/// What choosing a program in the Start menu opens. Terminal is Command Prompt wherever it is
/// listed (CommandPromptLaunch). Calculator in the left pane (pins, recents) and the search hits is the shell's own
/// Windows 7 Calculator; All Programs keeps the macOS Calculator under its macOS name. Everything else opens as an
/// application. Names come from ProgramNames.
public enum StartMenuLaunch: Equatable, Sendable {
    case application, commandPrompt, shellCalculator

    public static let calculatorBundleID = "com.apple.calculator"

    public static func target(bundleID: String?, inAllPrograms: Bool) -> StartMenuLaunch {
        if CommandPromptLaunch.isCommandPrompt(bundleID: bundleID) { return .commandPrompt }
        return bundleID == calculatorBundleID && !inAllPrograms ? .shellCalculator : .application
    }
}

/// Reads and writes the Start menu's pins and recents in the shell's defaults (com.win7mac.shell).
public struct StartMenuStore {
    public static let pinsKey = "startPins"
    /// The key the earlier Start menu kept its recents under (`{"paths": [...]}`), kept so they carry over.
    public static let recentsKey = "recentApps"

    private struct Recents: Codable { var paths: [String] }

    public let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// The saved model. On first run (no pins saved yet) `defaultPins` is used and saved at once, so a
    /// default pin the user removes stays removed.
    public func load(defaultPins: () -> [String]) -> StartMenuModel {
        let history = defaults.data(forKey: StartMenuStore.recentsKey)
            .flatMap { try? JSONDecoder().decode(Recents.self, from: $0) }?.paths ?? []
        if let data = defaults.data(forKey: StartMenuStore.pinsKey),
           let pins = try? JSONDecoder().decode([String].self, from: data) {
            return StartMenuModel(pins: pins, history: history)
        }
        let model = StartMenuModel(pins: defaultPins(), history: history)
        save(model)
        return model
    }

    public func save(_ model: StartMenuModel) {
        if let pins = try? JSONEncoder().encode(model.pins) { defaults.set(pins, forKey: StartMenuStore.pinsKey) }
        if let recents = try? JSONEncoder().encode(Recents(paths: model.history)) {
            defaults.set(recents, forKey: StartMenuStore.recentsKey)
        }
    }
}

/// The taskbar's pinned apps, as the taskbar stores them (a JSON `[PinnedApp]` under `pinnedApps`), so
/// the Start menu's "Pin to Taskbar" edits the same list.
public enum TaskbarPinList {
    public static let key = "pinnedApps"
    /// Posted (on NotificationCenter.default) after the Start menu saved a changed list.
    public static let didChange = Notification.Name("com.win7mac.taskbarPinsChanged")

    public static func load(_ defaults: UserDefaults) -> [PinnedApp] {
        guard let data = defaults.data(forKey: key),
              let pins = try? JSONDecoder().decode([PinnedApp].self, from: data) else { return TaskbarModel.defaultPins }
        return pins
    }

    public static func save(_ pins: [PinnedApp], _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(pins) { defaults.set(data, forKey: key) }
    }

    /// Unpins `bundleID` if pinned, otherwise pins it at the end.
    public static func toggled(_ pins: [PinnedApp], bundleID: String, name: String) -> [PinnedApp] {
        if pins.contains(where: { $0.bundleID == bundleID }) { return pins.filter { $0.bundleID != bundleID } }
        return pins + [PinnedApp(bundleID: bundleID, name: name)]
    }
}

// MARK: - Search results

/// Windows 7 lists documents apart from other files (pictures, folders and the rest).
public enum FileHitKind: Equatable, Sendable { case document, other }

public struct FileHit: Equatable, Hashable, Sendable {
    public var name: String
    public var path: String
    public var kind: FileHitKind
    /// The Uniform Type Identifier, for the icon (so the file itself is never read).
    public var contentType: String?
    public init(name: String, path: String, kind: FileHitKind, contentType: String?) {
        self.name = name; self.path = path; self.kind = kind; self.contentType = contentType
    }
}

public enum SearchItem: Equatable, Sendable {
    case program(AppEntry)
    case file(FileHit)
}

public struct SearchSection: Equatable, Sendable {
    /// "Programs (n)", with n the number of matches before the cap.
    public var title: String
    public var items: [SearchItem]
}

public enum StartMenuSearchResults {
    /// Files asked of Spotlight.
    public static let fileQueryLimit = 20
    /// Typing waits this long before the file query starts.
    public static let debounce: TimeInterval = 0.15

    /// "Programs (n)", "Documents (n)", "Files (n)", each listing at most `limit` items. Empty groups
    /// are left out.
    public static func sections(programs: [AppEntry], files: [FileHit], limit: Int) -> [SearchSection] {
        let documents = files.filter { $0.kind == .document }
        let others = files.filter { $0.kind == .other }
        let groups: [(String, [SearchItem])] = [
            ("Programs", programs.map(SearchItem.program)),
            ("Documents", documents.map(SearchItem.file)),
            ("Files", others.map(SearchItem.file)),
        ]
        return groups.compactMap { name, items in
            items.isEmpty ? nil : SearchSection(title: "\(name) (\(items.count))", items: Array(items.prefix(limit)))
        }
    }

    /// A document is any file that is neither a folder nor an image (from kMDItemContentTypeTree).
    /// Package documents (Pages, Keynote, Numbers, RTFD) are directories but also content, so content
    /// is checked before the folder and package types.
    public static func kind(contentTypeTree: [String]) -> FileHitKind {
        if contentTypeTree.isEmpty || contentTypeTree.contains("public.image") { return .other }
        if contentTypeTree.contains("public.composite-content") || contentTypeTree.contains("public.content") { return .document }
        let other: Set<String> = ["public.folder", "public.directory", "com.apple.package"]
        return contentTypeTree.contains(where: other.contains) ? .other : .document
    }

    private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "photoslibrary", "musiclibrary", "tvlibrary",
        "photolibrary", "xcodeproj", "xcworkspace", "playground", "rtfd", "pages", "numbers", "key",
        "lproj", "xcassets", "appex", "pkg", "mpkg", "imovielibrary", "fcpbundle", "logicx", "band",
    ]

    /// Whether a Spotlight hit belongs in the results: inside the home folder, not in ~/Library or a
    /// hidden folder, not an app (those are programs) and not inside a package.
    public static func isListable(path: String, home: String) -> Bool {
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(prefix) else { return false }
        let parts = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard let first = parts.first, first != "Library" else { return false }
        for (i, part) in parts.enumerated() {
            if part.hasPrefix(".") { return false }
            let ext = (part as NSString).pathExtension.lowercased()
            if ext == "app" { return false }
            if i < parts.count - 1, packageExtensions.contains(ext) { return false }
        }
        return true
    }

    /// The text as a `LIKE[cd]` pattern matching it anywhere in the name; `*` and `?` match literally.
    public static func likePattern(_ text: String) -> String {
        var escaped = ""
        for c in text {
            if c == "*" || c == "?" || c == "\\" { escaped.append("\\") }
            escaped.append(c)
        }
        return "*\(escaped)*"
    }
}

// MARK: - Keyboard focus

/// Which Start menu item the keyboard highlights. Windows 7: Up/Down move through the programs pane
/// (or the search results); Right/Left switch to and from the right column; Tab cycles programs →
/// right column → power button. With nothing highlighted, typing goes to the search box.
public struct StartMenuFocus: Equatable, Sendable {
    public enum Zone: Equatable, Sendable { case programs, places, power }
    public enum Key: Sendable { case up, down, left, right, tab, backTab }
    public struct Counts: Equatable, Sendable {
        public var programs, places, power: Int
        public init(programs: Int, places: Int, power: Int) { self.programs = programs; self.places = places; self.power = power }
        func count(_ zone: Zone) -> Int {
            switch zone { case .programs: programs; case .places: places; case .power: power }
        }
    }

    public var zone: Zone?
    public var index: Int

    public init(zone: Zone? = nil, index: Int = 0) { self.zone = zone; self.index = index }

    private static let cycle: [Zone] = [.programs, .places, .power]

    /// Moves for `key`. Returns false when the key is not the Start menu's to handle (Left with nothing
    /// highlighted belongs to the search box).
    public mutating func handle(_ key: Key, _ counts: Counts) -> Bool {
        guard let zone else {
            switch key {
            case .down, .tab: enter(.programs, counts, forward: true)
            case .up: enter(.programs, counts, forward: true, last: true)
            case .right: enter(.places, counts, forward: true)
            case .backTab: enter(.power, counts, forward: false)
            case .left: return false
            }
            return true
        }
        let n = counts.count(zone)
        switch (key, zone) {
        case (.down, .power), (.up, .power):
            if key == .up { enter(.places, counts, forward: false, last: true) }
        case (.down, _): index = n > 0 ? (index + 1) % n : 0
        case (.up, _): index = n > 0 ? (index - 1 + n) % n : 0
        case (.right, .programs): enter(.places, counts, forward: true)
        case (.right, .places): return true
        case (.right, .power): index = min(index + 1, max(n - 1, 0))
        case (.left, .programs): return false
        case (.left, .places): enter(.programs, counts, forward: false)
        case (.left, .power):
            if index > 0 { index -= 1 } else { enter(.places, counts, forward: false) }
        case (.tab, _): enter(next(zone, by: 1), counts, forward: true)
        case (.backTab, _): enter(next(zone, by: -1), counts, forward: false)
        }
        return true
    }

    /// Keeps the focus valid after the lists changed: the index is clamped, an emptied zone clears it.
    public mutating func clamp(_ counts: Counts) {
        guard let zone else { return }
        let n = counts.count(zone)
        if n == 0 { self = StartMenuFocus() } else { index = min(index, n - 1) }
    }

    private func next(_ zone: Zone, by step: Int) -> Zone {
        let i = StartMenuFocus.cycle.firstIndex(of: zone)!
        return StartMenuFocus.cycle[(i + step + 3) % 3]
    }

    /// Focuses `target`, or the next non-empty zone in the Tab direction.
    private mutating func enter(_ target: Zone, _ counts: Counts, forward: Bool, last: Bool = false) {
        var z = target
        for _ in 0..<3 {
            let n = counts.count(z)
            if n > 0 {
                zone = z
                index = last ? n - 1 : 0
                return
            }
            z = next(z, by: forward ? 1 : -1)
        }
        self = StartMenuFocus()
    }
}
