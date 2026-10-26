import Foundation

/// A running app as the relaunch policy sees it.
public struct ChromeRelaunchApp: Equatable, Sendable {
    public var bundleID: String
    public var name: String
    public var launchDate: Date?
    /// Whether Win7Chrome.dylib is mapped in the process; nil when the kernel would not say.
    public var hasChrome: Bool?
    /// On the dylib's process blacklist, on `W7ChromeDenylist`, or not eligible for the dylib at all.
    public var denylisted: Bool
    /// A regular (Dock) app; background and accessory apps are never touched.
    public var isRegular: Bool
    /// Runs as arm64/arm64e; an x86_64 app under Rosetta can never map the dylib and is never touched.
    public var isNativeARM64: Bool

    public init(bundleID: String, name: String, launchDate: Date?, hasChrome: Bool?, denylisted: Bool, isRegular: Bool,
                isNativeARM64: Bool = true) {
        self.bundleID = bundleID
        self.name = name
        self.launchDate = launchDate
        self.hasChrome = hasChrome
        self.denylisted = denylisted
        self.isRegular = isRegular
        self.isNativeARM64 = isNativeARM64
    }
}

public enum ChromeRelaunchDecision: Equatable, Sendable {
    /// Quit and reopen these now, without asking.
    case relaunch([ChromeRelaunchApp])
    /// Offer a restart from a tray balloon.
    case notify([ChromeRelaunchApp])
}

/// Apps that macOS reopened at login can start before Ammonia injects Win7Chrome.dylib and keep the macOS
/// frame. At login (the shell itself started within 120 s of the session start and the decision comes within
/// 60 s of it, so nothing the user typed can be lost yet) the ones launched within 20 s of the session start are
/// relaunched; every other app without the chrome is offered a restart from a balloon. The windows are
/// one-sided: something that started before the login record counts only within `loginSlack`.
public enum ChromeRelaunchPolicy {
    /// An app launched this long after the session start counts as reopened at login.
    public static let loginAppWindow: TimeInterval = 20
    /// The shell started this long after the session start is still "at login".
    public static let loginShellWindow: TimeInterval = 120
    /// The decision, and each quit of the automatic loop after it, must come this soon after the session start
    /// (a timer delayed by sleep at the login screen, or a loop slowed by a quit dialog, only notifies).
    public static let loginDecisionWindow: TimeInterval = 60
    /// How far before the login record a start may lie and still count (the record has whole seconds).
    public static let loginSlack: TimeInterval = 5
    /// More than this gap between wall-clock and monotonic elapsed time means the Mac slept (or the clock
    /// stepped).
    public static let sleepTolerance: TimeInterval = 2

    /// Whether `date` lies within `window` after `start`, or at most `loginSlack` before it.
    static func within(_ window: TimeInterval, of start: Date, _ date: Date) -> Bool {
        let d = date.timeIntervalSince(start)
        return d >= -loginSlack && d <= window
    }

    /// Re-checked before every quit of the automatic loop: still within the decision window of the login
    /// record, and no sleep since the decision. Otherwise the remaining apps go to the balloon.
    public static func mayStillRelaunch(sessionStart: Date?, now: Date, sleptSinceDecision: Bool) -> Bool {
        guard !sleptSinceDecision, let sessionStart else { return false }
        return within(loginDecisionWindow, of: sessionStart, now)
    }

    /// Whether the wall clock and the monotonic uptime (which stands still in sleep) disagree.
    public static func slept(wallElapsed: TimeInterval, uptimeElapsed: TimeInterval) -> Bool {
        abs(wallElapsed - uptimeElapsed) > sleepTolerance
    }
    /// Never relaunched or offered, whatever their state.
    public static let neverTouched: Set<String> = ["com.apple.finder", "com.apple.loginwindow"]
    /// Never relaunched when the dylib's blacklist cannot be read.
    public static let systemFallbackDenylist: Set<String> = [
        "com.apple.systemuiserver", "com.apple.dock", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.Spotlight",
    ]

    /// Zero, one or two decisions: the relaunch set (at login) first, then the set to offer.
    public static func decide(sessionStart: Date?, shellLaunch: Date, now: Date, apps: [ChromeRelaunchApp],
                              shellBundleID: String = "com.win7mac.shell") -> [ChromeRelaunchDecision] {
        let candidates = apps.filter {
            $0.isRegular && $0.isNativeARM64 && $0.hasChrome == false && !$0.denylisted
                && $0.bundleID != shellBundleID && !neverTouched.contains($0.bundleID)
        }
        guard !candidates.isEmpty else { return [] }
        var relaunch: [ChromeRelaunchApp] = []
        var notify: [ChromeRelaunchApp] = []
        let atLogin = sessionStart.map {
            within(loginShellWindow, of: $0, shellLaunch) && within(loginDecisionWindow, of: $0, now)
        } ?? false
        for app in candidates {
            if atLogin, let start = sessionStart, let launched = app.launchDate, within(loginAppWindow, of: start, launched) {
                relaunch.append(app)
            } else {
                notify.append(app)
            }
        }
        var out: [ChromeRelaunchDecision] = []
        if !relaunch.isEmpty { out.append(.relaunch(relaunch)) }
        if !notify.isEmpty { out.append(.notify(notify)) }
        return out
    }

    /// The process names in the dylib's blacklist (`Win7Chrome.dylib.blacklist`): one per line, blank lines
    /// and `#` comments skipped.
    public static func parseBlacklist(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    /// Whether the blacklist names the process (by executable or display name). A nil blacklist (unreadable)
    /// is treated as empty, but the system UI apps are then still never relaunched.
    public static func isDenylisted(bundleID: String, executableName: String, localizedName: String?,
                                    blacklist: Set<String>?) -> Bool {
        guard let blacklist else { return systemFallbackDenylist.contains(bundleID) }
        if blacklist.contains(executableName) { return true }
        if let localizedName, blacklist.contains(localizedName) { return true }
        return false
    }

    public struct BalloonText: Equatable, Sendable {
        public var title: String
        /// The program names, when there are three or fewer.
        public var names: String?
        public var action: String
    }

    public static func balloonText(names: [String]) -> BalloonText {
        let n = names.count
        return BalloonText(
            title: "\(n) program\(n == 1 ? "" : "s") started before the Windows 7 frames were ready",
            names: n <= 3 ? names.joined(separator: ", ") : nil,
            action: n == 1 ? "Click to restart it" : "Click to restart them")
    }
}
