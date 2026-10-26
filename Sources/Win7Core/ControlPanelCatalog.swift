import Foundation

/// The Control Panel's content: Windows 7's categories, their home-page sub-links and items, each
/// mapped to what opens it on macOS. Every pane id is a Settings extension verified on macOS 27.0.1
/// (scripts/control-panel-pane-ids.sh; the list is committed as scripts/fixtures/control-panel-pane-ids.txt).
public enum ControlPanelCatalog {
    // MARK: Targets

    /// Settings extension bundle id -> its `.appex` in /System/Library/ExtensionKit/Extensions.
    public static let paneBundles: [String: String] = [
        Pane.accessibility: "AccessibilitySettingsExtension.appex",
        Pane.appearance: "Appearance.appex",
        Pane.about: "AboutExtension.appex",
        Pane.appleAccount: "AppleIDSettings.appex",
        Pane.battery: "PowerPreferences.appex",
        Pane.bluetooth: "Bluetooth.appex",
        Pane.cdsAndDVDs: "CDs & DVDs Settings Extension.appex",
        Pane.controlCenter: "ControlCenterSettings.appex",
        Pane.dateTime: "DateAndTime Extension.appex",
        Pane.desktopDock: "DesktopSettings.appex",
        Pane.displays: "DisplaysExt.appex",
        Pane.keyboard: "KeyboardSettings.appex",
        Pane.languageRegion: "Localization.appex",
        Pane.lockScreen: "LockScreen.appex",
        Pane.mouse: "MouseExtension.appex",
        Pane.network: "Network.appex",
        Pane.notifications: "NotificationsSettings.appex",
        Pane.printers: "PrinterScannerSettings.appex",
        Pane.privacySecurity: "SecurityPrivacyExtension.appex",
        Pane.screenTime: "ScreenTimePreferencesExtension.appex",
        Pane.sharing: "Sharing.appex",
        Pane.siri: "SiriPreferenceExtension.appex",
        Pane.softwareUpdate: "SoftwareUpdateSettingsExtension.appex",
        Pane.sound: "Sound.appex",
        Pane.spotlight: "SpotlightPreferenceExtension.appex",
        Pane.storage: "Storage.appex",
        Pane.timeMachine: "TimeMachineSettings.appex",
        Pane.touchIDPassword: "Touch ID & Password.appex",
        Pane.trackpad: "TrackpadExtension.appex",
        Pane.usersGroups: "UsersGroups.appex",
        Pane.wallpaper: "Wallpaper.appex",
        Pane.wifi: "Wi-Fi.appex",
    ]

