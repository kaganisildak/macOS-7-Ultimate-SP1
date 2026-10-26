import Foundation
import Testing
@testable import Win7Core

// Device Manager's tree from `system_profiler -json`. The fixture is hand-written from the documented
// key names (Fixtures/system-profiler-synthetic.json); its serials, MAC addresses and paths are fake and must never
// reach a node.

private func fixture() throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/system-profiler-synthetic.json")
    return try Data(contentsOf: url)
}

private func names(_ categories: [DeviceCategory], _ kind: DeviceKind) -> [String] {
    categories.first { $0.kind == kind }?.devices.map(\.name) ?? []
}

@Suite struct DeviceTreeTests {
    @Test func categoriesAreWindows7sTitlesInItsAlphabeticalOrder() {
        #expect(DeviceKind.allCases.map(\.title) == [
            "Audio inputs and outputs", "Batteries", "Bluetooth", "Cameras", "Computer", "Disk drives", "Display adapters",
            "Keyboards", "Mice and other pointing devices", "Monitors", "Network adapters", "Print queues", "Processors",
            "Storage controllers", "Universal Serial Bus controllers",
        ])
        let titles = DeviceKind.allCases.map(\.title)
        #expect(titles == titles.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test func iconNamesPerCategory() {
        let icons = Dictionary(uniqueKeysWithValues: DeviceKind.allCases.map { ($0, $0.iconName) })
        #expect(icons == [
            .audio: "dev-audio", .batteries: "dev-battery", .bluetooth: "dev-bluetooth", .cameras: "dev-camera",
            .computer: "dev-computer", .diskDrives: "dev-disk", .displayAdapters: "dev-display", .keyboards: "dev-keyboard",
            .mice: "dev-mouse", .monitors: "dev-monitor", .networkAdapters: "dev-network", .printQueues: "dev-printer",
            .processors: "dev-processor", .storageControllers: "dev-storage", .usbControllers: "dev-usb",
        ])
        // Every icon name is one the shell's catalogue lists (and so one the maps must cover).
        for kind in DeviceKind.allCases { #expect(IconCatalog.shell.contains(kind.iconName), "\(kind.iconName)") }
    }

    @Test func parsesTheFixtureIntoTheCategoriesWithNamesAndCounts() throws {
        let tree = try DeviceTree.parse(json: fixture())
        // Every category of the fixture, in order; none empty.
        #expect(tree.map(\.kind) == DeviceKind.allCases)
        #expect(tree.allSatisfy { !$0.devices.isEmpty })
        #expect(names(tree, .audio) == ["Example Microphone", "Example Speakers", "Sample USB Headset"])
        #expect(names(tree, .batteries) == ["AC Adapter", "Internal Battery"])
        // The radio and the connected peripherals that are not keyboards or mice; not-connected devices are left out.
        #expect(names(tree, .bluetooth) == ["Bluetooth Controller (EX_1234)", "Sample Headphones"])
        #expect(names(tree, .cameras) == ["Example HD Camera"])
        #expect(names(tree, .computer) == ["Example Mac"])
        // NVMe, SATA and the volumes' physical drives, each drive once.
        #expect(names(tree, .diskDrives) == ["EXAMPLE SSD 512", "Sample Flash Drive", "Sample HDD 1TB"])
        #expect(names(tree, .displayAdapters) == ["Example GPU 10-Core"])
        // Keyboards and mice from USB (by name) and from Bluetooth (by minor type).
        #expect(names(tree, .keyboards) == ["Sample Keyboard", "Sample USB Keyboard"])
        #expect(names(tree, .mice) == ["Sample Mouse", "Sample Optical Mouse"])
        #expect(names(tree, .monitors) == ["Built-in Example Display", "Sample 27 Monitor"])
        #expect(names(tree, .networkAdapters) == ["Ethernet", "Thunderbolt Bridge", "Wi-Fi"])
        #expect(names(tree, .printQueues) == ["Example LaserJet", "Sample Inkjet"])
        #expect(names(tree, .processors) == Array(repeating: "Example Chip X1", count: 8))
        #expect(names(tree, .storageControllers) == ["Example SATA Controller", "Generic SSD Controller"])
        // SPUSBDataType has data, so SPUSBHostDataType (the same buses on newer macOS) is not read again.
        #expect(names(tree, .usbControllers) == ["USB eXtensible Host Controller", "USB Root Hub", "USB2.0 Hub"])
        #expect(!tree.flatMap(\.devices).contains { $0.name == "Ignored Host Gadget" || $0.name == "Should Be Ignored" })
    }

    @Test func keepsNoSerialNumbersMACAddressesOrPaths() throws {
        let tree = try DeviceTree.parse(json: fixture())
        let fields = tree.flatMap(\.devices).flatMap { [$0.name, $0.manufacturer ?? "", $0.location ?? ""] }
        for f in fields {
            #expect(!f.contains("FAKE") && !f.contains("00:00:5") && !f.contains("/") && !f.contains("0000-0000"), "\(f)")
            #expect(!f.contains("ipp:") && !f.contains("disk9") && !f.contains("en0"), "\(f)")
        }
    }

    @Test func manufacturersAndLocationsForThePropertiesDialog() throws {
        let tree = try DeviceTree.parse(json: fixture())
        func device(_ kind: DeviceKind, _ name: String) -> DeviceNode? {
            tree.first { $0.kind == kind }?.devices.first { $0.name == name }
        }
        #expect(device(.audio, "Example Speakers")?.manufacturer == "Example Audio Co.")
        #expect(device(.audio, "Example Speakers")?.location == "Built-in")
        #expect(device(.audio, "Sample USB Headset")?.location == "USB")
        #expect(device(.displayAdapters, "Example GPU 10-Core")?.manufacturer == "Example")
        #expect(device(.monitors, "Sample 27 Monitor")?.location == "on Example GPU 10-Core")
        #expect(device(.keyboards, "Sample USB Keyboard")?.manufacturer == "Sample Devices")
        #expect(device(.keyboards, "Sample USB Keyboard")?.location == "USB")
        #expect(device(.keyboards, "Sample Keyboard")?.location == "Bluetooth")
        #expect(device(.diskDrives, "EXAMPLE SSD 512")?.location == "PCI Express")
        #expect(device(.diskDrives, "Sample HDD 1TB")?.location == "Serial ATA")
        #expect(device(.diskDrives, "Sample Flash Drive")?.location == "USB")
        #expect(device(.batteries, "Internal Battery")?.manufacturer == "Example Cells")
        #expect(device(.bluetooth, "Bluetooth Controller (EX_1234)")?.manufacturer == "Example")
        #expect(device(.bluetooth, "Bluetooth Controller (EX_1234)")?.isAdapter == true)
        #expect(device(.bluetooth, "Sample Headphones")?.isAdapter == false)
        // The dialog's text: the category title, "(Standard system devices)" and "Unknown" when nothing is known.
        let printer = try #require(device(.printQueues, "Sample Inkjet"))
        let props = DeviceProperties(printer, kind: .printQueues)
        #expect(props.title == "Sample Inkjet Properties")
        #expect(props.deviceType == "Print queues")
        #expect(props.manufacturer == "(Standard system devices)")
        #expect(props.location == "Unknown")
        #expect(DeviceProperties.status == "This device is working properly.")
    }

    @Test func emptyAndGarbageInput() throws {
        #expect(try DeviceTree.parse(json: Data("{}".utf8)) == [])
        #expect(try DeviceTree.parse(json: Data(#"{"SPAudioDataType": "nope", "SPPrintersDataType": [{"cupsversion": "2", "status": "no_printers"}]}"#.utf8)) == [])
        #expect(throws: DeviceTreeError.self) { try DeviceTree.parse(json: Data("not json".utf8)) }
        #expect(throws: DeviceTreeError.self) { try DeviceTree.parse(json: Data("[1, 2]".utf8)) }
        #expect(throws: DeviceTreeError.self) { try DeviceTree.parse(json: Data()) }
        // What the loader hands the window: never a throw, an empty tree.
        #expect(DeviceTree.categories(from: Data("garbage".utf8)) == [])
        #expect(DeviceTree.categories(from: nil) == [])
        #expect(try DeviceTree.categories(from: fixture()).count == DeviceKind.allCases.count)
    }

    @Test func newerMacOSUSBHostFormat() throws {
        let json = """
        {"SPUSBDataType": [],
         "SPUSBHostDataType": [{"_name": "USB3 Bus", "Driver": "ExampleXHCI", "USBKeyLocationID": "0x01000000",
           "_items": [{"_name": "Sample Trackball", "USBDeviceKeyVendorName": "Sample Devices", "USBDeviceKeySerialNumber": "FAKE-1",
                       "_items": [{"_name": "Sample Wired Keyboard", "USBDeviceKeyVendorName": "Sample Devices"}]},
                      {"_name": "Sample Card Reader"}]}]}
        """
        let tree = try DeviceTree.parse(json: Data(json.utf8))
        #expect(names(tree, .mice) == ["Sample Trackball"])
        #expect(names(tree, .keyboards) == ["Sample Wired Keyboard"])
        #expect(names(tree, .usbControllers) == ["Sample Card Reader", "USB eXtensible Host Controller", "USB Root Hub"])
        #expect(tree.first { $0.kind == .mice }?.devices.first?.manufacturer == "Sample Devices")
    }

    @Test func processorCountForms() throws {
        func count(_ value: String) throws -> Int {
            let json = #"{"SPHardwareDataType": [{"machine_name": "M", "cpu_type": "Example CPU", "number_processors": \#(value)}]}"#
            return names(try DeviceTree.parse(json: Data(json.utf8)), .processors).count
        }
        #expect(try count("4") == 4)
        #expect(try count(#""proc 10:8:2""#) == 10)
        #expect(try count(#""12 (8 performance and 4 efficiency)""#) == 12)
        #expect(try count(#""none""#) == 1)
        #expect(try count("100000") == DeviceTree.maxProcessors)
        let noCount = #"{"SPHardwareDataType": [{"machine_name": "M", "chip_type": "Example Chip"}]}"#
        #expect(names(try DeviceTree.parse(json: Data(noCount.utf8)), .processors) == ["Example Chip"])
    }

    @Test func namesAreTrimmedBoundedAndPlaceholdersCleaned() throws {
        let long = String(repeating: "x", count: 500)
        let json = """
        {"SPCameraDataType": [{"_name": "  Spaced Camera \\n"}, {"_name": ""}, {"_name": "\(long)"}],
         "SPDisplaysDataType": [{"_name": "kHW_ExampleAdapterItem"}]}
        """
        let tree = try DeviceTree.parse(json: Data(json.utf8))
        let cams = names(tree, .cameras)
        #expect(cams.count == 2)
        #expect(cams.contains("Spaced Camera"))
        #expect(cams.allSatisfy { $0.count <= DeviceTree.maxNameLength })
        #expect(names(tree, .displayAdapters) == ["ExampleAdapter"])
    }

    @Test func theCommandIsFixedAndBounded() {
        #expect(DeviceTree.executable == "/usr/sbin/system_profiler")
        #expect(DeviceTree.arguments == ["-json", "-detailLevel", "mini"] + DeviceTree.dataTypes)
        #expect(DeviceTree.dataTypes == [
            "SPAudioDataType", "SPBluetoothDataType", "SPCameraDataType", "SPDisplaysDataType", "SPNVMeDataType",
            "SPSerialATADataType", "SPStorageDataType", "SPUSBDataType", "SPUSBHostDataType", "SPNetworkDataType",
            "SPHardwareDataType", "SPPowerDataType", "SPPrintersDataType",
        ])
        #expect(DeviceTree.timeout == 20)
        #expect(DeviceTree.outputCap == 8 * 1024 * 1024)
    }

    @Test func outputIsReadUpToTheCap() throws {
        let small = Pipe()
        small.fileHandleForWriting.write(Data(repeating: 65, count: 1000))
        try small.fileHandleForWriting.close()
        let ok = DeviceTree.readCapped(small.fileHandleForReading, cap: 1000)
        #expect(ok.data.count == 1000 && !ok.overflow)

        let big = Pipe()
        big.fileHandleForWriting.write(Data(repeating: 66, count: 3000))
        try big.fileHandleForWriting.close()
        let over = DeviceTree.readCapped(big.fileHandleForReading, cap: 1000)
        #expect(over.overflow)
        #expect(over.data.count <= 1000)
    }

    // MARK: The bounded runner (review 71 items 1-2): its own process group, killed on timeout or overflow.

    /// No process and no process group with this id remain (the run reaped its child).
    private func gone(_ pid: pid_t) -> Bool {
        errno = 0
        let process = kill(pid, 0) == -1 && errno == ESRCH
        errno = 0
        let group = kill(-pid, 0) == -1 && errno == ESRCH
        return process && group
    }

    @Test func aTimedOutRunIsKilledAsAGroupAndReturnsPromptly() {
        let started = Date()
        let run = DeviceTree.run(executable: "/bin/sleep", arguments: ["30"], timeout: 0.3, cap: 1024)
        let elapsed = Date().timeIntervalSince(started)
        #expect(run.outcome == .timedOut)
        #expect(run.data == nil)
        #expect(elapsed < 1.5, "\(elapsed)")
        #expect(run.pid > 0)
        #expect(gone(run.pid))
        #expect(DeviceTree.runProfiler(executable: "/bin/sleep", arguments: ["30"], timeout: 0.3, cap: 1024) == nil)
    }

    @Test func aChildThatOutlivesSIGTERMIsKilledAfterTheGrace() {
        // A child that ignores the polite signal (SIGWINCH stands in for a SIGTERM it ignores) ends only with the
        // SIGKILL after the 1 s grace. (A stopped child would not do: XNU ends a stopped process on SIGTERM.)
        let started = Date()
        let run = DeviceTree.run(executable: "/bin/sleep", arguments: ["30"], timeout: 0.3, cap: 1024,
                                 politeSignal: SIGWINCH)
        let elapsed = Date().timeIntervalSince(started)
        #expect(run.outcome == .timedOut)
        #expect(elapsed >= 1.2 && elapsed < 2.5, "\(elapsed)")
        #expect(gone(run.pid))
    }

    @Test func anOverflowingRunStopsAtTheCapAndIsKilled() {
        let started = Date()
        let run = DeviceTree.run(executable: "/usr/bin/yes", arguments: [], timeout: 10, cap: 64 * 1024)
        #expect(run.outcome == .overflow)
        #expect(run.data == nil)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(gone(run.pid))
        #expect(DeviceTree.runProfiler(executable: "/usr/bin/yes", arguments: [], timeout: 10, cap: 64 * 1024) == nil)
    }

    @Test func aRunThatEndsOnItsOwnGivesItsOutputOnlyOnAZeroExit() {
        let ok = DeviceTree.run(executable: "/bin/sleep", arguments: ["0"], timeout: 5, cap: 1024)
        #expect(ok.outcome == .exited(0))
        #expect(ok.data == Data())
        #expect(gone(ok.pid))
        // A usage error: a non-zero exit gives no data.
        let bad = DeviceTree.run(executable: "/bin/sleep", arguments: ["not-a-number", "x"], timeout: 5, cap: 1024)
        if case .exited(let status) = bad.outcome { #expect(status != 0) } else { Issue.record("\(bad.outcome)") }
        #expect(bad.data == nil)
        let missing = DeviceTree.run(executable: "/nonexistent/tool", arguments: [], timeout: 5, cap: 1024)
        #expect(missing.outcome == .launchFailed)
        #expect(missing.data == nil)
    }

    @Test func aStoppedChildIsNotTakenForAnExitedOne() {
        // macOS's waitid(WNOWAIT) reports stopped children too; the run must still wait out the grace, then kill it.
        let started = Date()
        let run = DeviceTree.run(executable: "/bin/sleep", arguments: ["30"], timeout: 0.3, cap: 1024,
                                 politeSignal: SIGSTOP)
        let elapsed = Date().timeIntervalSince(started)
        #expect(run.outcome == .timedOut)
        #expect(elapsed >= 1.2 && elapsed < 2.5, "\(elapsed)")
        #expect(gone(run.pid))
    }

    @Test func outputUpToTheCapIsKept() {
        // `yes` would never stop on its own; a run reading exactly what was asked for proves data flows.
        let run = DeviceTree.run(executable: "/usr/bin/yes", arguments: ["abc"], timeout: 10, cap: 4)
        #expect(run.outcome == .overflow)
        #expect(run.output == Data("abc\n".utf8))
    }

    @Test func theComputerNameComesFromTheLocalStore() {
        #expect(DeviceTree.fallbackComputerName == "Computer")
        #expect(!DeviceTree.computerName().isEmpty)
        #expect(DeviceTree.computerName() == (DeviceTree.localComputerName() ?? "Computer"))
    }
}

