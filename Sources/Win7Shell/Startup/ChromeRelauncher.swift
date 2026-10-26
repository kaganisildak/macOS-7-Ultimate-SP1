import AppKit
import OSLog
import Win7ChromeCore
import Win7Core

/// apps macOS reopens at login can start before Ammonia injects Win7Chrome.dylib and keep the macOS
/// frame. 8 s after the shell starts (the taskbar is up), if Finder has the chrome (injection works), the
/// regular apps without it are relaunched when we are at login, or offered a restart from a tray balloon
/// otherwise (ChromeRelaunchPolicy; the automatic loop stops 60 s after login or on sleep).
/// `defaults write com.win7mac.shell W7RelaunchDisabled -bool YES` turns both off. One log line per app:
/// `log stream --predicate 'subsystem == "com.win7mac.shell" AND category == "relaunch"'`.
@MainActor
final class ChromeRelauncher {
    static let log = Logger(subsystem: "com.win7mac.shell", category: "relaunch")
    static let delay: TimeInterval = 8
    /// How long a graceful quit may take before the loop moves on (an unsaved-changes dialog keeps the app open).
    static let quitTimeout: TimeInterval = 15
    /// An app still open after `quitTimeout` is watched this much longer: if the user confirms its quit dialog,
    /// it is reopened then.
    static let lateQuitWatch: TimeInterval = 120
    nonisolated static let installedBlacklist = "/var/ammonia/core/tweaks/Win7Chrome.dylib.blacklist"
    static var isSwitchedOff: Bool { UserDefaults.standard.bool(forKey: "W7RelaunchDisabled") }

    private let shellLaunch: Date
    private var balloon: PermissionBalloon?
    /// The apps the visible balloon offers; a later offer adds to them.
    private var offered: [Entry] = []
    /// The balloon's × hides it for the rest of this shell session.
    private var dismissed = false
    private var busy = false
    /// Restarts asked for (a balloon click) while a loop runs; the loop takes them when it is done.
    private var queued: [Entry] = []
    /// The apps of each check in flight, kept on the main actor while their regions are read in the background.
    private var pending: [Int: [NSRunningApplication]] = [:]
    private var nextCheck = 0
    /// Set by NSWorkspace.didWakeNotification; cleared when the automatic loop is decided.
    private var woke = false
    private var wakeObserver: NSObjectProtocol?

    /// `shellLaunch` defaults to this process's start time from the kernel.
    init(shellLaunch: Date? = nil) {
        self.shellLaunch = shellLaunch ?? ChromePresence.startDate(pid: getpid()) ?? Date()
    }

