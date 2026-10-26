import AppKit
import Win7Core

/// The desktop's verbs: open (with), send to, trash, rename, new items, shortcuts, cut/copy/paste, move
/// into a folder, undo, properties and the Recycle Bin commands. File work runs off the main thread;
/// completions run on the main actor. Failures show a Windows 7-style balloon instead of crashing.
@MainActor
final class DesktopActions {
    /// Finder's "Show Info" service (Finder's Info.plist NSServices): Get Info without AppleScript.
    nonisolated static let showInfoService = "Finder/Show Info"

    let store: DesktopStore
    private var balloon: PermissionBalloon?
    /// Names cut with Cmd+X, valid while the pasteboard still holds what was cut.
    private var cut: (names: Set<String>, changeCount: Int)?
    /// Renames and moves into folders, for Undo.
    private var undoHistory = DesktopUndoController()

    init(store: DesktopStore) {
        self.store = store
    }

    // MARK: Open

    /// Opens with the busy cursor until each launch completes (LaunchFeedback).
    func open(_ names: [String]) {
        for n in names { LaunchFeedback.open(store.url(for: n)) }
    }

    func openRecycleBin() { NSWorkspace.shared.open(store.trashURL) }

    /// Open with ▸: the default application first, then the others, at most DesktopMenuModel.openWithLimit.
    func applications(toOpen name: String) -> [URL] {
        let url = store.url(for: name)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        if let preferred = NSWorkspace.shared.urlForApplication(toOpen: url) {
            apps.removeAll { $0.standardizedFileURL == preferred.standardizedFileURL }
            apps.insert(preferred, at: 0)
        }
        return Array(apps.prefix(DesktopMenuModel.openWithLimit))
    }

