import AppKit
import ScreenCaptureKit
import Win7Core

/// Lists an app's windows with whatever permissions exist: CGWindowList alone (ids, bounds),
/// Accessibility (titles, minimized windows), Screen Recording (thumbnails). The window lists come
/// from the WindowSnapshotStore (fetched off the main thread).
@MainActor
final class ThumbnailProvider {
    typealias Entry = WindowListEntry<CGImage>

    /// At most two window captures run at once, across the window popup and the switcher.
    private static let captures = ConcurrencyLimiter(limit: 2)

    /// Set from the AppDelegate's 5 s permission tick; capture is skipped without `.thumbnails`.
    var features: Set<Feature> = []
    /// Set from the same tick; without it windows are counted and listed from CGWindowList only.
    var accessibilityTrusted = false {
        didSet { store.accessibilityTrusted = accessibilityTrusted }
    }
    let store: WindowSnapshotStore

    init(store: WindowSnapshotStore) { self.store = store }

    /// The app's windows front to back, minimized ones last; images only with `.thumbnails`. Each
    /// capture is scaled in the capture itself (`maxWidth` at 2x); a cancelled task stops before its
    /// next capture.
    func thumbnails(pid: pid_t, maxWidth: CGFloat) async -> [Entry] {
        let snapshot = await store.windows(pid: pid)
        let app = NSRunningApplication(processIdentifier: pid)
        let appName = ProgramNames.displayName(bundleID: app?.bundleIdentifier, macName: app?.localizedName ?? "")
        var images: [UInt32: CGImage] = [:]
        if features.contains(.thumbnails), !Task.isCancelled, let content = try? await SCShareableContent.current {
            let wanted = Set(WindowList.merge(ax: snapshot.ax, cg: snapshot.cg, images: [UInt32: CGImage](), appName: appName)
                .filter { !$0.isMinimized }.map(\.id))
            let windows = content.windows.filter {
                $0.owningApplication?.processID == pid && $0.isOnScreen && wanted.contains($0.windowID)
            }
            for w in windows {
                if Task.isCancelled { return [] }
                let config = SCStreamConfiguration()
                let scale: CGFloat = 2
                config.width = Int(maxWidth * scale)
                config.height = max(1, Int(maxWidth * scale * w.frame.height / w.frame.width))
                config.showsCursor = false
                // Cancelled while waiting for a slot (the popup closed): stop at once, holding none.
                guard await Self.captures.acquire() else { return [] }
                if Task.isCancelled { await Self.captures.release(); return [] }
                let state = ShellPerf.signposter.beginInterval("windowCapture")
                let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: config)
                ShellPerf.signposter.endInterval("windowCapture", state)
                await Self.captures.release()
                if let image { images[w.windowID] = image }
            }
        }
        return WindowList.merge(ax: snapshot.ax, cg: snapshot.cg, images: images, appName: appName)
    }

    /// What a taskbar click decides on: CGWindowList, plus AX minimized windows when trusted (cached
    /// for up to 1 s by the store).
    func windowCounts(pid: pid_t) -> WindowCounts { store.counts(pid: pid) }
}
