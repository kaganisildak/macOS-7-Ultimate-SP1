import Foundation

/// The battery state Action Center looks at. Nil (no internal battery) gives no battery message.
public struct ActionCenterBattery: Equatable, Sendable {
    public var percent: Int
    public var charging: Bool
    public init(percent: Int, charging: Bool) {
        self.percent = percent
        self.charging = charging
    }
}

/// One Action Center message: a title, a short explanation and a button that runs `action`.
public struct ActionCenterMessage: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case accessibility, screenRecording, batteryLow }
    public let kind: Kind
    public let title: String
    public let detail: String
    public let buttonTitle: String
    public let action: TrayMenuAction
}

/// Pure logic behind the Action Center flag and flyout: which messages the shell's state gives, and
/// the Windows 7 wording around them.
public enum ActionCenterModel {
    /// Below this percent, on battery and not charging, Action Center warns.
    public static let lowBatteryPercent = 10

    /// Messages in Windows 7 order: the permissions the shell needs (from `PermissionGate`), then
    /// the battery (from the shell's battery status).
    public static func messages(axTrusted: Bool, screenCaptureGranted: Bool,
                                battery: ActionCenterBattery?) -> [ActionCenterMessage] {
        var out: [ActionCenterMessage] = []
        if !axTrusted {
            out.append(ActionCenterMessage(
                kind: .accessibility, title: "Turn on Accessibility for Win7Mac",
                detail: "Aero Snap and Alt-Tab need Accessibility permission.",
                buttonTitle: "Open settings", action: .open(.accessibilityPrivacy)))
        }
        if !screenCaptureGranted {
            out.append(ActionCenterMessage(
                kind: .screenRecording, title: "Turn on Screen Recording for Win7Mac",
                detail: "Taskbar thumbnails and window titles need Screen Recording permission.",
                buttonTitle: "Open settings", action: .open(.screenRecordingPrivacy)))
        }
        if let battery, battery.percent < lowBatteryPercent, !battery.charging {
            out.append(ActionCenterMessage(
                kind: .batteryLow, title: "Your battery is running low",
                detail: "\(battery.percent)% remaining. Plug in your computer.",
                buttonTitle: "Power Options", action: .open(.battery)))
        }
        return out
    }

    /// The flyout header: "Solve 1 problem", "Solve 2 problems", or "No current issues detected".
    public static func headerText(count: Int) -> String {
        switch count {
        case ...0: "No current issues detected"
        case 1: "Solve 1 problem"
        default: "Solve \(count) problems"
        }
    }

    /// The flag's tooltip.
    public static func tooltip(count: Int) -> String {
        switch count {
        case ...0: "No current issues detected"
        case 1: "Solve PC issues: 1 message"
        default: "Solve PC issues: \(count) messages"
        }
    }
}
