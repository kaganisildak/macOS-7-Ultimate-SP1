import Darwin
import Foundation

/// Whether Ammonia injected Win7Chrome.dylib into a running process, read the way `vmmap` and
/// `lsof` do: the process's mapped regions and their file paths through libproc. A process of the same user
/// needs no entitlement; hardened-runtime and library-validation apps answer like any other.
enum ChromePresence {
    static let dylibName = "Win7Chrome.dylib"
    /// The walk stops after this many regions (the dylib is mapped next to the main executable, so in the
    /// first hundred or so; Safari has about 2000 regions in all).
    static let maxRegions = 4096

    /// True when a mapped region's path ends in Win7Chrome.dylib; false when every region was read without
    /// one; nil when the kernel refused (another user's process, one that went away), the walk hit its bound
    /// or stopped advancing, or `pid` is 0, 1 or our own.
    static func hasWin7Chrome(pid: pid_t) -> Bool? {
        guard pid > 1, pid != getpid() else { return nil }
        var info = proc_regionwithpathinfo()
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        var address: UInt64 = 0
        for index in 0..<maxRegions {
            errno = 0
            let read = proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &info, size)
            if read < size {
                // Past the last region the kernel answers EINVAL; anything else (EPERM, ESRCH) is a refusal.
                return index > 0 && errno == EINVAL ? false : nil
            }
            let matches = withUnsafeBytes(of: info.prp_vip.vip_path) { raw -> Bool in
                let path = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                return path.hasSuffix("/" + dylibName)
            }
            if matches { return true }
            let next = info.prp_prinfo.pri_address &+ info.prp_prinfo.pri_size
            guard next > address else { return nil }   // a walk that stops advancing is not an answer
            address = next
        }
        return nil
    }

    /// The process's start time from the kernel (`ps -o lstart`), for processes LaunchServices gives no
    /// launch date (loginwindow, Finder, the shell when started by launchd).
    static func startDate(pid: pid_t) -> Date? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }
}
