import ApplicationServices
import AppKit
import Win7Core

/// Private but long-stable: maps an AX window element to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Thin Accessibility wrapper. All frames are AX coordinates (global, top-left origin).
@MainActor
final class WindowService {
    nonisolated private static let timeout: Float = 0.25

    init() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.timeout)
    }

    func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, Self.timeout)
        let window: AXUIElement? = attribute(appElement, kAXFocusedWindowAttribute)
        if let window { AXUIElementSetMessagingTimeout(window, Self.timeout) }
        return window
    }

    func windows(pid: pid_t) -> [AXUIElement] { Self.axWindows(pid: pid) }

    func frame(_ window: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let p: AXValue = attribute(window, kAXPositionAttribute),
              let s: AXValue = attribute(window, kAXSizeAttribute),
              AXValueGetValue(p, .cgPoint, &origin), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Size, then position, then size again: the first size can be clamped by the old screen position.
    func setFrame(_ window: AXUIElement, _ frame: CGRect) {
        setSize(window, frame.size)
        setPosition(window, frame.origin)
        setSize(window, frame.size)
    }

    func setPosition(_ window: AXUIElement, _ origin: CGPoint) {
        var o = origin
        if let v = AXValueCreate(.cgPoint, &o) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v) }
    }

    func setSize(_ window: AXUIElement, _ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v) }
    }

    func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    func minimize(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    func unminimize(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    func isMinimized(_ window: AXUIElement) -> Bool {
        (attribute(window, kAXMinimizedAttribute) as Bool?) ?? false
    }

    func pid(_ window: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(window, &pid) == .success ? pid : nil
    }

    /// A standard document window, not a panel, sheet or dialog.
    func isStandard(_ window: AXUIElement) -> Bool {
        (attribute(window, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole
    }

    /// A native fullscreen window (`AXFullScreen`).
    func isFullscreen(_ window: AXUIElement) -> Bool {
        (attribute(window, "AXFullScreen") as Bool?) ?? false
    }

    func windowID(_ window: AXUIElement) -> UInt32? { Self.axWindowID(window) }

    func title(_ window: AXUIElement) -> String? {
        attribute(window, kAXTitleAttribute)
    }

    // MARK: Shared with background callers (no main-actor state)

    /// The app's AX windows, each with the 0.25 s messaging timeout.
    nonisolated private static func axWindows(pid: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, timeout)
        let list: [AXUIElement] = axAttribute(appElement, kAXWindowsAttribute) ?? []
        for w in list { AXUIElementSetMessagingTimeout(w, timeout) }
        return list
    }

    nonisolated private static func axWindowID(_ window: AXUIElement) -> UInt32? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(window, &id) == .success && id != 0 ? id : nil
    }

    nonisolated private static func axAttribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// An app's windows as the taskbar's lists and counts see them (id, title, minimized), with the
    /// same 0.25 s messaging timeouts. Callable from any thread (the window snapshot store
    /// runs it on a background queue); Accessibility calls are thread-safe.
    nonisolated static func windowInfos(pid: pid_t) -> [AXWindowInfo] {
        axWindows(pid: pid).compactMap { w in
            guard let id = axWindowID(w) else { return nil }
            return AXWindowInfo(id: id, title: axAttribute(w, kAXTitleAttribute),
                                isMinimized: axAttribute(w, kAXMinimizedAttribute) ?? false)
        }
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? { Self.axAttribute(element, name) }

    // MARK: Window change notifications (the work area)

    /// Watches one app's windows: `onChange` gets the window element when a window of the app moves,
    /// resizes or opens. Nil when the app takes none of the notifications (not ready yet, no AX support).
    func observeWindowChanges(pid: pid_t, onChange: @escaping @MainActor (AXUIElement) -> Void) -> WindowObservation? {
        WindowObservation(pid: pid, onChange: onChange)
    }

    /// One app's AX observer on the main run loop; its owner calls `invalidate()` to remove it.
    @MainActor
    final class WindowObservation {
        private static let notifications = [kAXWindowMovedNotification, kAXWindowResizedNotification,
                                            kAXWindowCreatedNotification]
        private let observer: AXObserver
        private let app: AXUIElement
        private let handler: Unmanaged<AXChangeHandler>
        private var isValid = true

        fileprivate init?(pid: pid_t, onChange: @escaping @MainActor (AXUIElement) -> Void) {
            var created: AXObserver?
            guard AXObserverCreate(pid, axObserverCallback, &created) == .success, let created else { return nil }
            observer = created
            app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, WindowService.timeout)
            handler = Unmanaged.passRetained(AXChangeHandler(onChange))
            var added = 0
            for n in Self.notifications
            where AXObserverAddNotification(observer, app, n as CFString, handler.toOpaque()) == .success {
                added += 1
            }
            guard added > 0 else {
                handler.release()
                isValid = false
                return nil
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }

        func invalidate() {
            guard isValid else { return }
            isValid = false
            for n in Self.notifications { AXObserverRemoveNotification(observer, app, n as CFString) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            handler.release()
        }
    }
}

/// The closure an AX observer calls, kept alive by its `WindowObservation`.
@MainActor
private final class AXChangeHandler {
    let onChange: @MainActor (AXUIElement) -> Void
    init(_ onChange: @escaping @MainActor (AXUIElement) -> Void) { self.onChange = onChange }
}

// The observer's source is on the main run loop, so the callback always runs on the main thread.
private func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
                                _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let handler = Unmanaged<AXChangeHandler>.fromOpaque(refcon).takeUnretainedValue()
    nonisolated(unsafe) let window = element   // used only on this (main) thread
    MainActor.assumeIsolated { handler.onChange(window) }
}
