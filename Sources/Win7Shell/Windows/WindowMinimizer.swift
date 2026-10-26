import AppKit
import ApplicationServices

/// Minimizes many windows at once and brings them back: Win+M / Win+Shift+M, and Win+Home /
/// Aero Shake. Frames are AX coordinates.
@MainActor
final class WindowMinimizer {
    private let service: WindowService
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    /// What Win+M did: windows it minimized (Accessibility), or apps it hid (without it).
    private var minimizedAll: [AXUIElement] = []
    private var hiddenApps: [NSRunningApplication] = []
    /// The window (or, without Accessibility, the app) that had focus at the first Win+M; restored last.
    private var focusedAtMinimizeAll: AXUIElement?
    private var frontAppAtMinimizeAll: NSRunningApplication?
    /// What the last Win+Home or shake minimized around the window it kept.
    private var minimizedOthers: [AXUIElement] = []
    private var keptWindow: AXUIElement?

    init(service: WindowService) { self.service = service }

    /// Win+M. Without Accessibility the visible apps are hidden instead; Show Desktop (Win+D)
    /// does not bring those back, Win+Shift+M does.
    func minimizeAll(accessibility: Bool) {
        let front = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == ownPID ? nil : $0 }
        if accessibility {
            if minimizedAll.isEmpty, front != nil { focusedAtMinimizeAll = service.focusedWindow() }
            let windows = openWindows()
            for w in windows { service.minimize(w) }
            minimizedAll += windows
        } else {
            if hiddenApps.isEmpty { frontAppAtMinimizeAll = front }
            let apps = visibleApps()
            for app in apps { app.hide() }
            hiddenApps += apps
        }
    }

    /// Win+Shift+M: restores what Win+M minimized or hid. The window or app that had focus at Win+M
    /// comes back last and gets focus again, so it ends on top.
    func restoreAll() {
        let focused = focusedAtMinimizeAll
        for w in minimizedAll.reversed() where focused.map({ !CFEqual(w, $0) }) ?? true { service.unminimize(w) }
        let frontApp = frontAppAtMinimizeAll
        for app in hiddenApps where !app.isTerminated && app != frontApp { app.unhide() }
        if let focused { bringBack(focused) }
        if let frontApp, hiddenApps.contains(frontApp), !frontApp.isTerminated {
            frontApp.unhide()
            frontApp.activate()
        }
        minimizedAll = []
        hiddenApps = []
        focusedAtMinimizeAll = nil
        frontAppAtMinimizeAll = nil
    }

    /// Win+Home (`screen` nil: every screen) and Aero Shake (the shaken window's screen): minimizes
    /// every other window; if windows the last such call minimized are still minimized, restores
    /// them instead, and the window kept then comes back last with focus. Needs Accessibility.
    func toggleOthers(keeping window: AXUIElement, on screen: CGRect?) {
        if minimizedOthers.contains(where: { service.isMinimized($0) }) {
            for w in minimizedOthers.reversed() { service.unminimize(w) }
            bringBack(keptWindow ?? window)
            minimizedOthers = []
            keptWindow = nil
            return
        }
        keptWindow = window
        minimizedOthers = openWindows().filter { w in
            guard !CFEqual(w, window) else { return false }
            guard let screen else { return true }
            guard let f = service.frame(w) else { return false }
            return screen.contains(CGPoint(x: f.midX, y: f.midY))
        }
        for w in minimizedOthers { service.minimize(w) }
    }

    /// Un-minimizes (if needed), raises and focuses one window.
    private func bringBack(_ window: AXUIElement) {
        if service.isMinimized(window) { service.unminimize(window) }
        service.raise(window)
        if let pid = service.pid(window) { NSRunningApplication(processIdentifier: pid)?.activate() }
    }

    /// Standard, un-minimized windows of the visible apps, each app's front to back.
    private func openWindows() -> [AXUIElement] {
        visibleApps().flatMap { service.windows(pid: $0.processIdentifier) }
            .filter { service.isStandard($0) && !service.isMinimized($0) }
    }

    /// Regular apps other than the shell that are not hidden.
    private func visibleApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID && !$0.isHidden
        }
    }
}
