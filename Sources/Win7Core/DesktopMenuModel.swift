public enum DesktopMenuContext: Sendable {
    case items(count: Int)
    case recycleBin
    /// `undo` is the label of what Undo would undo ("Undo Rename"), nil when there is nothing.
    case empty(canPaste: Bool, undo: String? = nil)
}

/// Titles of the desktop's context menus. "—" is a separator; a title ending in " ▸" has a submenu
/// (`viewTitles`, `sortTitles`, `newTitles`, `sendToTitles`; Open with is built from the item's apps).
/// Enablement is separate: see `isEnabled(title:context:)`; `displayTitle` gives the shown text.
public enum DesktopMenuModel {
    public static let separator = "—"

    public static func titles(for context: DesktopMenuContext) -> [String] {
        switch context {
        case .items(let count):
            var t = ["Open"]
            if count == 1 { t.append("Open with ▸") }
            t += ["—", "Send to ▸", "—", "Cut", "Copy", "—", "Create shortcut", "Delete"]
            if count == 1 { t.append("Rename") }
            return t + ["—", "Properties"]
        case .recycleBin:
            return ["Open", "—", "Empty Recycle Bin", "—", "Properties"]
        case .empty(_, let undo):
            var t = ["View ▸", "Sort by ▸", "Refresh", "—", "Paste", "Paste shortcut"]
            if undo != nil { t.append("Undo") }
            return t + ["—", "New ▸", "—", "Screen resolution", "Gadgets", "Personalize"]
        }
    }

    /// Paste and Paste shortcut on empty space are shown but disabled unless the pasteboard holds file URLs.
    public static func isEnabled(title: String, context: DesktopMenuContext) -> Bool {
        if case .empty(let canPaste, let undo) = context {
            if title == "Paste" || title == "Paste shortcut" { return canPaste }
            if title == "Undo" { return undo != nil }
        }
        return true
    }

    /// The text shown for `title`: Undo carries what it undoes; submenu titles lose their " ▸".
    public static func displayTitle(_ title: String, context: DesktopMenuContext) -> String {
        if title == "Undo", case .empty(_, let undo?) = context { return undo }
        return title.hasSuffix(" ▸") ? String(title.dropLast(2)) : title
    }

    public static let viewTitles = ["Large icons", "Medium icons", "Small icons", "—",
                                    "Auto arrange icons", "Align icons to grid", "—", "Show desktop icons"]
    public static let sortTitles = ["Name", "Size", "Item type", "Date modified"]
    public static let newTitles = ["Folder", "Shortcut…", "—", "Text Document", "Rich Text Document"]
    /// The New ▸ entries shown but not available (the Create Shortcut wizard isn't implemented).
    public static let newDisabled: Set<String> = ["Shortcut…"]
    public static let sendToTitles = ["Compressed (zipped) folder", "Desktop (create shortcut)", "Mail recipient"]
    /// Open with ▸ lists at most this many applications, then "Choose default program…".
    public static let openWithLimit = 8
    public static let chooseDefaultProgram = "Choose default program…"

    /// The Windows 7 Delete confirmation: title and question for one file, one folder or several items.
    public static func deleteConfirmation(count: Int, isFolder: Bool) -> (title: String, message: String) {
        if count > 1 {
            return ("Delete Multiple Items", "Are you sure you want to move these \(count) items to the Recycle Bin?")
        }
        return isFolder
            ? ("Delete Folder", "Are you sure you want to move this folder to the Recycle Bin?")
            : ("Delete File", "Are you sure you want to move this file to the Recycle Bin?")
    }
}
