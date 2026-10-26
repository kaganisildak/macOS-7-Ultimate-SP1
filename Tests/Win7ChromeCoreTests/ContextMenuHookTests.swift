import AppKit
import Testing
import Win7ChromeCore
import Win7Theme

//: every NSMenu context-menu entry point goes through W7MenuWindow, and falls back to
// AppKit's own menu whenever W7MenuWindow cannot show one.

/// Stands in for NSMenu: implements each hooked entry point itself, with NSMenu's exact encodings, and records
/// every call that reaches it (the "native" path, after the hook declined).
final class W7FakeContextMenu: NSMenu {
    nonisolated(unsafe) static var nativeCalls: [String] = []
    nonisolated(unsafe) static var completionCalls = 0
    /// The native completion variants call their block (off for blocks of another type, which must not be called).
    nonisolated(unsafe) static var callsCompletion = true
    /// Runs inside the native +popUpContextMenu:withEvent:forView: (an original calling another entry point).
    nonisolated(unsafe) static var nested: (() -> Void)?
    /// The native -_popUpContextMenu:withContext:forView:withFont: raises an Objective-C exception.
    nonisolated(unsafe) static var contextRaises = false

    override dynamic class func popUpContextMenu(_ menu: NSMenu, with event: NSEvent, for view: NSView) {
        nativeCalls.append("+popUpContextMenu:withEvent:forView:")
        nested?()
    }

    override dynamic class func popUpContextMenu(_ menu: NSMenu, with event: NSEvent, for view: NSView, with font: NSFont?) {
        nativeCalls.append("+popUpContextMenu:withEvent:forView:withFont:")
    }

    override dynamic func popUp(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool {
        W7FakeContextMenu.nativeCalls.append("-popUpMenuPositioningItem:atLocation:inView:")
        return false
    }

    @objc(popUpMenuPositioningItem:atLocation:inView:appearance:)
    dynamic func w7PopUp(_ item: NSMenuItem?, _ location: NSPoint, _ view: NSView?, _ appearance: NSAppearance?) -> Bool {
        W7FakeContextMenu.nativeCalls.append("-popUpMenuPositioningItem:atLocation:inView:appearance:")
        return false
    }

    @objc(_popUpContextMenu:withEvent:forView:withFont:)
    dynamic func w7Event(_ menu: NSMenu, _ event: NSEvent?, _ view: NSView?, _ font: NSFont?) {
        W7FakeContextMenu.nativeCalls.append("-_popUpContextMenu:withEvent:forView:withFont:")
    }

    @objc(_popUpContextMenu:withEvent:forView:withFont:completionBlock:)
    dynamic func w7EventDone(_ menu: NSMenu, _ event: NSEvent?, _ view: NSView?, _ font: NSFont?,
                     _ done: (@convention(block) () -> Void)?) {
        W7FakeContextMenu.nativeCalls.append("-_popUpContextMenu:withEvent:forView:withFont:completionBlock:")
        if W7FakeContextMenu.callsCompletion { done?() }
    }

    @objc(_popUpContextMenu:withContext:forView:withFont:)
    dynamic func w7Context(_ menu: NSMenu, _ context: AnyObject?, _ view: NSView?, _ font: NSFont?) {
        W7FakeContextMenu.nativeCalls.append("-_popUpContextMenu:withContext:forView:withFont:")
        if W7FakeContextMenu.contextRaises {
            NSException(name: .genericException, reason: "test: native menu failed", userInfo: nil).raise()
        }
    }

    @objc(_popUpContextMenu:withContext:forView:withFont:completionBlock:)
    dynamic func w7ContextDone(_ menu: NSMenu, _ context: AnyObject?, _ view: NSView?, _ font: NSFont?,
                       _ done: (@convention(block) () -> Void)?) {
        W7FakeContextMenu.nativeCalls.append("-_popUpContextMenu:withContext:forView:withFont:completionBlock:")
        if W7FakeContextMenu.callsCompletion { done?() }
    }
}

/// Implements two entry points with the wrong encodings (the font is an integer, the result an integer): never hooked.
final class W7WrongEncodingMenu: NSMenu {
    @objc(_popUpContextMenu:withEvent:forView:withFont:)
    dynamic func w7Event(_ menu: NSMenu, _ event: NSEvent?, _ view: NSView?, _ size: Int) {}

