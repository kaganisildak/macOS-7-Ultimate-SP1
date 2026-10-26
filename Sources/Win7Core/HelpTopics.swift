import Foundation

// The topics of the shell's "Windows Help and Support" window. Written for this project: how the
// taskbar, the Start menu, Explorer, Control Panel, your own Windows 7 assets and the switches work here. Plain
// text; links go to other topics, Control Panel items (by catalogue id) or the shell's own windows.

/// Where a Help link goes.
public enum HelpLinkTarget: Hashable, Sendable {
    case topic(String)
    /// A Control Panel item, by its ControlPanelCatalog id: choosing it does what the item does.
    case controlPanel(String)
    case window(ShellWindowTarget)
    /// The Help home page.
    case home
    /// "Browse Help topics".
    case browse
    /// The project README (bundled with the shell).
    case readme

    private static let scheme = "w7help"

    /// The link as the window's text carries it: `w7help://topic/<id>`, `w7help://cp/<id>`, `w7help://window/<id>`,
    /// `w7help://home`, `w7help://browse`, `w7help://readme`.
    public var url: URL {
        let path: String
        switch self {
        case .topic(let id): path = "topic/" + id
        case .controlPanel(let id): path = "cp/" + id
        case .window(let t): path = "window/" + t.rawValue
        case .home: path = "home"
        case .browse: path = "browse"
        case .readme: path = "readme"
        }
        return URL(string: "\(Self.scheme)://\(path)")!
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host else { return nil }
        let arg = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        switch (host, arg.isEmpty) {
        case ("home", true): self = .home
        case ("browse", true): self = .browse
        case ("readme", true): self = .readme
        case ("topic", false): self = .topic(arg)
        case ("cp", false): self = .controlPanel(arg)
        case ("window", false):
            guard let t = ShellWindowTarget(rawValue: arg) else { return nil }
            self = .window(t)
        default: return nil
        }
    }
}

public struct HelpLink: Hashable, Sendable {
    public var title: String
    public var target: HelpLinkTarget
    public init(_ title: String, _ target: HelpLinkTarget) { self.title = title; self.target = target }
}

/// The groups "Browse Help topics" lists, in this order.
public enum HelpCategory: String, CaseIterable, Hashable, Sendable {
    case gettingStarted, desktop, files, settings, customizing, support

    public var title: String {
        switch self {
        case .gettingStarted: "Getting started"
        case .desktop: "Desktop, taskbar and Start menu"
        case .files: "Files, folders and programs"
        case .settings: "Control Panel and devices"
        case .customizing: "Windows 7 pictures, sounds and switches"
        case .support: "Getting help"
        }
    }
}

public struct HelpTopic: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// One line under the title in lists and search results.
    public var summary: String
    public var category: HelpCategory
    /// Paragraphs; one starting with "• " is a list item.
    public var body: [String]
    /// "Open" and "See also" links under the text.
    public var links: [HelpLink]

    public init(id: String, title: String, summary: String, category: HelpCategory, body: [String], links: [HelpLink] = []) {
        self.id = id; self.title = title; self.summary = summary; self.category = category; self.body = body; self.links = links
    }

    /// Everything search looks at.
    public var searchText: String { ([title, summary] + body + links.map(\.title)).joined(separator: "\n") }
}

/// The page the Help window shows.
public enum HelpLocation: Hashable, Sendable {
    case home
    case browse
    case topic(String)
    case search(String)
}

/// Back and Forward, as the Control Panel's.
public struct HelpHistory: Equatable, Sendable {
    public static let limit = 50
    public private(set) var back: [HelpLocation] = []
    public private(set) var current: HelpLocation
    public private(set) var forward: [HelpLocation] = []

    public init(_ start: HelpLocation = .home) { current = start }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Goes to `location`; false (and nothing changes) when it is already the current page.
    @discardableResult public mutating func navigate(to location: HelpLocation) -> Bool {
        guard location != current else { return false }
        back.append(current)
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        current = location
        forward = []
        return true
    }