    public enum Pane {
        public static let accessibility = "com.apple.Accessibility-Settings.extension"
        public static let appearance = "com.apple.Appearance-Settings.extension"
        public static let about = "com.apple.SystemProfiler.AboutExtension"
        public static let appleAccount = "com.apple.systempreferences.AppleIDSettings"
        /// "Battery" on a laptop, "Energy" on a desktop Mac: the same extension.
        public static let battery = "com.apple.Battery-Settings.extension"
        public static let bluetooth = "com.apple.BluetoothSettings"
        public static let cdsAndDVDs = "com.apple.CD-DVD-Settings.extension"
        public static let controlCenter = "com.apple.ControlCenter-Settings.extension"
        public static let dateTime = "com.apple.Date-Time-Settings.extension"
        /// Desktop & Dock, where macOS keeps the default web browser.
        public static let desktopDock = "com.apple.Desktop-Settings.extension"
        public static let displays = "com.apple.Displays-Settings.extension"
        /// Keyboard, which also holds input sources and Dictation.
        public static let keyboard = "com.apple.Keyboard-Settings.extension"
        public static let languageRegion = "com.apple.Localization-Settings.extension"
        public static let lockScreen = "com.apple.Lock-Screen-Settings.extension"
        public static let mouse = "com.apple.Mouse-Settings.extension"
        /// Network, which also holds the firewall since macOS 15.
        public static let network = "com.apple.Network-Settings.extension"
        public static let notifications = "com.apple.Notifications-Settings.extension"
        public static let printers = "com.apple.Print-Scan-Settings.extension"
        /// Privacy & Security, with FileVault; opened only, it stays native.
        public static let privacySecurity = "com.apple.settings.PrivacySecurity.extension"
        public static let screenTime = "com.apple.Screen-Time-Settings.extension"
        public static let sharing = "com.apple.Sharing-Settings.extension"
        public static let siri = "com.apple.Siri-Settings.extension"
        public static let softwareUpdate = "com.apple.Software-Update-Settings.extension"
        public static let sound = "com.apple.Sound-Settings.extension"
        public static let spotlight = "com.apple.Spotlight-Settings.extension"
        public static let storage = "com.apple.settings.Storage"
        public static let timeMachine = "com.apple.Time-Machine-Settings.extension"
        /// "Touch ID & Password", or "Login Password" on a Mac without Touch ID.
        public static let touchIDPassword = "com.apple.Touch-ID-Settings.extension"
        public static let trackpad = "com.apple.Trackpad-Settings.extension"
        public static let usersGroups = "com.apple.Users-Groups-Settings.extension"
        public static let wallpaper = "com.apple.Wallpaper-Settings.extension"
        public static let wifi = "com.apple.wifi-settings-extension"
    }

    private static func pane(_ id: String) -> ControlPanelAction { .settingsPane(id) }
    private static func utility(_ name: String) -> ControlPanelAction { .app("/System/Applications/Utilities/\(name).app") }
    private static func systemApp(_ name: String) -> ControlPanelAction { .app("/System/Applications/\(name).app") }
    private static let systemInformation = utility("System Information")
    private static let diskUtility = utility("Disk Utility")
    private static let safari = ControlPanelAction.app("/Applications/Safari.app")
    /// Opens System Settings at its first page (the task pane's "See also").
    public static let systemSettings = ControlPanelAction.url("x-apple.systempreferences:")

    // MARK: Home page

    /// The sub-links under each category on the home page (Windows 7's, in its order).
    public static func homeLinks(_ category: ControlPanelCategory) -> [ControlPanelLink] {
        switch category {
        case .systemAndSecurity:
            [ControlPanelLink("Review your computer's status", pane(Pane.privacySecurity)),
             ControlPanelLink("Back up your computer", pane(Pane.timeMachine)),
             ControlPanelLink("Find and fix problems", diskUtility)]
        case .userAccounts:
            [ControlPanelLink("Change account type", pane(Pane.usersGroups)),
             ControlPanelLink("Add or remove user accounts", pane(Pane.usersGroups))]
        case .networkAndInternet:
            [ControlPanelLink("View network status and tasks", pane(Pane.network)),
             ControlPanelLink("Choose homegroup and sharing options", pane(Pane.sharing))]
        case .appearance:
            [ControlPanelLink("Change the theme", .shellWindow(.personalization)),
             ControlPanelLink("Change desktop background", .shellWindow(.desktopBackground)),
             ControlPanelLink("Adjust screen resolution", .shellWindow(.screenResolution))]
        case .hardwareAndSound:
            [ControlPanelLink("View devices and printers", .shellWindow(.devicesAndPrinters)),
             ControlPanelLink("Add a device", pane(Pane.bluetooth)),
             ControlPanelLink("Adjust commonly used mobility settings", pane(Pane.controlCenter))]
        case .clockLanguageRegion:
            [ControlPanelLink("Change keyboards or other input methods", pane(Pane.keyboard)),
             ControlPanelLink("Change display language", pane(Pane.languageRegion))]
        case .programs:
            [ControlPanelLink("Uninstall a program", .finder("/Applications"))]
        case .easeOfAccess:
            [ControlPanelLink("Let Windows suggest settings", pane(Pane.accessibility)),
             ControlPanelLink("Optimize visual display", pane(Pane.accessibility))]
        }
    }

