import AppKit
import ObjectiveC
import Testing

/// Feeds W7MenuWindow's tracking loop a fixed list of events, with no window server involved.
///
/// The test runner's main loop is Swift concurrency's CFMainExecutor: a bare CFRunLoopRun, and
/// any CFRunLoopStop that reaches it ends the process with exit 0 and no results. Real event
/// delivery causes exactly that:
/// - `NSApp.postEvent` calls CFRunLoopStop on the main run loop.
/// - The first `NSApp.nextEvent(…)` makes HIToolbox start pulling window-server events. From then
///   on, every window-server event (e.g. the AppKit-defined event after a menu window orders out)
///   enqueues a common-modes block that calls CFRunLoopStop. If no nested event loop is running
///   when it fires, it stops the executor's run loop.
///
/// While `run` is active on the main thread, these are answered from the script: NSApp's
/// nextEvent (never touching the window server), `NSEvent.mouseLocation` (a fixed point far from
/// any menu), `NSEvent.pressedMouseButtons` (none) and `NSApp.isActive` (false). The loop then
/// does not depend on the real cursor or on activation. Everywhere else the originals run.
@MainActor enum ScriptedMenuInput {
    /// Runs `body` with the hooks answering from `events`, in order. The loop must end on its own
    /// script; asking for more records an issue and gets Esc so it still ends.
    static func run<T>(_ events: [NSEvent], _ body: () -> T) -> T {
        _ = installHooks
        ScriptState.pending = events
        ScriptState.overran = false
        ScriptState.active = true
        defer { ScriptState.active = false }
        let result = body()
        #expect(!ScriptState.overran, "the tracking loop asked for more events than the script had")
        #expect(ScriptState.pending.isEmpty, "the tracking loop ended with unread scripted events")
        return result
    }

    static func key(_ chars: String, _ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    /// A mouse move to `p` (screen coordinates, no window).
    static func mouseMoved(to p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
    }
}

/// Read by the hooks, which AppKit may call on any thread; they only answer from it on the main
/// thread, where `run` sets it.
private enum ScriptState {
    nonisolated(unsafe) static var active = false
    nonisolated(unsafe) static var pending: [NSEvent] = []
    nonisolated(unsafe) static var overran = false
    /// Where the scripted cursor rests: off every screen, so it never selects a row or enters a region.
    static let mouseLocation = NSPoint(x: -100_000, y: -100_000)

    static var scripting: Bool { Thread.isMainThread && active }

    static func next() -> NSEvent {
        if !pending.isEmpty { return pending.removeFirst() }
        overran = true
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                isARepeat: false, keyCode: 53)!
    }
}

private func replace(_ method: Method?, with block: Any) -> IMP {
    guard let method else { fatalError("ScriptedMenuInput: method to hook is missing") }
    return method_setImplementation(method, imp_implementationWithBlock(block))
}

@MainActor private let installHooks: Void = {
    typealias NextEvent = @convention(c) (AnyObject, Selector, UInt64, NSDate?, NSString, Bool) -> NSEvent?
    let nextSel = #selector(NSApplication.nextEvent(matching:until:inMode:dequeue:))
    var originalNext: NextEvent?
    let next: @convention(block) (AnyObject, UInt64, NSDate?, NSString, Bool) -> NSEvent? = { app, mask, date, mode, dequeue in
        ScriptState.scripting ? ScriptState.next() : originalNext!(app, nextSel, mask, date, mode, dequeue)
    }
    originalNext = unsafeBitCast(replace(class_getInstanceMethod(NSApplication.self, nextSel), with: next), to: NextEvent.self)

    typealias IsActive = @convention(c) (AnyObject, Selector) -> Bool
    let activeSel = #selector(getter: NSApplication.isActive)
    var originalActive: IsActive?
    let active: @convention(block) (AnyObject) -> Bool = { app in
        ScriptState.scripting ? false : originalActive!(app, activeSel)
    }
    originalActive = unsafeBitCast(replace(class_getInstanceMethod(NSApplication.self, activeSel), with: active), to: IsActive.self)

    typealias Location = @convention(c) (AnyObject, Selector) -> NSPoint
    let locationSel = #selector(getter: NSEvent.mouseLocation)
    var originalLocation: Location?
    let location: @convention(block) (AnyObject) -> NSPoint = { cls in
        ScriptState.scripting ? ScriptState.mouseLocation : originalLocation!(cls, locationSel)
    }
    originalLocation = unsafeBitCast(replace(class_getClassMethod(NSEvent.self, locationSel), with: location), to: Location.self)

    typealias Buttons = @convention(c) (AnyObject, Selector) -> Int
    let buttonsSel = #selector(getter: NSEvent.pressedMouseButtons)
    var originalButtons: Buttons?
    let buttons: @convention(block) (AnyObject) -> Int = { cls in
        ScriptState.scripting ? 0 : originalButtons!(cls, buttonsSel)
    }
    originalButtons = unsafeBitCast(replace(class_getClassMethod(NSEvent.self, buttonsSel), with: buttons), to: Buttons.self)
}()
