import AppKit
import Carbon.HIToolbox
import Win7Core

/// Global hot keys through Carbon `RegisterEventHotKey` (needs no Accessibility permission).
@MainActor
final class HotKeyCenter {
    private static var current: HotKeyCenter?
    private var handlers: [UInt32: () -> Void] = [:]
    private var releaseHandlers: [UInt32: () -> Void] = [:]
    private var refs: [(tag: String?, id: UInt32, ref: EventHotKeyRef)] = []
    private var nextID: UInt32 = 1
    private var installed = false

    init() { HotKeyCenter.current = self }

    /// `onRelease` runs when the hot key's key goes up again.
    func register(keyCode: UInt32, modifiers: UInt32, tag: String? = nil, onRelease: (() -> Void)? = nil,
                  handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x57374D43) /* 'W7MC' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("Win7Shell: RegisterEventHotKey(\(keyCode), \(modifiers)) failed: \(status)")
            return
        }
        refs.append((tag, id, ref))
        handlers[id] = handler
        releaseHandlers[id] = onRelease
    }

    func register(_ combo: KeyCombo, tag: String? = nil, onRelease: (() -> Void)? = nil, handler: @escaping () -> Void) {
        register(keyCode: combo.keyCode, modifiers: combo.modifiers.carbonFlags, tag: tag, onRelease: onRelease, handler: handler)
    }

    /// Unregisters every hot key registered with `tag`.
    func unregisterAll(tag: String) {
        for entry in refs where entry.tag == tag {
            UnregisterEventHotKey(entry.ref)
            handlers[entry.id] = nil
            releaseHandlers[entry.id] = nil
        }
        refs.removeAll { $0.tag == tag }
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard status == noErr else { return status }
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            MainActor.assumeIsolated {
                guard let center = HotKeyCenter.current else { return }
                (released ? center.releaseHandlers[hkID.id] : center.handlers[hkID.id])?()
            }
            return noErr
        }, specs.count, &specs, nil, nil)
    }
}
