import Foundation

/// The Windows 7 names the shell shows for Mac programs — in the Start menu (left pane, All Programs,
/// search hits), taskbar tooltips and jump list headers, and the switcher. A program without an entry keeps its
/// macOS name. Only the shown name changes; programs are still found and launched by path and bundle ID.
public enum ProgramNames {
    /// Bundle ID (exact case) → Windows name.
    public static let table: [String: String] = [
        "com.apple.finder": "Windows Explorer",
        "com.apple.Safari": "Internet Explorer",
        "com.apple.Terminal": "Command Prompt",
        "com.apple.Notes": "Sticky Notes",
        "com.apple.TextEdit": "Notepad",
        "com.apple.ActivityMonitor": "Task Manager",
        "com.apple.Music": "Windows Media Player",
        "com.apple.Preview": "Windows Photo Viewer",
        "com.apple.calculator": "Calculator",
        "com.apple.systempreferences": "Control Panel",
        "com.apple.mail": "Windows Live Mail",
        "com.apple.MobileSMS": "Windows Live Messenger",
        "com.apple.Photos": "Windows Live Photo Gallery",
    ]

    /// The Windows name of the program with this bundle ID, or nil (the macOS name stays).
    public static func windowsName(bundleID: String) -> String? { table[bundleID] }

    /// The name to show: the Windows name when there is one, else `macName`.
    public static func displayName(bundleID: String?, macName: String) -> String {
        bundleID.flatMap(windowsName(bundleID:)) ?? macName
    }

    /// The catalog with Windows names, sorted by the names shown (as AppCatalog.scan sorts).
    public static func renamed(_ entries: [AppEntry]) -> [AppEntry] {
        entries.map { e in
            var e = e
            e.name = displayName(bundleID: e.bundleID, macName: e.name)
            return e
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Taskbar buttons with Windows names, in their own order: TaskbarView's reload and each step of a drag reorder
    /// (tooltips, jump list headers, close prompts).
    public static func renamed(_ items: [TaskbarItem]) -> [TaskbarItem] {
        items.map { item in
            var item = item
            item.name = displayName(bundleID: item.bundleID, macName: item.name)
            return item
        }
    }

    /// What else finds a program in the Start menu's search (AppCatalog.search's `extraTerms`): its macOS name (the
    /// bundle's file name), and "cmd" for Command Prompt, as Windows users type it.
    public static func searchTerms(_ entry: AppEntry) -> [String] {
        var terms = [(entry.path as NSString).lastPathComponent].map { ($0 as NSString).deletingPathExtension }
            .filter { !$0.isEmpty && $0 != entry.name }
        if entry.bundleID == CommandPromptLaunch.terminalBundleID { terms.append("cmd") }
        return terms
    }
}

/// How the shell opens Command Prompt: the "Win7 Command Prompt" Terminal profile file (install.sh generates it in
/// `Assets/terminal/`), opened with NSWorkspace — Terminal opens a window with that profile; no AppleScript — or
/// plain Terminal when the file is missing.
public enum CommandPromptLaunch {
    public static let terminalBundleID = "com.apple.Terminal"
    public static let profileName = "Win7 Command Prompt"
    /// The profile file, relative to an Assets root (AssetStore's roots).
    public static let profileRelativePath = "terminal/\(profileName).terminal"

    public enum Target: Equatable, Sendable {
        /// Open this `.terminal` file.
        case profile(URL)
        /// Launch Terminal (terminalBundleID) as it is.
        case terminal
    }

    /// Whether starting this program means Command Prompt (the Start menu, a taskbar pin, a jump list's program row):
    /// Terminal, by exact bundle ID.
    public static func isCommandPrompt(bundleID: String?) -> Bool { bundleID == terminalBundleID }

    /// The first of `candidates` that exists, else plain Terminal.
    public static func target(candidates: [URL], fileExists: (String) -> Bool) -> Target {
        candidates.first { fileExists($0.path) }.map(Target.profile) ?? .terminal
    }
}