    func open(_ name: String, with app: URL) {
        let done = LaunchFeedback.shared.begin()
        NSWorkspace.shared.open([store.url(for: name)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    done()
                    if let error { self.showError(error) }
                }
            }
        }
    }

    /// "Choose default program…": Finder's Get Info, whose "Open with" section sets the default.
    func chooseDefaultProgram(_ name: String) { showInfo([store.url(for: name)]) }

    // MARK: Trash

    func trash(_ names: [String]) { trash(urls: names.map(store.url(for:))) }

    func trash(urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            do { _ = try await NSWorkspace.shared.recycle(urls) } catch { showError(error) }
            store.rescan()
        }
    }

    /// Delete: the Windows 7 confirmation first, then the Recycle Bin.
    func confirmTrash(_ names: [String], icon: NSImage?) {
        guard !names.isEmpty else { return }
        let single = names.count == 1 ? store.url(for: names[0]) : nil
        let isFolder = single.flatMap { try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) }
            .map { $0.isDirectory == true && $0.isPackage != true } ?? false
        DesktopConfirmBox.confirmTrash(count: names.count, isFolder: isFolder, icon: icon) { [weak self] in self?.trash(names) }
    }

    /// Finder's own "empty trash", which keeps its confirmation; the Empty Recycle Bin sound plays once
    /// it has emptied. (The AppleScript predates ; there is no public API that empties the Trash.)
    func emptyRecycleBin() {
        runAppleScript(["tell application \"Finder\" to empty trash"]) {
            SoundPlayer.play(.emptyRecycleBin)
        }
    }

    func recycleBinProperties() { showInfo([store.trashURL]) }

    func properties(_ names: [String]) {
        guard !names.isEmpty else { return }
        showInfo(names.map(store.url(for:)))
    }

    /// Get Info through Finder's Show Info service, on a background queue so a slow or busy Finder never
    /// blocks the desktop. Without the service, the items are shown selected in a Finder window instead.
    private func showInfo(_ urls: [URL]) {
        let paths = urls.map(\.path)
        let first = urls.first?.absoluteString
        DispatchQueue.global(qos: .userInitiated).async {
            let pb = NSPasteboard.withUniqueName()
            let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
            pb.declareTypes([filenames, .fileURL], owner: nil)
            pb.setPropertyList(paths, forType: filenames)
            if let first { pb.setString(first, forType: .fileURL) }
            let ok = NSPerformService(DesktopActions.showInfoService, pb)
            pb.releaseGlobally()
            if !ok {
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) }) }
            }
        }
    }

    // MARK: Create, rename, transfer

    func newFolder(done: @escaping (String) -> Void) {
        let files = store.files
        run({ try files.createFolder() }, done: done)
    }

    func newTextDocument(done: @escaping (String) -> Void) {
        let files = store.files
        run({ try files.createTextDocument() }, done: done)
    }

    func newRichTextDocument(done: @escaping (String) -> Void) {
        let files = store.files
        run({ try files.createRichTextDocument() }, done: done)
    }

    /// Renames and records the rename for Undo.
    func rename(_ name: String, to newName: String, done: @escaping (String) -> Void) {
        let files = store.files
        run({ try files.rename(name, to: newName) }) { [weak self] final in
            if final != name { self?.undoHistory.record(.rename(from: name, to: final)) }
            done(final)
        }
    }

    /// Create shortcut / Send to ▸ Desktop (create shortcut): a Finder alias "<name> - Shortcut" on the desktop.
    func createShortcuts(_ names: [String], done: @escaping ([String]) -> Void) {
        createShortcuts(to: names.map(store.url(for:)), done: done)
    }

    /// Paste shortcut: aliases on the desktop to the file URLs on the pasteboard.
    func pasteShortcuts(done: @escaping ([String]) -> Void) {
        guard let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return }
        createShortcuts(to: urls, done: done)
    }

    private func createShortcuts(to urls: [URL], done: @escaping ([String]) -> Void) {
        guard !urls.isEmpty else { return }
        let files = store.files
        run({ try urls.map { try files.createShortcut(to: $0) } }, done: done)
    }

    /// Send to ▸ Compressed (zipped) folder: one zip next to the items, named after the first one, made with
    /// `ditto -c -k --sequesterRsrc` (one item keeps its folder as the archive's root, as Windows does).
    func compress(_ names: [String], done: @escaping (String) -> Void) {
        guard let primary = names.first else { return }
        let files = store.files
        let urls = names.map(store.url(for:))
        run({ () throws -> String in
            let isDir = (try? urls[0].resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map {
                $0.isDirectory == true && $0.isPackage != true
            } ?? false
            let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: files.directory.path)) ?? [])
            let zipName = FileNaming.archiveName(for: primary, isDirectory: isDir, existing: existing)
            let dst = files.directory.appendingPathComponent(zipName)
            if urls.count == 1 {
                try DesktopActions.ditto(["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].path, dst.path])
            } else {
                // ditto archives one source: stage the items (APFS clones) in a temporary folder.
                let stage = FileManager.default.temporaryDirectory.appendingPathComponent("w7zip-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: stage) }
                for u in urls { try FileManager.default.copyItem(at: u, to: stage.appendingPathComponent(u.lastPathComponent)) }
                try DesktopActions.ditto(["-c", "-k", "--sequesterRsrc", stage.path, dst.path])
            }
            return zipName
        }, done: done)
    }

    nonisolated private static func ditto(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        // Drain stderr while ditto runs (to EOF, i.e. until it exits), so a full pipe can't block it.
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw DesktopActionError.compressFailed(String(decoding: errData, as: UTF8.self))
        }
    }

    /// Send to ▸ Mail recipient: a new message with the items attached.
    func mail(_ names: [String]) {
        let urls = names.map(store.url(for:))
        guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: urls) else {
            showError(DesktopActionError.noMail)
            return
        }
        service.perform(withItems: urls)
    }

    /// Moves or copies the sources onto the desktop in one sequential batch. `done` gets the names that
    /// arrived, even when some sources failed; the first failure shows in the balloon.
    func transfer(_ items: [DesktopTransfer], done: @escaping ([String]) -> Void) {
        guard !items.isEmpty else { return }
        let files = store.files
        run({ files.transfer(items) }) { [weak self] result in
            done(result.names)
            if let error = result.error {
                self?.showError(error)
                if result.names.isEmpty { self?.store.rescan() }
            }
        }
    }

    // MARK: Move into a folder, Undo

    /// Desktop items dropped on a folder icon move into it (Undo-able). Their desktop positions are dropped.
    func move(_ names: [String], into folder: String) {
        let files = store.files
        run({ files.moveIntoFolder(names, folder: folder) }) { [weak self] result in
            guard let self else { return }
            self.undoHistory.record(.move(result.moves))
            var positions = self.store.positions
            for m in result.moves { positions.removeValue(forKey: m.from.lastPathComponent) }
            self.store.positions = positions
            if let error = result.error { self.showError(error) }
            self.store.rescan()
        }
    }

    /// "Undo Rename" / "Undo Move", nil when there is nothing to undo (or an undo is running).
    var undoLabel: String? { undoHistory.label }

    /// Takes the last rename or move back (DesktopUndoController: one at a time; what couldn't be undone,
    /// such as the failed part of a move, stays in the history and the error shows). `done` gets the action
    /// and the desktop names that came back, when any did.
    func undo(done: @escaping (DesktopUndoAction, [String]) -> Void) {
        guard let action = undoHistory.begin() else { return }
        let files = store.files
        run({ files.undoResult(action) }) { [weak self] result in
            guard let self else { return }
            self.undoHistory.finish(action, remaining: result.remaining)
            if let error = result.error { self.showError(error) }
            if result.names.isEmpty { self.store.rescan() } else { done(action, result.names) }
        }
    }

    // MARK: Clipboard

    /// Copy and Cut with nothing to put on the pasteboard (no files, or only the Recycle Bin) leave it alone.
    func copy(_ names: [String]) {
        guard !names.isEmpty else { return }
        writePasteboard(names)
        cut = nil
    }

    func cut(_ names: [String]) {
        guard !names.isEmpty else { return }
        cut = (Set(names), writePasteboard(names))
    }

    /// Names drawn dimmed: the last cut, while the pasteboard still holds it.
    var cutNames: Set<String> {
        guard let cut, cut.changeCount == NSPasteboard.general.changeCount else { return [] }
        return cut.names
    }

    var canPaste: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// Pastes file URLs onto the desktop: moved after a cut from this desktop, copied otherwise.
    func paste(done: @escaping ([String]) -> Void) {
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return }
        let move = cut?.changeCount == pb.changeCount
        if move {
            cut = nil
            pb.clearContents()
        }
        transfer(urls.map { DesktopTransfer(url: $0, copy: !move) }, done: done)
    }

    @discardableResult
    private func writePasteboard(_ names: [String]) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(names.map { store.url(for: $0) as NSURL })
        return pb.changeCount
    }

    // MARK: Menus

    /// Builds an NSMenu from model titles ("—" = separator). `submenus` supplies the " ▸" entries. With a
    /// `context`, titles are shown with DesktopMenuModel.displayTitle and enabled by its rules.
    func menu(_ titles: [String], context: DesktopMenuContext? = nil, checked: Set<String> = [],
              disabled: Set<String> = [], submenus: [String: NSMenu] = [:],
              handler: @escaping (String) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for title in titles {
            if title == DesktopMenuModel.separator {
                menu.addItem(.separator())
                continue
            }
            let shown = context.map { DesktopMenuModel.displayTitle(title, context: $0) }
                ?? (title.hasSuffix(" ▸") ? String(title.dropLast(2)) : title)
            let item: NSMenuItem
            if let sub = submenus[title] {
                item = NSMenuItem(title: shown, action: nil, keyEquivalent: "")
                item.submenu = sub
            } else {
                item = Self.item(shown) { handler(title) }
            }
            item.state = checked.contains(title) ? .on : .off
            item.isEnabled = !disabled.contains(title) && (context.map { DesktopMenuModel.isEnabled(title: title, context: $0) } ?? true)
            menu.addItem(item)
        }
        return menu
    }

    /// A menu item that runs `body`.
    static func item(_ title: String, image: NSImage? = nil, _ body: @escaping @MainActor () -> Void) -> NSMenuItem {
        let target = MenuHandler(body)
        let item = NSMenuItem(title: title, action: #selector(MenuHandler.fire), keyEquivalent: "")
        item.target = target
        item.representedObject = target  // the target is weak; this keeps it alive
        item.image = image
        return item
    }

    // MARK: Errors and helpers

    func showError(_ error: Error) {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        balloon?.dismiss()
        let b = PermissionBalloon(message: text)
        balloon = b
        b.present()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak b] in
            MainActor.assumeIsolated {
                b?.dismiss()
                if self?.balloon === b { self?.balloon = nil }
            }
        }
    }

    /// Runs `work` off the main thread, then `done` on the main actor; errors go to the balloon.
    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T, done: @escaping (T) -> Void) {
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
            switch result {
            case .success(let value): done(value)
            case .failure(let error): showError(error); store.rescan()
            }
        }
    }

    private func runAppleScript(_ lines: [String], onSuccess: (@MainActor () -> Void)? = nil) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = lines.flatMap { ["-e", $0] }
        let stderr = Pipe()
        p.standardError = stderr
        p.terminationHandler = { [weak self] proc in
            guard proc.terminationStatus != 0 else {
                if let onSuccess { Task { @MainActor in onSuccess() } }
                return
            }
            let text = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard !text.contains("-128") else { return }  // the user cancelled Finder's confirmation
            let error: DesktopActionError = text.contains("-1743") ? .finderNotAllowed : .finderFailed(text)
            Task { @MainActor in self?.showError(error) }
        }
        do { try p.run() } catch { showError(error) }
    }
}

private enum DesktopActionError: LocalizedError {
    case finderNotAllowed
    case finderFailed(String)
    case compressFailed(String)
    case noMail

    var errorDescription: String? {
        switch self {
        case .finderNotAllowed:
            "Win7Shell isn't allowed to control Finder. Allow it in System Settings > Privacy & Security > Automation."
        case .finderFailed(let text):
            "Finder couldn't complete the operation. \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .compressFailed(let text):
            "The compressed (zipped) folder couldn't be created. \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .noMail:
            "No mail program is set up to send these items."
        }
    }
}

@MainActor
private final class MenuHandler: NSObject {
    let body: @MainActor () -> Void
    init(_ body: @escaping @MainActor () -> Void) { self.body = body }
    @objc func fire() { body() }
}