    // MARK: Info pages

    public static let lookInfo = """
        Win7Mac draws the taskbar, the Start menu, the desktop and this Control Panel; the window frames come from \
        the Win7Chrome library. Nothing from Windows is included, so the Windows 7 pictures, icons, sounds and \
        fonts come from your own copy of Windows 7. Run these in Terminal, in the win7mac folder:

        Everything from a Windows 7 disc:  make import-assets SRC=/path/to/Win7.iso  (needs 7-Zip's 7zz on your PATH)
        Then:  make install  (or copy the files in Assets/icons into \
        ~/Library/Application Support/Win7Mac/Assets/icons), and make chrome, make install-chrome, so sandboxed \
        apps such as Safari get the icons too.
        Wallpaper only:  make wallpaper SRC=/path/to/img0.jpg
        Icons from .ico files:  make import-icons SRC=/path/to/imageres-icons.zip

        The shell reads icons when it starts; Finder and Safari when they launch. A map line marked ICON/? is \
        chosen on Assets/_contact/<dll>.png; ICON/- means Windows 7 media have no such icon and the drawn or macOS \
        one stays (IE's Add to Favorites, the battery, Notes, Mobility Center).
        """

    public static let taskbarInfo = """
        The taskbar and the Start menu keep their settings in the shell's defaults (com.win7mac.shell):

        pinnedApps: the taskbar's pinned programs (right-click a button: Pin this program to taskbar)
        startPins, recentApps: the Start menu's pinned and recently used programs
        W7SoundsDisabled: YES turns the Windows 7 sounds off
        desktopIconSize, desktopAutoArrange, desktopShowIcons, desktopSort: the desktop's View and Sort by choices

        The Start menu's user picture is Assets/icons/user.png and the Start button is Assets/start-orb.png \
        (see Assets/README.md). Restart the shell after changing a value by hand: \
        launchctl kickstart -k gui/$(id -u)/com.win7mac.shell
        """

    public static let gadgetsInfo = """
        Right-click the desktop and choose Gadgets to open the gadget gallery, then pick a gadget to put it on \
        the desktop. Drag a gadget to move it; the × on its toolbar removes it.
        """

    public static let folderOptionsInfo = """
        Finder's own options are in Finder > Settings (Command+Comma in a Finder window): what the desktop shows, \
        new window folders, tags, sidebar items and file name extensions. To show or hide hidden files, press \
        Command+Shift+Period in a Finder window.
        """

    /// Calculator's Help ▸ View Help.
    public static let calculatorInfo = """
        Calculator is the shell's own Windows 7 Calculator in Standard mode: type numbers and operators with the \
        mouse or the keyboard (Enter or = for equals, Esc for C, Delete for CE, Backspace to erase a digit, @ for the \
        square root, R for 1/x, F9 for the sign, Control+L, R, M, P and Q for MC, MR, MS, M+ and M-). Operations run \
        as you type them, as in Windows: 2 + 3 × 4 = is 20. Edit > Copy and Paste exchange the number on the display \
        with other programs, and View > Digit grouping adds thousands separators. Numbers reach about 3.4e165 \
        (round ones such as 1e128 sooner); beyond that the display shows Overflow.

        The Start menu's Calculator and Programs > Calculator open it. The macOS Calculator app stays in the Start \
        menu's All Programs.
        """

    /// Screen Resolution's "What display settings should I choose?" as a Control Panel info page: the fallback when the
    /// Help topic (HelpTopics.displaySettingsTopic) is missing.
    public static let displaySettingsInfo = """
        Screen Resolution lists the modes macOS offers for each display, largest first. The recommended one is the \
        mode macOS itself uses by default (on a Retina display a scaled mode, which looks sharpest); a "low \
        resolution" mode is the same size drawn without Retina scaling. After you choose a resolution and click \
        Apply or OK, the display changes and you have 15 seconds to keep it: if you don't click Keep changes, the \
        previous resolution comes back on its own. Advanced settings opens the Displays pane of System Settings \
        (refresh rate, arrangement, colour profile); "Make text and other items larger or smaller" opens \
        Accessibility settings.
        """