    @objc(popUpMenuPositioningItem:atLocation:inView:appearance:)
    dynamic func w7PopUp(_ item: NSMenuItem?, _ location: NSPoint, _ view: NSView?, _ appearance: NSAppearance?) -> Int { 7 }
}

@MainActor private final class Chosen: NSObject {
    var fired: [String] = []
    var onFire: (() -> Void)?
    @objc func run(_ sender: NSMenuItem) { fired.append(sender.title); onFire?() }
}

/// Asks W7MenuWindow for a second menu while the first one tracks (menuWillOpen: runs inside the loop).
@MainActor private final class NestedShowProbe: NSObject, NSMenuDelegate {
    var nestedShown: Bool?
    func menuWillOpen(_ menu: NSMenu) {
        let other = NSMenu()
        other.addItem(withTitle: "Other", action: nil, keyEquivalent: "")
        nestedShown = W7MenuWindow.show(other, topLeft: NSPoint(x: 300, y: 500), minWidth: 0)
    }
}

/// Fills its menu in menuNeedsUpdate:, as dynamic context menus do.
@MainActor private final class FillingDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.numberOfItems == 0 { menu.addItem(withTitle: "Filled", action: nil, keyEquivalent: "") }
    }
}

@MainActor private final class CountingDelegate: NSObject, NSMenuDelegate {
    func numberOfItems(in menu: NSMenu) -> Int { 1 }
}

/// Calls every entry point from inside a tracking W7 menu (menuWillOpen: runs inside its loop).
@MainActor private final class EveryEntryPointProbe: NSObject, NSMenuDelegate {
    var ran = false
    func menuWillOpen(_ menu: NSMenu) {
        ran = true
        callEveryEntryPointUnscripted { fillPlain($0) }
    }
}

/// Records the widest W7 menu window that exists when its menu opens.
@MainActor private final class WidthProbe: NSObject, NSMenuDelegate {
    var width: CGFloat?
    func menuWillOpen(_ menu: NSMenu) {
        width = NSApp.windows.compactMap { $0 as? W7MenuWindow }.map(\.frame.width).max()
    }
}

/// A menu action that calls an entry point whose original raises.
@MainActor private final class ThrowingAction: NSObject {
    var ran = false
    @objc func run(_ sender: NSMenuItem) {
        ran = true
        W7FakeContextMenu().w7Context(customViewMenu(), nil, nil, nil)
    }
}

/// Records the view side of AppKit's context-menu protocol.
@MainActor private final class MenuCallbackView: NSView {
    var calls: [String] = []
    var events: [NSEvent.EventType] = []
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) { calls.append("willOpen"); events.append(event.type) }
    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) { calls.append("didClose") }
}

/// Handles (and validates) an action for nil-target items, up the clicked view's responder chain.
@MainActor private final class ResponderView: NSView, NSMenuItemValidation {
    var renamed = 0
    var allow = true
    @objc func w7Rename(_ sender: Any?) { renamed += 1 }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { allow }
}

/// A block with no signature (flags without BLOCK_HAS_SIGNATURE), as old compilers emitted: global, never called.
nonisolated(unsafe) private let signaturelessBlock: AnyObject = {
    struct Descriptor { var reserved: UInt; var size: UInt }
    struct Literal {
        var isa: UnsafeMutableRawPointer?
        var flags: Int32
        var reserved: Int32
        var invoke: @convention(c) (UnsafeMutableRawPointer?) -> Void
        var descriptor: UnsafeMutablePointer<Descriptor>
    }
    let descriptor = UnsafeMutablePointer<Descriptor>.allocate(capacity: 1)
    descriptor.initialize(to: Descriptor(reserved: 0, size: UInt(MemoryLayout<Literal>.size)))
    let literal = UnsafeMutablePointer<Literal>.allocate(capacity: 1)
    literal.initialize(to: Literal(isa: dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_NSConcreteGlobalBlock"),
                                   flags: 1 << 28, reserved: 0, invoke: { _ in }, descriptor: descriptor))
    return Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(literal)).takeUnretainedValue()
}()

