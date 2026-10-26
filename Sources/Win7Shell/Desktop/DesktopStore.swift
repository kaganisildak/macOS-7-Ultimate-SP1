import AppKit
import Win7Core

/// An item's display name and icon, keyed to the modification date it was read at. NSImage isn't
/// Sendable; these are created in the scan task and only read on the main actor afterwards.
struct DesktopLook: @unchecked Sendable {
    let label: String
    let icon: NSImage
    let stamp: Date
    /// The Windows 7 folder art drawn instead of `icon` (DesktopFolderArt.art), nil to draw `icon`.
    var art: DesktopFolderArt? = nil
    /// The `Assets/icons/` override a file or application is drawn with when its PNG exists
    /// (IconOverrideNames.desktop), nil to keep `icon`.
    var fileIcon: String? = nil
    /// A real folder (not a package) that desktop items can be dropped into.
    var isFolder = false
}

/// The desktop's model: scans and watches the desktop folder (off the main thread), keeps the persisted
/// icon positions and View/Sort settings, and tracks whether the Trash is full. The directory and the
/// defaults are injectable; the shell uses ~/Desktop and `UserDefaults.standard`.
@MainActor
final class DesktopStore {
    static let positionsKey = "desktopPositions"
    static let iconSizeKey = "desktopIconSize"
    static let autoArrangeKey = "desktopAutoArrange"
    static let showIconsKey = "desktopShowIcons"
    static let sortKey = "desktopSort"
    /// Position key of the Recycle Bin. A slash can't appear in a file name, so it never collides.
    static let recycleBinID = "/Recycle Bin"

    let files: DesktopFiles
    let trashURL: URL
    private let defaults: UserDefaults

    private(set) var entries: [DesktopEntry] = []
    /// Display name (Finder's, honouring hidden extensions) and icon per entry name.
    private(set) var looks: [String: DesktopLook] = [:]
    private(set) var recycleBinFull = false
    private(set) var scanError: Error?
    /// True once a scan has succeeded and the last one did. Until then `entries` isn't the folder's real
    /// content, so positions must not be pruned against it.
    private(set) var isLoaded = false
    /// Called on the main actor after every applied scan.
    var onChange: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var trashSource: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    private var generation = 0
    private var pending: [() -> Void] = []

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"),
         trash: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"),
         defaults: UserDefaults = .standard) {
        files = DesktopFiles(directory: directory)
        trashURL = trash
        self.defaults = defaults
    }

    // MARK: Settings

    var positions: [String: [Int]] {
        get { (defaults.dictionary(forKey: Self.positionsKey) as? [String: [Int]]) ?? [:] }
        set { if newValue != positions { defaults.set(newValue, forKey: Self.positionsKey) } }
    }

    var iconSize: DesktopIconSize {
        get { defaults.string(forKey: Self.iconSizeKey).flatMap(DesktopIconSize.init(rawValue:)) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: Self.iconSizeKey) }
    }

    var autoArrange: Bool {
        get { defaults.bool(forKey: Self.autoArrangeKey) }
        set { defaults.set(newValue, forKey: Self.autoArrangeKey) }
    }

    var showIcons: Bool {
        get { defaults.object(forKey: Self.showIconsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.showIconsKey) }
    }

    var sort: DesktopSort {
        get { defaults.string(forKey: Self.sortKey).flatMap(DesktopSort.init(rawValue:)) ?? .name }
        set { defaults.set(newValue.rawValue, forKey: Self.sortKey) }
    }

    func url(for name: String) -> URL { files.directory.appendingPathComponent(name) }

    /// Ids in the current sort order, Recycle Bin first.
    var orderedIDs: [String] {
        [Self.recycleBinID] + DesktopOrdering.sorted(entries, by: sort).map(\.name)
    }

    // MARK: Scanning and watching

    func start() {
        rescan()
        source = watch(files.directory)
        trashSource = watch(trashURL)
    }

    /// Debounced (200 ms) rescan, for watcher events.
    func scheduleRescan() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.rescan() } }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    /// Scans off the main thread; `then` runs once a scan started at or after this call is applied.
    func rescan(then: (() -> Void)? = nil) {
        if let then { pending.append(then) }
        generation += 1
        let g = generation
        let files = files, trash = trashURL
        let known = looks.mapValues(\.stamp)
        Task.detached(priority: .userInitiated) {
            let result = Result { try files.scan() }
            // Icons and display names go through LaunchServices; read only new or changed entries, here.
            var fresh: [String: DesktopLook] = [:]
            for e in (try? result.get()) ?? [] where known[e.name] != e.modified {
                fresh[e.name] = DesktopStore.look(files.directory.appendingPathComponent(e.name).path, stamp: e.modified)
            }
            let full = DesktopStore.trashHasItems(trash)
            await self.apply(result, fresh: fresh, trashFull: full, generation: g)
        }
    }

    nonisolated private static func look(_ path: String, stamp: Date) -> DesktopLook {
        let url = URL(fileURLWithPath: path)
        let traits = DesktopFolderArt.traits(of: url)
        let art = DesktopFolderArt.art(for: traits, home: NSHomeDirectory())
        // Applications get `app-<bundle id>` (read from the bundle's Info.plist, here off the main actor, and only
        // for an application that can use it: not one with a custom icon, nor a link to one), files their type's
        // override; folders are the art's.
        let readsID = traits.isApplication && !traits.hasCustomIcon && !traits.isSymlink && !traits.isAlias
        let fileIcon = traits.isDirectory && !traits.isApplication ? nil
            : IconOverrideNames.desktop(traits, type: (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType,
                                        bundleID: readsID ? IconOverrideNames.bundleIdentifier(ofApp: url) : nil)
        // Folders drawn with the art don't need LaunchServices' icon. Files and applications keep theirs as the
        // fallback for a missing override PNG.
        let icon = art == nil ? NSWorkspace.shared.icon(forFile: path) : NSImage()
        return DesktopLook(label: FileManager.default.displayName(atPath: path), icon: icon, stamp: stamp, art: art,
                           fileIcon: fileIcon,
                           isFolder: traits.isDirectory && !traits.isPackage && !traits.isSymlink && !traits.isAlias)
    }

    private func apply(_ result: Result<[DesktopEntry], Error>, fresh: [String: DesktopLook], trashFull: Bool, generation g: Int) {
        guard g == generation else { return }
        switch result {
        case .success(let e): entries = e; scanError = nil; isLoaded = true
        case .failure(let error): entries = []; scanError = error; isLoaded = false
        }
        var next: [String: DesktopLook] = [:]
        for e in entries {
            if let look = fresh[e.name] ?? looks[e.name], look.stamp == e.modified {
                next[e.name] = look
            } else {  // a rare race with an older scan's cache; read it here
                next[e.name] = Self.look(url(for: e.name).path, stamp: e.modified)
            }
        }
        looks = next
        recycleBinFull = trashFull
        onChange?()
        let done = pending
        pending = []
        for f in done { f() }
    }

    nonisolated private static func trashHasItems(_ url: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.contains { $0 != ".DS_Store" && $0 != ".localized" }
    }

    /// A `.write` vnode source on `url` (nil if it can't be opened, e.g. the Trash without access).
    private func watch(_ url: URL) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleRescan() } }
        s.setCancelHandler { close(fd) }
        s.resume()
        return s
    }
}
