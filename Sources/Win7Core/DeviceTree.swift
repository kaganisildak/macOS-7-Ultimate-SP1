import Foundation
import SystemConfiguration

// Device Manager and Devices and Printers, read-only viewers fed by `system_profiler -json`. Only
// names, categories, manufacturers and a coarse location ("USB", "Built-in") are kept: never a serial number, a MAC
// address, a UUID, a path or a URI, and nothing but counts is logged.

/// Windows 7's Device Manager categories, in its (alphabetical) order, with its exact titles.
public enum DeviceKind: Int, CaseIterable, Hashable, Sendable {
    case audio, batteries, bluetooth, cameras, computer, diskDrives, displayAdapters, keyboards, mice, monitors,
         networkAdapters, printQueues, processors, storageControllers, usbControllers

    public var title: String {
        switch self {
        case .audio: "Audio inputs and outputs"
        case .batteries: "Batteries"
        case .bluetooth: "Bluetooth"
        case .cameras: "Cameras"
        case .computer: "Computer"
        case .diskDrives: "Disk drives"
        case .displayAdapters: "Display adapters"
        case .keyboards: "Keyboards"
        case .mice: "Mice and other pointing devices"
        case .monitors: "Monitors"
        case .networkAdapters: "Network adapters"
        case .printQueues: "Print queues"
        case .processors: "Processors"
        case .storageControllers: "Storage controllers"
        case .usbControllers: "Universal Serial Bus controllers"
        }
    }

    /// The icon override (`Assets/icons/<name>.png`, IconCatalog.shell, both maps).
    public var iconName: String {
        switch self {
        case .audio: "dev-audio"
        case .batteries: "dev-battery"
        case .bluetooth: "dev-bluetooth"
        case .cameras: "dev-camera"
        case .computer: "dev-computer"
        case .diskDrives: "dev-disk"
        case .displayAdapters: "dev-display"
        case .keyboards: "dev-keyboard"
        case .mice: "dev-mouse"
        case .monitors: "dev-monitor"
        case .networkAdapters: "dev-network"
        case .printQueues: "dev-printer"
        case .processors: "dev-processor"
        case .storageControllers: "dev-storage"
        case .usbControllers: "dev-usb"
        }
    }

    /// An older shared name with the same Windows 7 picture (the pack map cannot list one id twice), tried next.
    public var sharedIconName: String? {
        switch self {
        case .audio: "cp-sound"
        case .batteries: "cp-power-options"
        case .computer: "computer"
        case .diskDrives: "drive"
        case .mice: "cp-mouse"
        case .networkAdapters: "network"
        default: nil
        }
    }

    /// Every icon name everything in this file can ask for.
    public static var iconNames: [String] { allCases.map(\.iconName) }
}

/// One device under a category.
public struct DeviceNode: Hashable, Sendable {
    public var name: String
    public var manufacturer: String?
    /// Where it hangs: "Built-in", "USB", "Bluetooth", "PCI Express", "on <display adapter>" …; nil when unknown.
    public var location: String?
    /// A controller rather than a peripheral (the Bluetooth radio): left out of Devices and Printers.
    public var isAdapter: Bool

    public init(name: String, manufacturer: String? = nil, location: String? = nil, isAdapter: Bool = false) {
        self.name = name; self.manufacturer = manufacturer; self.location = location; self.isAdapter = isAdapter
    }
}

/// A non-empty category of the tree, its devices sorted by name.
public struct DeviceCategory: Hashable, Sendable {
    public var kind: DeviceKind
    public var devices: [DeviceNode]
    public var title: String { kind.title }
    public var iconName: String { kind.iconName }

    public init(kind: DeviceKind, devices: [DeviceNode]) { self.kind = kind; self.devices = devices }
}

public enum DeviceTreeError: Error, Equatable {
    /// Not a JSON object (garbage, an array, empty data).
    case notAnObject
}

