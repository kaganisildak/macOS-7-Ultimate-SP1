import AppKit
import Carbon.HIToolbox
import Win7Core
import ApplicationServices
import CoreGraphics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var taskbarWindow: TaskbarWindow?
    private let startMenu = StartMenuWindow()
    private let hotKeys = HotKeyCenter()
    private let observer = RunningAppsObserver()
    private let windowService = WindowService()
    /// Snap fills the same work area the keeper keeps windows in.
    private lazy var snap = SnapController(service: windowService) { [weak self] in self?.visibleBarFrame }
    /// App windows are kept out of the taskbar band.
    private lazy var workArea = WorkAreaKeeper(service: windowService) { [weak self] in self?.visibleBarFrame }
    /// The taskbar's AppKit frame while it is on screen.
    private var visibleBarFrame: NSRect? {
        guard let bar = taskbarWindow, bar.isVisible else { return nil }
        return bar.frame
    }
    private let balloon = PermissionBalloon()
    /// what to enable for Screen Recording, shown after its system prompt on a click.
    private lazy var screenCaptureBalloon = PermissionBalloon(permission: .screenCapture)
    private let gate = PermissionGate(
        isAXTrusted: { AXIsProcessTrusted() },
        hasScreenCapture: { CGPreflightScreenCaptureAccess() })
    private var balloonPolicy = BalloonPolicy()
    private let peek = PeekController()
    /// Cached window lists and counts for the taskbar, fetched off the main thread.
    private let windowSnapshots = WindowSnapshotStore()
    private lazy var thumbnailProvider = ThumbnailProvider(store: windowSnapshots)
    private lazy var thumbnailPopup = ThumbnailPopup(provider: thumbnailProvider)
    private lazy var switcher = SwitcherController(service: windowService, provider: thumbnailProvider)
    private let desktopStore = DesktopStore()
    private lazy var desktopActions = DesktopActions(store: desktopStore)
    private var desktopWindow: DesktopWindow?
    private var showDesktop = ShowDesktopState()
    /// Hiding apps makes macOS activate another app; that activation must not reset Show Desktop.
    private var ignoreActivationsUntil = Date.distantPast
    private lazy var minimizer = WindowMinimizer(service: windowService)
    private lazy var winKeys = WinKeyShortcuts(hotKeys: hotKeys, service: windowService, snap: snap, minimizer: minimizer)
    // desktop gadgets, device connect/disconnect sounds.
    private let gadgets = GadgetController()
    private let deviceSounds = DeviceSoundMonitor()
    /// apps that started before Ammonia injected are relaunched at login or offered a restart.
    private let relauncher = ChromeRelauncher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ShellCursors.install()
        SessionSplash.welcomeIfFirstLaunch()
        let desktop = DesktopWindow(store: desktopStore, actions: desktopActions)
        desktopWindow = desktop
        desktop.orderFrontRegardless()
        desktopStore.start()
        desktop.desktopView.onGadgets = { [weak self] in self?.gadgets.showGallery() }
        gadgets.start()
        deviceSounds.start()
        WallpaperController.shared.start()   // A saved slideshow goes on
        let window = TaskbarWindow(observer: observer)
        window.taskbarView.onShowDesktop = { [weak self] in
            self?.thumbnailPopup.taskbarControlUsed()
            self?.toggleShowDesktop()
        }
        taskbarWindow = window
        peek.installSignalHandlers()
        window.taskbarView.onPeekBegin = { [weak self] in self?.peek.begin() }
        window.taskbarView.onPeekEnd = { [weak self] in self?.peek.end() }
        window.taskbarView.onThumbnailHover = { [weak self] item, rect in
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID).first else { return }
            self?.thumbnailPopup.show(pid: app.processIdentifier, above: rect)
        }
        window.taskbarView.onThumbnailHoverEnd = { [weak self] in self?.thumbnailPopup.scheduleClose() }
        // hovering a running button fetches its windows in the background, so the click that
        // usually follows decides on cached counts; the stacked look gets its counts the same way.
        window.taskbarView.onButtonHover = { [weak self] item in
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID).first else { return }
            self?.windowSnapshots.prefetch(pid: app.processIdentifier)
        }
        window.taskbarView.requestStacks = { [weak self] in self?.windowSnapshots.refreshOnScreen() }
        // An action on an app's windows makes its cached snapshot stale; the next click
        // must see the new state (an un-minimized window, a closed one).
        window.taskbarView.onWindowsActedOn = { [weak self] item in
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID) {
                self?.windowSnapshots.invalidate(pid: app.processIdentifier)
            }
        }
        windowSnapshots.hoveredPID = { [weak window] in
            guard let item = window?.taskbarView.hoveredRunningItem else { return nil }
            return NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID).first?.processIdentifier
        }
        windowSnapshots.onScreenChange = { [weak window] byPID in window?.taskbarView.applyStacks(byPID) }
        window.taskbarView.windowCounts = { [weak self] item in
            guard let self, let app = NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID).first
            else { return WindowCounts(total: 0) }
            return self.thumbnailProvider.windowCounts(pid: app.processIdentifier)
        }
        window.taskbarView.onUnminimize = { [weak self] item in
            guard let self, let app = NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID).first
            else { return }
            let pid = app.processIdentifier
            defer { self.windowSnapshots.invalidate(pid: pid) }
            if let id = self.windowService.windows(pid: pid).first(where: { self.windowService.isMinimized($0) })
                .flatMap({ self.windowService.windowID($0) }) {
                self.raiseWindow(pid: pid, id: id)
            } else {
                TaskbarView.reopen(bundleID: item.bundleID)   // the window went away meanwhile
            }
        }
        window.taskbarView.onWindowList = { [weak self] item, rect in
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID).first else { return }
            self?.thumbnailPopup.toggle(pid: app.processIdentifier, above: rect)
        }
        window.taskbarView.onButtonClick = { [weak self] in self?.thumbnailPopup.close() }
        thumbnailPopup.onSelect = { [weak self] pid, id in self?.raiseWindow(pid: pid, id: id) }
        window.taskbarView.onStartClick = { [weak self] in
            self?.thumbnailPopup.taskbarControlUsed()
            self?.startMenu.toggle()
        }
        // what a taskbar click hit; the app to give focus back to, handed between the window
        // popup and the taskbar's jump lists and menus; the × that closes a window from its preview.
        thumbnailPopup.taskbarHit = { [weak window] p in window?.taskbarView.hit(atScreen: p) ?? .button }
        window.taskbarView.rememberedFocus = { [weak self] in self?.thumbnailPopup.rememberedApp }
        thumbnailPopup.fallbackFocus = { [weak window] in window?.taskbarView.jumpListRememberedApp }
        thumbnailPopup.closeWindow = { [weak self] pid, id in
            guard let self else { return }
            for ax in self.windowService.windows(pid: pid) where self.windowService.windowID(ax) == id {
                TaskbarWindowActions.close(ax)
            }
            self.windowSnapshots.invalidate(pid: pid)
        }
        // a jump list's Close window or a preview's × without Accessibility shows the balloon;
        // after the system prompt, for whichever grant is missing.
        PermissionPrompter.shared.presentBalloon = { [weak self] kind in
            guard let self else { return }
            switch kind {
            case .accessibility: self.balloon.present()
            case .screenCapture: self.screenCaptureBalloon.present()
            }
        }
        startMenu.onVisibilityChange = { [weak window] open in window?.taskbarView.startMenuOpen = open }
        ControlPanelWindow.listenForShowRequests()   // Explorer's Computer view: Open Control Panel
        // Ctrl+Esc (Esc = key code 53)
        hotKeys.register(keyCode: 53, modifiers: UInt32(controlKey)) { [weak self] in
            self?.thumbnailPopup.taskbarControlUsed()   // no mouse event reaches the popup's monitors
            TaskbarActivation.cancel()   // the Start menu takes focus; no pending restore may steal it
            self?.startMenu.toggle()
        }
        observer.onForeignActivation = { [weak self] in
            guard let self, Date() >= self.ignoreActivationsUntil else { return }
            self.showDesktop.reset()
        }
        window.orderFrontRegardless()
        snap.start(hotKeys: hotKeys)
        startWinKeyShortcuts(taskbar: window)
        // One shared 5 s poll for the feature gate and the Action Center.
        PermissionPoller.shared.subscribe { [weak self] snapshot in self?.evaluateGate(snapshot) }
        // a missing grant is asked for once per launch (the system prompt opens its pane).
        PermissionPrompter.shared.launch(PermissionPoller.shared.current)
        windowSnapshots.refreshOnScreen()
        relauncher.scheduleAfterLaunch()
    }

    private func evaluateGate(_ snapshot: PermissionSnapshot) {
        let features = snapshot.features
        snap.isEnabled = features.contains(.snap)
        workArea.isEnabled = features.contains(.snap) && !WorkAreaKeeper.isSwitchedOff
        thumbnailProvider.features = features
        thumbnailProvider.accessibilityTrusted = features.contains(.snap)
        switcher.isEnabled = features.contains(.switcher)
        let trusted = features.contains(.snap)
        if trusted { balloon.dismiss() }
        if balloonPolicy.shouldShow(trusted: trusted) { balloon.present() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        peek.endUnconditionally()
        ScreenResolutionWindow.revertPendingChange()   // a display mode still on trial goes back
    }

    /// With Accessibility the exact window comes forward (un-minimized first); without it only the
    /// app can be activated, and the system prompt and the Accessibility balloon explain why, at most
    /// once per 60 s.
    private func raiseWindow(pid: pid_t, id: CGWindowID) {
        defer { windowSnapshots.invalidate(pid: pid) }
        let app = NSRunningApplication(processIdentifier: pid)
        app?.unhide()
        if thumbnailProvider.accessibilityTrusted {
            for ax in windowService.windows(pid: pid) where windowService.windowID(ax) == id {
                if windowService.isMinimized(ax) { windowService.unminimize(ax) }
                windowService.raise(ax)
            }
        } else {
            PermissionPrompter.shared.needed(.accessibility)
        }
        TaskbarActivation.bringForward(pid: pid)   // activate, check after 300 ms, retry once
    }

    private func toggleShowDesktop() {
        let visible = observer.visibleBundleIDs()
        ignoreActivationsUntil = Date().addingTimeInterval(1)
        switch showDesktop.toggle(visibleApps: visible) {
        case .hide(let ids): forEachApp(ids) { $0.hide() }
        case .unhide(let ids): forEachApp(ids) { $0.unhide() }
        }
    }

    private func forEachApp(_ ids: [String], _ body: (NSRunningApplication) -> Void) {
        for id in ids {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) { body(app) }
        }
    }
}