    func scheduleAfterLaunch() {
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.woke = true }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay) { [weak self] in
            MainActor.assumeIsolated { self?.evaluate() }
        }
    }

    private struct Entry {
        let app: NSRunningApplication
        let model: ChromeRelaunchApp
    }

    /// When the automatic loop was decided, so each quit can re-check the login window and sleep.
    private struct Deadline {
        let sessionStart: Date?
        let wall: Date
        let uptime: TimeInterval
    }

    /// Reads which apps have the chrome off the main thread, then decides on the main actor.
    func evaluate() {
        guard !Self.isSwitchedOff else {
            Self.log.info("W7RelaunchDisabled is on; relaunch check skipped")
            return
        }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        let check = nextCheck
        nextCheck += 1
        pending[check] = apps
        let pids = apps.map(\.processIdentifier)
        let finderPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
        let loginwindowPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow").first?.processIdentifier
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let finderHasChrome = finderPID.flatMap { ChromePresence.hasWin7Chrome(pid: $0) } ?? false
            let presence = finderHasChrome ? pids.map { ChromePresence.hasWin7Chrome(pid: $0) } : []
            let starts = pids.map { ChromePresence.startDate(pid: $0) }
            let sessionStart = Self.sessionStart(loginwindowPID: loginwindowPID)
            let blacklist = Self.readBlacklist()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let apps = self.pending.removeValue(forKey: check) else { return }
                    guard finderHasChrome else {
                        Self.log.info("relaunch check: injection not available (Finder has no Win7Chrome.dylib)")
                        return
                    }
                    guard apps.count == presence.count, apps.count == starts.count else { return }
                    self.decide(apps: apps, presence: presence, starts: starts, sessionStart: sessionStart, blacklist: blacklist)
                }
            }
        }
    }

    private func decide(apps: [NSRunningApplication], presence: [Bool?], starts: [Date?], sessionStart: Date?,
                        blacklist: Set<String>?) {
        let defaults = UserDefaults.standard
        let extra = defaults.array(forKey: "W7ChromeDenylist") as? [String] ?? []
        let chromeDisabled = defaults.bool(forKey: "W7ChromeDisabled")
        var entries: [Entry] = []
        for (i, app) in apps.enumerated() where !app.isTerminated {
            guard let id = app.bundleIdentifier else { continue }
            let info = app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary }
            // An app the dylib would not decorate gains nothing from a relaunch.
            let eligible = W7ShouldLoadInProcess(id, info, extra, chromeDisabled)
            let listed = ChromeRelaunchPolicy.isDenylisted(
                bundleID: id, executableName: app.executableURL?.lastPathComponent ?? "",
                localizedName: app.localizedName, blacklist: blacklist)
            entries.append(Entry(app: app, model: ChromeRelaunchApp(
                bundleID: id, name: app.localizedName ?? id, launchDate: app.launchDate ?? starts[i],
                hasChrome: presence[i], denylisted: listed || !eligible, isRegular: app.activationPolicy == .regular,
                isNativeARM64: app.executableArchitecture == NSBundleExecutableArchitectureARM64)))
        }
        let now = Date()
        let decisions = ChromeRelaunchPolicy.decide(sessionStart: sessionStart, shellLaunch: shellLaunch, now: now,
                                                    apps: entries.map(\.model))
        if decisions.isEmpty { Self.log.info("relaunch check: nothing to relaunch") }
        for decision in decisions {
            switch decision {
            case .relaunch(let models):
                woke = false
                relaunch(targets(models, in: entries), deadline: Deadline(
                    sessionStart: sessionStart, wall: now, uptime: ProcessInfo.processInfo.systemUptime))
            case .notify(let models):
                offer(targets(models, in: entries))
            }
        }
    }

    private func targets(_ models: [ChromeRelaunchApp], in entries: [Entry]) -> [Entry] {
        entries.filter { entry in models.contains(entry.model) }
    }

    // MARK: Balloon

    private func offer(_ entries: [Entry]) {
        guard !dismissed else { return }
        let fresh = entries.filter { e in !offered.contains { $0.app.processIdentifier == e.app.processIdentifier } }
        offered = (offered + fresh).filter { !$0.app.isTerminated }
        guard !offered.isEmpty else { return }
        for e in fresh { Self.log.info("\(e.model.name, privacy: .public): started before the chrome; offered a restart") }
        let text = ChromeRelaunchPolicy.balloonText(names: offered.map(\.model.name))
        let message = [text.names, text.action].compactMap { $0 }.joined(separator: "\n")
        balloon?.dismiss()
        let b = PermissionBalloon(message: message, title: text.title, onClose: { [weak self] in
            self?.dismissed = true
            self?.offered = []
            self?.balloon = nil
        }, onClick: { [weak self] in
            guard let self else { return }
            let chosen = self.offered
            self.offered = []
            self.balloon = nil
            self.relaunch(chosen, deadline: nil)
        })
        balloon = b
        b.present()
    }

    // MARK: Relaunch

    /// One app at a time: a graceful quit (the app's own save dialog may keep it open), up to 15 s for it to
    /// end, then the same bundle is opened again in the background. The automatic loop (`deadline` set)
    /// re-checks before every quit that it is still within the login window and the Mac has not slept;
    /// otherwise the remaining apps are offered from the balloon. A balloon click (no deadline) while a loop
    /// runs is queued and run after it.
    private func relaunch(_ entries: [Entry], deadline: Deadline?) {
        guard !entries.isEmpty else { return }
        if busy {
            for e in entries {
                Self.log.info("\(e.model.name, privacy: .public): restart requested while another relaunch runs; queued")
            }
            queued += entries
            return
        }
        busy = true
        Task { @MainActor in
            var batch = entries
            var batchDeadline = deadline
            while !batch.isEmpty {
                var late: [Entry] = []
                for entry in batch {
                    if let d = batchDeadline, !late.isEmpty || !mayContinue(d) {
                        late.append(entry)
                        continue
                    }
                    await relaunchOne(entry)
                }
                for e in late {
                    Self.log.info("\(e.model.name, privacy: .public): too late for an automatic relaunch; offered a restart")
                }
                if !late.isEmpty { offer(late) }
                batch = queued.filter { !$0.app.isTerminated }
                batchDeadline = nil
                queued = []
            }
            busy = false
        }
    }

    private func mayContinue(_ d: Deadline) -> Bool {
        let now = Date()
        let slept = woke || ChromeRelaunchPolicy.slept(wallElapsed: now.timeIntervalSince(d.wall),
                                                      uptimeElapsed: ProcessInfo.processInfo.systemUptime - d.uptime)
        return ChromeRelaunchPolicy.mayStillRelaunch(sessionStart: d.sessionStart, now: now, sleptSinceDecision: slept)
    }

    private func relaunchOne(_ entry: Entry) async {
        let app = entry.app
        let name = entry.model.name
        guard !app.isTerminated else {
            Self.log.info("\(name, privacy: .public): already quit; not reopened")
            return
        }
        guard let url = app.bundleURL else {
            Self.log.info("\(name, privacy: .public): no bundle; left running")
            return
        }
        guard app.terminate() else {
            Self.log.info("\(name, privacy: .public): quit request not delivered; left running")
            return
        }
        guard await Self.waitForTermination(app, timeout: Self.quitTimeout, poll: .milliseconds(250)) else {
            Self.log.info("\(name, privacy: .public): did not quit within 15 s; reopened if it quits within 2 min")
            Task { @MainActor in
                if await Self.waitForTermination(app, timeout: Self.lateQuitWatch, poll: .seconds(1)) {
                    await Self.reopen(url, name: name, outcome: "quit later; reopened")
                } else {
                    Self.log.info("\(name, privacy: .public): still running after 2 min; left running")
                }
            }
            return
        }
        await Self.reopen(url, name: name, outcome: "relaunched")
    }

    private static func waitForTermination(_ app: NSRunningApplication, timeout: TimeInterval,
                                           poll: Duration) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !app.isTerminated, Date() < deadline {
            try? await Task.sleep(for: poll)
        }
        return app.isTerminated
    }

    private static func reopen(_ url: URL, name: String, outcome: String) async {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            log.info("\(name, privacy: .public): \(outcome, privacy: .public)")
        } catch {
            log.error("\(name, privacy: .public): quit but could not be reopened: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Inputs

    /// The console login of this user (utmpx). loginwindow's own start is the fallback: it starts with the
    /// login screen, minutes before the login itself (measured 2026-10-18: 10:40:40 vs a 10:44:20 login).
    nonisolated static func sessionStart(loginwindowPID: pid_t?) -> Date? {
        LoginSession.loginTime() ?? loginwindowPID.flatMap { ChromePresence.startDate(pid: $0) }
    }

    /// The dylib's installed process blacklist; nil when it cannot be read (the policy then fails open).
    nonisolated static func readBlacklist() -> Set<String>? {
        guard let text = try? String(contentsOfFile: installedBlacklist, encoding: .utf8) else { return nil }
        return ChromeRelaunchPolicy.parseBlacklist(text)
    }
}
