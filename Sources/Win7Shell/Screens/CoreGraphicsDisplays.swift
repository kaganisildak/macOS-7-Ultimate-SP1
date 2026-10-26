import CoreGraphics
import OSLog
import Win7Core

/// The only code in the shell that changes a display: the public CoreGraphics configuration API —
/// CGDisplayCopyAllDisplayModes to list, CGBeginDisplayConfiguration / CGConfigureDisplayWithDisplayMode /
/// CGCompleteDisplayConfiguration to switch. Nothing is written to firmware or `nvram`; it only picks among the
/// modes macOS offers. Called only from the Screen Resolution window when the user applies, keeps or reverts a mode;
/// the tests use a fake DisplayConfiguring and never reach this type (it lives in the shell executable).
///
/// a mode on trial is completed `.forAppOnly`, so the window server undoes it if the shell exits during the
/// "Keep changes?" countdown (quit, crash, kill, logout); Keep changes re-commits the current mode `.permanently`
/// (`persist`), and a revert commits the previous mode `.permanently` (re-asserting the stored preference). If a
/// testing shows the re-commit of the current mode doesn't stick across a relaunch, `.forSession` is the fallback
/// for the trial (README, Screen Resolution).
final class CoreGraphicsDisplays: DisplayConfiguring, Sendable {
    static let shared = CoreGraphicsDisplays()
    private static let log = Logger(subsystem: "com.win7mac.shell", category: "display")
    /// IOGraphicsTypes.h: kDisplayModeNativeFlag and kDisplayModeDefaultFlag.
    private static let nativeFlag: UInt32 = 0x0200_0000
    private static let defaultFlag: UInt32 = 0x0000_0004

    private func cgModes(_ display: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
    }

    private static func info(_ m: CGDisplayMode) -> DisplayModeInfo {
        DisplayModeInfo(id: m.ioDisplayModeID, width: m.width, height: m.height, scaled: m.pixelWidth > m.width,
                        refresh: m.refreshRate, isNative: m.ioFlags & nativeFlag != 0, isDefault: m.ioFlags & defaultFlag != 0,
                        usableForDesktop: m.isUsableForDesktopGUI(), pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight)
    }

    func modes(for display: CGDirectDisplayID) -> [DisplayModeInfo] { cgModes(display).map(Self.info) }

    func currentMode(for display: CGDirectDisplayID) -> DisplayModeInfo? { CGDisplayCopyDisplayMode(display).map(Self.info) }

    func setMode(_ mode: DisplayModeInfo, for display: CGDirectDisplayID, scope: DisplayChangeScope) throws {
        let all = cgModes(display)
        guard let index = DisplayModes.match(mode, in: all.map(Self.info)) else { throw fail(.modeNotFound, .success) }
        try configure(display, all[index], scope == .permanent ? .permanently : .forAppOnly)
        Self.log.info("display \(display, privacy: .public): mode \(mode.width, privacy: .public)x\(mode.height, privacy: .public)\(mode.scaled ? " HiDPI" : "", privacy: .public) set \(scope == .permanent ? "permanently" : "until the shell quits", privacy: .public)")
    }

    func persist(display: CGDirectDisplayID) throws {
        guard let current = CGDisplayCopyDisplayMode(display) else { throw fail(.modeNotFound, .success) }
        try configure(display, current, .permanently)
        Self.log.info("display \(display, privacy: .public): current mode stored")
    }

    /// Begin, configure `display` with `mode`, complete with `option`; cancels after a configure failure (a failed
    /// complete has consumed the configuration).
    private func configure(_ display: CGDirectDisplayID, _ mode: CGDisplayMode, _ option: CGConfigureOption) throws {
        var config: CGDisplayConfigRef?
        let begun = CGBeginDisplayConfiguration(&config)
        guard begun == .success, let config else { throw fail(.begin, begun) }
        let configured = CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
        guard configured == .success else {
            CGCancelDisplayConfiguration(config)
            throw fail(.configure, configured)
        }
        let completed = CGCompleteDisplayConfiguration(config, option)
        guard completed == .success else { throw fail(.complete, completed) }
    }

    private func fail(_ stage: DisplayConfigurationError.Stage, _ error: CGError) -> DisplayConfigurationError {
        let e = DisplayConfigurationError(stage: stage, code: error.rawValue)
        Self.log.error("display mode change: \(e.description, privacy: .public)")
        return e
    }
}
