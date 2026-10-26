import AppKit
import CoreServices
import Win7Core

/// The installed programs, scanned off the main thread and kept between Start menu openings. FSEvents
/// on /Applications and ~/Applications trigger a rescan; opening the menu rescans when the last scan
/// is more than 60 s old (that also covers /System/Applications, which only changes with macOS).
@MainActor
final class AppCatalogCache {
    static let shared = AppCatalogCache()
    static let maxAge: TimeInterval = 60

    private(set) var apps: [AppEntry] = []
    /// The applications folders, as `ProgramTree.build` takes them.
    let roots = AppCatalog.defaultDirectories.map(\.path)
    /// Called on the main thread after a scan changed `apps`.
    var onChange: (() -> Void)?

    private var scannedAt: Date?
    private var scanning = false
    private var rescanPending = false
    private var stream: FSEventStreamRef?
    private var started = false

    private init() {}

    /// Starts watching and runs the first scan. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        watch()
        scan()
    }

    /// Called when the Start menu opens.
    func refreshIfStale() {
        // A scan in progress is fresh enough; only FSEvents queue a rescan behind it.
        if scanning { return }
        if let at = scannedAt, Date().timeIntervalSince(at) < AppCatalogCache.maxAge { return }
        scan()
    }

    private func scan() {
        if scanning { rescanPending = true; return }
        scanning = true
        let directories = AppCatalog.defaultDirectories
        DispatchQueue.global(qos: .userInitiated).async {
            let found = AppCatalog.scan(directories: directories)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppCatalogCache.shared.finish(found) }
            }
        }
    }

    private func finish(_ found: [AppEntry]) {
        scanning = false
        scannedAt = Date()
        if found != apps {
            apps = found
            onChange?()
        }
        if rescanPending {
            rescanPending = false
            scan()
        }
    }

    private func watch() {
        let fm = FileManager.default
        let paths = ["/Applications", fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
            .filter { fm.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }
        // The stream delivers on the main queue; the callback only marks the catalog for a rescan.
        let callback: FSEventStreamCallback = { _, _, _, _, _, _ in
            MainActor.assumeIsolated { AppCatalogCache.shared.scan() }
        }
        guard let s = FSEventStreamCreate(nil, callback, nil, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        if FSEventStreamStart(s) { stream = s } else { FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
    }
}
