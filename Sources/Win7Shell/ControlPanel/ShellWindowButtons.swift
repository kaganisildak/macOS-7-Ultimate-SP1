import AppKit
import os
import Win7Core

/// Shell-owned windows that get a taskbar button like an app window. The taskbar leaves the shell's
/// own process out (RunningAppsObserver), since its panels are the taskbar, the desktop and the menus; a window
/// registered here is allow-listed by its identifier (`win7.controlpanel`), which stands in for a bundle id
/// while the window is open or minimized.
@MainActor
enum ShellWindowButtons {
    /// Posted when a registered window opens, closes, (de)miniaturizes or gains or loses key status.
    static let didChange = Notification.Name("com.win7mac.shell.windowButtonsChanged")

    struct Entry {
        let identifier: String
        let name: String
        let window: () -> NSWindow?
        let icon: (CGFloat) -> NSImage
    }

    private static var entries: [Entry] = []

    /// Control Panel and taskbar-button diagnostics:
    /// `log stream --predicate 'subsystem == "com.win7mac.shell" AND category == "controlpanel"'`.
    static let log = Logger(subsystem: "com.win7mac.shell", category: "controlpanel")

    static func register(_ entry: Entry) {
        entries.removeAll { $0.identifier == entry.identifier }
        entries.append(entry)
        log.info("taskbar: registered shell window button \(entry.identifier, privacy: .public)")
        changed()
    }

    static func entry(_ identifier: String) -> Entry? { entries.first { $0.identifier == identifier } }

    static func changed() { NotificationCenter.default.post(name: didChange, object: nil) }

    private static func isOpen(_ w: NSWindow) -> Bool { w.isVisible || w.isMiniaturized }
    private static func isActive(_ w: NSWindow) -> Bool { NSApp.isActive && w.isKeyWindow && !w.isMiniaturized }

    /// The open windows as running taskbar entries of the shell's process, in registration order.
    static func runningApps(pid: Int32, order: (String) -> Int) -> [RunningApp] {
        entries.compactMap { e in
            guard let w = e.window(), isOpen(w) else { return nil }
            return RunningApp(bundleID: e.identifier, name: e.name, pid: pid, isActive: isActive(w),
                              launchOrder: order(e.identifier))
        }
    }

    /// A left click on the button, as Windows 7 does it for a single window: the active window minimizes,
    /// any other state restores it and brings it forward. False when `identifier` is not a shell window's.
    @discardableResult static func click(_ identifier: String) -> Bool {
        guard let e = entry(identifier) else { return false }
        guard let w = e.window() else {
            log.error("taskbar: \(identifier, privacy: .public) clicked but its window is gone")
            return true
        }
        let active = isActive(w)
        log.info("taskbar: \(identifier, privacy: .public) clicked, active=\(active), minimized=\(w.isMiniaturized)")
        if active {
            w.miniaturize(nil)
        } else {
            bringForward(w)
        }
        return true
    }

    /// Restores and raises `w`. The shell is an accessory app and macOS may refuse its activation while
    /// another app is frontmost, so the window is also ordered front regardless: it always comes up.
    static func bringForward(_ w: NSWindow) {
        if w.isMiniaturized { w.deminiaturize(nil) }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    /// The button's right-click menu (Windows 7's jump list for a window without tasks).
    static func menu(_ identifier: String) -> NSMenu? {
        guard let e = entry(identifier) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(MenuAction.item(e.name) { if let w = e.window() { bringForward(w) } })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Close window") { e.window()?.performClose(nil) })
        return menu
    }
}
