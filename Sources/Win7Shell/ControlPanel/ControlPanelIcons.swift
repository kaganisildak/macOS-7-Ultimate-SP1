import AppKit
import Win7Core
import Win7Theme

/// The Control Panel's icons: the user's imported PNG (`Assets/icons/cp-<name>.png`, then an older shared name,
/// see scripts/win7-icon-map.txt), otherwise one of Win7Theme's procedural icons. No artwork of its own.
@MainActor
enum ControlPanelIcons {
    /// Procedural fallbacks already drawn by Win7Theme (or the desktop's folder art).
    enum Glyph {
        case nav(W7NavPaneGlyph)
        case folder(DesktopFolderArt)
        case tray(W7TrayIcon, Int)
        case flag, clock, help, star
    }

    private static var cache: [String: NSImage] = [:]

    static func category(_ c: ControlPanelCategory, side: CGFloat) -> NSImage {
        image(names: c.iconNames, glyph: glyph(for: c), side: side)
    }

    static func item(_ item: ControlPanelItem, side: CGFloat) -> NSImage {
        image(names: item.iconNames, glyph: itemGlyphs[item.id] ?? item.categories.first.map(glyph(for:)) ?? .nav(.appBadge),
              side: side)
    }

    /// The window's own icon (taskbar button, address bar): `control-panel.png`, else a drawn monitor.
    static func window(side: CGFloat) -> NSImage {
        image(names: ["control-panel"], glyph: .nav(.computer), side: side)
    }

    static func image(names: [String], glyph: Glyph, side: CGFloat) -> NSImage {
        let key = names.joined(separator: ",") + "|\(side)"
        if let hit = cache[key] { return hit }
        let img = names.lazy.compactMap { IconOverrides.image($0, side: side) }.first ?? draw(glyph, side: side)
        cache[key] = img
        return img
    }

    private static func glyph(for c: ControlPanelCategory) -> Glyph {
        switch c {
        case .systemAndSecurity: .flag
        case .userAccounts: .folder(.user)
        case .networkAndInternet: .nav(.network)
        case .appearance: .folder(.pictures)
        case .hardwareAndSound: .tray(.volume, 4)
        case .clockLanguageRegion: .clock
        case .programs: .nav(.appBadge)
        case .easeOfAccess: .help
        }
    }

    private static let itemGlyphs: [String: Glyph] = [
        "action-center": .flag, "windows-firewall": .nav(.network), "system": .nav(.computer),
        "windows-update": .nav(.systemDrive), "power-options": .tray(.battery, 4), "backup-restore": .nav(.drive),
        "bitlocker": .nav(.systemDrive), "administrative-tools": .nav(.systemDrive), "credential-manager": .nav(.tag),
        "homegroup": .folder(.plain), "internet-options": .nav(.network), "display": .nav(.computer),
        "desktop-gadgets": .clock, "taskbar-start-menu": .nav(.appBadge), "notification-area-icons": .flag,
        "folder-options": .folder(.plain), "fonts": .folder(.documents), "devices-printers": .nav(.computer),
        "autoplay": .nav(.drive), "sound": .tray(.volume, 4), "mobility-center": .tray(.battery, 3),
        "mouse": .nav(.appBadge), "keyboard": .nav(.appBadge), "date-time": .clock, "region-language": .nav(.network),
        "default-programs": .star, "speech-recognition": .tray(.volume, 2), "getting-started": .star,
        "indexing-options": .nav(.tag), "color-management": .folder(.pictures), "performance": .nav(.computer),
        "troubleshooting": .help, "recovery": .nav(.drive), "location-sensors": .nav(.network), "sync-center": .nav(.cloud),
    ]

    /// The shared override a fallback glyph tries before it is drawn (the tray glyphs through TrayIcons' names);
    /// nil for the glyphs that stay drawn (the clock, tag, cloud and application badge).
    private static func overrideName(_ glyph: Glyph) -> String? {
        switch glyph {
        case .help: "help"
        case .star: "favorites"
        case .nav(.computer): "computer"
        case .nav(.network): "network"
        case .nav(.drive): "drive"
        case .nav(.systemDrive): "drive-system"
        case .nav: nil
        case .folder(let art): IconOverrideNames.folder(art)
        case .tray(let kind, let level): TrayIcons.name(kind, level, false)
        case .flag: TrayIcons.actionCenterName(alert: false)
        case .clock: nil
        }
    }

    private static func draw(_ glyph: Glyph, side: CGFloat) -> NSImage {
        if let name = overrideName(glyph), let img = IconOverrides.image(name, side: side) { return img }
        if case .folder(let art) = glyph, let folder = DesktopFolderIcons.image(art, side: side) { return folder }
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            switch glyph {
            case .nav(let g): W7DrawNavPaneGlyph(ctx, rect, g)
            case .tray(let kind, let level): W7DrawTrayIcon(ctx, rect, kind, level, false)
            case .flag: W7DrawActionCenterFlag(ctx, rect, false)
            case .clock where side < 24: W7DrawNavPaneGlyph(ctx, rect, .appBadge)   // the gadget clock doesn't read at 16 pt
            case .clock: W7DrawGadgetClock(ctx, rect.insetBy(dx: 1, dy: 1), 305, 60, 180)   // 10:10
            case .help: W7DrawHelpButton(ctx, rect.insetBy(dx: side * 0.08, dy: side * 0.08))
            case .star: W7DrawFavoritesStar(ctx, rect)
            case .folder: W7DrawNavPaneGlyph(ctx, rect, .appBadge)
            }
            return true
        }
    }
}