    /// Device Manager's Help (until the shell has a Help and Support window).
    public static let deviceManagerInfo = """
        Device Manager and Devices and Printers list this Mac's hardware as macOS reports it: each time one of them \
        opens, the shell asks /usr/sbin/system_profiler once for the audio, Bluetooth, camera, display, disk, USB, \
        network, processor, battery and printer information, and shows the names it finds. Both are viewers: \
        nothing here installs, updates or removes a driver or changes a setting, and serial numbers and network \
        addresses are not kept.

        To add a Bluetooth device, use Add a device; to add a printer, Add a printer (both open System Settings). \
        System Information (in Utilities) shows every detail macOS knows about a device.
        """

    /// Personalization's "Window Color".
    public static let windowColorInfo = """
        The window frames keep the Windows 7 Aero glass colour ("Sky") that the Win7Chrome library draws; there is \
        no colour to choose yet. macOS's own accent and highlight colours are in System Settings > Appearance.
        """

    /// Personalization's "Change desktop icons".
    public static let desktopIconsInfo = """
        The desktop shows the files in your Desktop folder and the Recycle Bin. Right-click the desktop and use \
        View > Show desktop icons to show or hide them, and View > Large, Medium or Small icons for their size. \
        A file's own icon comes from Finder (Get Info); the Windows 7 icons come from your imported Assets/icons.
        """

    /// Personalization's "Change mouse pointers".
    public static let mousePointersInfo = """
        Win7Mac draws the Windows 7 Aero pointers (arrow, text select, link select, resize) in its own windows and \
        in the apps it decorates: your imported Assets/cursors (from make import-assets) where present, drawn ones \
        otherwise. defaults write -g W7ProceduralCursorsDisabled -bool YES turns them off. The pointer's size and \
        colour are in System Settings > Accessibility > Display > Pointer.
        """

    // MARK: Items

    /// Older icon names some items fall back to (scripts/win7-icon-map.txt).
    static let sharedIconNames: [String: String] = [
        "network-sharing-center": "network", "devices-printers": "devices", "system": "computer",
        "administrative-tools": "drive-system", "folder-options": "folder", "programs-features": "file-app",
        "backup-restore": "drive", "autoplay": "drive-optical", "calculator": "app-com.apple.calculator",
    ]

    public static let items: [ControlPanelItem] = systemItems + accountAndNetworkItems + appearanceItems
        + hardwareItems + regionProgramsAccessItems + otherItems