// MARK: Windows-key shortcuts and Aero Shake

extension AppDelegate {
    private func startWinKeyShortcuts(taskbar: TaskbarWindow) {
        winKeys.isAccessibilityTrusted = { [gate] in gate.isAXTrusted() }
        winKeys.onNeedsAccessibility = { PermissionPrompter.shared.needed(.accessibility) }
        winKeys.showDesktop = { [weak self] in
            self?.thumbnailPopup.taskbarControlUsed()   // as for Ctrl+Esc: no mouse event reaches the popup
            self?.toggleShowDesktop()
        }
        // Win+R opens the Run dialog, as the Start menu's Run… does; an open Start menu closes first.
        winKeys.run = { [weak self] in
            self?.thumbnailPopup.taskbarControlUsed()
            self?.startMenu.close()
            RunDialog.shared.present()
        }
        winKeys.peekBegin = { [weak self] in self?.peek.begin() }
        winKeys.peekEnd = { [weak self] in self?.peek.end() }
        winKeys.taskbar = { [weak taskbar] in taskbar?.taskbarView }
        winKeys.start()
        // Deferred, so the drag event that completed the shake returns before the AX minimizing starts.
        snap.onShake = { [weak self] window, screen in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.minimizer.toggleOthers(keeping: window, on: screen) } }
        }
    }
}
