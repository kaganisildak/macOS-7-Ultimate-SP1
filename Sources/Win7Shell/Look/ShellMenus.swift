import AppKit
import Win7ChromeCore

/// The shell's own menus (desktop items and empty space, Recycle Bin, taskbar and Start orb, taskbar buttons, tray
/// icons and the clock, the Start menu's, the Control Panel's "View by") drawn as Windows 7 menus by W7MenuWindow
///. Falls back to AppKit's menu at the same point whenever W7MenuWindow cannot show it (empty, a custom
/// view item, a modal session, another menu tracking) and with `defaults write -g W7ContextMenusDisabled -bool YES`.
@MainActor
enum ShellMenus {
    /// Shows `menu` with its top-left corner at `screenPoint` and tracks it; returns after the chosen item's action
    /// has run. W7MenuWindow opens it upward when it doesn't fit below the point. `above` (screen) is the rect a
    /// menu placed with pointAbove(_:for:) sits on: the AppKit fallback, whose rows are taller than W7's, is then
    /// placed on that rect by its own height instead of at the W7-sized point.
    static func show(_ menu: NSMenu, at screenPoint: NSPoint, minWidth: CGFloat = W7MenuMinWidth, above: NSRect? = nil) {
        if !W7ContextMenusDisabled(), W7MenuWindow.show(menu, topLeft: screenPoint, minWidth: minWidth) { return }
        menu.font = W7MenuWindowFont()
        var point = screenPoint
        if let above { point.y = above.maxY + menu.size.height }
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    /// The top-left corner, on screen, that puts a W7 menu for `menu` right above `rect` (screen coordinates): the
    /// menu's rows (22 pt items, 7 pt separators) plus its 2 pt padding at both ends.
    static func pointAbove(_ rect: NSRect, for menu: NSMenu) -> NSPoint {
        NSPoint(x: rect.minX, y: rect.maxY + W7MenuRowsHeight(W7MenuNodes(menu)) + 4)
    }
}