/// The General tab of Windows 7's device Properties dialog.
public struct DeviceProperties: Equatable, Sendable {
    public static let status = "This device is working properly."
    public var title: String
    public var name: String
    public var deviceType: String
    public var manufacturer: String
    public var location: String

    public init(_ node: DeviceNode, kind: DeviceKind) {
        name = node.name
        title = node.name + " Properties"
        deviceType = kind.title
        manufacturer = node.manufacturer ?? "(Standard system devices)"
        location = node.location ?? "Unknown"
    }
}

public enum DeviceTree {
    public static let executable = "/usr/sbin/system_profiler"
    /// SPUSBHostDataType holds the USB buses on macOS 15 and later, where SPUSBDataType comes back empty.
    public static let dataTypes = [
        "SPAudioDataType", "SPBluetoothDataType", "SPCameraDataType", "SPDisplaysDataType", "SPNVMeDataType",
        "SPSerialATADataType", "SPStorageDataType", "SPUSBDataType", "SPUSBHostDataType", "SPNetworkDataType",
        "SPHardwareDataType", "SPPowerDataType", "SPPrintersDataType",
    ]
    /// Fixed. `-detailLevel mini` makes system_profiler itself leave out serial numbers, UUIDs and addresses.
    public static let arguments = ["-json", "-detailLevel", "mini"] + dataTypes
    public static let timeout: TimeInterval = 20
    public static let outputCap = 8 * 1024 * 1024
    public static let maxNameLength = 128
    public static let maxProcessors = 256
    /// Devices kept per category at most (a runaway USB tree stays bounded).
    public static let maxDevicesPerCategory = 512

    // MARK: Parsing

    /// The categories with devices, in Windows 7's order. Unknown data types are ignored; a value of the wrong
    /// shape is skipped. Throws only when `json` is not a JSON object.
    public static func parse(json: Data) throws -> [DeviceCategory] {
        guard !json.isEmpty, let any = try? JSONSerialization.jsonObject(with: json),
              let root = any as? [String: Any] else { throw DeviceTreeError.notAnObject }
        var b = Builder()
        b.audio(items(root["SPAudioDataType"]))
        b.bluetooth(items(root["SPBluetoothDataType"]))
        b.cameras(items(root["SPCameraDataType"]))
        b.displays(items(root["SPDisplaysDataType"]))
        b.disks(items(root["SPNVMeDataType"]), location: "PCI Express")
        b.disks(items(root["SPSerialATADataType"]), location: "Serial ATA")
        b.storage(items(root["SPStorageDataType"]))
        let legacyUSB = items(root["SPUSBDataType"])
        b.usb(legacyUSB.isEmpty ? items(root["SPUSBHostDataType"]) : legacyUSB)
        b.network(items(root["SPNetworkDataType"]))
        b.hardware(items(root["SPHardwareDataType"]))
        b.power(items(root["SPPowerDataType"]))
        b.printers(items(root["SPPrintersDataType"]))
        return b.categories()
    }

    /// What the loader hands the window: the parsed tree, or an empty one for missing or unreadable output.
    public static func categories(from data: Data?) -> [DeviceCategory] {
        guard let data, let tree = try? parse(json: data) else { return [] }
        return tree
    }

