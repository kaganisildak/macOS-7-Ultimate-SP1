import AppKit
import Darwin
import Win7Core
import Win7Theme

/// Reads CPU ticks (host_processor_info) and VM page counts (host_statistics64). Public Mach APIs.
enum SystemLoadSampler {
    private static let host = mach_host_self()

    static func cpuTicks() -> [CPUTicks] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { i in
            func tick(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[stride * i + Int(state)]) }
            return CPUTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM), idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }

    static func vmPages() -> VMPageCounts? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return VMPageCounts(free: UInt64(stats.free_count), active: UInt64(stats.active_count), inactive: UInt64(stats.inactive_count),
                            wired: UInt64(stats.wire_count), compressed: UInt64(stats.compressor_page_count),
                            speculative: UInt64(stats.speculative_count))
    }

    static var pageSize: UInt64 {
        var size: vm_size_t = 0
        return host_page_size(host, &size) == KERN_SUCCESS ? UInt64(size) : 16384
    }
}

/// The CPU Meter gadget: the large dial is CPU use, the small one physical memory in use, with their
/// percentages in readouts under them; sampled once a second. With the user's artwork
/// (Assets/gadgets/CPU/images/), as cpu.js draws it docked: `back.png`, the readouts (white Calibri 10 bold, "00%"),
/// the needles `dial.png` / `dial_sml.png` turned −125°…+125° (CPUMeterDial) about their centres with the grey
/// shadow, the caps `dialdot.png` and `glass.png` on top. The larger size (`*_lrg.png`) is not offered. Without the
/// back, needles and caps: Win7Theme's drawn meter, as before.
final class CPUMeterGadgetView: GadgetContentView {
    private let art = GadgetArt(folder: "CPU", kind: .cpuMeter)
    private var timer: Timer?
    private var previous: [CPUTicks] = []
    private var cpu: Double = 0
    private var memory: Double = 0

    override func start() {
        previous = SystemLoadSampler.cpuTicks()
        sample()
        timer = {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
            RunLoop.main.add(t, forMode: .common)
            return t
        }()
    }

    override func stop() { timer?.invalidate(); timer = nil }

    private func sample() {
        let now = SystemLoadSampler.cpuTicks()
        cpu = SystemLoad.cpuPercent(previous: previous, current: now)
        previous = now
        if let pages = SystemLoadSampler.vmPages() {
            memory = SystemLoad.memoryPercent(pages, pageSize: SystemLoadSampler.pageSize, totalBytes: ProcessInfo.processInfo.physicalMemory)
        }
        needsDisplay = true
    }

    private var bigDial: NSRect { NSRect(x: bounds.minX + 12, y: bounds.minY + 23, width: 70, height: 70) }
    private var smallDial: NSRect { NSRect(x: bounds.maxX - 54, y: bounds.minY + 34, width: 46, height: 46) }

    override func draw(_ dirtyRect: NSRect) {
        if art.has(["back.png", "dial.png", "dial_sml.png", "dialdot.png"]), let back = art.image("back.png"),
           let needle = art.image("dial.png"), let small = art.image("dial_sml.png"), let caps = art.image("dialdot.png") {
            typealias L = GadgetLayout.CPU
            let c = GadgetCanvas(height: bounds.height)
            c.draw(back, at: .zero)
            let font = GadgetFonts.calibriBold(10)
            let cpuText = CPUMeterDial.readout(percent: cpu), memoryText = CPUMeterDial.readout(percent: memory)
            c.text(cpuText, font: font, color: .white, x: CPUMeterDial.readoutLeft(base: L.cpuReadoutLeft, text: cpuText),
                   baseline: L.cpuReadoutBaseline)
            c.text(memoryText, font: font, color: .white, x: CPUMeterDial.readoutLeft(base: L.memoryReadoutLeft, text: memoryText),
                   baseline: L.memoryReadoutBaseline)
            c.draw(needle, in: L.cpuNeedle, rotated: CPUMeterDial.angle(percent: cpu), shadow: true)
            c.draw(small, in: L.memoryNeedle, rotated: CPUMeterDial.angle(percent: memory), shadow: true)
            c.draw(caps, at: .zero)
            if let glass = art.image("glass.png") { c.draw(glass, at: .zero) }
            return
        }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        W7DrawGadgetMeterBody(ctx, bounds)
        W7DrawGadgetMeterDial(ctx, bigDial, cpu / 100)
        W7DrawGadgetMeterDial(ctx, smallDial, memory / 100)
        readout("\(Int(cpu.rounded()))%", centerX: bigDial.midX, y: bounds.minY + 8)
        readout("\(Int(memory.rounded()))%", centerX: smallDial.midX, y: bounds.minY + 18)
    }

    /// A small dark readout box with green digits, as on the Windows 7 CPU Meter.
    private func readout(_ text: String, centerX: CGFloat, y: CGFloat) {
        let box = NSRect(x: centerX - 17, y: y, width: 34, height: 14)
        NSColor(white: 0.1, alpha: 1).setFill()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor(srgbRed: 0x8C / 255, green: 0xF0 / 255, blue: 0x5A / 255, alpha: 1),
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2), withAttributes: attrs)
    }
}