@MainActor @discardableResult
private func fillPlain(_ m: NSMenu, _ titles: [String] = ["Open", "Delete"], target: Chosen? = nil) -> NSMenu {
    m.autoenablesItems = false
    for t in titles {
        let item = m.addItem(withTitle: t, action: target == nil ? nil : #selector(Chosen.run(_:)), keyEquivalent: "")
        item.target = target
    }
    return m
}

@MainActor @discardableResult private func addCustomView(_ m: NSMenu) -> NSMenu {
    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    item.view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 30))
    m.addItem(item)
    return m
}

@MainActor private func plainMenu(_ titles: [String] = ["Open", "Delete"], target: Chosen? = nil) -> NSMenu {
    fillPlain(NSMenu(), titles, target: target)
}

@MainActor private func customViewMenu() -> NSMenu { addCustomView(plainMenu()) }

@MainActor private func rightClick() -> NSEvent {
    NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 200, y: 600), modifierFlags: [], timestamp: 0,
                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}

private let esc = { @MainActor in ScriptedMenuInput.key("\u{1b}", 53) }
private let down = { @MainActor in ScriptedMenuInput.key(String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), 125) }
private let enter = { @MainActor in ScriptedMenuInput.key("\r", 36) }

/// Calls every hooked entry point of W7FakeContextMenu with a menu built by `fill`; the positioning entry points
/// draw their receiver, a fake built by `fill` too. An empty script: a W7 menu that appears by mistake still ends
/// (with an issue recorded) instead of waiting for real input.
@MainActor private func callEveryEntryPoint(_ fill: (NSMenu) -> Void) {
    ScriptedMenuInput.run([]) { callEveryEntryPointUnscripted(fill) }
}

@MainActor private func callEveryEntryPointUnscripted(_ fill: (NSMenu) -> Void) {
    let menu = NSMenu(); fill(menu)
    let fake = W7FakeContextMenu(); fill(fake)
    let view = NSView(frame: .zero)
    W7FakeContextMenu.popUpContextMenu(menu, with: rightClick(), for: view)
    W7FakeContextMenu.popUpContextMenu(menu, with: rightClick(), for: view, with: nil)
    _ = fake.popUp(positioning: nil, at: NSPoint(x: 200, y: 600), in: nil)
    _ = fake.w7PopUp(nil, NSPoint(x: 200, y: 600), nil, nil)
    fake.w7Event(menu, rightClick(), view, nil)
    fake.w7EventDone(menu, rightClick(), view, nil) { W7FakeContextMenu.completionCalls += 1 }
    fake.w7Context(menu, nil, view, nil)
    fake.w7ContextDone(menu, nil, view, nil) { W7FakeContextMenu.completionCalls += 1 }
}

private let everyEntryPoint = [
    "+popUpContextMenu:withEvent:forView:",
    "+popUpContextMenu:withEvent:forView:withFont:",
    "-popUpMenuPositioningItem:atLocation:inView:",
    "-popUpMenuPositioningItem:atLocation:inView:appearance:",
    "-_popUpContextMenu:withEvent:forView:withFont:",
    "-_popUpContextMenu:withEvent:forView:withFont:completionBlock:",
    "-_popUpContextMenu:withContext:forView:withFont:",
    "-_popUpContextMenu:withContext:forView:withFont:completionBlock:",
]

// MARK: - Pure decisions

@MainActor @Test func contextMenuInterceptTable() {
    _ = NSApplication.shared
    let menu = plainMenu()
    #expect(W7ContextMenuShouldIntercept(menu, false, true, false))
    #expect(!W7ContextMenuShouldIntercept(nil, false, true, false))
    #expect(!W7ContextMenuShouldIntercept(menu, true, true, false), "another W7 menu is tracking")
    #expect(!W7ContextMenuShouldIntercept(menu, false, false, false), "off the main thread")
    #expect(!W7ContextMenuShouldIntercept(menu, false, true, true), "W7ContextMenusDisabled")
    #expect(!W7ContextMenuShouldIntercept(NSMenu(), false, true, false), "empty")
    let onlyHidden = plainMenu(["Hidden"]); onlyHidden.items[0].isHidden = true
    onlyHidden.addItem(.separator())
    #expect(!W7ContextMenuShouldIntercept(onlyHidden, false, true, false), "no visible item")
    #expect(!W7ContextMenuShouldIntercept(customViewMenu(), false, true, false), "custom view item")

    // A custom view inside a submenu counts too: W7MenuWindow would draw the submenu.
    let parent = plainMenu()
    parent.items[0].submenu = customViewMenu()
    #expect(!W7ContextMenuShouldIntercept(parent, false, true, false))

    // A menu filled by menuNeedsUpdate: may be empty until W7MenuWindow updates it; one driven by
    // numberOfItemsInMenu: is left to AppKit, which runs that protocol.
    let dynamic = NSMenu(); let filler = FillingDelegate(); dynamic.delegate = filler
    #expect(W7ContextMenuShouldIntercept(dynamic, false, true, false))
    let counted = plainMenu(); let counter = CountingDelegate(); counted.delegate = counter
    #expect(!W7ContextMenuShouldIntercept(counted, false, true, false))
    withExtendedLifetime((filler, counter)) {}
}

