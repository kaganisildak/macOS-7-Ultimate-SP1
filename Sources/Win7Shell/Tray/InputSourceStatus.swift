import AppKit
import Carbon
import Win7Core

/// The current keyboard input source (Carbon TIS), observed through the
/// `com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged` distributed notification.
@MainActor
final class InputSourceStatus {
    struct Source {
        let id: String
        let name: String
        let abbreviation: String
        fileprivate let ref: TISInputSource
    }

    private(set) var abbreviation = ""
    private(set) var currentName = ""
    private(set) var currentID = ""
    var onChange: (() -> Void)?
    private var token: NSObjectProtocol?

    init() {
        read()
        token = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
    }

    private func read() {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        let s = InputSourceStatus.describe(src)
        guard s.abbreviation != abbreviation || s.id != currentID else { return }
        abbreviation = s.abbreviation
        currentName = s.name
        currentID = s.id
        onChange?()
    }

    /// The enabled, selectable keyboard layouts and input modes.
    func enabledSources() -> [Source] {
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        let types: Set<String> = [kTISTypeKeyboardLayout as String, kTISTypeKeyboardInputMode as String]
        return list.filter { InputSourceStatus.string($0, kTISPropertyInputSourceType).map(types.contains) ?? false }
            .map(InputSourceStatus.describe)
    }

    /// Switches the keyboard input source. Only ever called from the language menu.
    func select(_ source: Source) {
        TISSelectInputSource(source.ref)
    }

    private static func describe(_ src: TISInputSource) -> Source {
        let name = string(src, kTISPropertyLocalizedName) ?? ""
        var languages: [String] = []
        if let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) {
            languages = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String] ?? []
        }
        return Source(id: string(src, kTISPropertyInputSourceID) ?? name, name: name,
                      abbreviation: TrayLogic.inputSourceAbbreviation(languages: languages, fallbackName: name),
                      ref: src)
    }

    private static func string(_ src: TISInputSource, _ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}
