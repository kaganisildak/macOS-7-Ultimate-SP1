import AppKit
import Win7Theme

/// One place that draws a notification-area icon: the user's `Assets/icons/tray-<name>.png` aspect-fit when it
/// exists (IconOverrides), else Win7Theme's drawing. Used by the tray, its flyouts and the Control Panel. Draws
/// into the current graphics context, whose CGContext is `ctx`.
@MainActor
enum TrayIcons {
    /// The override name, for example `tray-wifi-3` or `tray-battery-2-charging` (`flag` is the battery's
    /// plugged-in state; the network icons have no flagged name).
    static func name(_ kind: W7TrayIcon, _ level: Int, _ flag: Bool) -> String {
        let base = switch kind {
        case .wifi: "wifi-\(level)"
        case .wired: "wired"
        case .disconnected: "disconnected"
        case .noNetwork: "no-network"
        case .volume: "volume-\(level)"
        case .battery: "battery-\(level)" + (flag ? "-charging" : "")
        case .chevron: "chevron"
        @unknown default: "unknown"
        }
        return "tray-" + base
    }

    /// The Action Center flag's override name: `tray-action-center`, or `tray-action-center-alert` with its badge.
    static func actionCenterName(alert: Bool) -> String {
        alert ? "tray-action-center-alert" : "tray-action-center"
    }

    static func draw(_ ctx: CGContext, in rect: NSRect, kind: W7TrayIcon, level: Int, flag: Bool) {
        guard !IconOverrides.draw(name(kind, level, flag), in: rect) else { return }
        W7DrawTrayIcon(ctx, rect, kind, level, flag)
    }

    static func drawActionCenter(_ ctx: CGContext, in rect: NSRect, alert: Bool) {
        guard !IconOverrides.draw(actionCenterName(alert: alert), in: rect) else { return }
        W7DrawActionCenterFlag(ctx, rect, alert)
    }
}
