import AppKit
import Win7Core

/// The Windows 7 Delete confirmation ("Are you sure you want to move this file to the Recycle Bin?")
/// with Yes and No, built on the Run dialog's AeroDialog. The item's icon sits at the top left.
@MainActor
final class DesktopConfirmBox: AeroDialog {
    private static var current: DesktopConfirmBox?
    private let onYes: () -> Void

    /// Shows the confirmation for `count` items (`isFolder` for a single folder); `onYes` runs on Yes.
    static func confirmTrash(count: Int, isFolder: Bool, icon: NSImage?, onYes: @escaping () -> Void) {
        current?.close()
        let text = DesktopMenuModel.deleteConfirmation(count: count, isFolder: isFolder)
        let box = DesktopConfirmBox(title: text.title, message: text.message, icon: icon, onYes: onYes)
        current = box
        if let screen = NSScreen.screens.first {
            box.setFrameOrigin(NSPoint(x: screen.frame.midX - box.frame.width / 2, y: screen.frame.midY - box.frame.height / 2))
        }
        NSApp.activate()
        box.makeKeyAndOrderFront(nil)
    }

    private init(title: String, message: String, icon: NSImage?, onYes: @escaping () -> Void) {
        self.onYes = onYes
        super.init(title: title, size: NSSize(width: 400, height: 128))
        body.message = message
        if let icon { body.icon = { icon.draw(in: $0) } }
        let no = bandButton("No", slot: 0, action: #selector(no(_:)))
        no.keyEquivalent = "\u{1b}"
        let yes = bandButton("Yes", slot: 1, action: #selector(yes(_:)))
        yes.keyEquivalent = "\r"
    }

    override func cancelOperation(_ sender: Any?) { no(nil) }

    @objc private func yes(_ sender: Any?) {
        close()
        DesktopConfirmBox.current = nil
        onYes()
    }

    @objc private func no(_ sender: Any?) {
        close()
        DesktopConfirmBox.current = nil
    }
}
