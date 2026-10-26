import CoreGraphics
import Foundation
import Win7Core


/// Session-wide CGEventTap on the main run loop. `handler` runs inside the tap callback, so it
/// must be fast and must not make AX calls; return true to consume the event.
@MainActor
final class EventTap {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    var handler: ((SwitcherKeyEvent) -> Bool)?

    var isRunning: Bool { port != nil }

    /// Returns false when the tap can't be created (no Accessibility permission).
    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let p = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let s = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, p, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        CGEvent.tapEnable(tap: p, enable: true)
        port = p
        source = s
        return true
    }

    func stop() {
        if let p = port {
            CGEvent.tapEnable(tap: p, enable: false)
            CFMachPortInvalidate(p)
        }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        port = nil
        source = nil
    }

    /// Returns true to consume the event.
    fileprivate func handle(_ e: SwitcherKeyEvent) -> Bool {
        if case .tapDisabled = e, let port { CGEvent.tapEnable(tap: port, enable: true) }
        return handler?(e) == true
    }
}

// The tap source lives on the main run loop, so the callback always runs on the main thread.
private func eventTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                              _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let info else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(info).takeUnretainedValue()
    // Check the type before touching the event: a disabled-notification carries no usable event.
    let key: SwitcherKeyEvent
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        _ = MainActor.assumeIsolated { tap.handle(.tapDisabled) }
        return nil
    case .keyDown:
        let f = event.flags
        key = .keyDown(code: event.getIntegerValueField(.keyboardEventKeycode), option: f.contains(.maskAlternate),
                       shift: f.contains(.maskShift), cmd: f.contains(.maskCommand), ctrl: f.contains(.maskControl))
    case .keyUp:
        key = .keyUp(code: event.getIntegerValueField(.keyboardEventKeycode))
    case .flagsChanged:
        key = .flagsChanged(option: event.flags.contains(.maskAlternate))
    default:
        return Unmanaged.passUnretained(event)
    }
    return MainActor.assumeIsolated { tap.handle(key) } ? nil : Unmanaged.passUnretained(event)
}
