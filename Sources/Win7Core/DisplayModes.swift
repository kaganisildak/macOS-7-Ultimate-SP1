import CoreGraphics
import Foundation

// The Screen Resolution window's decisions. The modes come from a `DisplayConfiguring` — in the shell
// the public CoreGraphics configuration API (CoreGraphicsDisplays), in the tests a fake — so nothing here ever
// changes a display by itself, and no test or build ever does.

/// One display mode as CoreGraphics reports it (CGDisplayCopyAllDisplayModes with
/// kCGDisplayShowDuplicateLowResolutionModes). `width`/`height` are points (what the desktop gets); `scaled` is a
/// HiDPI mode (more pixels than points).
public struct DisplayModeInfo: Hashable, Sendable {
    /// `CGDisplayModeGetIODisplayModeID`.
    public var id: Int32
    public var width: Int
    public var height: Int
    public var scaled: Bool
    public var refresh: Double
    /// IOKit's native flag (`kDisplayModeNativeFlag`): the panel's own resolution.
    public var isNative: Bool
    /// IOKit's default flag (`kDisplayModeDefaultFlag`): the mode macOS itself recommends ("Default").
    public var isDefault: Bool
    /// `CGDisplayModeIsUsableForDesktopGUI`.
    public var usableForDesktop: Bool
    /// `CGDisplayModeGetPixelWidth` / `…PixelHeight` (0 when unknown): told apart when two modes share id and size.
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(id: Int32, width: Int, height: Int, scaled: Bool, refresh: Double, isNative: Bool, isDefault: Bool,
                usableForDesktop: Bool, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.id = id
        self.width = width
        self.height = height
        self.scaled = scaled
        self.refresh = refresh
        self.isNative = isNative
        self.isDefault = isDefault
        self.usableForDesktop = usableForDesktop
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// The same mode: id, size and scale (a HiDPI mode and its 1× duplicate may share an id). Refresh and flags
    /// are left out, so the current mode CoreGraphics reports matches its row in the list.
    public func isSameMode(as other: DisplayModeInfo) -> Bool {
        id == other.id && width == other.width && height == other.height && scaled == other.scaled
    }

    /// The very same mode: `isSameMode`, and the same refresh rate and pixel size.
    public func isExactly(_ other: DisplayModeInfo) -> Bool {
        isSameMode(as: other) && hasSameRefresh(as: other, tolerance: 0.01)
            && pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight
    }

    /// Refresh rates within `tolerance` Hz (CoreGraphics reports e.g. 59.94 and 60 for one panel's modes).
    public func hasSameRefresh(as other: DisplayModeInfo, tolerance: Double = 0.5) -> Bool {
        abs(refresh - other.refresh) < tolerance
    }
}

/// How long a display change lasts (`CGConfigureOption`).
public enum DisplayChangeScope: Equatable, Sendable {
    /// `.forAppOnly`: macOS undoes it when the shell exits for any reason, a crash included — a mode on trial.
    case untilQuit
    /// `.permanently`: the stored display preference, kept across logouts and restarts.
    case permanent
}

/// A row of the Resolution list: the mode that stands for one size, and its Windows 7 title
/// ("1920 × 1080 (recommended)").
public struct DisplayModeEntry: Hashable, Sendable {
    public var mode: DisplayModeInfo
    public var isCurrent: Bool
    public var isRecommended: Bool
    /// A 1× mode whose size is also offered as a HiDPI mode (macOS's "low resolution" duplicate).
    public var isLowResolution: Bool

    public var title: String {
        var t = "\(mode.width) × \(mode.height)"
        if isRecommended { t += " (recommended)" }
        if isLowResolution { t += " (low resolution)" }
        return t
    }
}

/// Why a display change failed, for the log (the window shows only `DisplayModes.applyErrorText`).
public struct DisplayConfigurationError: Error, Equatable, CustomStringConvertible, Sendable {
    public enum Stage: String, Sendable { case modeNotFound = "mode lookup", begin, configure, complete }
    public var stage: Stage
    /// The `CGError` raw value (0 for a mode that was not found).
    public var code: Int32

    public init(stage: Stage, code: Int32) {
        self.stage = stage
        self.code = code
    }