    private static let systemItems: [ControlPanelItem] = [
        ControlPanelItem(id: "action-center", title: "Action Center", categories: [.systemAndSecurity],
                         action: pane(Pane.notifications), tasks: [
                            ControlPanelLink("Review your computer's status and resolve issues", pane(Pane.privacySecurity)),
                            ControlPanelLink("Change User Account Control settings", pane(Pane.privacySecurity)),
                            ControlPanelLink("Troubleshoot common computer problems", diskUtility),
                            ControlPanelLink("Restore your computer to an earlier time", pane(Pane.timeMachine)),
                         ], keywords: ["Notifications", "Security", "Maintenance"]),
        ControlPanelItem(id: "windows-firewall", title: "Windows Firewall", categories: [.systemAndSecurity],
                         action: pane(Pane.network), tasks: [ControlPanelLink("Check firewall status", pane(Pane.network))],
                         keywords: ["Firewall", "Network"]),
        ControlPanelItem(id: "system", title: "System", categories: [.systemAndSecurity],
                         action: pane(Pane.about), tasks: [
                            ControlPanelLink("View amount of RAM and processor speed", systemInformation),
                            ControlPanelLink("Allow remote access", pane(Pane.sharing)),
                            ControlPanelLink("See the name of this computer", pane(Pane.about)),
                            ControlPanelLink("Device Manager", .shellWindow(.deviceManager)),
                         ], keywords: ["About This Mac", "System Information", "Computer name"]),
        ControlPanelItem(id: "windows-update", title: "Windows Update", categories: [.systemAndSecurity],
                         action: pane(Pane.softwareUpdate), tasks: [
                            ControlPanelLink("Turn automatic updating on or off", pane(Pane.softwareUpdate)),
                            ControlPanelLink("Check for updates", pane(Pane.softwareUpdate)),
                            ControlPanelLink("View installed updates", systemInformation),
                         ], keywords: ["Software Update"]),
        ControlPanelItem(id: "power-options", title: "Power Options", categories: [.systemAndSecurity, .hardwareAndSound],
                         action: pane(Pane.battery), tasks: [
                            ControlPanelLink("Require a password when the computer wakes", pane(Pane.lockScreen)),
                            ControlPanelLink("Change what the power buttons do", pane(Pane.battery)),
                            ControlPanelLink("Change when the computer sleeps", pane(Pane.battery)),
                         ], keywords: ["Battery", "Energy", "Sleep"]),
        ControlPanelItem(id: "backup-restore", title: "Backup and Restore", categories: [.systemAndSecurity],
                         action: pane(Pane.timeMachine), tasks: [
                            ControlPanelLink("Back up your computer", pane(Pane.timeMachine)),
                            ControlPanelLink("Restore files from backup", systemApp("Time Machine")),
                         ], keywords: ["Time Machine"]),
        ControlPanelItem(id: "bitlocker", title: "BitLocker Drive Encryption", categories: [.systemAndSecurity],
                         action: pane(Pane.privacySecurity), tasks: [
                            ControlPanelLink("Protect your computer by encrypting data on your disk", pane(Pane.privacySecurity)),
                         ], keywords: ["FileVault", "Encryption"]),
        ControlPanelItem(id: "administrative-tools", title: "Administrative Tools", categories: [.systemAndSecurity],
                         action: .finder("/System/Applications/Utilities"), tasks: [
                            ControlPanelLink("Free up disk space", pane(Pane.storage)),
                            ControlPanelLink("Create and format hard disk partitions", diskUtility),
                            ControlPanelLink("View event logs", utility("Console")),
                         ], keywords: ["Utilities", "Storage", "Disk Utility", "Console"]),
    ]

    private static let accountAndNetworkItems: [ControlPanelItem] = [
        ControlPanelItem(id: "user-accounts", title: "User Accounts", categories: [.userAccounts],
                         action: pane(Pane.usersGroups), tasks: [
                            ControlPanelLink("Change your account picture", pane(Pane.usersGroups)),
                            ControlPanelLink("Add or remove user accounts", pane(Pane.usersGroups)),
                            ControlPanelLink("Change your Windows password", pane(Pane.touchIDPassword)),
                         ], keywords: ["Users & Groups", "Password", "Login"]),
        ControlPanelItem(id: "parental-controls", title: "Parental Controls", categories: [.userAccounts],
                         action: pane(Pane.screenTime), tasks: [
                            ControlPanelLink("Set up parental controls for any user", pane(Pane.screenTime)),
                         ], keywords: ["Screen Time", "Family Safety"]),
        ControlPanelItem(id: "credential-manager", title: "Credential Manager", categories: [.userAccounts],
                         action: systemApp("Passwords"), tasks: [
                            ControlPanelLink("Manage Windows Credentials", systemApp("Passwords")),
                         ], keywords: ["Passwords", "Keychain"]),
        ControlPanelItem(id: "network-sharing-center", title: "Network and Sharing Center", categories: [.networkAndInternet],
                         action: pane(Pane.network), tasks: [
                            ControlPanelLink("View network status and tasks", pane(Pane.network)),
                            ControlPanelLink("Connect to a network", pane(Pane.wifi)),
                         ], keywords: ["Network", "Wi-Fi", "Ethernet", "VPN"]),
        ControlPanelItem(id: "homegroup", title: "HomeGroup", categories: [.networkAndInternet],
                         action: pane(Pane.sharing), tasks: [
                            ControlPanelLink("Choose homegroup and sharing options", pane(Pane.sharing)),
                         ], keywords: ["Sharing", "File Sharing", "AirDrop"]),
        ControlPanelItem(id: "internet-options", title: "Internet Options", categories: [.networkAndInternet],
                         action: safari, tasks: [
                            ControlPanelLink("Change your homepage", safari),
                            ControlPanelLink("Delete browsing history and cookies", safari),
                         ], keywords: ["Safari", "Browser", "Internet Explorer"]),
    ]

