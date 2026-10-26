import Testing
import Foundation
@testable import Win7Core

@Suite struct TrayTests {
    @Test func volumeLevels() {
        #expect(TrayLogic.volumeLevel(volume: 0.5, muted: true) == .muted)
        #expect(TrayLogic.volumeLevel(volume: 0, muted: false) == .zero)
        #expect(TrayLogic.volumeLevel(volume: 0.2, muted: false) == .low)
        #expect(TrayLogic.volumeLevel(volume: 0.5, muted: false) == .medium)
        #expect(TrayLogic.volumeLevel(volume: 0.9, muted: false) == .high)
    }

    @Test func wifiBars() {
        #expect(TrayLogic.wifiBars(rssi: nil) == 0)
        #expect(TrayLogic.wifiBars(rssi: -50) == 4)
        #expect(TrayLogic.wifiBars(rssi: -60) == 3)
        #expect(TrayLogic.wifiBars(rssi: -70) == 2)
        #expect(TrayLogic.wifiBars(rssi: -80) == 1)
        #expect(TrayLogic.wifiBars(rssi: -95) == 1)
    }

    @Test func batteryTooltips() {
        #expect(TrayLogic.batteryTooltip(percent: 100, charging: false, pluggedIn: true) == "Fully charged (100%)")
        #expect(TrayLogic.batteryTooltip(percent: 57, charging: true, pluggedIn: true) == "57% available (plugged in, charging)")
        #expect(TrayLogic.batteryTooltip(percent: 80, charging: false, pluggedIn: true) == "80% available (plugged in, not charging)")
        #expect(TrayLogic.batteryTooltip(percent: 42, charging: false, pluggedIn: false) == "42% remaining")
    }

    @Test func batteryIconBuckets() {
        #expect(TrayLogic.batteryIconLevel(percent: 9) == 0)
        #expect(TrayLogic.batteryIconLevel(percent: 10) == 1)
        #expect(TrayLogic.batteryIconLevel(percent: 34) == 1)
        #expect(TrayLogic.batteryIconLevel(percent: 35) == 2)
        #expect(TrayLogic.batteryIconLevel(percent: 85) == 4)
    }

    @Test func inputSourceAbbreviations() {
        #expect(TrayLogic.inputSourceAbbreviation(languages: ["tr"], fallbackName: "Turkish Q") == "TR")
        #expect(TrayLogic.inputSourceAbbreviation(languages: ["en-US"], fallbackName: "") == "EN")
        #expect(TrayLogic.inputSourceAbbreviation(languages: [], fallbackName: "ABC") == "AB")
    }

    @Test func monthGridMondayFirst() {
        let grid = TrayLogic.monthGrid(year: 2026, month: 10, firstWeekday: 2, calendar: Calendar(identifier: .gregorian))
        #expect(grid.count == 6)
        #expect(grid.allSatisfy { $0.count == 7 })
        #expect(grid[0] == [nil, nil, nil, 1, 2, 3, 4])
        // 31 Oct 2026 is a Saturday: row 4, column 5 with Monday first; Sunday and row 5 are padding.
        #expect(grid[4] == [26, 27, 28, 29, 30, 31, nil])
        #expect(grid[5] == [nil, nil, nil, nil, nil, nil, nil])
        #expect(grid.flatMap { $0 }.compactMap { $0 } == Array(1...31))
    }

    @Test func monthGridSundayFirst() {
        let grid = TrayLogic.monthGrid(year: 2026, month: 10, firstWeekday: 1, calendar: Calendar(identifier: .gregorian))
        #expect(grid.count == 6)
        #expect(grid[0] == [nil, nil, nil, nil, 1, 2, 3])
        #expect(grid[4] == [25, 26, 27, 28, 29, 30, 31])
        #expect(grid[5] == [nil, nil, nil, nil, nil, nil, nil])
    }
}
