import Foundation
import CoreGraphics

// the Windows 7 Control Panel, drawn by the shell. Every item only opens something: a System
// Settings pane (x-apple.systempreferences:<extension bundle id>), an application, a Finder folder, a URL or
// one of the shell's own info pages. Nothing here runs commands or changes settings. The table itself is in
// ControlPanelCatalog.swift.

/// What choosing a Control Panel link does.
public enum ControlPanelAction: Hashable, Sendable {
    /// Opens `x-apple.systempreferences:<id>`; the id is a Settings extension's CFBundleIdentifier.
    case settingsPane(String)
    /// Opens the application at this absolute path.
    case app(String)
    /// Opens this folder in Finder; a leading `~` is the home folder.
    case finder(String)
    /// Opens this URL.
    case url(String)
    /// Shows one of the shell's own info pages with this text.
    case win7mac(String)
    /// Opens one of the shell's own windows.
    case shellWindow(ShellWindowTarget)
}

/// The shell's own windows a Control Panel link opens, framed like the Control Panel (ShellWindow).
public enum ShellWindowTarget: String, CaseIterable, Hashable, Sendable {
    case deviceManager, devicesAndPrinters, calculator, personalization, desktopBackground, screenResolution
    /// Windows Help and Support.
    case help

    public var title: String {
        switch self {
        case .deviceManager: "Device Manager"
        case .devicesAndPrinters: "Devices and Printers"
        case .help: "Windows Help and Support"
        case .calculator: "Calculator"
        case .personalization: "Personalization"
        case .desktopBackground: "Desktop Background"
        case .screenResolution: "Screen Resolution"
        }
    }

    /// The window's identifier, which also names its taskbar button (ShellWindowButtons).
    public var identifier: String {
        switch self {
        case .deviceManager: "win7.devicemanager"
        case .devicesAndPrinters: "win7.devicesprinters"
        case .help: "win7.help"
        case .calculator: "win7.calculator"
        case .personalization: "win7.personalization"
        case .desktopBackground: "win7.desktopbackground"
        case .screenResolution: "win7.screenresolution"
        }
    }
}

/// The eight Windows 7 categories, in the order Windows 7 lists them (row by row, two columns).
public enum ControlPanelCategory: String, CaseIterable, Hashable, Sendable {
    case systemAndSecurity, userAccounts, networkAndInternet, appearance, hardwareAndSound, clockLanguageRegion,
         programs, easeOfAccess

    public var title: String {
        switch self {
        case .systemAndSecurity: "System and Security"
        case .userAccounts: "User Accounts"
        case .networkAndInternet: "Network and Internet"
        case .appearance: "Appearance and Personalization"
        case .hardwareAndSound: "Hardware and Sound"
        case .clockLanguageRegion: "Clock, Language, and Region"
        case .programs: "Programs"
        case .easeOfAccess: "Ease of Access"
        }
    }

    /// The icon override, `Assets/icons/<name>.png` (scripts/win7-icon-map.txt), then an older shared name.
    public var iconNames: [String] {
        switch self {
        case .systemAndSecurity: ["cp-system-security", "drive-system"]
        case .userAccounts: ["cp-user-accounts"]
        case .networkAndInternet: ["cp-network-internet", "network"]
        case .appearance: ["cp-appearance"]
        case .hardwareAndSound: ["cp-hardware-sound", "devices"]
        case .clockLanguageRegion: ["cp-clock-region"]
        case .programs: ["cp-programs", "file-app"]
        case .easeOfAccess: ["cp-ease-of-access"]
        }
    }
}

/// A link: a category's sub-link on the home page, or an item's task on a category page.
public struct ControlPanelLink: Hashable, Sendable {
    public var title: String
    public var action: ControlPanelAction
    public init(_ title: String, _ action: ControlPanelAction) { self.title = title; self.action = action }
}

/// One Control Panel item ("Action Center", "Sound", ...).
public struct ControlPanelItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// The category pages it is listed on (Windows 7 lists some items twice); empty: the icon views and
    /// search only.
    public var categories: [ControlPanelCategory]
    /// What its title opens.
    public var action: ControlPanelAction
    /// The task links under its title on a category page.
    public var tasks: [ControlPanelLink]
    /// Extra words search matches (the macOS names, for example).
    public var keywords: [String]

    public init(id: String, title: String, categories: [ControlPanelCategory], action: ControlPanelAction,
                tasks: [ControlPanelLink] = [], keywords: [String] = []) {
        self.id = id; self.title = title; self.categories = categories; self.action = action
        self.tasks = tasks; self.keywords = keywords
    }

    /// `cp-<id>`, then an older shared name for some items.
    public var iconNames: [String] { ["cp-\(id)"] + (ControlPanelCatalog.sharedIconNames[id].map { [$0] } ?? []) }
}