    private static let appearanceItems: [ControlPanelItem] = [
        ControlPanelItem(id: "personalization", title: "Personalization", categories: [.appearance],
                         action: .shellWindow(.personalization), tasks: [
                            ControlPanelLink("Change the theme", .shellWindow(.personalization)),
                            ControlPanelLink("Change desktop background", .shellWindow(.desktopBackground)),
                            ControlPanelLink("Change window glass colors", pane(Pane.appearance)),
                            ControlPanelLink("Change sound effects", pane(Pane.sound)),
                            ControlPanelLink("Change screen saver", pane(Pane.wallpaper)),
                            ControlPanelLink("Get the Windows 7 look", .win7mac(lookInfo)),
                         ], keywords: ["Appearance", "Wallpaper", "Theme", "Screen Saver"]),
        ControlPanelItem(id: "display", title: "Display", categories: [.appearance, .hardwareAndSound],
                         action: pane(Pane.displays), tasks: [
                            ControlPanelLink("Make text and other items larger or smaller", pane(Pane.accessibility)),
                            ControlPanelLink("Adjust resolution", .shellWindow(.screenResolution)),
                            ControlPanelLink("Connect to an external display", .shellWindow(.screenResolution)),
                            ControlPanelLink("Change display settings", pane(Pane.displays)),
                         ], keywords: ["Displays", "Resolution", "Monitor"]),
        ControlPanelItem(id: "desktop-gadgets", title: "Desktop Gadgets", categories: [.appearance, .programs],
                         action: .win7mac(gadgetsInfo), tasks: [
                            ControlPanelLink("Add gadgets to the desktop", .win7mac(gadgetsInfo)),
                         ], keywords: ["Gadgets", "Clock", "CPU Meter"]),
        ControlPanelItem(id: "taskbar-start-menu", title: "Taskbar and Start Menu", categories: [.appearance],
                         action: .win7mac(taskbarInfo), tasks: [
                            ControlPanelLink("Customize the Start menu", .win7mac(taskbarInfo)),
                            ControlPanelLink("Customize icons on the taskbar", .win7mac(taskbarInfo)),
                         ], keywords: ["Taskbar", "Start menu", "Pins"]),
        ControlPanelItem(id: "notification-area-icons", title: "Notification Area Icons", categories: [.appearance],
                         action: pane(Pane.controlCenter), tasks: [
                            ControlPanelLink("Show or hide icons in the notification area", pane(Pane.controlCenter)),
                            ControlPanelLink("Change notification settings", pane(Pane.notifications)),
                         ], keywords: ["Control Center", "Menu bar", "Notifications", "Tray"]),
        ControlPanelItem(id: "folder-options", title: "Folder Options", categories: [.appearance],
                         action: .finder("~"), tasks: [
                            ControlPanelLink("Show hidden files and folders", .win7mac(folderOptionsInfo)),
                         ], keywords: ["Finder"]),
        ControlPanelItem(id: "fonts", title: "Fonts", categories: [.appearance],
                         action: systemApp("Font Book"), tasks: [
                            ControlPanelLink("Preview, delete, or show and hide fonts", systemApp("Font Book")),
                         ], keywords: ["Font Book"]),
    ]

