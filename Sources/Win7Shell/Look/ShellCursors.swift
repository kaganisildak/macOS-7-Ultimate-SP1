import AppKit
import Win7ChromeCore
import Win7Theme

/// The shell's own windows (taskbar, desktop, Start menu) are denylisted from the dylib, so the shell
/// installs the same cursors itself: the imported Assets/cursors/*.png where present (with
/// cursors/hotspots.txt), the procedural Aero cursors from Win7Theme otherwise. Every view that asks
/// NSCursor for the arrow, I-beam, hand or a resize cursor (cursor rects, cursorUpdate) then gets them.
@MainActor
enum ShellCursors {
    /// Swizzles (honouring `defaults write -g W7ProceduralCursorsDisabled -bool YES`) and sets the arrow.
    static func install() {
        W7InstallCursorsWithImported(imported())
        NSCursor.arrow.set()
    }

    /// {arrow|ibeam|hand: NSCursor} from the imported PNGs.
    static func imported() -> [String: NSCursor] {
        var hot: [String: NSPoint] = [:]
        if let url = AssetStore.shared.url("cursors/hotspots.txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let f = line.split(separator: " ")
                if f.count == 3, let x = Double(f[1]), let y = Double(f[2]) { hot[String(f[0])] = NSPoint(x: x, y: y) }
            }
        }
        var out: [String: NSCursor] = [:]
        for name in ["arrow", "ibeam", "hand"] {
            guard let image = AssetStore.shared.image("cursors/\(name).png"), image.size.width > 0 else { continue }
            out[name] = NSCursor(image: image, hotSpot: hot[name] ?? .zero)
        }
        return out
    }
}

/// Windows 7's "working in background" cursor while an app the shell started is launching: the arrow
/// with the spinning ring, until the launch completes or 5 s pass. No system-wide cursor change (no
/// private APIs): macOS shows it only while the pointer is over the shell's own windows.
@MainActor
final class LaunchFeedback {
    static let shared = LaunchFeedback()
    static let timeout: TimeInterval = 5

    private var pending = 0
    private var timer: Timer?
    private var frame = 0
    private var deadline = Date.distantPast

    /// Call when a launch starts; call the returned closure when it completes (or failed).
    func begin() -> @MainActor () -> Void {
        pending += 1
        deadline = Date().addingTimeInterval(Self.timeout)
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / Double(W7CursorBusyFrameCount), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        var ended = false
        return { [weak self] in
            guard !ended else { return }
            ended = true
            self?.end()
        }
    }

    private func end() {
        pending = max(0, pending - 1)
        if pending == 0 { stop() }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        pending = 0
        NSCursor.arrow.set()
    }

    private func tick() {
        guard Date() < deadline else { stop(); return }
        frame += 1
        // Only over the shell's windows: elsewhere the app under the pointer owns the cursor.
        let n = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        guard NSApp.windows.contains(where: { $0.windowNumber == n }) else { return }
        W7ProceduralCursor(.working, frame).set()
    }

    /// Opens `url` with the busy feedback until NSWorkspace reports the launch done.
    static func open(_ url: URL) {
        let done = shared.begin()
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
        }
    }

    static func openApplication(at url: URL) {
        let done = shared.begin()
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
        }
    }
}
