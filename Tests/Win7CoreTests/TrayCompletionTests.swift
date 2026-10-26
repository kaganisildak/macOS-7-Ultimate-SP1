import Testing
import Foundation
@testable import Win7Core

@Suite struct ActionCenterTests {
    private func messages(ax: Bool = true, screen: Bool = true, battery: ActionCenterBattery? = nil) -> [ActionCenterMessage] {
        ActionCenterModel.messages(axTrusted: ax, screenCaptureGranted: screen, battery: battery)
    }

    @Test func allGrantedNoBatteryHasNoMessages() {
        #expect(messages().isEmpty)
        #expect(ActionCenterModel.headerText(count: 0) == "No current issues detected")
    }

    @Test func missingPermissionsGiveOneMessageEach() {
        let m = messages(ax: false, screen: false)
        #expect(m.map(\.kind) == [.accessibility, .screenRecording])
        #expect(m.map(\.action) == [.open(.accessibilityPrivacy), .open(.screenRecordingPrivacy)])
        #expect(m.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty && !$0.buttonTitle.isEmpty })
        #expect(messages(ax: true, screen: false).map(\.kind) == [.screenRecording])
        #expect(messages(ax: false, screen: true).map(\.kind) == [.accessibility])
    }

    @Test func lowBatteryOnlyBelowTenPercentAndNotCharging() {
        #expect(messages(battery: .init(percent: 9, charging: false)).map(\.kind) == [.batteryLow])
        #expect(messages(battery: .init(percent: 9, charging: false)).first?.action == .open(.battery))
        #expect(messages(battery: .init(percent: 9, charging: false)).first?.detail.contains("9%") == true)
        #expect(messages(battery: .init(percent: 10, charging: false)).isEmpty)
        #expect(messages(battery: .init(percent: 5, charging: true)).isEmpty)
        #expect(messages(ax: false, battery: .init(percent: 3, charging: false)).map(\.kind) == [.accessibility, .batteryLow])
    }

    @Test func headerCountText() {
        #expect(ActionCenterModel.headerText(count: 1) == "Solve 1 problem")
        #expect(ActionCenterModel.headerText(count: 2) == "Solve 2 problems")
        #expect(ActionCenterModel.headerText(count: 3) == "Solve 3 problems")
    }

    @Test func tooltipText() {
        #expect(ActionCenterModel.tooltip(count: 0) == "No current issues detected")
        #expect(ActionCenterModel.tooltip(count: 1) == "Solve PC issues: 1 message")
        #expect(ActionCenterModel.tooltip(count: 2) == "Solve PC issues: 2 messages")
    }

    @Test func settingsPaneURLs() {
        #expect(SettingsPane.accessibilityPrivacy.url.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        #expect(SettingsPane.screenRecordingPrivacy.url.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        #expect(SettingsPane.notifications.url.absoluteString
            == "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        #expect(SettingsPane.allCases.allSatisfy { $0.url.scheme == "x-apple.systempreferences" })
    }
}

@Suite struct NetworkListTests {
    @Test func wifiOffHasNoRows() {
        let scan = [WiFiScanEntry(ssid: "Home", rssi: -50, secured: true)]
        #expect(NetworkListModel.rows(scan: scan, currentSSID: "Home", wifiOn: false).isEmpty)
    }

    @Test func sortedBySignalWithCurrentFirst() {
        let scan = [
            WiFiScanEntry(ssid: "Weak", rssi: -85, secured: true),
            WiFiScanEntry(ssid: "Strong", rssi: -45, secured: false),
            WiFiScanEntry(ssid: "Home", rssi: -70, secured: true),
            WiFiScanEntry(ssid: "Mid", rssi: -62, secured: true),
        ]
        let rows = NetworkListModel.rows(scan: scan, currentSSID: "Home", wifiOn: true)
        #expect(rows.map(\.name) == ["Home", "Strong", "Mid", "Weak"])
        #expect(rows.map(\.isCurrent) == [true, false, false, false])
        #expect(rows[1].secured == false && rows[0].secured)
    }