@MainActor @Test func customViewItemDetection() {
    #expect(!W7MenuHasCustomViewItem(plainMenu()))
    #expect(W7MenuHasCustomViewItem(customViewMenu()))
    let hidden = customViewMenu(); hidden.items.last!.isHidden = true
    #expect(!W7MenuHasCustomViewItem(hidden), "a hidden view item is drawn by nobody")
}

@Test func contextMenusKillSwitchOverride() {
    W7ContextMenusUseDisabledOverride(1)
    #expect(W7ContextMenusDisabled())
    W7ContextMenusUseDisabledOverride(0)
    #expect(!W7ContextMenusDisabled())
    W7ContextMenusUseDisabledOverride(-1)
}

@Test func blockTypeEncoding() {
    let plain: @convention(block) () -> Void = {}
    #expect(W7BlockTypeEncoding(plain as AnyObject) == "v8@?0")
    let withArg: @convention(block) (Bool) -> Void = { _ in }
    #expect(W7BlockTypeEncoding(withArg as AnyObject) != "v8@?0")
    // Read through _Block_signature: a capturing (heap) block, an object argument, and a block without a signature.
    var count = 0
    let capturing: @convention(block) () -> Void = { count += 1 }
    #expect(W7BlockTypeEncoding(capturing as AnyObject) == "v8@?0")
    let objectArg: @convention(block) (AnyObject?) -> Void = { _ in }
    #expect(W7BlockTypeEncoding(objectArg as AnyObject) == "v16@?0@8")
    #expect(W7BlockTypeEncoding(signaturelessBlock) == nil)
    _ = count
    #expect(W7BlockTypeEncoding(nil) == nil)
    #expect(W7BlockTypeEncoding(NSObject()) == nil)
}

// MARK: - The entry points on this macOS

@Test func nsMenuEntryPointsMatchTheHookTable() {
    // The public ones are part of the SDK; their encodings are fixed.
    let meta: AnyClass = object_getClass(NSMenu.self)!
    #expect(W7ContextMenuOwnsExactMethod(meta, NSSelectorFromString("popUpContextMenu:withEvent:forView:"), "v40@0:8@16@24@32"))
    #expect(W7ContextMenuOwnsExactMethod(NSMenu.self, NSSelectorFromString("popUpMenuPositioningItem:atLocation:inView:"),
                                         "B48@0:8@16{CGPoint=dd}24@40"))
    #expect(!W7ContextMenuOwnsExactMethod(NSMenu.self, NSSelectorFromString("popUpMenuPositioningItem:atLocation:inView:"),
                                          "c48@0:8@16{CGPoint=dd}24@40"), "a different encoding is not the method")
    // Inherited is not owned: W7FakeContextMenu doesn't implement -_popUpMenuWithEvent:forView: itself.
    #expect(!W7ContextMenuOwnsExactMethod(W7FakeContextMenu.self, NSSelectorFromString("_popUpMenuWithEvent:forView:"),
                                          "v32@0:8@16@24"))
    // The hook table names the entry points the right-click and popUp paths of this macOS go through.
    let table = W7ContextMenuEntryPoints()
    #expect(table.count == everyEntryPoint.count)
    for e in everyEntryPoint { #expect(table.contains { $0.hasPrefix(e + " ") }, "\(e)") }
    // The verbose dump lists NSMenu's popUp/contextMenu selectors with their encodings.
    let dump = W7ContextMenuSelectorDump(NSMenu.self)
    #expect(dump.contains("-popUpMenuPositioningItem:atLocation:inView: B48@0:8@16{CGPoint=dd}24@40"))
    #expect(dump.contains("+popUpContextMenu:withEvent:forView: v40@0:8@16@24@32"))
    #expect(!dump.contains { $0.lowercased().range(of: "popup") == nil && $0.lowercased().range(of: "contextmenu") == nil })
}

