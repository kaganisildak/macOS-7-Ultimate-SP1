import AppKit
import Win7Core

/// The taskbar's window level: the Dock's level (20), so app windows stay under the
/// bar while the Dock-level system UI (the screenshot thumbnail, notification banners) and the menu
/// bar draw above it. `defaults write com.win7mac.shell W7TaskbarLevelLegacy -bool YES` restores the
/// old `.statusBar` level (25) on the next launch.
enum TaskbarLevel {
    static let legacyKey = "W7TaskbarLevelLegacy"

    static func value(legacy: Bool) -> NSWindow.Level {
        NSWindow.Level(rawValue: ShellWindowLevels.taskbar(legacy: legacy))
    }

    static var current: NSWindow.Level { value(legacy: UserDefaults.standard.bool(forKey: legacyKey)) }
}