/// How the home page shows the Control Panel ("View by").
public enum ControlPanelViewMode: String, CaseIterable, Sendable {
    case category, largeIcons, smallIcons

    public var title: String {
        switch self {
        case .category: "Category"
        case .largeIcons: "Large icons"
        case .smallIcons: "Small icons"
        }
    }
}

// MARK: - Availability

public enum ControlPanelAvailability {
    public static let extensionsDirectory = "/System/Library/ExtensionKit/Extensions"

    /// Whether `action`'s target exists: a pane whose extension is installed (the bundle at its known path
    /// has that bundle id), an app or folder that exists. URLs, info pages and the shell's windows always do.
    public static func isAvailable(_ action: ControlPanelAction, fileExists: (String) -> Bool,
                                   bundleID: (String) -> String?) -> Bool {
        switch action {
        case .settingsPane(let id):
            guard let appex = ControlPanelCatalog.paneBundles[id] else { return false }
            return bundleID(extensionsDirectory + "/" + appex) == id
        case .app(let path):
            return fileExists(path)
        case .finder(let path):
            return fileExists((path as NSString).expandingTildeInPath)
        case .url, .win7mac, .shellWindow:
            return true
        }
    }

    /// The catalog without what can't open on this Mac: an item whose own target is missing is hidden; a
    /// task or home sub-link whose target is missing is left out.
    public static func filter(_ items: [ControlPanelItem], available: (ControlPanelAction) -> Bool) -> [ControlPanelItem] {
        items.compactMap { item in
            guard available(item.action) else { return nil }
            var item = item
            item.tasks = item.tasks.filter { available($0.action) }
            return item
        }
    }
}

// MARK: - Search

public enum ControlPanelSearch {
    /// Items matching `query` (case- and diacritic-insensitive, also in tr_TR): rank 0 a title prefix,
    /// 1 a title word prefix, 2 a title substring, 3 a task title or keyword substring. Ties keep the
    /// given order; an empty query matches nothing.
    public static func search(_ query: String, in items: [ControlPanelItem]) -> [ControlPanelItem] {
        let q = AppCatalog.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return [] }
        var ranked: [(rank: Int, index: Int, item: ControlPanelItem)] = []
        for (i, item) in items.enumerated() {
            let t = AppCatalog.fold(item.title)
            let rank: Int
            if t.hasPrefix(q) { rank = 0 }
            else if words(t).contains(where: { $0.hasPrefix(q) }) { rank = 1 }
            else if t.contains(q) { rank = 2 }
            else if (item.tasks.map(\.title) + item.keywords).contains(where: { AppCatalog.fold($0).contains(q) }) { rank = 3 }
            else { continue }
            ranked.append((rank, i, item))
        }
        ranked.sort { ($0.rank, $0.index) < ($1.rank, $1.index) }
        return ranked.map(\.item)
    }

    private static func words(_ s: String) -> [Substring] {
        s.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "," || $0 == "/" })
    }
}

// MARK: - Navigation

/// A page of the Control Panel window.
public enum ControlPanelLocation: Hashable, Sendable {
    /// "Control Panel": the categories, or every item in the icon views.
    case home
    case category(ControlPanelCategory)
    /// One of the shell's info pages, reached from `category` (nil: from home or search).
    case info(title: String, text: String, category: ControlPanelCategory?)
}

/// One breadcrumb of the address bar and where clicking it goes.
public struct ControlPanelCrumb: Equatable, Sendable {
    public var title: String
    public var location: ControlPanelLocation
    public init(_ title: String, _ location: ControlPanelLocation) { self.title = title; self.location = location }
}

/// Back/forward history, as Explorer keeps it: navigating somewhere new drops the forward list.
public struct ControlPanelHistory: Equatable, Sendable {
    public static let limit = 50
    public private(set) var back: [ControlPanelLocation] = []
    public private(set) var current: ControlPanelLocation
    public private(set) var forward: [ControlPanelLocation] = []