@Suite struct DevicesAndPrintersTests {
    @Test func groupsTheComputerItsPeripheralsAndThePrinters() throws {
        let tree = try DeviceTree.parse(json: fixture())
        let view = DevicesAndPrinters(categories: tree, computerName: "Test Computer")
        #expect(view.devices.map(\.name) == ["Test Computer", "Sample Keyboard", "Sample USB Keyboard", "Sample Mouse",
                                             "Sample Optical Mouse", "Built-in Example Display", "Sample 27 Monitor",
                                             "Sample Headphones"])
        #expect(view.devices.map(\.iconName) == ["dev-computer", "dev-keyboard", "dev-keyboard", "dev-mouse", "dev-mouse",
                                                 "dev-monitor", "dev-monitor", "dev-bluetooth"])
        #expect(view.printers.map(\.name) == ["Example LaserJet", "Sample Inkjet"])
        #expect(view.printers.allSatisfy { $0.iconName == "dev-printer" && $0.kind == .printQueues })
        #expect(DevicesAndPrinters.devicesTitle(view.devices.count) == "Devices (8)")
        #expect(DevicesAndPrinters.printersTitle(2) == "Printers and Faxes (2)")
        // The computer tile stands even when nothing else was found.
        let empty = DevicesAndPrinters(categories: [], computerName: "Lonely")
        #expect(empty.devices.map(\.name) == ["Lonely"] && empty.printers.isEmpty)
    }

    @Test func searchFiltersTilesByName() throws {
        let view = DevicesAndPrinters(categories: try DeviceTree.parse(json: fixture()), computerName: "Test Computer")
        let hits = view.filtered("mouse")
        #expect(hits.devices.map(\.name) == ["Sample Mouse", "Sample Optical Mouse"])
        #expect(hits.printers.isEmpty)
        #expect(view.filtered("  ") == view)
        #expect(view.filtered("INKJET").printers.map(\.name) == ["Sample Inkjet"])
    }

    @Test func arrowKeysMoveByTileAndByRowWithinAndAcrossGroups() {
        // Devices: 7 tiles in rows of 3 (0 1 2 / 3 4 5 / 6); Printers: 2 tiles (7 8).
        let groups = [7, 2]
        func step(_ i: Int?, _ d: TileStep) -> Int? { DevicesAndPrinters.step(from: i, d, groupCounts: groups, columns: 3) }
        #expect(step(4, .left) == 3 && step(4, .right) == 5)
        #expect(step(0, .left) == 0 && step(8, .right) == 8)
        #expect(step(6, .right) == 7)                      // Left/Right run through the groups in order
        #expect(step(1, .down) == 4 && step(4, .up) == 1)
        #expect(step(5, .down) == 6)                       // a shorter last row: its last tile
        #expect(step(4, .down) == 6)
        #expect(step(6, .down) == 7)                       // into the next group, same column (clamped)
        #expect(step(5, .down) == 6 && step(2, .down) == 5)
        #expect(step(8, .up) == 6)                         // back to the previous group's last row, column 1 clamped
        #expect(step(7, .up) == 6)
        #expect(step(0, .up) == 0 && step(8, .down) == 8)  // at the edges it stays
        // Nothing selected: the first tile; no tiles: nothing.
        #expect(step(nil, .down) == 0 && step(nil, .up) == 0)
        #expect(DevicesAndPrinters.step(from: nil, .down, groupCounts: [0, 0], columns: 3) == nil)
        // An empty first group is skipped; a single column moves one tile per row.
        #expect(DevicesAndPrinters.step(from: 0, .up, groupCounts: [0, 3], columns: 2) == 0)
        #expect(DevicesAndPrinters.step(from: 1, .down, groupCounts: [2, 0, 2], columns: 1) == 2)
        #expect(DevicesAndPrinters.step(from: 2, .up, groupCounts: [2, 0, 2], columns: 1) == 1)
        #expect(DevicesAndPrinters.step(from: 1, .down, groupCounts: [3], columns: 0) == 2)
        // A row-major test across a wide group: column kept.
        #expect(DevicesAndPrinters.step(from: 2, .down, groupCounts: [3, 5], columns: 4) == 5)
        #expect(DevicesAndPrinters.step(from: 6, .up, groupCounts: [3, 5], columns: 4) == 2)
    }
}
