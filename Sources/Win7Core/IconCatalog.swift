import Foundation

/// Every icon override name the code reads (`Assets/icons/<name>.png`, names without `.png`): `shell` for the
/// shell, `chrome` for the injected dylib (also scripts/chrome-icon-names.txt, which `make chrome` embeds: it is
/// `IconCatalog.chrome` one name per line, in the same byte order as `LC_ALL=C sort`, and a test keeps the two equal).
/// Each list is sorted and has no duplicates. The map files (scripts/win7-icon-map.txt and
/// scripts/win7-asset-map.txt) are checked against it with `uncovered(names:iconMap:assetMapText:)`.
public enum IconCatalog {
    /// The names both the shell and the chrome read.
    private static let shared: [String] = [
        "file", "file-text", "file-image", "file-audio", "file-video",
        "folder", "folder-documents", "folder-pictures", "folder-music", "folder-videos", "folder-downloads",
        "folder-desktop", "folder-user", "user",
        "computer", "drive", "drive-system", "network", "recycle-bin-empty", "recycle-bin-full", "help", "favorites",
        "drive-removable", "drive-optical",   // the Computer view's drive tiles
        "recent-places", "shared",   // Finder's sidebar Recents and Shared rows
        "msgbox-warning", "msgbox-info",
    ] + apps

    /// `app-<bundle id>` for the applications the shell pins, lists or decorates by default.
    private static let apps: [String] = [
        "com.apple.finder", "com.apple.Safari", "com.apple.Music", "com.apple.TextEdit", "com.apple.Terminal",
        "com.apple.ActivityMonitor", "com.apple.systempreferences", "com.apple.calculator", "com.apple.Notes",
        "com.apple.Preview",
    ].map { "app-" + $0 }

    /// The notification area: TrayIcons.name for every state but the chevron, and TrayIcons.actionCenterName.
    private static let tray: [String] = {
        var names = ["wired", "disconnected", "no-network", "action-center", "action-center-alert"]
        for level in 0...4 {
            names += ["wifi-\(level)", "volume-\(level)", "battery-\(level)", "battery-\(level)-charging"]
        }
        return names.map { "tray-" + $0 }
    }()

    /// The Control Panel's own names: each category's and each item's first icon name (`cp-<id>`).
    private static let controlPanel: [String] =
        ControlPanelCategory.allCases.compactMap(\.iconNames.first) + ControlPanelCatalog.items.compactMap(\.iconNames.first)

    public static let shell: [String] = normalized(shared + [
        "documents", "pictures", "music", "control-panel", "devices", "games",
        "file-app", "run", "msgbox-error", "msgbox-question",
    ] + tray + controlPanel + DeviceKind.iconNames)   // dev-*: Device Manager, Devices and Printers

    public static let chrome: [String] = normalized(shared + ["ie-add-favorite", "ie-home", "ie-print", "ie-help", "ie-page"])

    /// The shell's and the chrome's names together, sorted, without duplicates.
    public static var all: [String] { normalized(shell + chrome) }

    private static func normalized(_ names: [String]) -> [String] { Array(Set(names)).sorted() }

    /// The names that neither map covers, in the order given: the icon map covers `name` when any of its
    /// targets is `<name>.png`; the asset map text covers it when a line's first field is `icons/<name>.png`
    /// (whatever the resource spec: `ICON/?`, not chosen yet, and `ICON/-`, no icon on this media, count as
    /// covered too). Comments in the asset map start at `#` at the start of
    /// a line or after a space or tab.
    public static func uncovered(names: [String], iconMap: IconMap, assetMapText: String) -> [String] {
        let targets = Set(iconMap.ids.values).union(iconMap.files.values)
        var assets = Set<String>()
        for raw in assetMapText.components(separatedBy: "\n") {
            let line = IconOverrideNames.stripComment(raw)
            guard let first = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).first,
                  first.hasPrefix("icons/") else { continue }
            assets.insert(String(first.dropFirst("icons/".count)))
        }
        return names.filter { !targets.contains($0 + ".png") && !assets.contains($0 + ".png") }
    }
}