@MainActor @Test func menuWindowFontIsTwelvePointUIFont() {
    let font = W7MenuWindowFont()
    #expect(font.pointSize == 12)
    #expect(font.fontName == W7UIFont(12).fontName)
    let family = font.familyName ?? ""
    #expect(family == "Segoe UI" || family == NSFont.systemFont(ofSize: 12).familyName)
}

// MARK: - Hooks and their fallbacks (one suite: W7MenuWindow refuses to nest, and scripted input is global)

@MainActor @Suite(.serialized) struct ContextMenuHookTests {
    init() {
        _ = NSApplication.shared
        _ = W7InstallContextMenuHooksOnClass(W7FakeContextMenu.self)
        W7FakeContextMenu.nativeCalls = []
        W7FakeContextMenu.completionCalls = 0
    }

    @Test func hooksOnlyExactOwnEncodings() {
        let wrong = W7WrongEncodingMenu.self
        let sel = NSSelectorFromString("_popUpContextMenu:withEvent:forView:withFont:")
        let before = class_getMethodImplementation(wrong, sel)
        let report = W7InstallContextMenuHooksOnClass(wrong)
        #expect(class_getMethodImplementation(wrong, sel) == before, "wrong encoding: not hooked")
        #expect(report.contains { $0.hasPrefix("-_popUpContextMenu:withEvent:forView:withFont:: types v48@0:8@16@24@32q40") })
        #expect(report.contains { $0.hasPrefix("-popUpMenuPositioningItem:atLocation:inView:appearance:: types q56") })
        #expect(report.contains("+popUpContextMenu:withEvent:forView:: not found"), "inherited from NSMenu, not its own")
        #expect(!report.contains { $0.hasSuffix(": hooked") })
        #expect(W7WrongEncodingMenu().w7PopUp(nil, .zero, nil, nil) == 7)

        // The fake implements every entry point with the exact encodings: all hooked, once.
        let again = W7InstallContextMenuHooksOnClass(W7FakeContextMenu.self)
        #expect(again.count == everyEntryPoint.count)
        #expect(again.allSatisfy { $0.hasSuffix(": already hooked") }, "\(again)")
    }

    @Test func customViewMenuFallsBackAtEveryEntryPoint() {
        // The positioning entry points' receiver has the custom-view item too, so they fall back for that reason
        // (not because the receiver is empty).
        callEveryEntryPoint { fillPlain($0); addCustomView($0) }
        #expect(W7FakeContextMenu.nativeCalls == everyEntryPoint)
        #expect(W7MenuWindow.isTracking() == false)
        #expect(NSApp.windows.allSatisfy { !($0 is W7MenuWindow) || !$0.isVisible })
    }

    @Test func emptyMenuFallsBackAtEveryEntryPoint() {
        callEveryEntryPoint { _ in }
        #expect(W7FakeContextMenu.nativeCalls == everyEntryPoint)
    }

    @Test func killSwitchFallsBackAtEveryEntryPoint() {
        W7ContextMenusUseDisabledOverride(1)
        defer { W7ContextMenusUseDisabledOverride(-1) }
        callEveryEntryPoint { fillPlain($0) }
        #expect(W7FakeContextMenu.nativeCalls == everyEntryPoint)
    }