    @discardableResult public mutating func goBack() -> Bool {
        guard let previous = back.popLast() else { return false }
        forward.append(current)
        current = previous
        return true
    }

    @discardableResult public mutating func goForward() -> Bool {
        guard let next = forward.popLast() else { return false }
        back.append(current)
        current = next
        return true
    }
}

public enum HelpTopics {
    // MARK: Home page

    /// "Not sure where to start?"
    public static let homeStartLinks: [HelpLink] = [
        HelpLink("How to get started with your computer", .topic("getting-started")),
        HelpLink("Learn about Windows Basics", .topic("windows-basics")),
        HelpLink("Browse Help topics", .browse),
    ]
    /// "More on the Windows website": this project's README, which comes with the shell (nothing online).
    public static let websiteLink = HelpLink("Read the Win7Mac README for setup, switches and what changed", .readme)
    /// The footer's "More support options".
    public static let moreSupportLink = HelpLink("More support options", .topic("more-support"))

    // MARK: Lookup and search

    public static func topic(_ id: String) -> HelpTopic? { all.first { $0.id == id } }

    public static func topics(in category: HelpCategory) -> [HelpTopic] { all.filter { $0.category == category } }

    /// Every category with its topics, in order (Browse Help topics).
    public static func browse() -> [(category: HelpCategory, topics: [HelpTopic])] {
        HelpCategory.allCases.map { ($0, topics(in: $0)) }
    }

    /// Every link of every topic and of the home page.
    public static var allLinks: [HelpLink] { homeStartLinks + [websiteLink, moreSupportLink] + all.flatMap(\.links) }