    private static func items(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    /// A display name: trimmed, control characters dropped, at most `maxNameLength` characters; system_profiler's
    /// `kHW_<name>Item` placeholders read as `<name>`. Nil when nothing is left.
    static func clean(_ value: Any?) -> String? {
        guard var s = value as? String else { return nil }
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("kHW_") {
            s.removeFirst(4)
            if s.hasSuffix("Item") { s.removeLast(4) }
        }
        if s.count > maxNameLength { s = String(s.prefix(maxNameLength)) }
        return s.isEmpty ? nil : s
    }

    /// The first number of `number_processors`: an integer, "proc 10:8:2" (Apple silicon) or "12 (8 performance …)";
    /// 1 when there is none; at most `maxProcessors`.
    static func processorCount(_ value: Any?) -> Int {
        var n = 1
        if let i = value as? Int {
            n = i
        } else if let s = value as? String {
            let digits = s.drop { !$0.isNumber }.prefix { $0.isNumber }
            n = Int(digits.prefix(6)) ?? 1
        }
        return min(max(n, 1), maxProcessors)
    }

    private struct Builder {
        var devices: [DeviceKind: [DeviceNode]] = [:]

        mutating func add(_ kind: DeviceKind, _ name: String?, manufacturer: String? = nil, location: String? = nil,
                          adapter: Bool = false, unique: Bool = false) {
            guard let name, (devices[kind]?.count ?? 0) < DeviceTree.maxDevicesPerCategory else { return }
            if unique, devices[kind]?.contains(where: { $0.name == name }) == true { return }
            devices[kind, default: []].append(DeviceNode(name: name, manufacturer: manufacturer, location: location,
                                                         isAdapter: adapter))
        }

        func categories() -> [DeviceCategory] {
            DeviceKind.allCases.compactMap { kind in
                guard let list = devices[kind], !list.isEmpty else { return nil }
                return DeviceCategory(kind: kind, devices: list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            }
        }

        mutating func audio(_ groups: [[String: Any]]) {
            for d in groups.flatMap({ DeviceTree.items($0["_items"]) }) {
                add(.audio, clean(d["_name"]), manufacturer: clean(d["coreaudio_device_manufacturer"]),
                    location: Self.audioLocation(d["coreaudio_device_transport"] as? String))
            }
        }

        static func audioLocation(_ transport: String?) -> String? {
            guard let t = transport?.replacingOccurrences(of: "coreaudio_device_type_", with: "") else { return nil }
            let known = ["builtin": "Built-in", "usb": "USB", "bluetooth": "Bluetooth", "bluetoothle": "Bluetooth",
                         "virtual": "Virtual", "hdmi": "HDMI", "displayport": "DisplayPort", "thunderbolt": "Thunderbolt",
                         "airplay": "AirPlay", "aggregate": "Aggregate", "pci": "PCI"]
            return known[t.lowercased()]
        }

        mutating func bluetooth(_ controllers: [[String: Any]]) {
            for c in controllers {
                if let props = c["controller_properties"] as? [String: Any] {
                    let chipset = clean(props["controller_chipset"])
                    add(.bluetooth, chipset.map { "Bluetooth Controller (\($0))" } ?? "Bluetooth Controller",
                        manufacturer: Self.parenthesised(props["controller_vendorID"] as? String), location: "Built-in",
                        adapter: true)
                }
                // Connected devices only: [{"<name>": {"device_minorType": …}}].
                for entry in DeviceTree.items(c["device_connected"]) {
                    for (rawName, info) in entry {
                        let minor = ((info as? [String: Any])?["device_minorType"] as? String)?.lowercased() ?? ""
                        let kind: DeviceKind = minor.contains("keyboard") ? .keyboards
                            : (minor.contains("mouse") || minor.contains("trackpad") || minor.contains("pointing")) ? .mice
                            : .bluetooth
                        add(kind, clean(rawName), location: "Bluetooth")
                    }
                }
            }
        }

        /// "0x004C (Apple)" -> "Apple".
        static func parenthesised(_ s: String?) -> String? {
            guard let s, let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close else { return nil }
            return clean(String(s[s.index(after: open)..<close]))
        }

        mutating func cameras(_ list: [[String: Any]]) {
            for c in list { add(.cameras, clean(c["_name"])) }
        }

        mutating func displays(_ adapters: [[String: Any]]) {
            for a in adapters {
                let name = clean(a["sppci_model"]) ?? clean(a["_name"])
                var vendor = a["spdisplays_vendor"] as? String
                if let v = vendor, v.hasPrefix("sppci_vendor_") { vendor = String(v.dropFirst("sppci_vendor_".count)) }
                add(.displayAdapters, name, manufacturer: clean(vendor))
                for m in DeviceTree.items(a["spdisplays_ndrvs"]) {
                    let isInternal = (m["spdisplays_connection_type"] as? String) == "spdisplays_internal"
                    add(.monitors, clean(m["_name"]), location: name.map { "on " + $0 } ?? (isInternal ? "Built-in" : nil))
                }
            }
        }

        mutating func disks(_ controllers: [[String: Any]], location: String) {
            for c in controllers {
                add(.storageControllers, clean(c["_name"]), location: "Built-in", unique: true)
                for d in DeviceTree.items(c["_items"]) {
                    add(.diskDrives, clean(d["device_model"]) ?? clean(d["_name"]), location: location, unique: true)
                }
            }
        }

        /// The volumes' physical drives (external disks too), each drive once.
        mutating func storage(_ volumes: [[String: Any]]) {
            for v in volumes {
                guard let drive = v["physical_drive"] as? [String: Any] else { continue }
                let name = clean(drive["device_name"]) ?? clean(drive["media_name"])
                let isInternal = (drive["is_internal_disk"] as? String) == "yes"
                let location = isInternal ? "Internal" : (clean(drive["protocol"]) ?? "External")
                add(.diskDrives, name, location: location, unique: true)
            }
        }

        /// Buses become a host controller and its root hub; devices (any depth) go to Keyboards or Mice by name,
        /// the rest stay under the USB controllers.
        mutating func usb(_ buses: [[String: Any]]) {
            for bus in buses {
                let id = [bus["host_controller"], bus["Driver"], bus["_name"]].compactMap { $0 as? String }.joined(separator: " ")
                let upper = id.uppercased()
                let controller = upper.contains("XHCI") ? "USB eXtensible Host Controller"
                    : upper.contains("EHCI") ? "USB Enhanced Host Controller" : "USB Host Controller"
                add(.usbControllers, controller, location: "Built-in")
                add(.usbControllers, "USB Root Hub", location: "Built-in")
                usbDevices(DeviceTree.items(bus["_items"]), depth: 0)
            }
        }

        private mutating func usbDevices(_ list: [[String: Any]], depth: Int) {
            guard depth < 8 else { return }
            for d in list {
                if let name = clean(d["_name"]) {
                    let lower = name.lowercased()
                    let kind: DeviceKind = lower.contains("keyboard") ? .keyboards
                        : (lower.contains("mouse") || lower.contains("trackpad") || lower.contains("trackball")) ? .mice
                        : .usbControllers
                    add(kind, name, manufacturer: clean(d["manufacturer"]) ?? clean(d["USBDeviceKeyVendorName"]), location: "USB")
                }
                usbDevices(DeviceTree.items(d["_items"]), depth: depth + 1)
            }
        }

        mutating func network(_ services: [[String: Any]]) {
            for s in services { add(.networkAdapters, clean(s["_name"]), unique: true) }
        }

        mutating func hardware(_ list: [[String: Any]]) {
            guard let h = list.first else { return }
            add(.computer, clean(h["machine_name"]) ?? clean(h["machine_model"]), manufacturer: "Apple Inc.")
            guard let cpu = clean(h["chip_type"]) ?? clean(h["cpu_type"]) else { return }
            let maker = cpu.hasPrefix("Apple") ? "Apple Inc." : cpu.contains("Intel") ? "Intel Corporation" : nil
            for _ in 0..<DeviceTree.processorCount(h["number_processors"]) { add(.processors, cpu, manufacturer: maker) }
        }

        /// A battery and, with it, the AC adapter (as Windows 7 lists both under Batteries).
        mutating func power(_ list: [[String: Any]]) {
            guard let info = list.lazy.compactMap({ $0["sppower_battery_model_info"] as? [String: Any] }).first else { return }
            add(.batteries, "AC Adapter")
            add(.batteries, "Internal Battery", manufacturer: clean(info["sppower_battery_manufacturer"]), location: "Built-in")
        }

        /// Printers only: with none, system_profiler gives one entry without a `_name` (the CUPS status).
        mutating func printers(_ list: [[String: Any]]) {
            for p in list { add(.printQueues, clean(p["_name"]), unique: true) }
        }
    }

    // MARK: Running system_profiler

    /// Used for the root and the computer tile when the local store has no name.
    public static let fallbackComputerName = "Computer"

    /// The computer's name from the local dynamic store (System Settings ▸ Sharing), never a network lookup; nil
    /// when it is not set.
    public static func localComputerName() -> String? {
        guard let name = SCDynamicStoreCopyComputerName(nil, nil) as String? else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maxNameLength))
    }

