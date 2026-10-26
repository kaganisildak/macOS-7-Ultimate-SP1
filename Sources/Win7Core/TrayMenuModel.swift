import Foundation

/// System Settings panes the notification area opens (`x-apple.systempreferences:` URLs).
public enum SettingsPane: String, CaseIterable, Sendable {
    case sound = "com.apple.Sound-Settings.extension"
    case network = "com.apple.Network-Settings.extension"
    case wifi = "com.apple.wifi-settings-extension"
    case dateTime = "com.apple.Date-Time-Settings.extension"
    case battery = "com.apple.Battery-Settings.extension"
    case notifications = "com.apple.Notifications-Settings.extension"
    case accessibilityPrivacy = "com.apple.preference.security?Privacy_Accessibility"
    case screenRecordingPrivacy = "com.apple.preference.security?Privacy_ScreenCapture"

    public var url: URL { URL(string: "x-apple.systempreferences:" + rawValue)! }
}

/// What a tray menu item (or an Action Center button) does.
public enum TrayMenuAction: Equatable, Sendable {
    case open(SettingsPane)
    /// Launches the Wireless Diagnostics app.
    case wirelessDiagnostics
    /// Opens the notification area's overflow (chevron) flyout.
    case showOverflow
}

public struct TrayMenuEntry: Equatable, Sendable {
    public let title: String
    public let action: TrayMenuAction
    public let enabled: Bool
    public init(_ title: String, _ action: TrayMenuAction, enabled: Bool = true) {
        self.title = title
        self.action = action
        self.enabled = enabled
    }
}

/// The tray icons with a right-click menu.
public enum TrayMenuIcon: Sendable { case volume, network, clock, actionCenter, battery }

/// The right-click menus of the notification area icons, in Windows 7 wording.
public enum TrayMenus {
    public static let wirelessDiagnosticsBundleID = "com.apple.wifi.diagnostics"

    public static func items(for icon: TrayMenuIcon, wirelessDiagnosticsAvailable: Bool = true) -> [TrayMenuEntry] {
        switch icon {
        case .volume:
            ["Open Volume Mixer", "Playback devices", "Recording devices", "Sounds"].map { TrayMenuEntry($0, .open(.sound)) }
        case .network:
            [TrayMenuEntry("Troubleshoot problems", .wirelessDiagnostics, enabled: wirelessDiagnosticsAvailable),
             TrayMenuEntry("Open Network and Sharing Center", .open(.network))]
        case .clock:
            [TrayMenuEntry("Adjust date/time", .open(.dateTime)),
             TrayMenuEntry("Customize notification icons", .showOverflow)]
        case .actionCenter:
            [TrayMenuEntry("Open Action Center", .open(.notifications))]
        case .battery:
            [TrayMenuEntry("Power Options", .open(.battery))]
        }
    }
}
