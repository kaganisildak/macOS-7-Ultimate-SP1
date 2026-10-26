import Foundation

/// One network from the Wi-Fi interface's cached scan. `ssid` is nil when Location isn't granted.
public struct WiFiScanEntry: Equatable, Sendable {
    public var ssid: String?
    public var rssi: Int
    public var secured: Bool
    public init(ssid: String?, rssi: Int, secured: Bool) {
        self.ssid = ssid
        self.rssi = rssi
        self.secured = secured
    }
}

/// A row of the network flyout's Wi-Fi list.
public enum NetworkListRow: Equatable, Sendable {
    case network(name: String, bars: Int, secured: Bool, isCurrent: Bool)
    /// Networks are visible but their names are not readable (no Location grant).
    case summary(String)

    public var name: String {
        switch self {
        case .network(let name, _, _, _): name
        case .summary(let text): text
        }
    }
    public var bars: Int { if case .network(_, let bars, _, _) = self { bars } else { 0 } }
    public var secured: Bool { if case .network(_, _, let secured, _) = self { secured } else { false } }
    public var isCurrent: Bool { if case .network(_, _, _, let current) = self { current } else { false } }
}

/// Pure logic behind the network flyout's list of visible Wi-Fi networks.
public enum NetworkListModel {
    public static let summaryText = "Wi-Fi networks available"

    /// The rows: nothing with Wi-Fi off; the current network first, then the rest by signal (strongest
    /// first, then by name), one row per name at its strongest. When networks are visible but none has
    /// a name, a single summary row.
    public static func rows(scan: [WiFiScanEntry], currentSSID: String?, wifiOn: Bool) -> [NetworkListRow] {
        guard wifiOn, !scan.isEmpty else { return [] }
        var strongest: [String: WiFiScanEntry] = [:]
        for e in scan {
            guard let name = e.ssid, !name.isEmpty else { continue }
            if let old = strongest[name], old.rssi >= e.rssi { continue }
            strongest[name] = e
        }
        guard !strongest.isEmpty else { return [.summary(summaryText)] }
        let sorted = strongest.sorted { a, b in
            let ac = a.key == currentSSID, bc = b.key == currentSSID
            if ac != bc { return ac }
            if a.value.rssi != b.value.rssi { return a.value.rssi > b.value.rssi }
            return a.key < b.key
        }
        return sorted.map { name, e in
            .network(name: name, bars: signalBars(rssi: e.rssi), secured: e.secured, isCurrent: name == currentSSID)
        }
    }

    /// The flyout's two status lines: "Currently connected to:" over the network's name, or
    /// "Not connected" over whether any network can be joined (never "Not connected" twice).
    public static func headerLines(connectedName: String?, networksAvailable: Bool) -> (header: String, detail: String) {
        if let connectedName { return ("Currently connected to:", connectedName) }
        return ("Not connected", networksAvailable ? "Connections are available" : "No connections are available")
    }

    /// Windows 7's five signal bars for a network in the list (never fewer than one).
    public static func signalBars(rssi: Int) -> Int {
        if rssi >= -50 { return 5 }
        if rssi >= -60 { return 4 }
        if rssi >= -67 { return 3 }
        if rssi >= -75 { return 2 }
        return 1
    }

    /// Clicking a row: nothing for the current network; otherwise the Wi-Fi pane, where macOS joins
    /// (the shell never joins or asks for passwords).
    public static func clickAction(_ row: NetworkListRow) -> SettingsPane? {
        row.isCurrent ? nil : .wifi
    }
}
