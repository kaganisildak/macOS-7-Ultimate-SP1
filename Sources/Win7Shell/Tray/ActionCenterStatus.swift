import AppKit
import Win7Core

/// The Action Center's messages, from the shell's permission state and the battery. Re-read on every
/// tick of the shared 5 s permission poll (the one the app delegate's feature gate uses) and
/// whenever the battery changes.
@MainActor
final class ActionCenterStatus {
    private(set) var messages: [ActionCenterMessage] = []
    var onChange: (() -> Void)?

    private let battery: BatteryStatus
    private var permissions: PermissionSnapshot

    init(battery: BatteryStatus) {
        self.battery = battery
        permissions = PermissionPoller.shared.current
        messages = compute()
        PermissionPoller.shared.subscribe { [weak self] snapshot in
            guard let self else { return }
            self.permissions = snapshot
            self.refresh()
        }
    }

    var tooltip: String { ActionCenterModel.tooltip(count: messages.count) }

    func refresh() {
        let new = compute()
        guard new != messages else { return }
        messages = new
        onChange?()
    }

    private func compute() -> [ActionCenterMessage] {
        ActionCenterModel.messages(
            axTrusted: permissions.axTrusted, screenCaptureGranted: permissions.screenCapture,
            battery: battery.isPresent ? ActionCenterBattery(percent: battery.percent, charging: battery.charging) : nil)
    }
}
