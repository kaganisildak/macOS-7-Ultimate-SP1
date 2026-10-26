import AppKit
import Win7Core

/// Executes `PowerAction`s. Never called from tests.
@MainActor
enum PowerActions {
    /// Fast user switching needs CGSession, which recent macOS releases no longer ship; without it the
    /// Start menu hides Switch user.
    static var canSwitchUser: Bool { FileManager.default.isExecutableFile(atPath: PowerAction.cgSessionPath) }

    private static var splashDriver: PowerSplashDriver?

    /// Log off, Restart and Shut down first play their sound (Windows Logoff / Shutdown) and show the
    /// Windows 7 session screen (PowerSplashDriver), then run.
    static func perform(_ action: PowerAction) {
        guard let command = action.command else {
            lock()
            return
        }
        guard let kind = SessionSplashKind.forPowerAction(action) else {
            run(command, onFailure: {})
            return
        }
        if let sound = SoundEvent.forPowerAction(action) { SoundPlayer.play(sound) }
        splashDriver?.stop()
        let driver = PowerSplashDriver(kind: kind, command: command)
        splashDriver = driver
        driver.onFinished = { [weak driver] in if splashDriver === driver { splashDriver = nil } }
        driver.start()
    }

    static func run(_ command: [String], onFailure: @escaping @MainActor () -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command[0])
        p.arguments = Array(command.dropFirst())
        p.terminationHandler = { proc in
            guard proc.terminationStatus != 0 else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { onFailure() } }
        }
        do { try p.run() } catch {
            NSLog("Win7Shell: power action failed: \(error)")
            onFailure()
        }
    }

    /// Ctrl+Cmd+Q is macOS's Lock Screen shortcut.
    private static func lock() {
        let q: CGKeyCode = 12
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: q, keyDown: down) else { continue }
            e.flags = [.maskControl, .maskCommand]
            e.post(tap: .cghidEventTap)
        }
    }
}

/// Runs PowerSplashMachine: the splash covers everything for the first 1.2 s only. Once the command is
/// sent it sits below alerts and closes as soon as another app activates (loginwindow's confirmation,
/// "Save changes?", a privacy prompt); NSWorkspace.willPowerOffNotification brings it back below normal
/// windows, where quitting apps' sheets stay on top. Shown phases are capped at
/// SessionSplashKind.failureTimeout; after a dismissal the observers stay SessionSplashKind.lingerAfterDismiss
/// for a late willPowerOff, then stop for good.
@MainActor
final class PowerSplashDriver {
    private var machine = PowerSplashMachine()
    private let kind: SessionSplashKind
    private let command: [String]
    private var splash: SessionSplash?
    private var tokens: [NSObjectProtocol] = []
    private var timerGeneration = 0
    private var stopped = false
    /// Called once the driver has stopped observing (so PowerActions can let it go).
    var onFinished: (() -> Void)?

    init(kind: SessionSplashKind, command: [String]) {
        self.kind = kind
        self.command = command
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        tokens.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            let terminated = app?.isTerminated ?? false
            MainActor.assumeIsolated { self?.handle(.otherAppActivated(terminated: terminated)) }
        })
        tokens.append(nc.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.willPowerOff) }
        })
        handle(.start)
        DispatchQueue.main.asyncAfter(deadline: .now() + SessionSplashKind.minimumDuration) { [weak self] in
            MainActor.assumeIsolated { self?.handle(.minimumElapsed) }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        for t in tokens { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        tokens = []
        splash?.dismiss()
        splash = nil
        onFinished?()
    }

    private func handle(_ event: PowerSplashEvent) {
        guard !stopped else { return }
        for effect in machine.handle(event) {
            switch effect {
            case .show(let level):
                if splash == nil { splash = SessionSplash.show(kind) }
                splash?.setVisible(true, level: level)
            case .hide:
                splash?.setVisible(false, level: .belowWindows)
            case .runCommand:
                PowerActions.run(command) { [weak self] in self?.handle(.commandFailed) }
            case .armTimeout:
                arm(SessionSplashKind.failureTimeout)
            case .armLinger:
                arm(SessionSplashKind.lingerAfterDismiss)
            case .stopObserving:
                stop()
            }
        }
    }

    /// One timer at a time: arming again makes an older one a no-op.
    private func arm(_ seconds: TimeInterval) {
        timerGeneration += 1
        let g = timerGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, g == self.timerGeneration else { return }
                self.handle(.timeout)
            }
        }
    }
}
