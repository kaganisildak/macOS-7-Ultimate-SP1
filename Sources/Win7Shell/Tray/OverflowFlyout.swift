import AppKit
import Win7Theme

/// The chevron (overflow) flyout. macOS menu-bar extras can't be moved into the taskbar, so this
/// offers a "Show macOS menu bar" toggle to reach them, plus links to Wi-Fi, Bluetooth and Control
/// Center settings.
@MainActor
final class OverflowFlyout: NSView {
    static let size = NSSize(width: 230, height: 124)
    private let toggle: NSButton

    init() {
        toggle = NSButton(checkboxWithTitle: "Show macOS menu bar", target: nil, action: nil)
        super.init(frame: NSRect(origin: .zero, size: OverflowFlyout.size))
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.font = W7UIFont(12)
        toggle.isEnabled = false   // until the current state is known
        toggle.sizeToFit()
        toggle.setFrameOrigin(NSPoint(x: 12, y: bounds.height - 30))
        addSubview(toggle)

        let links: [(String, String)] = [
            ("Wi-Fi settings", "x-apple.systempreferences:com.apple.wifi-settings-extension"),
            ("Bluetooth settings", "x-apple.systempreferences:com.apple.BluetoothSettings"),
            ("Control Center settings", "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"),
        ]
        for (i, (title, url)) in links.enumerated() {
            let link = FlyoutLink(title) { openSettings(url) }
            link.setFrameOrigin(NSPoint(x: 14, y: bounds.height - 58 - CGFloat(i) * 22))
            addSubview(link)
        }

        MenuBarSetting.readAutohide { [weak self] autohide in
            guard let self, let autohide else { return }
            self.toggle.state = autohide ? .off : .on
            self.toggle.isEnabled = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggled() {
        let show = toggle.state == .on
        toggle.isEnabled = false
        MenuBarSetting.setAutohide(!show) { [weak self] in self?.toggle.isEnabled = true }
    }
}

/// Reads and writes System Events' `autohide menu bar` with osascript, asynchronously.
enum MenuBarSetting {
    private static let prefix = "tell application \"System Events\" to tell dock preferences to "

    @MainActor
    static func readAutohide(_ completion: @escaping @MainActor (Bool?) -> Void) {
        run(prefix + "get autohide menu bar") { out in
            switch out?.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "true": completion(true)
            case "false": completion(false)
            default: completion(nil)
            }
        }
    }

    @MainActor
    static func setAutohide(_ hide: Bool, completion: @escaping @MainActor () -> Void) {
        run(prefix + "set autohide menu bar to \(hide)") { _ in completion() }
    }

    /// Runs `osascript -e script` and hands its standard output (nil on failure) to the main actor.
    @MainActor
    private static func run(_ script: String, completion: @escaping @MainActor (String?) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let text = proc.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
            Task { @MainActor in completion(text) }
        }
        do { try p.run() } catch { completion(nil) }
    }
}