    public var description: String { "\(stage.rawValue) failed (CGError \(code))" }
}

/// Where display modes come from and go to. The shell's conformer is the only code that changes a display, through
/// CGBeginDisplayConfiguration / CGConfigureDisplayWithDisplayMode / CGCompleteDisplayConfiguration; tests use a fake.
public protocol DisplayConfiguring: AnyObject {
    func modes(for display: CGDirectDisplayID) -> [DisplayModeInfo]
    func currentMode(for display: CGDirectDisplayID) -> DisplayModeInfo?
    /// Switches `display` to `mode` (looked up again with `DisplayModes.match`) for `scope`; throws
    /// `DisplayConfigurationError` on any failure.
    func setMode(_ mode: DisplayModeInfo, for display: CGDirectDisplayID, scope: DisplayChangeScope) throws
    /// Makes `display`'s current mode (applied `.untilQuit`) the stored one: begin, configure with the current mode,
    /// complete `.permanently`. Throws `DisplayConfigurationError`.
    func persist(display: CGDirectDisplayID) throws
}

public enum DisplayApplyResult: Equatable, Sendable {
    /// The mode is already the display's.
    case unchanged
    /// The display now runs the mode; `previous` is the mode to go back to.
    case applied(previous: DisplayModeInfo)
    /// Nothing changed; `message` is the Windows 7 text to show.
    case failed(message: String)
}

/// What the end of a "Keep changes?" countdown did to the display.
public enum KeepChangesOutcome: Equatable, Sendable {
    /// Keep changes: the mode is now the stored one.
    case kept
    /// Keep changes, but storing the mode failed: it lasts until the shell quits.
    case keptUntilQuit
    /// Revert, Esc, closing, or the countdown ran out: the previous mode is back.
    case reverted
    /// The previous mode could not be put back; `message` is the Windows 7 text.
    case revertFailed(message: String)
}

public enum DisplayModes {
    /// Windows 7's text when a mode cannot be set.
    public static let applyErrorText = "The display settings could not be applied."

    /// The Resolution list. Modes macOS doesn't offer for the desktop are left out (the current one always stays);
    /// one entry per width × height × HiDPI, the mode standing for it being the current one, else the default-
    /// flagged, else the native-flagged, else the highest refresh rate (then the lowest id). Sorted largest first:
    /// width, then height, a HiDPI mode before the 1× mode of the same size, which is then marked "(low resolution)".
    /// Within a size a mode at the current refresh rate comes right after the current mode, so choosing another size
    /// doesn't also change the refresh rate (ProMotion at 120 Hz stays at 120 Hz).
    /// "(recommended)" goes on exactly one size: the one with a default-flagged mode, else a native-flagged one (the
    /// largest such), else the largest size; when that is a 1× size with a HiDPI twin, the twin carries it, so no row
    /// is both "(recommended)" and "(low resolution)".
    public static func list(_ modes: [DisplayModeInfo], current: DisplayModeInfo?) -> [DisplayModeEntry] {
        struct Key: Hashable { var width: Int, height: Int, scaled: Bool }
        func isCurrent(_ m: DisplayModeInfo) -> Bool { current.map(m.isSameMode) ?? false }
        var groups: [Key: [DisplayModeInfo]] = [:]
        for m in modes where m.usableForDesktop || isCurrent(m) {
            groups[Key(width: m.width, height: m.height, scaled: m.scaled), default: []].append(m)
        }
        func sameRefresh(_ m: DisplayModeInfo) -> Bool { current.map { m.hasSameRefresh(as: $0) } ?? false }
        func rank(_ m: DisplayModeInfo) -> (Int, Int, Int, Int, Double, Int32) {
            (isCurrent(m) ? 0 : 1, sameRefresh(m) ? 0 : 1, m.isDefault ? 0 : 1, m.isNative ? 0 : 1, -m.refresh, m.id)
        }
        let keys = groups.keys.sorted {
            ($0.width, $0.height, $0.scaled ? 1 : 0) > ($1.width, $1.height, $1.scaled ? 1 : 0)
        }
        var recommended = keys.first { groups[$0]!.contains(where: \.isDefault) }
            ?? keys.first { groups[$0]!.contains(where: \.isNative) }
            ?? keys.first
        if let r = recommended, !r.scaled, groups[Key(width: r.width, height: r.height, scaled: true)] != nil {
            recommended = Key(width: r.width, height: r.height, scaled: true)
        }
        return keys.map { key in
            let best = groups[key]!.min { rank($0) < rank($1) }!
            let lowRes = !key.scaled && groups[Key(width: key.width, height: key.height, scaled: true)] != nil
            return DisplayModeEntry(mode: best, isCurrent: isCurrent(best), isRecommended: key == recommended,
                                    isLowResolution: lowRes)
        }
    }

    /// The Resolution list for `display` as `config` reports it now.
    public static func list(for display: CGDirectDisplayID, using config: DisplayConfiguring) -> [DisplayModeEntry] {
        list(config.modes(for: display), current: config.currentMode(for: display))
    }

    /// Of `candidates`, the index of `mode`: the exact one (same id, size, scale, refresh and pixel size) if there
    /// is one, else the first with the same id, size and scale; nil when none.
    public static func match(_ mode: DisplayModeInfo, in candidates: [DisplayModeInfo]) -> Int? {
        candidates.firstIndex(where: mode.isExactly) ?? candidates.firstIndex(where: mode.isSameMode)
    }