    @Test func duplicatesKeepTheStrongestAndEmptyNamesAreDropped() {
        let scan = [
            WiFiScanEntry(ssid: "Cafe", rssi: -80, secured: false),
            WiFiScanEntry(ssid: "Cafe", rssi: -55, secured: false),
            WiFiScanEntry(ssid: "", rssi: -40, secured: true),
            WiFiScanEntry(ssid: nil, rssi: -40, secured: true),
        ]
        let rows = NetworkListModel.rows(scan: scan, currentSSID: nil, wifiOn: true)
        #expect(rows.map(\.name) == ["Cafe"])
        #expect(rows.first?.bars == NetworkListModel.signalBars(rssi: -55))
    }

    @Test func nilNamesGiveSummaryRow() {
        let scan = [WiFiScanEntry(ssid: nil, rssi: -50, secured: true), WiFiScanEntry(ssid: nil, rssi: -60, secured: true)]
        let rows = NetworkListModel.rows(scan: scan, currentSSID: nil, wifiOn: true)
        #expect(rows == [.summary("Wi-Fi networks available")])
        #expect(NetworkListModel.rows(scan: [], currentSSID: nil, wifiOn: true).isEmpty)
    }

    @Test func signalBarsFiveSteps() {
        #expect(NetworkListModel.signalBars(rssi: -45) == 5)
        #expect(NetworkListModel.signalBars(rssi: -58) == 4)
        #expect(NetworkListModel.signalBars(rssi: -65) == 3)
        #expect(NetworkListModel.signalBars(rssi: -72) == 2)
        #expect(NetworkListModel.signalBars(rssi: -90) == 1)
    }

    /// "Not connected" appears once: the line under it says whether anything can be joined.
    @Test func headerLinesNeverRepeatNotConnected() {
        let off = NetworkListModel.headerLines(connectedName: nil, networksAvailable: false)
        #expect(off.header == "Not connected" && off.detail == "No connections are available")
        let avail = NetworkListModel.headerLines(connectedName: nil, networksAvailable: true)
        #expect(avail.header == "Not connected" && avail.detail == "Connections are available")
        let on = NetworkListModel.headerLines(connectedName: "Home", networksAvailable: true)
        #expect(on.header == "Currently connected to:" && on.detail == "Home")
    }

    @Test func clickingCurrentDoesNothingOtherOpensWiFi() {
        let current = NetworkListRow.network(name: "Home", bars: 4, secured: true, isCurrent: true)
        let other = NetworkListRow.network(name: "Cafe", bars: 2, secured: false, isCurrent: false)
        #expect(NetworkListModel.clickAction(current) == nil)
        #expect(NetworkListModel.clickAction(other) == .wifi)
        #expect(NetworkListModel.clickAction(.summary("Wi-Fi networks available")) == .wifi)
    }
}

@Suite struct TrayMenuTests {
    @Test func volumeMenu() {
        let m = TrayMenus.items(for: .volume)
        #expect(m.map(\.title) == ["Open Volume Mixer", "Playback devices", "Recording devices", "Sounds"])
        #expect(m.allSatisfy { $0.action == .open(.sound) && $0.enabled })
    }

    @Test func networkMenu() {
        let m = TrayMenus.items(for: .network, wirelessDiagnosticsAvailable: true)
        #expect(m.map(\.title) == ["Troubleshoot problems", "Open Network and Sharing Center"])
        #expect(m.map(\.action) == [.wirelessDiagnostics, .open(.network)])
        #expect(m.allSatisfy { $0.enabled })
        let without = TrayMenus.items(for: .network, wirelessDiagnosticsAvailable: false)
        #expect(without.map(\.enabled) == [false, true])
    }

    @Test func clockMenu() {
        let m = TrayMenus.items(for: .clock)
        #expect(m.map(\.title) == ["Adjust date/time", "Customize notification icons"])
        #expect(m.map(\.action) == [.open(.dateTime), .showOverflow])
    }

    @Test func actionCenterAndBatteryMenus() {
        #expect(TrayMenus.items(for: .actionCenter) == [TrayMenuEntry("Open Action Center", .open(.notifications))])
        #expect(TrayMenus.items(for: .battery) == [TrayMenuEntry("Power Options", .open(.battery))])
    }
}
