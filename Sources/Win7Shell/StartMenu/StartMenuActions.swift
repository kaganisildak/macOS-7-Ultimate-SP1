import AppKit
import Win7Core

/// The Start menu's programs: the pinned and recent lists (persisted in the shell's defaults), and
/// what its items do when chosen.
@MainActor
final class StartMenuPrograms {
    private let defaults: UserDefaults
    private let store: StartMenuStore
    private(set) var model: StartMenuModel
    /// Names and bundle IDs of programs outside the catalog (Finder lives in CoreServices).
    private var entryCache: [String: AppEntry] = [:]

    /// The jump-list rows of each program (by bundle id) since the menu last opened.
    private var jumpLists: [String: [JumpListSection]] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        store = StartMenuStore(defaults: defaults)
        // The defaults apply on first run only (no saved pins): an existing user's pins are never reordered.
        model = store.load {
            StartMenuModel.defaultPinBundleIDs.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path }
        }
        observeLaunches()
    }

    /// Windows 7 counts every program start in the recent list, not only the Start menu's: launches seen through
    /// NSWorkspace (Dock, Finder, Spotlight) are recorded too (regular apps only, never the shell). The model records
    /// the path with symlinks resolved, the same entry as a Start menu launch of the program.
    private func observeLaunches() {
        let shellPath = Bundle.main.bundleURL.path
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil,
                                                          queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let path = app?.bundleURL?.path
            let regular = app?.activationPolicy == .regular
            MainActor.assumeIsolated {
                guard let self, StartMenuModel.recordsLaunch(path: path, regular: regular, shellPath: shellPath),
                      let path else { return }
                self.model.recordLaunch(path)
                self.store.save(self.model)
            }
        }
    }

    /// The program at `path` as the left pane shows it. Launches are recorded by canonical path (StartMenuModel
    /// resolves symlinks, so the catalog's `/Applications/Safari.app` and the running Safari's Cryptex path are one
    /// program); such a path still shows as the catalog's entry.
    func entry(forPath path: String, catalog: [AppEntry]) -> AppEntry {
        if let e = StartMenuModel.catalogEntry(forPath: path, in: catalog) ?? entryCache[path] { return e }
        let name = (FileManager.default.displayName(atPath: path) as NSString).deletingPathExtension
        let id = Bundle(path: path)?.bundleIdentifier
        let e = AppEntry(name: ProgramNames.displayName(bundleID: id, macName: name), path: path, bundleID: id)
        entryCache[path] = e
        return e
    }

    /// The left pane's two sections, without programs that were deleted.
    func sections(catalog: [AppEntry]) -> (pinned: [AppEntry], recent: [AppEntry]) {
        let s = model.sections { FileManager.default.fileExists(atPath: $0) }
        return (s.pinned.map { entry(forPath: $0, catalog: catalog) }, s.recent.map { entry(forPath: $0, catalog: catalog) })
    }

    func isPinned(_ e: AppEntry) -> Bool { model.isPinned(e.path) }

    /// Opens the program (StartMenuLaunch): Terminal as Command Prompt, Calculator outside All Programs as the shell's
    /// Windows 7 Calculator, anything else as itself. Each counts as a launch for the recent list (by canonical path,
    /// so the did-launch notification that follows records no second entry).
    func launch(_ e: AppEntry, inAllPrograms: Bool) {
        model.recordLaunch(e.path)
        store.save(model)
        switch StartMenuLaunch.target(bundleID: e.bundleID, inAllPrograms: inAllPrograms) {
        case .commandPrompt: Self.launchCommandPrompt()
        case .shellCalculator: ShellScreens.open(.calculator)
        case .application: LaunchFeedback.openApplication(at: URL(fileURLWithPath: e.path))   // busy cursor
        }
    }

    /// Command Prompt: Terminal opens the "Win7 Command Prompt" profile file (a new window with that profile; no
    /// AppleScript), or starts as it is when the file is missing (CommandPromptLaunch).
    static func launchCommandPrompt() {
        let candidates = AssetStore.shared.candidates(CommandPromptLaunch.profileRelativePath)
        let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CommandPromptLaunch.terminalBundleID)
        switch CommandPromptLaunch.target(candidates: candidates, fileExists: { FileManager.default.fileExists(atPath: $0) }) {
        case .profile(let file):
            guard let terminal else { LaunchFeedback.open(file); return }
            let done = LaunchFeedback.shared.begin()
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
            }
        case .terminal:
            if let terminal { LaunchFeedback.openApplication(at: terminal) }
        }
    }

    func togglePin(_ e: AppEntry) {
        if model.isPinned(e.path) { model.unpin(e.path) } else { model.pin(e.path) }
        store.save(model)
    }

    func removeFromList(_ e: AppEntry) {
        model.removeRecent(e.path)
        store.save(model)
    }

    // MARK: Taskbar pins

    func isTaskbarPinned(_ e: AppEntry) -> Bool {
        guard let id = e.bundleID else { return false }
        return TaskbarPinList.load(defaults).contains { $0.bundleID == id }
    }

    /// Edits the taskbar's own pin list and announces it (TaskbarPinList.didChange).
    func toggleTaskbarPin(_ e: AppEntry) {
        guard let id = e.bundleID else { return }
        TaskbarPinList.save(TaskbarPinList.toggled(TaskbarPinList.load(defaults), bundleID: id, name: e.name), defaults)
        NotificationCenter.default.post(name: TaskbarPinList.didChange, object: nil)
    }

    // MARK: Jump lists

    /// The taskbar jump list's Recent (and for Windows Explorer, Frequent) rows for `e`, read once per menu opening
    /// with the taskbar's readers (RecentDocuments, FrequentFolders). Empty without a bundle id.
    func jumpSections(_ e: AppEntry) -> [JumpListSection] {
        guard let id = e.bundleID else { return [] }
        if let known = jumpLists[id] { return known }
        let home = NSHomeDirectory()
        let recent = RecentDocuments.load(bundleID: id,
                                          directory: RecentDocuments.defaultDirectory(home: FileManager.default.homeDirectoryForCurrentUser),
                                          home: home)
        let frequent = id == TaskbarLaunch.finderID
            ? FrequentFolders.load(preference: CFPreferencesCopyAppValue(FrequentFolders.key as CFString,
                                                                         FrequentFolders.domain as CFString), home: home)
            : nil
        let sections = StartMenuJumpList.sections(recent: recent, frequent: frequent)
        jumpLists[id] = sections
        return sections
    }

    /// The menu opened again: documents may have changed since.
    func forgetJumpLists() { jumpLists = [:] }

    // MARK: Places

    /// Computer: Finder's own Computer helper (it opens a Finder window at the Computer location, which the chrome
    /// draws as the Windows 7 Computer view), through NSWorkspace; the root folder when the helper is missing or fails.
    static func openComputer() {
        let root = URL(fileURLWithPath: "/")
        let helper = URL(fileURLWithPath: StartMenuPlaces.finderComputerHelper)
        guard FileManager.default.fileExists(atPath: helper.path) else {
            ShellWindowButtons.log.info("start menu: no Finder Computer helper, opening the root folder")
            NSWorkspace.shared.open(root)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: helper, configuration: config) { _, error in
            guard error != nil else { return }
            Task { @MainActor in
                ShellWindowButtons.log.error("start menu: Finder Computer helper failed, opening the root folder")
                NSWorkspace.shared.open(root)
            }
        }
    }

    // MARK: Files

    static func open(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }

    /// "Open file location": the item selected in a Finder window of its folder.
    static func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
}

/// A menu item's action as a closure. The item keeps it alive through `representedObject`
/// (NSMenuItem.target is weak).
final class MenuAction: NSObject {
    private let body: @MainActor () -> Void
    init(_ body: @escaping @MainActor () -> Void) { self.body = body }
    @MainActor @objc func run(_ sender: Any?) { body() }

    @MainActor static func item(_ title: String, enabled: Bool = true, _ body: @escaping @MainActor () -> Void) -> NSMenuItem {
        let action = MenuAction(body)
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        item.isEnabled = enabled
        return item
    }
}
