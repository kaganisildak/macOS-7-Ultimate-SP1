import Foundation
import IOKit.ps
import Win7Core

/// The internal battery, from IOKit power sources, updated by an `IOPSNotificationCreateRunLoopSource`
/// on the main run loop in the common modes, so it also updates while a menu is tracking. `isPresent`
/// is false on Macs without an internal battery.
@MainActor
final class BatteryStatus {
    private(set) var isPresent = false
    private(set) var percent = 0
    private(set) var charging = false
    private(set) var pluggedIn = false
    var onChange: (() -> Void)?
    private var source: CFRunLoopSource?

    init() {
        read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        // The source lives on the main run loop, so the callback runs on the main thread. The
        // BatteryStatus lives as long as the app, so the unretained context stays valid.
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            MainActor.assumeIsolated {
                Unmanaged<BatteryStatus>.fromOpaque(ctx).takeUnretainedValue().read()
            }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            source = src
        }
    }

    var tooltip: String { TrayLogic.batteryTooltip(percent: percent, charging: charging, pluggedIn: pluggedIn) }
    var iconLevel: Int { TrayLogic.batteryIconLevel(percent: percent) }

    private func read() {
        var present = false, pct = 0, chg = false, plugged = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                present = (d[kIOPSIsPresentKey] as? Bool) ?? true
                let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
                let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
                pct = max > 0 ? Swift.min(100, Swift.max(0, Int((Double(cur) * 100 / Double(max)).rounded()))) : 0
                chg = d[kIOPSIsChargingKey] as? Bool ?? false
                plugged = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
                break
            }
        }
        guard present != isPresent || pct != percent || chg != charging || plugged != pluggedIn else { return }
        isPresent = present; percent = pct; charging = chg; pluggedIn = plugged
        onChange?()
    }
}