    /// The computer's name, or "Computer".
    public static func computerName() -> String { localComputerName() ?? fallbackComputerName }

    /// Runs `system_profiler` once, off the main thread (20 s timeout, at most 8 MB of output), and calls
    /// `completion` on the main queue with the tree (empty when anything went wrong) and the computer name.
    public static func load(completion: @escaping @Sendable (_ categories: [DeviceCategory], _ computerName: String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let tree = categories(from: runProfiler())
            let computer = computerName()
            DispatchQueue.main.async { completion(tree, computer) }
        }
    }

    /// Reads `handle` until end of file or past `cap` bytes; on overflow the data stops at `cap`.
    public static func readCapped(_ handle: FileHandle, cap: Int) -> (data: Data, overflow: Bool) {
        var data = Data()
        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { return (data, false) }
            if data.count + chunk.count > cap {
                data.append(chunk.prefix(cap - data.count))
                return (data, true)
            }
            data.append(chunk)
        }
    }

    /// How a bounded run ended.
    public enum RunOutcome: Equatable, Sendable {
        /// It exited on its own before the deadline, with this status.
        case exited(Int32)
        /// It was ended by this signal before the deadline (not by the runner).
        case signalled(Int32)
        case timedOut
        case overflow
        case launchFailed
        /// Reading its output failed.
        case readFailed
    }

    public struct Run: Sendable {
        public var outcome: RunOutcome
        /// What was read (at most `cap` bytes), whatever the outcome.
        public var output: Data
        /// The child's id (its process group's too); 0 when it never started.
        public var pid: pid_t
        /// The output, only after a zero exit.
        public var data: Data? { outcome == .exited(0) ? output : nil }
    }

    /// The profiler's output, or nil after a launch failure, the timeout, an overflow or a non-zero exit.
    static func runProfiler(executable: String = executable, arguments: [String] = arguments,
                            timeout: TimeInterval = timeout, cap: Int = outputCap) -> Data? {
        run(executable: executable, arguments: arguments, timeout: timeout, cap: cap).data
    }

    /// The SIGTERM-to-SIGKILL grace.
    static let killGrace: TimeInterval = 1

    /// Runs `executable` in a process group of its own (posix_spawn, POSIX_SPAWN_SETPGROUP; only stdin, stdout and
    /// stderr inherited, signals at their defaults) and reads its stdout until end of file, the deadline (`timeout`
    /// after the launch) or past `cap` bytes, whichever comes first. A run still going at the deadline or past the
    /// cap gets SIGTERM sent to its whole group, then SIGKILL after `killGrace`; every run ends with SIGKILL to the
    /// group (a helper that kept the pipe open goes too) before the child is reaped, so the group id cannot be
    /// reused under the signal. Bounded: returns within about `timeout + killGrace + 1` s whatever the child does.
    /// `politeSignal` is SIGTERM; tests pass one the child ignores to see the SIGKILL escalation.
    static func run(executable: String, arguments: [String], timeout: TimeInterval, cap: Int,
                    politeSignal: Int32 = SIGTERM) -> Run {
        let start = monotonicNow()
        let deadline = start + timeout
        guard let child = spawn(executable, arguments) else { return Run(outcome: .launchFailed, output: Data(), pid: 0) }
        let pid = child.pid

        var output = Data()
        var stop: RunOutcome?
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        reading: while true {
            let remaining = deadline - monotonicNow()
            if remaining <= 0 { stop = .timedOut; break }
            var fd = pollfd(fd: child.output, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fd, 1, Int32(min(remaining * 1000, 60_000).rounded(.up)))
            if ready < 0 {
                if errno == EINTR { continue }
                stop = .readFailed
                break
            }
            if ready == 0 { continue }
            let n = buffer.withUnsafeMutableBytes { read(child.output, $0.baseAddress, $0.count) }
            switch n {
            case 0:
                break reading   // end of file: every writer closed the pipe
            case let n where n > 0:
                if output.count + n > cap {
                    output.append(contentsOf: buffer[0..<(cap - output.count)])
                    stop = .overflow
                    break reading
                }
                output.append(contentsOf: buffer[0..<n])
            default:
                if errno == EINTR || errno == EAGAIN { continue }
                stop = .readFailed
                break reading
            }
        }
        close(child.output)

        // End of file before the deadline: the child still has until the deadline to exit.
        if stop == nil, !hasExited(pid, until: deadline) { stop = .timedOut }
        if stop != nil {
            kill(-pid, politeSignal)
            _ = hasExited(pid, until: monotonicNow() + killGrace)
        }
        // The leader is alive or a zombie here, so its id still names the group.
        kill(-pid, SIGKILL)
        let status = reap(pid, until: monotonicNow() + 1)
        if let stop { return Run(outcome: stop, output: output, pid: pid) }
        guard let status else { return Run(outcome: .timedOut, output: output, pid: pid) }
        let signal = status & 0x7F
        let outcome: RunOutcome = signal == 0 ? .exited((status >> 8) & 0xFF) : .signalled(signal)
        return Run(outcome: outcome, output: output, pid: pid)
    }

    private static func monotonicNow() -> TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }

    /// Launches `executable` with stdin and stderr on /dev/null and stdout into a pipe; the pipe's read end
    /// (non-blocking) and the child's id, or nil.
    private static func spawn(_ executable: String, _ arguments: [String]) -> (pid: pid_t, output: Int32)? {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        // Other threads' spawns must not inherit either end (that would hold the pipe open).
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(readEnd, F_SETFL, fcntl(readEnd, F_GETFL) | O_NONBLOCK)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own group (pgid = its pid), nothing inherited but 0–2, default dispositions, nothing blocked.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        close(writeEnd)
        guard result == 0, pid > 0 else {
            close(readEnd)
            return nil
        }
        return (pid, readEnd)
    }

    /// Whether `pid` has exited by `deadline`, without reaping it (a zombie keeps its group id reserved). macOS's
    /// waitid also reports a stopped child here, so only an exit, a kill or a core dump counts.
    private static func hasExited(_ pid: pid_t, until deadline: TimeInterval) -> Bool {
        while true {
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid,
               [CLD_EXITED, CLD_KILLED, CLD_DUMPED].contains(info.si_code) { return true }
            if monotonicNow() >= deadline { return false }
            usleep(5_000)
        }
    }

    /// Reaps `pid` and returns its wait status; after `deadline` a background thread reaps it later and this
    /// returns nil (the caller never blocks past the deadline).
    private static func reap(_ pid: pid_t, until deadline: TimeInterval) -> Int32? {
        var status: Int32 = 0
        while true {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { return status }
            if r < 0, errno != EINTR { return nil }
            if monotonicNow() >= deadline {
                DispatchQueue.global(qos: .utility).async {
                    var s: Int32 = 0
                    while waitpid(pid, &s, 0) < 0, errno == EINTR {}
                }
                return nil
            }
            usleep(5_000)
        }
    }
}