    @Test func modalSessionFallsBackAtEveryEntryPoint() {
        let panel = NSPanel(contentRect: NSRect(x: -9000, y: -9000, width: 200, height: 100), styleMask: [.titled],
                            backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        let session = NSApp.beginModalSession(for: panel)
        callEveryEntryPoint { fillPlain($0) }
        NSApp.endModalSession(session)
        panel.orderOut(nil)
        #expect(W7FakeContextMenu.nativeCalls == everyEntryPoint)
    }

    @Test func anotherW7MenuTrackingFallsBackAtEveryEntryPoint() {
        let probe = EveryEntryPointProbe()
        let menu = plainMenu()
        menu.delegate = probe
        #expect(ScriptedMenuInput.run([esc()]) { W7MenuWindow.show(menu, topLeft: NSPoint(x: 200, y: 600), minWidth: 0) })
        #expect(probe.ran)
        #expect(W7FakeContextMenu.nativeCalls == everyEntryPoint)
        withExtendedLifetime(probe) {}
    }

    @Test func completionBlocksStillRunOnTheNativePath() {
        callEveryEntryPoint { _ in }
        #expect(W7FakeContextMenu.completionCalls == 2)
    }

    @Test func passThroughSendsTheEntryPointsAnOriginalCallsToAppKit() {
        // The outer call is declined (custom view); its original calls another hooked entry point with a menu
        // W7MenuWindow could draw, which must go to AppKit as well.
        W7FakeContextMenu.nested = { W7FakeContextMenu().w7Event(plainMenu(), rightClick(), nil, nil) }
        defer { W7FakeContextMenu.nested = nil }
        ScriptedMenuInput.run([]) {
            W7FakeContextMenu.popUpContextMenu(customViewMenu(), with: rightClick(), for: NSView(frame: .zero))
        }
        #expect(W7FakeContextMenu.nativeCalls == ["+popUpContextMenu:withEvent:forView:",
                                                  "-_popUpContextMenu:withEvent:forView:withFont:"])
        // Once the original returned, the count is back to 0: the same inner call is drawn by W7MenuWindow.
        ScriptedMenuInput.run([esc()]) { W7FakeContextMenu().w7Event(plainMenu(), rightClick(), nil, nil) }
        #expect(W7FakeContextMenu.nativeCalls.count == 2)
    }

    @Test func passThroughCountIsResetWhenTheOriginalThrows() {
        // A W7 menu's action calls an entry point that is declined (custom view) and whose original raises; the
        // exception passes the hook (its @finally) and is caught by W7MenuWindow around the action.
        W7FakeContextMenu.contextRaises = true
        defer { W7FakeContextMenu.contextRaises = false }
        let thrower = ThrowingAction()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "Throw", action: #selector(ThrowingAction.run(_:)), keyEquivalent: "").target = thrower
        ScriptedMenuInput.run([down(), enter()]) { W7FakeContextMenu().w7Event(menu, rightClick(), nil, nil) }
        #expect(thrower.ran)
        #expect(W7FakeContextMenu.nativeCalls == ["-_popUpContextMenu:withContext:forView:withFont:"])
        W7FakeContextMenu.contextRaises = false
        // The count went back to 0: a drawable menu at any entry point is drawn, not passed through.
        ScriptedMenuInput.run([esc()]) { W7FakeContextMenu().w7Event(plainMenu(), rightClick(), nil, nil) }
        ScriptedMenuInput.run([esc()]) { W7FakeContextMenu().w7Context(plainMenu(), nil, nil, nil) }
        #expect(W7FakeContextMenu.nativeCalls.count == 1)
    }

    @Test func completionBlocksOfAnotherTypeGoToAppKit() {
        W7FakeContextMenu.callsCompletion = false
        defer { W7FakeContextMenu.callsCompletion = true }
        let withArgument: @convention(block) (AnyObject?) -> Void = { _ in }
        #expect(W7BlockTypeEncoding(withArgument as AnyObject) == "v16@?0@8")
        #expect(W7BlockTypeEncoding(signaturelessBlock) == nil)
        for block in [withArgument as AnyObject, signaturelessBlock] {
            let typed = unsafeBitCast(block, to: (@convention(block) () -> Void).self)
            ScriptedMenuInput.run([]) {
                W7FakeContextMenu().w7EventDone(plainMenu(), rightClick(), nil, nil, typed)
                W7FakeContextMenu().w7ContextDone(plainMenu(), nil, nil, nil, typed)
            }
        }
        let pair = ["-_popUpContextMenu:withEvent:forView:withFont:completionBlock:",
                    "-_popUpContextMenu:withContext:forView:withFont:completionBlock:"]
        #expect(W7FakeContextMenu.nativeCalls == pair + pair)
    }

    @Test func w7PathCallsTheViewAndPostsTrackingNotifications() {
        let view = MenuCallbackView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let log = Chosen()
        let menu = plainMenu(target: log)
        let fake = fillPlain(W7FakeContextMenu())
        let center = NotificationCenter.default
        var observers: [NSObjectProtocol] = []
        for watched in [menu, fake] {
            for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
                observers.append(center.addObserver(forName: name, object: watched, queue: nil) { n in
                    let tag = n.name == NSMenu.didBeginTrackingNotification ? "begin" : "end"
                    MainActor.assumeIsolated { view.calls.append(tag) }
                })
            }
        }
        defer { observers.forEach(center.removeObserver) }
        log.onFire = { view.calls.append("action") }

        ScriptedMenuInput.run([esc()]) { W7FakeContextMenu.popUpContextMenu(menu, with: rightClick(), for: view) }
        #expect(view.calls == ["willOpen", "begin", "end", "didClose"])
        #expect(view.events == [.rightMouseDown])

        // The action runs before the view hears the menu closed (a table's clicked row is still set for it).
        view.calls = []
        ScriptedMenuInput.run([down(), enter()]) { W7FakeContextMenu().w7Event(menu, rightClick(), view, nil) }
        #expect(view.calls == ["willOpen", "begin", "action", "end", "didClose"])

        // A positioning call has no view to tell: only the notifications.
        view.calls = []
        _ = ScriptedMenuInput.run([esc()]) { fake.popUp(positioning: nil, at: NSPoint(x: 200, y: 600), in: nil) }
        #expect(view.calls == ["begin", "end"])

        // The native path leaves both to AppKit.
        view.calls = []
        ScriptedMenuInput.run([]) { W7FakeContextMenu.popUpContextMenu(customViewMenu(), with: rightClick(), for: view) }
        #expect(view.calls.isEmpty)
        #expect(W7FakeContextMenu.nativeCalls == ["+popUpContextMenu:withEvent:forView:"])
    }

    @Test func nilTargetItemsResolveThroughTheClickedViewsResponderChain() {
        let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 300, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let parent = ResponderView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let clicked = NSView(frame: NSRect(x: 10, y: 10, width: 50, height: 50))
        parent.addSubview(clicked)
        window.contentView = parent
        let menu = NSMenu()   // autoenablesItems: AppKit validates through the key window, which this isn't
        let item = menu.addItem(withTitle: "Rename", action: #selector(ResponderView.w7Rename(_:)), keyEquivalent: "")

        #expect(W7ContextMenuItemTarget(item, clicked) as AnyObject? === parent)
        #expect(W7ContextMenuItemTarget(item, nil) == nil, "no view: AppKit's own resolution")
        item.target = clicked
        #expect(W7ContextMenuItemTarget(item, clicked) == nil, "an item with a target keeps it")
        item.target = nil

        #expect(W7MenuNodes(menu).first?.enabled == false, "the key window's chain has no target")
        #expect(W7MenuNodesForView(menu, clicked).first?.enabled == true, "validated by the clicked view's chain")
        parent.allow = false
        #expect(W7MenuNodesForView(menu, clicked).first?.enabled == false, "validateMenuItem: says no")
        parent.allow = true

        ScriptedMenuInput.run([down(), enter()]) { W7FakeContextMenu.popUpContextMenu(menu, with: rightClick(), for: clicked) }
        #expect(parent.renamed == 1, "sent to the clicked view's chain")
        #expect(item.target == nil, "the item's own target is left as it was")
        #expect(W7FakeContextMenu.nativeCalls.isEmpty)
        window.close()
    }

    @Test func menuMinimumWidthIsHonoured() {
        let probe = WidthProbe()
        let menu = plainMenu()
        menu.minimumWidth = 420
        menu.delegate = probe
        ScriptedMenuInput.run([esc()]) { W7FakeContextMenu.popUpContextMenu(menu, with: rightClick(), for: NSView(frame: .zero)) }
        #expect(W7FakeContextMenu.nativeCalls.isEmpty)
        #expect((probe.width ?? 0) >= 420)
        withExtendedLifetime(probe) {}
    }

    @Test func keyboardContextMenusOpenAtTheView() {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 10, y: 20, width: 50, height: 40))
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView!.addSubview(view)
        let key = ScriptedMenuInput.key("\r", 36)
        // Not a mouse event, a view in a window: the view's top-left corner (its selection when it has one).
        #expect(W7ContextMenuAnchorPoint(key, view) == NSPoint(x: 110, y: 160))
        // No view (or one without a window), or a context object instead of an event: the pointer.
        let pointer = NSEvent.mouseLocation
        #expect(W7ContextMenuAnchorPoint(key, nil) == pointer)
        #expect(W7ContextMenuAnchorPoint(key, NSView(frame: .zero)) == pointer)
        #expect(W7ContextMenuAnchorPoint(nil, view) == pointer)
        window.close()
    }

    @Test func eventEntryPointDrawsAW7Menu() {
        let log = Chosen()
        let menu = plainMenu(target: log)
        ScriptedMenuInput.run([down(), enter()]) {
            W7FakeContextMenu.popUpContextMenu(menu, with: rightClick(), for: NSView(frame: .zero))
        }
        #expect(W7FakeContextMenu.nativeCalls.isEmpty)
        #expect(log.fired == ["Open"])
        ScriptedMenuInput.run([esc()]) { W7FakeContextMenu().w7Event(menu, rightClick(), nil, nil) }
        #expect(W7FakeContextMenu.nativeCalls.isEmpty)
    }

    @Test func positioningEntryPointReturnsWhetherAnItemWasChosen() {
        let log = Chosen()
        let fake = W7FakeContextMenu()
        fake.autoenablesItems = false
        let item = fake.addItem(withTitle: "Paste", action: #selector(Chosen.run(_:)), keyEquivalent: "")
        item.target = log
        let chose = ScriptedMenuInput.run([down(), enter()]) { fake.popUp(positioning: nil, at: NSPoint(x: 200, y: 600), in: nil) }
        #expect(chose)
        #expect(log.fired == ["Paste"])
        let dismissed = ScriptedMenuInput.run([esc()]) { fake.w7PopUp(nil, NSPoint(x: 200, y: 600), nil, nil) }
        #expect(!dismissed)
        #expect(W7FakeContextMenu.nativeCalls.isEmpty)
        // A positioning item asks for popup-button placement, which W7MenuWindow doesn't do: native.
        _ = fake.popUp(positioning: item, at: .zero, in: nil)
        #expect(W7FakeContextMenu.nativeCalls == ["-popUpMenuPositioningItem:atLocation:inView:"])
    }

    @Test func completionEntryPointRunsTheBlockAfterTheW7Menu() async {
        let menu = plainMenu()
        let order = Chosen()   // its `fired` list records the order
        ScriptedMenuInput.run([esc()]) {
            W7FakeContextMenu().w7EventDone(menu, rightClick(), nil, nil) { order.fired.append("completion") }
            order.fired.append("returned")
        }
        #expect(W7FakeContextMenu.nativeCalls.isEmpty)
        // The completion comes after the call returned, as AppKit's asynchronous menu calls it.
        for _ in 0..<100 where order.fired.count < 2 { try? await Task.sleep(nanoseconds: 2_000_000) }
        #expect(order.fired == ["returned", "completion"])
    }

    @Test func showMenuRefusesCustomViewAndNestedMenus() {
        #expect(!W7MenuWindow.show(customViewMenu(), topLeft: NSPoint(x: 200, y: 600), minWidth: 0))
        let probe = NestedShowProbe()
        let menu = plainMenu()
        menu.delegate = probe
        #expect(ScriptedMenuInput.run([esc()]) { W7MenuWindow.show(menu, topLeft: NSPoint(x: 200, y: 600), minWidth: 0) })
        #expect(probe.nestedShown == false, "another W7 menu is tracking")
        withExtendedLifetime(probe) {}
    }

    @Test func showMenuRefusesDuringAModalSession() {
        let panel = NSPanel(contentRect: NSRect(x: -9000, y: -9000, width: 200, height: 100), styleMask: [.titled],
                            backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        let session = NSApp.beginModalSession(for: panel)
        let shown = W7MenuWindow.show(plainMenu(), topLeft: NSPoint(x: 200, y: 600), minWidth: 0)
        NSApp.endModalSession(session)
        panel.orderOut(nil)
        #expect(!shown)
    }

    @Test func dynamicMenuFilledByItsDelegateIsDrawn() {
        let menu = NSMenu()
        let filler = FillingDelegate()
        menu.delegate = filler
        ScriptedMenuInput.run([esc()]) { W7FakeContextMenu.popUpContextMenu(menu, with: rightClick(), for: NSView(frame: .zero)) }
        #expect(W7FakeContextMenu.nativeCalls.isEmpty)
        withExtendedLifetime(filler) {}
    }
}