    private static let hardwareItems: [ControlPanelItem] = [
        ControlPanelItem(id: "devices-printers", title: "Devices and Printers", categories: [.hardwareAndSound],
                         action: .shellWindow(.devicesAndPrinters), tasks: [
                            ControlPanelLink("Add a device", pane(Pane.bluetooth)),
                            ControlPanelLink("Add a printer", pane(Pane.printers)),
                            ControlPanelLink("Mouse", pane(Pane.mouse)),
                            ControlPanelLink("Device Manager", .shellWindow(.deviceManager)),
                         ], keywords: ["Printers & Scanners", "Bluetooth", "Scanner"]),
        ControlPanelItem(id: "autoplay", title: "AutoPlay", categories: [.hardwareAndSound],
                         action: pane(Pane.cdsAndDVDs), tasks: [
                            ControlPanelLink("Change default settings for media or devices", pane(Pane.cdsAndDVDs)),
                            ControlPanelLink("Play CDs or other media automatically", pane(Pane.cdsAndDVDs)),
                         ], keywords: ["CDs & DVDs"]),
        ControlPanelItem(id: "sound", title: "Sound", categories: [.hardwareAndSound],
                         action: pane(Pane.sound), tasks: [
                            ControlPanelLink("Adjust system volume", pane(Pane.sound)),
                            ControlPanelLink("Change system sounds", pane(Pane.sound)),
                            ControlPanelLink("Manage audio devices", utility("Audio MIDI Setup")),
                         ], keywords: ["Volume", "Speakers", "Microphone"]),
        ControlPanelItem(id: "mobility-center", title: "Windows Mobility Center", categories: [.hardwareAndSound],
                         action: pane(Pane.controlCenter), tasks: [
                            ControlPanelLink("Adjust commonly used mobility settings", pane(Pane.controlCenter)),
                         ], keywords: ["Control Center"]),
        ControlPanelItem(id: "mouse", title: "Mouse", categories: [],
                         action: pane(Pane.mouse), tasks: [
                            ControlPanelLink("Change mouse settings", pane(Pane.mouse)),
                            ControlPanelLink("Change touchpad settings", pane(Pane.trackpad)),
                         ], keywords: ["Trackpad", "Pointer"]),
        ControlPanelItem(id: "keyboard", title: "Keyboard", categories: [],
                         action: pane(Pane.keyboard), tasks: [ControlPanelLink("Change keyboard settings", pane(Pane.keyboard))],
                         keywords: ["Shortcuts", "Input"]),
    ]