// MARK: - Devices and Printers

/// One tile of the Devices and Printers icon view.
public struct DeviceTile: Hashable, Sendable {
    public var name: String
    public var kind: DeviceKind
    public var node: DeviceNode
    public var iconName: String { kind.iconName }
}

/// Windows 7's Devices and Printers: "Devices" (this computer first, then keyboards, mice, monitors and the
/// connected Bluetooth peripherals) and "Printers and Faxes" (the print queues).
public struct DevicesAndPrinters: Equatable, Sendable {
    public var devices: [DeviceTile]
    public var printers: [DeviceTile]

    public init(devices: [DeviceTile], printers: [DeviceTile]) { self.devices = devices; self.printers = printers }

    public init(categories: [DeviceCategory], computerName: String) {
        func tiles(_ kind: DeviceKind) -> [DeviceTile] {
            (categories.first { $0.kind == kind }?.devices ?? []).filter { !$0.isAdapter }
                .map { DeviceTile(name: $0.name, kind: kind, node: $0) }
        }
        let computer = DeviceNode(name: computerName,
                                  manufacturer: categories.first { $0.kind == .computer }?.devices.first?.manufacturer)
        devices = [DeviceTile(name: computerName, kind: .computer, node: computer)]
            + tiles(.keyboards) + tiles(.mice) + tiles(.monitors) + tiles(.bluetooth)
        printers = tiles(.printQueues)
    }

