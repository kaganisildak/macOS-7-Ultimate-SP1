import Foundation
import os
import Win7Core

/// signposted intervals (subsystem com.win7mac.shell, category "perf"; Instruments' os_signpost
/// track) around the shell's hot paths, and with `defaults write -g W7PerfLog -bool YES` a log line
/// for every main-thread interval over 16 ms (`log stream --predicate 'subsystem == "com.win7mac.shell"'`).
enum ShellPerf {
    static let signposter = OSSignposter(subsystem: "com.win7mac.shell", category: "perf")
    private static let log = Logger(subsystem: "com.win7mac.shell", category: "perf")
    /// Read once: takes effect on the next launch, as the dylib's defaults do.
    private static let logEnabled = UserDefaults.standard.bool(forKey: PerfBudget.defaultsKey)

    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            signposter.endInterval(name, state)
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            if PerfBudget.shouldLog(duration: seconds, isMainThread: Thread.isMainThread, enabled: logEnabled) {
                log.notice("slow main-thread interval \(String(describing: name), privacy: .public): \(seconds * 1000, format: .fixed(precision: 1)) ms")
            }
        }
        return try body()
    }
}

extension Timer {
    /// `scheduledTimer` with a tolerance of `fraction` of `interval` (TimerTolerance, 10–20 %), so the
    /// system can coalesce the wake-up with others. `mode` .common keeps it firing while a menu tracks.
    @discardableResult
    static func w7Scheduled(_ interval: TimeInterval, repeats: Bool, fraction: Double = TimerTolerance.minFraction,
                            mode: RunLoop.Mode = .default, block: @escaping @Sendable (Timer) -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: repeats, block: block)
        t.tolerance = TimerTolerance.for(interval, fraction: fraction)
        RunLoop.main.add(t, forMode: mode)
        return t
    }
}