    private static let regionProgramsAccessItems: [ControlPanelItem] = [
        ControlPanelItem(id: "date-time", title: "Date and Time", categories: [.clockLanguageRegion],
                         action: pane(Pane.dateTime), tasks: [
                            ControlPanelLink("Set the time and date", pane(Pane.dateTime)),
                            ControlPanelLink("Change the time zone", pane(Pane.dateTime)),
                            ControlPanelLink("Add clocks for different time zones", systemApp("Clock")),
                         ], keywords: ["Clock", "Time zone"]),
        ControlPanelItem(id: "region-language", title: "Region and Language", categories: [.clockLanguageRegion],
                         action: pane(Pane.languageRegion), tasks: [
                            ControlPanelLink("Change location", pane(Pane.languageRegion)),
                            ControlPanelLink("Change the date, time, or number format", pane(Pane.languageRegion)),
                            ControlPanelLink("Change keyboards or other input methods", pane(Pane.keyboard)),
                            ControlPanelLink("Change display language", pane(Pane.languageRegion)),
                         ], keywords: ["Language & Region", "Input sources"]),
        ControlPanelItem(id: "programs-features", title: "Programs and Features", categories: [.programs],
                         action: .finder("/Applications"), tasks: [
                            ControlPanelLink("Uninstall a program", .finder("/Applications")),
                            ControlPanelLink("View installed updates", systemInformation),
                         ], keywords: ["Applications", "Uninstall"]),
        ControlPanelItem(id: "default-programs", title: "Default Programs", categories: [.programs],
                         action: pane(Pane.desktopDock), tasks: [
                            ControlPanelLink("Set your default programs", pane(Pane.desktopDock)),
                            ControlPanelLink("Change default settings for media or devices", pane(Pane.cdsAndDVDs)),
                         ], keywords: ["Default web browser", "Desktop & Dock"]),
        // The shell's Windows 7 Calculator.
        ControlPanelItem(id: "calculator", title: "Calculator", categories: [.programs],
                         action: .shellWindow(.calculator), tasks: [
                            ControlPanelLink("Open Calculator", .shellWindow(.calculator)),
                         ], keywords: ["Calc", "Arithmetic", "Accessories"]),
        ControlPanelItem(id: "ease-of-access-center", title: "Ease of Access Center", categories: [.easeOfAccess, .appearance],
                         action: pane(Pane.accessibility), tasks: [
                            ControlPanelLink("Let Windows suggest settings", pane(Pane.accessibility)),
                            ControlPanelLink("Optimize visual display", pane(Pane.accessibility)),
                            ControlPanelLink("Replace sounds with visual cues", pane(Pane.accessibility)),
                            ControlPanelLink("Change how your mouse works", pane(Pane.accessibility)),
                            ControlPanelLink("Change how your keyboard works", pane(Pane.accessibility)),
                         ], keywords: ["Accessibility", "VoiceOver", "Zoom"]),
        ControlPanelItem(id: "speech-recognition", title: "Speech Recognition", categories: [.easeOfAccess],
                         action: pane(Pane.siri), tasks: [
                            ControlPanelLink("Start speech recognition", pane(Pane.keyboard)),
                            ControlPanelLink("Set up a microphone", pane(Pane.sound)),
                         ], keywords: ["Siri", "Dictation", "Voice"]),
    ]

    /// Windows 7 lists these only in the icon views ("All Control Panel Items").
    private static let otherItems: [ControlPanelItem] = [
        ControlPanelItem(id: "getting-started", title: "Getting Started", categories: [], action: .win7mac(lookInfo),
                         keywords: ["Win7Mac", "Import"]),
        ControlPanelItem(id: "indexing-options", title: "Indexing Options", categories: [], action: pane(Pane.spotlight),
                         keywords: ["Spotlight", "Search"]),
        ControlPanelItem(id: "color-management", title: "Color Management", categories: [],
                         action: utility("ColorSync Utility"), keywords: ["ColorSync", "Color profiles"]),
        ControlPanelItem(id: "performance", title: "Performance Information and Tools", categories: [],
                         action: utility("Activity Monitor"), keywords: ["Activity Monitor", "Task Manager"]),
        ControlPanelItem(id: "troubleshooting", title: "Troubleshooting", categories: [], action: diskUtility,
                         keywords: ["First Aid", "Disk Utility"]),
        ControlPanelItem(id: "recovery", title: "Recovery", categories: [], action: pane(Pane.timeMachine),
                         keywords: ["Time Machine", "Restore"]),
        ControlPanelItem(id: "location-sensors", title: "Location and Other Sensors", categories: [],
                         action: pane(Pane.privacySecurity), keywords: ["Location Services", "Privacy"]),
        ControlPanelItem(id: "sync-center", title: "Sync Center", categories: [], action: pane(Pane.appleAccount),
                         keywords: ["iCloud", "Apple Account"]),
    ]

    /// The items a category page lists, in catalog order.
    public static func items(in category: ControlPanelCategory, from items: [ControlPanelItem] = items) -> [ControlPanelItem] {
        items.filter { $0.categories.contains(category) }
    }

    /// Every item once, by title, for the icon views.
    public static func allItemsSorted(_ items: [ControlPanelItem] = items) -> [ControlPanelItem] {
        items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