    public init(_ start: ControlPanelLocation = .home) { current = start }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Goes to `location`; false (and nothing changes) when it is already the current page.
    @discardableResult public mutating func navigate(to location: ControlPanelLocation) -> Bool {
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

    /// The address bar's breadcrumbs for `location` (after the leading ▸). Searching shows "Search
    /// Results" after "Control Panel"; the icon views' home page is "All Control Panel Items".
    public static func breadcrumbs(_ location: ControlPanelLocation, viewMode: ControlPanelViewMode,
                                   searching: Bool = false) -> [ControlPanelCrumb] {
        let root = ControlPanelCrumb("Control Panel", .home)
        if searching { return [root, ControlPanelCrumb("Search Results", location)] }
        switch location {
        case .home:
            return viewMode == .category ? [root] : [root, ControlPanelCrumb("All Control Panel Items", .home)]
        case .category(let c):
            return [root, ControlPanelCrumb(c.title, location)]
        case .info(let title, _, let c):
            return [root] + (c.map { [ControlPanelCrumb($0.title, .category($0))] } ?? []) + [ControlPanelCrumb(title, location)]
        }
    }
}

// MARK: - Layout (flipped: y grows downwards)

public enum ControlPanelLayout {
    public static let taskPaneWidth: CGFloat = 200
    public static let headerHeight: CGFloat = 36
    /// Body padding left, right and below the content.
    public static let margin: CGFloat = 22
    public static let columnGap: CGFloat = 24
    public static let minColumnWidth: CGFloat = 250
    public static let maxColumnWidth: CGFloat = 330
    public static let categoryIcon: CGFloat = 48
    public static let itemIcon: CGFloat = 32
    public static let iconTextGap: CGFloat = 10
    public static let titleLine: CGFloat = 21
    public static let linkLine: CGFloat = 17
    public static let rowGap: CGFloat = 18
    public static let iconGap: CGFloat = 6

    /// Two columns when two of the minimum width fit inside the margins, otherwise one.
    public static func columnCount(width: CGFloat) -> Int {
        width - 2 * margin >= 2 * minColumnWidth + columnGap ? 2 : 1
    }

    public static func columnWidth(width: CGFloat) -> CGFloat {
        let n = CGFloat(columnCount(width: width))
        return max(0, min(maxColumnWidth, (width - 2 * margin - (n - 1) * columnGap) / n))
    }

    /// An entry with an icon, a title line and `links` lines under it.
    public static func cellHeight(links: Int, icon: CGFloat) -> CGFloat {
        max(icon, titleLine + CGFloat(links) * linkLine)
    }

    /// The home page's categories, or a category page's items: entries placed row by row in
    /// `columnCount` columns from `top`; a row is as tall as its tallest entry plus `rowGap`.
    public static func listFrames(linkCounts: [Int], width: CGFloat, top: CGFloat, icon: CGFloat) -> [CGRect] {
        let n = columnCount(width: width), w = columnWidth(width: width)
        var frames: [CGRect] = []
        var y = top
        var i = 0
        while i < linkCounts.count {
            let row = linkCounts[i..<min(i + n, linkCounts.count)]
            let h = row.map { cellHeight(links: $0, icon: icon) }.max() ?? 0
            for (col, links) in row.enumerated() {
                frames.append(CGRect(x: margin + CGFloat(col) * (w + columnGap), y: y, width: w,
                                     height: cellHeight(links: links, icon: icon)))
            }
            y += h + rowGap
            i += n
        }
        return frames
    }

    /// One cell of the icon views: a 32 pt icon left of its title (large), or 16 pt (small).
    public static func iconCellSize(_ mode: ControlPanelViewMode) -> CGSize {
        mode == .smallIcons ? CGSize(width: 210, height: 24) : CGSize(width: 240, height: 42)
    }

    public static func iconSide(_ mode: ControlPanelViewMode) -> CGFloat { mode == .smallIcons ? 16 : 32 }

    public static func iconColumnCount(width: CGFloat, mode: ControlPanelViewMode) -> Int {
        let cell = iconCellSize(mode).width
        return max(1, Int(((width - 2 * margin + iconGap) / (cell + iconGap)).rounded(.down)))
    }

    /// The icon views: `count` cells row by row (Windows 7 fills the rows left to right) from `top`.
    public static func iconFrames(count: Int, width: CGFloat, mode: ControlPanelViewMode, top: CGFloat) -> [CGRect] {
        let n = iconColumnCount(width: width, mode: mode), size = iconCellSize(mode)
        return (0..<max(0, count)).map { i in
            CGRect(x: margin + CGFloat(i % n) * (size.width + iconGap), y: top + CGFloat(i / n) * size.height,
                   width: size.width, height: size.height)
        }
    }

    /// How tall the scrolling body must be to show `frames` with the bottom margin.
    public static func contentHeight(_ frames: [CGRect], top: CGFloat) -> CGFloat {
        (frames.map(\.maxY).max() ?? top) + margin
    }
}
