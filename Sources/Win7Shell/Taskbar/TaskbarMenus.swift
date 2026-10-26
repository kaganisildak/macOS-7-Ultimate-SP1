import AppKit
import Win7ChromeCore
import Win7Core
import Win7Theme

/// The Windows 7 menus of the bare taskbar and the Start orb (right click), drawn by W7MenuWindow.
///
/// The shell activates itself for the menu's keyboard navigation. When the menu closes without a
/// choice, or with one that brings no app forward (arranging windows), the app that was frontmost
/// gets focus back.
@MainActor
final class TaskbarMenus: NSObject {
    var onShowDesktop: (() -> Void)?
    /// Whether the chosen item brought something else forward; read after the menu returns.
    private var choiceTakesFocus = false

    /// "Toolbars ▸" (disabled), the three arrangements (Accessibility), "Show the desktop", "Start
    /// Task Manager", "Lock the taskbar" (checked, disabled) and "Properties" (disabled).
    func showTaskbarMenu(at screenPoint: NSPoint, remembered: NSRunningApplication?) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let toolbars = NSMenuItem(title: "Toolbars", action: nil, keyEquivalent: "")
        toolbars.submenu = NSMenu(title: "Toolbars")
        toolbars.isEnabled = false
        menu.addItem(toolbars)
        menu.addItem(.separator())
        let ax = TaskbarWindowActions.isTrusted
        menu.addItem(item("Cascade windows", #selector(cascade(_:)), enabled: ax))
        menu.addItem(item("Show windows stacked", #selector(stacked(_:)), enabled: ax))
        menu.addItem(item("Show windows side by side", #selector(sideBySide(_:)), enabled: ax))
        menu.addItem(item("Show the desktop", #selector(showDesktop(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Start Task Manager", #selector(taskManager(_:))))
        menu.addItem(.separator())
        let lock = item("Lock the taskbar", nil, enabled: false)
        lock.state = .on
        menu.addItem(lock)
        menu.addItem(item("Properties", nil, enabled: false))
        run(menu, at: screenPoint, remembered: remembered)
    }

    /// "Properties" (disabled) and "Open Windows Explorer".
    func showOrbMenu(at screenPoint: NSPoint, remembered: NSRunningApplication?) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("Properties", nil, enabled: false))
        menu.addItem(item("Open Windows Explorer", #selector(explorer(_:))))
        run(menu, at: screenPoint, remembered: remembered)
    }

    private func item(_ title: String, _ action: Selector?, enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.isEnabled = enabled && action != nil
        return i
    }

    private func run(_ menu: NSMenu, at point: NSPoint, remembered: NSRunningApplication?) {
        let front = NSWorkspace.shared.frontmostApplication
        let previous = (front != nil && front != NSRunningApplication.current) ? front : remembered
        choiceTakesFocus = false
        // the shell is an accessory app, so it must be active for keyboard navigation.
        NSApp.activate()
        // Opened at the pointer; W7MenuWindow opens it upward, as it doesn't fit below the taskbar.
        ShellMenus.show(menu, at: point)
        if !choiceTakesFocus, NSApp.isActive, let previous, !previous.isTerminated { previous.activate() }
    }

    @objc private func cascade(_ sender: Any?) { TaskbarWindowActions.arrange(.cascade) }
    @objc private func stacked(_ sender: Any?) { TaskbarWindowActions.arrange(.stacked) }
    @objc private func sideBySide(_ sender: Any?) { TaskbarWindowActions.arrange(.sideBySide) }

    @objc private func showDesktop(_ sender: Any?) {
        choiceTakesFocus = true   // Show Desktop hides the apps and decides focus itself
        onShowDesktop?()
    }

    @objc private func taskManager(_ sender: Any?) {
        choiceTakesFocus = true
        TaskbarLaunch.startTaskManager()
    }

    @objc private func explorer(_ sender: Any?) {
        choiceTakesFocus = true
        TaskbarLaunch.openFinderHome()
    }
}
