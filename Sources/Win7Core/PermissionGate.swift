import Foundation

public enum Feature: Hashable, Sendable { case snap, switcher, thumbnails, windowTitles }

public struct PermissionGate: Sendable {
    public var isAXTrusted: @Sendable () -> Bool
    public var hasScreenCapture: @Sendable () -> Bool

    public init(isAXTrusted: @escaping @Sendable () -> Bool, hasScreenCapture: @escaping @Sendable () -> Bool) {
        self.isAXTrusted = isAXTrusted
        self.hasScreenCapture = hasScreenCapture
    }

    public func enabled() -> Set<Feature> {
        guard isAXTrusted() else { return [] }
        var features: Set<Feature> = [.snap, .switcher]
        if hasScreenCapture() { features.formUnion([.thumbnails, .windowTitles]) }
        return features
    }

    /// Both permissions, each read once.
    public func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(axTrusted: isAXTrusted(), screenCapture: hasScreenCapture())
    }

    /// At most one prompt per kind every 60 s when something that needs it is used.
    public static let promptInterval: TimeInterval = 60

    /// Whether the shell asks for a grant now with the system prompt
    /// (`AXIsProcessTrustedWithOptions` with the prompt option, `CGRequestScreenCaptureAccess`), which
    /// only opens System Settings: the shell never grants anything itself. `lastPromptAt`: the last
    /// prompt for that kind in this launch (nil: none yet).
    /// - `.launch`: once per launch, when any grant is missing.
    /// - `.use(kind)`: the user chose something that needs `kind` while it is missing; at most once
    ///   per `promptInterval`.
    public static func shouldPrompt(snapshot: PermissionSnapshot, lastPromptAt: Date?, now: Date,
                                    trigger: PermissionPromptTrigger) -> Bool {
        switch trigger {
        case .launch:
            return !snapshot.missing.isEmpty && lastPromptAt == nil
        case .use(let kind):
            guard !snapshot.isGranted(kind) else { return false }
            guard let last = lastPromptAt else { return true }
            return now.timeIntervalSince(last) >= promptInterval
        }
    }

    /// The shell's defaults key holding the time of the last launch prompt.
    public static let launchPromptDefaultsKey = "W7LastLaunchPromptAt"

    /// The launch prompt, also across launches: none when a grant is missing but a previous launch
    /// prompted less than `promptInterval` ago (a KeepAlive respawn loop must not prompt every
    /// respawn). A stored time in the future (a clock change) does not hold the prompt back.
    public static func shouldPromptAtLaunch(snapshot: PermissionSnapshot, previousLaunchPromptAt: Date?, now: Date) -> Bool {
        guard !snapshot.missing.isEmpty else { return false }
        guard let previous = previousLaunchPromptAt, previous <= now else { return true }
        return now.timeIntervalSince(previous) >= promptInterval
    }

    /// item 4: whether a taskbar window list asks for Screen Recording. Only a list the user
    /// opened with a click (not a hover) while previews are unavailable (no `.thumbnails`) does;
    /// `shouldPrompt` then applies the 60 s cadence.
    public static func previewTrigger(features: Set<Feature>, openedByClick: Bool) -> PermissionPromptTrigger? {
        openedByClick && !features.contains(.thumbnails) ? .use(.screenCapture) : nil
    }
}

/// The two grants the shell uses.
public enum PermissionKind: Hashable, Sendable { case accessibility, screenCapture }

/// What makes the shell consider asking for a grant.
public enum PermissionPromptTrigger: Equatable, Sendable {
    /// The shell started.
    case launch
    /// The user chose something that needs this grant (Close window, a Windows-key shortcut, a window
    /// from a taskbar list).
    case use(PermissionKind)
}

/// The permission state at one poll.
public struct PermissionSnapshot: Equatable, Sendable {
    public var axTrusted: Bool
    public var screenCapture: Bool
    public init(axTrusted: Bool, screenCapture: Bool) {
        self.axTrusted = axTrusted; self.screenCapture = screenCapture
    }

    public func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .accessibility: return axTrusted
        case .screenCapture: return screenCapture
        }
    }

    /// The grants that are missing.
    public var missing: Set<PermissionKind> {
        Set([PermissionKind.accessibility, .screenCapture].filter { !isGranted($0) })
    }

    /// What `PermissionGate.enabled()` returns for this state.
    public var features: Set<Feature> {
        PermissionGate(isAXTrusted: { [axTrusted] in axTrusted }, hasScreenCapture: { [screenCapture] in screenCapture }).enabled()
    }
}

/// Shows the permission balloon once per untrusted period; trust being granted re-arms it.
public struct BalloonPolicy: Sendable {
    private var shown = false
    public init() {}
    /// Call once per gate tick; returns true when the balloon should be presented now.
    public mutating func shouldShow(trusted: Bool) -> Bool {
        if trusted { shown = false; return false }
        if shown { return false }
        shown = true
        return true
    }
}