    /// Topics matching `query` (case- and diacritic-insensitive, also in tr_TR, as the Start menu's search): rank 0 a
    /// title prefix, 1 a title word prefix, 2 a title substring, 3 the summary, text or links. Ties keep topic order;
    /// an empty query matches nothing.
    public static func search(_ query: String, in topics: [HelpTopic] = all) -> [HelpTopic] {
        let q = AppCatalog.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return [] }
        var ranked: [(rank: Int, index: Int, topic: HelpTopic)] = []
        for (i, topic) in topics.enumerated() {
            let t = AppCatalog.fold(topic.title)
            let rank: Int
            if t.hasPrefix(q) { rank = 0 }
            else if t.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "," || $0 == ":" }).contains(where: { $0.hasPrefix(q) }) { rank = 1 }
            else if t.contains(q) { rank = 2 }
            else if AppCatalog.fold(topic.searchText).contains(q) { rank = 3 }
            else { continue }
            ranked.append((rank, i, topic))
        }
        ranked.sort { ($0.rank, $0.index) < ($1.rank, $1.index) }
        return ranked.map(\.topic)
    }

    // MARK: Topics

    public static let all: [HelpTopic] = gettingStarted + desktop + files + settings + customizing + support

    private static let gettingStarted: [HelpTopic] = [
        HelpTopic(id: "getting-started", title: "How to get started with your computer",
                  summary: "What Win7Mac changes on this Mac and the first things to try.", category: .gettingStarted, body: [
            "Win7Mac makes this Mac look and work like Windows 7. Two parts do it: the shell, a background program that draws the desktop, the taskbar, the Start menu, Control Panel and this Help window, and the Win7Chrome library, which gives the windows of other programs their Aero frames, menu bars and toolbars.",
            "Everything underneath is still macOS: your programs, files and settings are the same, and Finder is what you see as Windows Explorer.",
            "Good first steps:",
            "• Click the Start button (or press Ctrl+Esc) and type the name of a program to open it.",
            "• Right-click a program on the taskbar to see its jump list: recent documents and the program's tasks.",
            "• Open Computer from the Start menu to see your drives the way Windows 7 shows them.",
            "• Open Control Panel to find settings by Windows 7 names; each item opens the macOS setting that does the job.",
            "• Install the pictures, icons and sounds from your own copy of Windows 7, so everything looks right.",
        ], links: [
            HelpLink("Learn about Windows Basics", .topic("windows-basics")),
            HelpLink("Installing your Windows 7 pictures, icons, sounds and fonts", .topic("installing")),
            HelpLink("Getting Started (Control Panel)", .controlPanel("getting-started")),
        ]),
        HelpTopic(id: "windows-basics", title: "Windows Basics: the parts of the screen",
                  summary: "The desktop, the taskbar, the Start menu and windows, and where to read more.", category: .gettingStarted, body: [
            "The desktop is the large area behind your windows. Its icons are the files and folders in your Desktop folder, plus Computer and the Recycle Bin.",
            "The taskbar runs along the bottom of the screen. It holds the Start button, a button for each pinned or running program, the notification area with the clock, and the Show desktop strip at the far right.",
            "The Start menu opens from the Start button. It lists your pinned and recently used programs on the left, and your folders, Computer, Control Panel and Help on the right.",
            "Every program window has the Windows 7 frame: the title bar with the Minimize, Maximize and Close buttons, and a menu bar inside the window instead of at the top of the screen.",
        ], links: [
            HelpLink("Using the taskbar", .topic("taskbar")),
            HelpLink("Using the Start menu", .topic("start-menu")),
            HelpLink("Using the desktop", .topic("desktop")),
            HelpLink("Moving, snapping and switching windows", .topic("windows")),
            HelpLink("Working with files in Windows Explorer", .topic("explorer")),
            HelpLink("Finding settings in Control Panel", .topic("control-panel")),
        ]),
    ]

    private static let desktop: [HelpTopic] = [
        HelpTopic(id: "taskbar", title: "Using the taskbar",
                  summary: "Pinned programs, running programs, jump lists, thumbnails and Aero Peek.", category: .desktop, body: [
            "Each program has one button. A pinned program keeps its button when it is not running; a running program's button has a glass frame, and the active one is brighter.",
            "• Click a button to open the program, switch to it, or minimize its window when it is already in front.",
            "• Point at a running program's button to see thumbnails of its windows; point at a thumbnail to see that window alone.",
            "• Right-click a button for its jump list: Frequent folders (Windows Explorer), Recent documents, and Pin or Unpin, Close window or Close all windows.",
            "• Drag a button to move it along the taskbar.",
            "The notification area at the right shows the network, volume and battery icons and the clock; click the clock for the calendar. Point at the Show desktop strip at the far right to see through your windows (Aero Peek), and click it to show the desktop.",
            "The taskbar keeps its pinned programs in the shell's settings (pinnedApps); new windows are kept clear of it, so nothing ends up underneath.",
        ], links: [
            HelpLink("Taskbar and Start Menu", .controlPanel("taskbar-start-menu")),
            HelpLink("Notification Area Icons", .controlPanel("notification-area-icons")),
            HelpLink("Using jump lists", .topic("jump-lists")),
        ]),
        HelpTopic(id: "start-menu", title: "Using the Start menu",
                  summary: "Pinned and recent programs, All Programs, search, and the right column.", category: .desktop, body: [
            "Click the Start button or press Ctrl+Esc. The left side lists your pinned programs at the top and the programs you used last under them (up to ten). Programs you open from the Dock, Finder or Spotlight are counted too.",
            "• Right-click a program to pin it to the Start menu or the taskbar, open its file location, or remove it from the list.",
            "• A program with recent documents shows a small arrow at the right of its row when you point at it. Point at the arrow, or click it, to see those documents.",
            "• All Programs lists every program in your Applications folders, with folders that open in place.",
            "• Type in the search box to find programs, documents and other files at once.",
            "The right column opens your user folder, Documents, Pictures, Music and Downloads, Computer, Control Panel, Devices and Printers, Default Programs and this Help window. Run… opens the Run box.",
            "On first use the Start menu pins Windows Explorer, Safari, Calculator, Notes, Terminal and Preview. After that the list is yours: pins you add or remove stay as you left them.",
        ], links: [
            HelpLink("Searching for programs and files", .topic("searching")),
            HelpLink("Shutting down, sleeping and logging off", .topic("shut-down")),
            HelpLink("Taskbar and Start Menu", .controlPanel("taskbar-start-menu")),
        ]),
        HelpTopic(id: "searching", title: "Searching for programs and files",
                  summary: "Find programs, documents and files from the Start menu's search box.", category: .desktop, body: [
            "Open the Start menu and start typing; the search box gets the letters even before you click it. Programs come first, then Documents and other Files from your home folder, found by Spotlight.",
            "Matches ignore case and accents, and Turkish letters too: typing \"ins\" finds Instruments even when the Mac's language is Turkish.",
            "Press Enter to open the highlighted result, or use the arrow keys to choose another. See more results opens a Finder search for the same words. Click the × in the box to clear it.",
            "Control Panel and this Help window have search boxes of their own that work the same way.",
        ], links: [
            HelpLink("Indexing Options", .controlPanel("indexing-options")),
        ]),
        HelpTopic(id: "desktop", title: "Using the desktop",
                  summary: "Desktop icons, the right-click menu, gadgets and the Recycle Bin.", category: .desktop, body: [
            "The desktop shows the files and folders in your Desktop folder, plus Computer and the Recycle Bin. Double-click an icon to open it, drag icons to arrange them, and drag files to the Recycle Bin to delete them.",
            "Right-click an empty part of the desktop for View (icon size, Auto arrange icons, Align icons to grid, Show desktop icons), Sort by, Refresh, Paste, New (Folder, Shortcut, Text Document, Rich Text Document), Screen resolution, Gadgets and Personalize.",
            "Right-click an icon for Open, Cut, Copy, Create shortcut, Delete, Rename and Properties.",
        ], links: [
            HelpLink("Personalization", .controlPanel("personalization")),
            HelpLink("Display", .controlPanel("display")),
            HelpLink("Desktop Gadgets", .controlPanel("desktop-gadgets")),
        ]),
        HelpTopic(id: "windows", title: "Moving, snapping and switching windows",
                  summary: "Snap windows to the screen's edges, switch with Option+Tab, and shake to tidy.", category: .desktop, body: [
            "Drag a window's title bar to move it. Drag it to the left or right edge of the screen to fill that half, or to the top to maximize it; drag it away to restore it. The same works from the keyboard with Win+arrow keys.",
            "Hold Option and press Tab to switch between windows; keep Option down and press Tab again to move on, Shift+Tab to go back, and let go of Option to choose. Esc cancels.",
            "Grab a title bar and shake the window left and right to minimize every other window (Aero Shake); shake again to bring them back.",
            "Snapping and moving other programs' windows needs the Accessibility permission for Win7Shell (System Settings ▸ Privacy & Security ▸ Accessibility).",
        ], links: [
            HelpLink("Keyboard shortcuts", .topic("keyboard")),
        ]),
        HelpTopic(id: "keyboard", title: "Keyboard shortcuts",
                  summary: "Start, Snap, switching and the Win key shortcuts on a Mac keyboard.", category: .desktop, body: [
            "A Mac keyboard has no Windows logo key, so Control+Option stands for it here (written Win below). Option is Alt.",
            "• Ctrl+Esc: open or close the Start menu.",
            "• Win+Left, Win+Right, Win+Up, Win+Down: snap the window left or right, maximize it, restore or minimize it.",
            "• Option+Tab, Option+Shift+Tab: switch windows.",
            "• Win+D: show the desktop. Win+Space: peek at the desktop while held. Win+M: minimize all; Win+Shift+M: restore them.",
            "• Win+E: open Windows Explorer. Win+R: Run. Win+L: lock the computer. Win+T: move through the taskbar buttons.",
            "• Win+1 to Win+9: open or switch to the program at that place on the taskbar.",
            "• Win+Home: minimize every window but the active one. Win+Shift+Left or Right: move the window to the other screen.",
            "• Option+F4 or Cmd+W: close a shell window such as Control Panel or this one.",
        ]),
        HelpTopic(id: "shut-down", title: "Shutting down, sleeping and logging off",
                  summary: "The Start menu's Shut down button and the choices next to it.", category: .desktop, body: [
            "Click Shut down at the bottom of the Start menu to turn the computer off. The arrow next to it offers Switch user (when fast user switching is on), Log off, Lock, Restart and Sleep.",
            "Programs with unsaved work ask before they quit, as they always do on a Mac.",
        ], links: [
            HelpLink("Power Options", .controlPanel("power-options")),
        ]),
    ]

    private static let files: [HelpTopic] = [
        HelpTopic(id: "explorer", title: "Working with files in Windows Explorer",
                  summary: "Finder windows as Windows Explorer: the command bar, navigation pane and details pane.", category: .files, body: [
            "Windows Explorer here is Finder with the Windows 7 look. The Back and Forward buttons and the address bar are at the top, the command bar (Organize, views, and commands for the selection) under them, the navigation pane with your favourite folders, drives and Computer on the left, and the details pane at the bottom.",
            "Everything you do in it is done by Finder: copying, moving, renaming and deleting work as they always have, and the keyboard shortcuts are Finder's.",
            "Double-click a folder to open it; use the address bar's arrows to jump to a folder higher up. Right-click a file for its menu.",
        ], links: [
            HelpLink("Seeing your drives in Computer", .topic("computer")),
            HelpLink("Folder Options", .controlPanel("folder-options")),
        ]),
        HelpTopic(id: "computer", title: "Seeing your drives in Computer",
                  summary: "The Computer window: your disks with their free space, and removable drives.", category: .files, body: [
            "Computer shows your drives as Windows 7 does: Hard Disk Drives first, then Devices with Removable Storage and network locations, each with a bar for the space used and the free space under it.",
            "Open it from the Start menu, from the desktop's Computer icon, or with Win+E and the Computer entry in the navigation pane. Double-click a drive to open it. The command bar has System properties, Uninstall or change a program, Map network drive and Open Control Panel.",
            "Computer only reads the drives' names and sizes; it never changes a disk.",
        ], links: [
            HelpLink("System", .controlPanel("system")),
            HelpLink("Device Manager", .window(.deviceManager)),
        ]),
        HelpTopic(id: "jump-lists", title: "Using jump lists",
                  summary: "Open recent documents and folders straight from the taskbar or the Start menu.", category: .files, body: [
            "A jump list is the list of things you open often with a program. Right-click a program's taskbar button to see it, or point at the arrow next to the program in the Start menu.",
            "Recent lists the documents macOS remembers for that program; Windows Explorer's Frequent lists the folders you opened last. Click one to open it with that program.",
            "The taskbar's jump list also has the program's tasks: open it, pin or unpin it, and close its windows.",
        ], links: [
            HelpLink("Using the taskbar", .topic("taskbar")),
            HelpLink("Using the Start menu", .topic("start-menu")),
        ]),
    ]

    private static let settings: [HelpTopic] = [
        HelpTopic(id: "control-panel", title: "Finding settings in Control Panel",
                  summary: "Windows 7's Control Panel categories, each opening the macOS setting that does the job.", category: .settings, body: [
            "Control Panel opens from the Start menu. Its home page shows the eight Windows 7 categories, such as System and Security, Appearance and Personalization and Hardware and Sound. Click a category for its items, or a task under it to go straight there.",
            "Use View by (top right) to see every item as large or small icons, or type in the search box to find an item by its Windows 7 name or by the macOS name of the setting.",
            "Most items open the matching pane of System Settings or a Mac utility. Some open the shell's own windows, such as Device Manager and Devices and Printers. Control Panel itself never changes a setting.",
        ], links: [
            HelpLink("System", .controlPanel("system")),
            HelpLink("Devices and Printers", .controlPanel("devices-printers")),
            HelpLink("Personalization", .controlPanel("personalization")),
            HelpLink("Default Programs", .controlPanel("default-programs")),
        ]),
        HelpTopic(id: "devices", title: "Viewing devices in Device Manager and Devices and Printers",
                  summary: "See the computer's hardware and connected devices; nothing is changed.", category: .settings, body: [
            "Device Manager lists the computer's hardware by type: processors, disk drives, display adapters, network adapters, USB controllers and more. Click the arrow before a type to open it, and double-click a device (or use Properties) to see its details.",
            "Devices and Printers shows the computer, your printers and connected devices such as Bluetooth and USB ones, as large icons.",
            "Both windows only look: they read what macOS reports about the hardware each time they open, and never install, update or switch off a driver. To add a printer or a Bluetooth device, use the links in Devices and Printers, which open System Settings.",
        ], links: [
            HelpLink("Open Device Manager", .window(.deviceManager)),
            HelpLink("Open Devices and Printers", .window(.devicesAndPrinters)),
        ]),
        HelpTopic(id: "personalization", title: "Changing the desktop background and the look",
                  summary: "Wallpaper, screen resolution, sounds and the Windows 7 themes.", category: .settings, body: [
            "Right-click the desktop and choose Personalize, or open Control Panel ▸ Appearance and Personalization, to change the desktop background and the window look.",
            "Screen resolution on the same menu changes how large everything on the display looks.",
            "The Windows 7 wallpapers, sounds and Start button come from your own copy of Windows 7.",
        ], links: [
            HelpLink("Personalization", .controlPanel("personalization")),
            HelpLink("Display", .controlPanel("display")),
            HelpLink("Sound", .controlPanel("sound")),
            HelpLink("Installing your Windows 7 pictures, icons, sounds and fonts", .topic("installing")),
        ]),
        HelpTopic(id: displaySettingsTopic, title: "What display settings should I choose?",
                  summary: "Picking a resolution in Screen Resolution, and getting the old one back.", category: .settings, body: [
            "Screen Resolution lists the modes macOS offers for each display, largest first. The recommended one is the mode macOS itself uses by default: on a Retina display that is a scaled mode, which looks sharpest. A \"low resolution\" mode is the same size drawn without Retina scaling.",
            "After you choose a resolution and click Apply or OK, the display changes and you have 15 seconds to keep it. If you don't click Keep changes, the previous resolution comes back on its own.",
            "• Advanced settings opens the Displays pane of System Settings: refresh rate, arrangement and colour profile.",
            "• \"Make text and other items larger or smaller\" opens Accessibility ▸ Display.",
        ], links: [
            HelpLink("Open Screen Resolution", .window(.screenResolution)),
            HelpLink("Display", .controlPanel("display")),
            HelpLink("Changing the desktop background and the look", .topic("personalization")),
        ]),
    ]

    /// Screen Resolution's "What display settings should I choose?" link opens this topic.
    public static let displaySettingsTopic = "display-settings"

    private static let customizing: [HelpTopic] = [
        HelpTopic(id: "installing", title: "Installing your Windows 7 pictures, icons, sounds and fonts",
                  summary: "Bring the artwork from your own Windows 7 disc or files; Win7Mac includes none.", category: .customizing, body: [
            "Win7Mac comes without any Windows artwork. Until you add your own, it draws its own stand-ins: a blue wallpaper, a drawn Start button, and macOS icons. Everything is taken from your own copy of Windows 7; nothing is downloaded.",
            "In Terminal, in the win7mac folder:",
            "• make import-assets SRC=/path/to/Win7.iso takes the wallpapers, icons, sounds, cursors and fonts from a Windows 7 disc image or folder (7-Zip's 7zz must be installed).",
            "• make wallpaper SRC=/path/to/picture.jpg sets just the wallpaper.",
            "• make import-icons SRC=/path/to/icons.zip converts .ico files you exported yourself.",
            "Then run make install, which copies the files to ~/Library/Application Support/Win7Mac/Assets and the Segoe UI fonts to your Fonts folder. The shell reads the icons when it starts; Finder, Safari and other programs when they next open.",
        ], links: [
            HelpLink("Getting Started (Control Panel)", .controlPanel("getting-started")),
            HelpLink("Fonts", .controlPanel("fonts")),
        ]),
        HelpTopic(id: "switches", title: "Turning parts of the Windows 7 look off",
                  summary: "The defaults switches that turn a feature off without removing anything.", category: .customizing, body: [
            "Each part of the look has a switch, set with the defaults command in Terminal. Switches for other programs take effect when the program next opens; the shell's take effect when it restarts.",
            "• defaults write -g W7ChromeDisabled -bool YES turns the window frames off in every program.",
            "• defaults write -g W7ChromeDenylist -array com.example.app leaves the programs you list alone.",
            "• W7ContextMenusDisabled, W7ToolbarLookDisabled, W7ComputerViewDisabled, W7FrameBorderDisabled and W7MessageBoxDisabled (also with -g) turn off the Windows 7 right-click menus, toolbars, the Computer view, the glass window borders and the message boxes.",
            "• defaults write com.win7mac.shell W7SoundsDisabled -bool YES silences the Windows 7 sounds.",
            "• defaults write com.win7mac.shell W7WorkAreaDisabled -bool YES stops the shell moving windows out from under the taskbar; W7TaskbarLevelLegacy puts the taskbar back on its older window level.",
            "To turn a switch back on, run defaults delete with the same domain and name.",
        ], links: [
            HelpLink("Taskbar and Start Menu", .controlPanel("taskbar-start-menu")),
        ]),
        HelpTopic(id: "removing", title: "Removing Win7Mac and putting macOS back",
                  summary: "make uninstall restores the Dock, the menu bar, the wallpaper and Finder's desktop.", category: .customizing, body: [
            "In Terminal, in the win7mac folder, run make uninstall. It removes the shell, its login item and the Win7Chrome library, and puts back the Dock, the menu bar, the wallpaper, Finder's desktop icons and Terminal's profile as they were before the first install.",
            "Your files and the assets you imported are not deleted.",
        ]),
    ]

    private static let support: [HelpTopic] = [
        HelpTopic(id: "more-support", title: "More support options",
                  summary: "The README, the setup check and the shell's log.", category: .support, body: [
            "The README that comes with Win7Mac explains setup, every switch and what each part changes.",
            "• make setup CHECK=1, in the win7mac folder, checks this Mac without changing anything. Setup's report, build/setup-report.txt, can be shared when asking for help: it leaves out your user name.",
            "• The shell writes what it does to the system log under com.win7mac.shell, and the window library under com.win7mac.chrome; Console shows both.",
            "• If one program misbehaves with the Windows 7 look, put it on the denylist (see Turning parts of the Windows 7 look off) and open it again.",
        ], links: [
            HelpLink("Read the Win7Mac README", .readme),
            HelpLink("When something doesn't look right", .topic("troubleshooting")),
            HelpLink("Turning parts of the Windows 7 look off", .topic("switches")),
        ]),
        HelpTopic(id: "troubleshooting", title: "When something doesn't look right",
                  summary: "Missing icons, a program without its frame, permissions the shell needs.", category: .support, body: [
            "• macOS icons instead of Windows 7 ones: install your Windows 7 assets, then restart the shell and reopen the program.",
            "• A program has no Windows 7 frame: programs that draw their own title bar (such as Chrome and other web-based apps) are left as they are on purpose, and System Settings' security panes and Safari's address field are never changed.",
            "• Thumbnails are blank or windows don't snap: Win7Shell needs Screen Recording and Accessibility in System Settings ▸ Privacy & Security.",
            "• The look is gone everywhere after a macOS update: run make setup CHECK=1 to see what changed.",
        ], links: [
            HelpLink("More support options", .topic("more-support")),
            HelpLink("Action Center", .controlPanel("action-center")),
        ]),
    ]
}