    /// Switches `display` to `mode` on trial: `.untilQuit`, so the shell quitting or crashing during the countdown
    /// puts the stored mode back on its own (`finish` stores it on Keep changes). A mode the display no longer
    /// offers, or a display whose current mode is unknown (nothing to revert to), is refused before anything is
    /// configured. After a configuration error the display is read again: if it did switch (a failed complete
    /// step), the change is reported as applied so the countdown still guards it; otherwise the old mode stays.
    /// Failures carry `applyErrorText`.
    public static func apply(_ mode: DisplayModeInfo, to display: CGDirectDisplayID, using config: DisplayConfiguring) -> DisplayApplyResult {
        change(to: mode, on: display, scope: .untilQuit, using: config)
    }

    /// Goes back to `previous` (the "Keep changes?" countdown ran out, Revert, Esc, or the dialog closed),
    /// `.permanent`, which re-asserts the stored mode.
    public static func revert(to previous: DisplayModeInfo, on display: CGDirectDisplayID, using config: DisplayConfiguring) -> DisplayApplyResult {
        change(to: previous, on: display, scope: .permanent, using: config)
    }

    /// Ends a "Keep changes?" countdown on the display: Keep changes stores the trial mode (`persist`); a revert
    /// (Revert, Esc, closing, running out) puts `previous` back and stores nothing. Nil while still counting.
    public static func finish(_ countdown: KeepChangesCountdown, previous: DisplayModeInfo, on display: CGDirectDisplayID,
                              using config: DisplayConfiguring) -> KeepChangesOutcome? {
        switch countdown.state {
        case .counting:
            return nil
        case .kept:
            do {
                try config.persist(display: display)
                return .kept
            } catch {
                return .keptUntilQuit
            }
        case .reverted:
            if case .failed(let message) = revert(to: previous, on: display, using: config) {
                return .revertFailed(message: message)
            }
            return .reverted
        }
    }

    private static func change(to mode: DisplayModeInfo, on display: CGDirectDisplayID, scope: DisplayChangeScope,
                               using config: DisplayConfiguring) -> DisplayApplyResult {
        guard let previous = config.currentMode(for: display) else { return .failed(message: applyErrorText) }
        if previous.isSameMode(as: mode) { return .unchanged }
        guard config.modes(for: display).contains(where: mode.isSameMode) else { return .failed(message: applyErrorText) }
        do {
            try config.setMode(mode, for: display, scope: scope)
            return .applied(previous: previous)
        } catch {
            if let now = config.currentMode(for: display), !now.isSameMode(as: previous) { return .applied(previous: previous) }
            return .failed(message: applyErrorText)
        }
    }
}

/// The "Keep changes?" countdown after a display mode was applied: 15 seconds to a deadline; `tick(now:)` (about once a
/// second) shows the whole seconds left, rounded up, and reverts once the deadline has passed — measured against the
/// clock, not counted in ticks, so a stalled run loop (a blocked main thread, dropped timer fires) still reverts at
/// 15 s. Keep changes ends it, Revert (also Esc, the caption's ×, the window closing) ends it reverting. Once ended it
/// no longer changes.
public struct KeepChangesCountdown: Equatable, Sendable {
    public static let seconds = 15

    public enum RevertReason: Equatable, Sendable { case user, expired }

    public enum State: Equatable, Sendable {
        case counting(Int)
        case kept
        case reverted(RevertReason)
    }

    public private(set) var state: State
    /// When the countdown runs out.
    public let deadline: Date
    private let length: Int

    /// Starts at `now`; `seconds` below one is held to one.
    public init(seconds: Int = KeepChangesCountdown.seconds, now: Date = Date()) {
        length = max(1, seconds)
        deadline = now.addingTimeInterval(TimeInterval(length))
        state = .counting(length)
    }

    public var isFinished: Bool {
        if case .counting = state { return false }
        return true
    }

    /// The display goes back to the previous mode.
    public var shouldRevert: Bool {
        if case .reverted = state { return true }
        return false
    }

    public mutating func tick(now: Date = Date()) {
        guard case .counting = state else { return }
        let left = deadline.timeIntervalSince(now)
        state = left > 0 ? .counting(min(length, Int(left.rounded(.up)))) : .reverted(.expired)
    }

    public mutating func keep() {
        if case .counting = state { state = .kept }
    }

    public mutating func revert() {
        if case .counting = state { state = .reverted(.user) }
    }

    /// The dialog's countdown line ("Reverting to previous display settings in 15 seconds.").
    public var message: String {
        let left: Int
        switch state {
        case .counting(let n): left = n
        default: left = 0
        }
        return "Reverting to previous display settings in \(left) \(left == 1 ? "second" : "seconds")."
    }
}