    public static func devicesTitle(_ count: Int) -> String { "Devices (\(count))" }
    public static func printersTitle(_ count: Int) -> String { "Printers and Faxes (\(count))" }

    /// The tiles whose name contains `query` (case- and diacritic-insensitive, also in tr_TR); all for a blank query.
    public func filtered(_ query: String) -> DevicesAndPrinters {
        let q = AppCatalog.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return self }
        let match: (DeviceTile) -> Bool = { AppCatalog.fold($0.name).contains(q) }
        return DevicesAndPrinters(devices: devices.filter(match), printers: printers.filter(match))
    }

    /// The tile an arrow key selects. Tiles are numbered through the groups in order (`groupCounts`, each group
    /// laid out in rows of `columns`). Left and Right step one tile through the groups; Up and Down step one row
    /// in the same column, onto the last tile of a shorter row, and across into the next (or previous) non-empty
    /// group's first (last) row; at the ends the selection stays. Nothing selected selects the first tile; nil
    /// when there are no tiles.
    public static func step(from index: Int?, _ direction: TileStep, groupCounts: [Int], columns: Int) -> Int? {
        let counts = groupCounts.map { max(0, $0) }
        let total = counts.reduce(0, +)
        guard total > 0 else { return nil }
        guard let i = index, i >= 0, i < total else { return 0 }
        let cols = max(1, columns)
        switch direction {
        case .left: return max(0, i - 1)
        case .right: return min(total - 1, i + 1)
        case .up, .down: break
        }
        var start = 0, group = 0
        while i >= start + counts[group] { start += counts[group]; group += 1 }
        let local = i - start, row = local / cols, column = local % cols
        if direction == .down {
            if (row + 1) * cols < counts[group] { return start + min(counts[group] - 1, (row + 1) * cols + column) }
            var next = start + counts[group]
            for g in (group + 1)..<counts.count {
                if counts[g] > 0 { return next + min(counts[g] - 1, column) }
                next += counts[g]
            }
            return i
        }
        if row > 0 { return start + (row - 1) * cols + column }
        var previousEnd = start
        for g in stride(from: group - 1, through: 0, by: -1) {
            let first = previousEnd - counts[g]
            if counts[g] > 0 {
                let lastRow = (counts[g] - 1) / cols
                return first + min(counts[g] - 1, lastRow * cols + column)
            }
            previousEnd = first
        }
        return i
    }
}

/// An arrow key in the Devices and Printers icon view.
public enum TileStep: Sendable { case left, right, up, down }
