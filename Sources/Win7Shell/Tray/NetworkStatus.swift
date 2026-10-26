import AppKit
import CoreLocation
import CoreWLAN
import Network
import Win7Core
import Win7Theme

/// The network shown in the notification area, from `NWPathMonitor` plus the Wi-Fi interface's RSSI.
/// The SSID is read only once Location is authorized; nothing asks for Location until the user
/// presses "Show network name" in the flyout.
@MainActor
final class NetworkStatus: NSObject, CLLocationManagerDelegate {
    enum Kind: Equatable {
        case wifi(bars: Int)
        case wired
        case disconnected
        /// No usable interface (Wi-Fi off, airplane-like): drawn grey.
        case noInterface
    }

    private(set) var kind: Kind = .noInterface
    private(set) var ssid: String?
    var onChange: (() -> Void)?

    private let monitor = NWPathMonitor()
    private var rssiTimer: Timer?
    private var pathSatisfied = false
    private var usesWifi = false
    /// Creating the manager only reads the authorization state; it never prompts.
    private let location = CLLocationManager()

    override init() {
        super.init()
        // The handler runs on the main queue, so it is on the main actor.
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pathSatisfied = satisfied
                self.usesWifi = wifi
                self.refresh()
            }
        }
        monitor.start(queue: .main)
        // The delegate reports later grants. (locationServicesEnabled() is not called: it can
        // block the main thread.)
        location.delegate = self
        // The signal bars and a powered-off Wi-Fi interface are not reported by NWPathMonitor: polled,
        // with 20 % tolerance so the wake-up coalesces.
        rssiTimer = Timer.w7Scheduled(10, repeats: true, fraction: TimerTolerance.maxFraction) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var locationStatus: CLAuthorizationStatus { location.authorizationStatus }
    private var locationAuthorized: Bool {
        switch locationStatus {
        case .notDetermined, .denied, .restricted: false
        default: true
        }
    }

    /// Asks for Location so the SSID can be shown. Only called from the flyout's button.
    func requestNetworkName() {
        location.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // CLLocationManager calls its delegate on the thread it was created on: the main thread.
        MainActor.assumeIsolated { self.refresh() }
    }

    func refresh() {
        let iface = CWWiFiClient.shared().interface()
        let new: Kind
        if pathSatisfied && usesWifi {
            let rssi = iface?.rssiValue() ?? 0
            new = .wifi(bars: max(1, TrayLogic.wifiBars(rssi: rssi == 0 ? nil : rssi)))
        } else if pathSatisfied {
            new = .wired
        } else if let iface, !iface.powerOn() {
            new = .noInterface
        } else {
            new = .disconnected
        }
        let name = (usesWifi && locationAuthorized) ? iface?.ssid() : nil
        guard new != kind || name != ssid else { return }
        kind = new
        ssid = name
        onChange?()
    }

    /// Whether the Wi-Fi interface exists and is powered on.
    var wifiPoweredOn: Bool { CWWiFiClient.shared().interface()?.powerOn() ?? false }

    /// The networks from the interface's last scan. This never starts a scan (a new scan would need
    /// Location); without Location the names come back nil.
    func cachedNetworks() -> [WiFiScanEntry] {
        guard let nets = CWWiFiClient.shared().interface()?.cachedScanResults() else { return [] }
        return nets.map { WiFiScanEntry(ssid: $0.ssid, rssi: $0.rssiValue, secured: !$0.supportsSecurity(.none)) }
    }

    /// The flyout's list rows for the current scan and connection.
    var networkRows: [NetworkListRow] {
        let current: String? = if case .wifi = kind { ssid } else { nil }
        return NetworkListModel.rows(scan: cachedNetworks(), currentSSID: current, wifiOn: wifiPoweredOn)
    }

    var tooltip: String {
        switch kind {
        case .wifi: return (ssid ?? "Wi-Fi") + "\nInternet access"
        case .wired: return "Ethernet\nInternet access"
        case .disconnected: return "Not connected - No connections are available"
        case .noInterface: return "No network connection"
        }
    }

    /// The icon to draw: kind and level for `W7DrawTrayIcon`.
    var icon: (W7TrayIcon, Int) {
        switch kind {
        case .wifi(let bars): return (.wifi, bars)
        case .wired: return (.wired, 0)
        case .disconnected: return (.disconnected, 0)
        case .noInterface: return (.noNetwork, 0)
        }
    }
}
