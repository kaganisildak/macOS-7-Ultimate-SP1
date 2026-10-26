import Foundation

// What the Desktop Background and Personalization windows show and do, without AppKit. The
// pictures come from the user's own Windows 7 media (scripts/import-win7-assets.sh writes Assets/wallpapers/<Theme>/)
// and from ~/Pictures; the shell sets the chosen one with NSWorkspace.setDesktopImageURL (WallpaperPosition gives
// its options). The slideshow is a shell timer around WallpaperPlayer.

/// A solid desktop colour, `0xRRGGBB`.
public struct SolidColor: Hashable, Sendable, Codable {
    public var hex: UInt32
    public init(_ hex: UInt32) { self.hex = hex & 0xFFFFFF }

    public var red: Double { Double((hex >> 16) & 0xFF) / 255 }
    public var green: Double { Double((hex >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(hex & 0xFF) / 255 }
    /// "#3A6EA5".
    public var hexString: String { String(format: "#%06X", hex) }
    /// The small picture the shell writes for this colour (macOS sets pictures, not colours): `solid-3A6EA5.png`.
    public var fileName: String { "solid-" + String(hexString.dropFirst()) + ".png" }
}

/// One cell of the Desktop Background grid.
public enum WallpaperItem: Hashable, Sendable, Codable {
    case picture(URL)
    case color(SolidColor)

    public var pictureURL: URL? { if case .picture(let u) = self { u } else { nil } }
    /// The name under a picture (its file name without the extension), or the colour's hex.
    public var name: String {
        switch self {
        case .picture(let u): u.deletingPathExtension().lastPathComponent
        case .color(let c): c.hexString
        }
    }
}

/// A folder of Assets/wallpapers: an Aero theme ("Landscapes", "Windows") or a regional set ("US").
public struct WallpaperTheme: Hashable, Sendable {
    public var folder: String
    /// The Desktop Background group's title: the folder name, or the country's name for a regional set.
    public var title: String
    public var isRegional: Bool
    public var pictures: [URL]

    public init(folder: String, title: String, isRegional: Bool, pictures: [URL]) {
        self.folder = folder
        self.title = title
        self.isRegional = isRegional
        self.pictures = pictures
    }

    /// The theme's name on the Personalization page ("Windows 7" for the Windows folder, as Windows 7 names it).
    public var themeName: String { folder == "Windows" ? "Windows 7" : title }
}

/// A titled run of grid cells ("Landscapes (6)" in Windows 7's grid; an empty title draws no header).
public struct WallpaperGroup: Hashable, Sendable {
    public var title: String
    public var items: [WallpaperItem]
    public init(title: String, items: [WallpaperItem]) { self.title = title; self.items = items }
}

/// The "Picture location" choices.
public enum WallpaperLocationKind: String, CaseIterable, Codable, Sendable {
    /// `folder` is a folder chosen with Browse…, titled by its name.
    case windowsBackgrounds, picturesLibrary, solidColors, folder

    public var title: String {
        switch self {
        case .windowsBackgrounds: "Windows Desktop Backgrounds"
        case .picturesLibrary: "Pictures Library"
        case .solidColors: "Solid Colors"
        case .folder: "Folder"
        }
    }
}

public struct WallpaperLocation: Hashable, Sendable {
    public var kind: WallpaperLocationKind
    public var groups: [WallpaperGroup]
    /// The Browse… folder.
    public var folder: URL?
    public init(kind: WallpaperLocationKind, groups: [WallpaperGroup], folder: URL? = nil) {
        self.kind = kind
        self.groups = groups
        self.folder = folder
    }
    public var title: String { kind == .folder ? (folder?.lastPathComponent ?? kind.title) : kind.title }
    public var items: [WallpaperItem] { groups.flatMap(\.items) }
    /// A location of pictures takes several (a slideshow); Solid Colors one.
    public var allowsMultiple: Bool { kind != .solidColors }
}

public enum WallpaperCatalog {
    public static let pictureExtensions: Set<String> = ["jpg", "jpeg", "png", "heic"]

    /// The Solid Colors location: 16 colours in the spirit of Windows 7's list (its classic blue first, white and
    /// black last).
    public static let solidColors: [SolidColor] = [
        0x3A6EA5, 0x004E98, 0x0A246A, 0x5A7EDC, 0x008080, 0x2E8B57, 0x6B8E23, 0x808000,
        0x8B4513, 0x800000, 0x800080, 0x4B0082, 0x696969, 0xA9A9A9, 0xFFFFFF, 0x000000,
    ].map(SolidColor.init)

    /// The regional sets Windows 7 media carry (Windows/Globalization/MCT/MCT-<code>).
    public static func regionName(_ code: String) -> String? {
        ["AU": "Australia", "CA": "Canada", "GB": "Great Britain", "US": "United States", "ZA": "South Africa"][code]
    }

    /// A folder scan stops after this many pictures (a Pictures folder of tens of thousands would otherwise be
    /// stat'd on the main thread and get a grid cell each).
    public static let maxPicturesPerFolder = 2000

    /// Explorer's name order (img7 before img10), made total: names it calls equal (case or width only) keep a
    /// fixed order by their plain comparison.
    public static func explorerOrder(_ names: [String]) -> [String] {
        names.sorted {
            let c = $0.localizedStandardCompare($1)
            return c == .orderedSame ? $0 < $1 : c == .orderedAscending
        }
    }

    /// The pictures directly inside `folder` (no subfolders, no hidden files), in Explorer's name order, at most
    /// `limit` of them (the first ones in that order).
    public static func pictures(in folder: URL, extensions: Set<String> = pictureExtensions,
                                limit: Int = maxPicturesPerFolder) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        let candidates = names.filter { !$0.hasPrefix(".") && extensions.contains(($0 as NSString).pathExtension.lowercased()) }
        return Array(explorerOrder(candidates).lazy
            .map { folder.appendingPathComponent($0) }
            .filter { var dir: ObjCBool = false; return fm.fileExists(atPath: $0.path, isDirectory: &dir) && !dir.boolValue }
            .prefix(max(0, limit)))
    }

    /// One theme per non-empty folder of `wallpapers` (Assets/wallpapers): the Aero themes by name, then the
    /// regional sets (two capital letters) by their country's name.
    public static func themes(in wallpapers: URL) -> [WallpaperTheme] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: wallpapers.path) else { return [] }
        let themes: [WallpaperTheme] = names.compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let url = wallpapers.appendingPathComponent(name)
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &dir), dir.boolValue else { return nil }
            let pics = pictures(in: url, extensions: ["jpg", "jpeg"])
            guard !pics.isEmpty else { return nil }
            let regional = name.count == 2 && name.allSatisfy { $0.isASCII && $0.isUppercase }
            return WallpaperTheme(folder: name, title: regional ? (regionName(name) ?? name) : name, isRegional: regional, pictures: pics)
        }
        return themes.sorted {
            if $0.isRegional != $1.isRegional { return !$0.isRegional }
            let c = $0.title.localizedStandardCompare($1.title)
            return c == .orderedSame ? $0.folder < $1.folder : c == .orderedAscending
        }
    }

    /// Windows Desktop Backgrounds (one group per theme of `assetsRoot`/wallpapers), Pictures Library (the top
    /// level of `pictures`) and Solid Colors. ("Top Rated Photos" has no Mac counterpart and is left out.)
    public static func locations(assetsRoot: URL?, pictures picturesFolder: URL?) -> [WallpaperLocation] {
        let themes = assetsRoot.map { themes(in: $0.appendingPathComponent("wallpapers")) } ?? []
        let library = picturesFolder.map { pictures(in: $0) } ?? []
        return [
            WallpaperLocation(kind: .windowsBackgrounds, groups: themes.map {
                WallpaperGroup(title: $0.title, items: $0.pictures.map(WallpaperItem.picture))
            }),
            WallpaperLocation(kind: .picturesLibrary,
                              groups: library.isEmpty ? [] : [WallpaperGroup(title: "Pictures", items: library.map(WallpaperItem.picture))]),
            WallpaperLocation(kind: .solidColors, groups: [WallpaperGroup(title: "", items: solidColors.map(WallpaperItem.color))]),
        ]
    }

    /// A folder chosen with Browse…: its top-level pictures in one group named after it.
    public static func folderLocation(_ folder: URL) -> WallpaperLocation {
        let pics = pictures(in: folder)
        return WallpaperLocation(kind: .folder, groups: pics.isEmpty ? [] : [
            WallpaperGroup(title: folder.lastPathComponent, items: pics.map(WallpaperItem.picture)),
        ], folder: folder)
    }
}

// MARK: - Picture position

/// NSImageScaling's raw values (AppKit is not imported here): the shell builds `NSImageScaling(rawValue:)`.
public enum WallpaperScaling: UInt, Sendable {
    case proportionallyDown = 0, axesIndependently = 1, none = 2, proportionallyUpOrDown = 3
}

/// Windows 7's "Picture position" choices, mapped onto NSWorkspace's desktop image options.
public enum WallpaperPosition: String, CaseIterable, Codable, Sendable {
    case fill, fit, stretch, tile, center

    public var title: String {
        switch self {
        case .fill: "Fill"
        case .fit: "Fit"
        case .stretch: "Stretch"
        case .tile: "Tile"
        case .center: "Center"
        }
    }

    /// `NSWorkspace.DesktopImageOptionKey.imageScaling`.
    public var scaling: WallpaperScaling {
        switch self {
        case .fill, .fit, .tile: .proportionallyUpOrDown
        case .stretch: .axesIndependently
        case .center: .none
        }
    }

    /// `NSWorkspace.DesktopImageOptionKey.allowClipping`: Fill (and Center, for a picture larger than the screen)
    /// crop; Fit shows the whole picture.
    public var allowsClipping: Bool {
        switch self {
        case .fill, .tile, .center: true
        case .fit, .stretch: false
        }
    }

    /// macOS cannot tile a desktop picture: Tile is offered as in Windows 7 and shown as Fill.
    public var isSupported: Bool { self != .tile }
}

// MARK: - Slideshow

/// "Change picture every": Windows 7's choices.
public enum SlideshowInterval: Int, CaseIterable, Codable, Sendable {
    case seconds10 = 10, seconds30 = 30, minute1 = 60, minutes5 = 300, minutes10 = 600, minutes30 = 1800,
         hour1 = 3600, hours6 = 21600, day1 = 86400

    public var seconds: TimeInterval { TimeInterval(rawValue) }

    public var title: String {
        switch self {
        case .seconds10: "10 seconds"
        case .seconds30: "30 seconds"
        case .minute1: "1 minute"
        case .minutes5: "5 minutes"
        case .minutes10: "10 minutes"
        case .minutes30: "30 minutes"
        case .hour1: "1 hour"
        case .hours6: "6 hours"
        case .day1: "1 day"
        }
    }
}

public struct SlideshowSchedule: Equatable, Sendable {
    public var interval: SlideshowInterval
    public init(interval: SlideshowInterval) { self.interval = interval }

    /// When the next picture is due: an interval after the last change, or now when that has passed (after sleep:
    /// one change, not one per missed interval).
    public func fireDate(lastChange: Date, now: Date) -> Date {
        let due = lastChange.addingTimeInterval(interval.seconds)
        return due > now ? due : now
    }
}

/// The order of a slideshow's pictures: in grid order, or shuffled so that every picture shows once per round
/// and none twice in a row.
public struct SlideshowOrder {
    public private(set) var count: Int
    public private(set) var current: Int
    public var shuffle: Bool
    private var bag: [Int] = []
    private let random: (Int) -> Int

    /// `random(n)` returns a number in 0..<n (a seeded one in tests).
    public init(count: Int, current: Int, shuffle: Bool, random: @escaping (Int) -> Int = { Int.random(in: 0..<$0) }) {
        self.count = max(0, count)
        self.current = count > 0 ? min(max(0, current), count - 1) : 0
        self.shuffle = shuffle
        self.random = random
        if shuffle { bag = shuffled((0..<self.count).filter { $0 != self.current }) }
    }

    public mutating func next() -> Int {
        guard count > 1 else { current = 0; return 0 }
        if !shuffle {
            current = (current + 1) % count
            return current
        }
        if bag.isEmpty {
            bag = shuffled(Array(0..<count))
            if bag[0] == current { bag.swapAt(0, 1 + random(count - 1)) }
        }
        current = bag.removeFirst()
        return current
    }

    private func shuffled(_ a: [Int]) -> [Int] {
        var a = a
        guard a.count > 1 else { return a }
        for i in stride(from: a.count - 1, to: 0, by: -1) { a.swapAt(i, random(i + 1)) }
        return a
    }
}

/// What the user chose in Desktop Background (or by clicking a theme), kept in the shell's defaults.
public struct WallpaperSettings: Codable, Equatable, Sendable {
    public static let defaultsKey = "W7WallpaperSettings"

    public var location: WallpaperLocationKind
    /// The checked pictures in grid order, or one colour.
    public var items: [WallpaperItem]
    public var position: WallpaperPosition
    public var interval: SlideshowInterval
    public var shuffle: Bool
    /// The theme these came from; nil once the background was changed in Desktop Background ("Unsaved Theme").
    public var themeName: String?
    /// The Browse… folder when `location` is `.folder`.
    public var folder: URL?

    public init(location: WallpaperLocationKind, items: [WallpaperItem], position: WallpaperPosition,
                interval: SlideshowInterval, shuffle: Bool, themeName: String?, folder: URL? = nil) {
        self.folder = folder
        self.location = location
        self.items = items
        self.position = position
        self.interval = interval
        self.shuffle = shuffle
        self.themeName = themeName
    }

    public var isSlideshow: Bool { items.count > 1 }

    /// A Windows 7 theme: all its pictures, Fill, a new one every 30 minutes, shuffled (as its .theme file says).
    public static func theme(_ t: WallpaperTheme) -> WallpaperSettings {
        WallpaperSettings(location: .windowsBackgrounds, items: t.pictures.map(WallpaperItem.picture), position: .fill,
                          interval: .minutes30, shuffle: true, themeName: t.themeName)
    }

    public func data() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public init?(data: Data) {
        guard let s = try? JSONDecoder().decode(WallpaperSettings.self, from: data) else { return nil }
        self = s
    }
}

/// Applies the chosen background and steps a slideshow. `apply` sets one picture or colour on the desktop (the
/// shell: NSWorkspace for every screen; tests: a fake) and reports whether it did; the shell's timer calls
/// `tick(now:)` at `nextFire`.
public final class WallpaperPlayer {
    public typealias Apply = (WallpaperItem, WallpaperPosition) -> Bool

    private let apply: Apply
    private let random: (Int) -> Int
    public private(set) var settings: WallpaperSettings?
    public private(set) var current: WallpaperItem?
    public private(set) var nextFire: Date?
    private var order: SlideshowOrder?

    public init(random: @escaping (Int) -> Int = { Int.random(in: 0..<$0) }, apply: @escaping Apply) {
        self.apply = apply
        self.random = random
    }

    /// Shows the first picture (a random one when shuffled) unless `applyFirst` is false (the shell's launch: the
    /// desktop still shows what was set), and schedules the next change for a slideshow.
    /// `showing` is what the desktop shows now (the shell's launch): when it is one of the choice's items the
    /// slideshow goes on from it, so the next Space or screen change does not swap the picture.
    public func start(_ s: WallpaperSettings, now: Date, applyFirst: Bool = true, showing: WallpaperItem? = nil) {
        stop()
        guard !s.items.isEmpty else { current = nil; return }
        settings = s
        var first = s.shuffle && s.isSlideshow ? random(s.items.count) : 0
        if !applyFirst, let shown = showing ?? current, let i = s.items.firstIndex(of: shown) { first = i }
        order = SlideshowOrder(count: s.items.count, current: first, shuffle: s.shuffle, random: random)
        current = s.items[first]
        if applyFirst { _ = apply(s.items[first], s.position) }
        nextFire = s.isSlideshow ? SlideshowSchedule(interval: s.interval).fireDate(lastChange: now, now: now) : nil
    }

    /// The next picture when it is due; true when one was set.
    @discardableResult
    public func tick(now: Date) -> Bool {
        guard let s = settings, let due = nextFire, now >= due.addingTimeInterval(-0.5), var o = order else { return false }
        let item = s.items[o.next()]
        order = o
        current = item
        let ok = apply(item, s.position)
        nextFire = SlideshowSchedule(interval: s.interval).fireDate(lastChange: now, now: now)
        return ok
    }

    public func stop() {
        settings = nil
        order = nil
        nextFire = nil
    }
}

// MARK: - Pictures set elsewhere, per display

/// A display's CGDirectDisplayID (its NSScreenNumber).
public typealias DisplayID = UInt32

/// Which screens the slideshow may change: only those that show one of the shell's pictures now. A picture the
/// user set in System Settings (or anywhere else) is theirs, and the slideshow stops once no screen shows ours.
public enum WallpaperSlideshow {
    /// The displays whose current picture is one of `ours` (compared as standardized file paths), in display order.
    public static func screensToUpdate(current: [DisplayID: URL], ours: Set<URL>) -> [DisplayID] {
        let paths = Set(ours.map(\.standardizedFileURL.path))
        return current.filter { paths.contains($0.value.standardizedFileURL.path) }.keys.sorted()
    }

    /// True when macOS reports pictures and none of them is ours: the slideshow ends (and is not resumed at the
    /// next launch). With no picture reported at all nothing is known, and the slideshow is kept.
    public static func shouldStop(current: [DisplayID: URL], ours: Set<URL>) -> Bool {
        !current.isEmpty && screensToUpdate(current: current, ours: ours).isEmpty
    }

    /// The shell's pictures: the chosen items, every picture of the catalogue (Assets/wallpapers), the pictures of
    /// a Desktop Background preview, and the colour pictures in `solidFolder` (the chosen colour and the palette's).
    public static func ours(items: [WallpaperItem], catalogue: [URL], previewed: Set<URL>, solidFolder: URL) -> Set<URL> {
        var set = Set(catalogue).union(previewed)
        for item in items {
            switch item {
            case .picture(let url): set.insert(url)
            case .color(let c): set.insert(solidFolder.appendingPathComponent(c.fileName))
            }
        }
        for c in WallpaperCatalog.solidColors { set.insert(solidFolder.appendingPathComponent(c.fileName)) }
        return set
    }
}

/// Desktop Background's preview and Cancel, per display (keyed by CGDirectDisplayID, so a stale screen object or
/// a Space switch cannot misdirect it). The snapshot of what every display shows is taken at the first preview,
/// not when the window opens (a slideshow change in between would make it stale). Cancel restores only displays
/// that still exist, were in the snapshot, and show a picture this session previewed: a display added meanwhile,
/// or one whose picture was changed elsewhere (another Space, System Settings), is left alone.
public struct WallpaperPreviewSession<Options> {
    public struct Shown {
        public var url: URL
        public var options: Options
        public init(url: URL, options: Options) { self.url = url; self.options = options }
    }

    public private(set) var snapshot: [DisplayID: Shown]?
    /// Every picture this session put on the desktop (standardized).
    public private(set) var previewed: Set<URL> = []

    public init() {}

    public var isActive: Bool { snapshot != nil }

    /// Before `url` is previewed; `current` (what every display shows) is kept only the first time.
    public mutating func willPreview(_ url: URL, current: @autoclosure () -> [DisplayID: Shown]) {
        if snapshot == nil { snapshot = current() }
        previewed.insert(url.standardizedFileURL)
    }

    /// What Cancel sets: each display's own picture and options from the snapshot, in display order.
    public func restorePlan(current: [DisplayID: URL]) -> [(display: DisplayID, shown: Shown)] {
        guard let snapshot else { return [] }
        let paths = Set(previewed.map(\.path))
        return current.keys.sorted().compactMap { display in
            guard let url = current[display], paths.contains(url.standardizedFileURL.path), let old = snapshot[display] else { return nil }
            return (display, old)
        }
    }
}

/// The Desktop Background grid's check boxes: a click on a picture selects only it, its check box adds or removes
/// it; Solid Colors takes one. The checked items stay in grid order.
public struct WallpaperSelection: Equatable, Sendable {
    public private(set) var items: [WallpaperItem]
    public private(set) var checked: [WallpaperItem]

    public init(items: [WallpaperItem], checked: [WallpaperItem]) {
        self.items = items
        let set = Set(checked)
        var kept = items.filter { set.contains($0) }
        if !items.allSatisfy({ $0.pictureURL != nil }) { kept = Array(kept.prefix(1)) }
        self.checked = kept
    }

    public var allowsMultiple: Bool { !items.isEmpty && items.allSatisfy { $0.pictureURL != nil } }
    public var canSave: Bool { !checked.isEmpty }
    public var isSlideshow: Bool { checked.count > 1 }

    public mutating func click(_ item: WallpaperItem) {
        guard items.contains(item) else { return }
        checked = [item]
    }

    public mutating func toggle(_ item: WallpaperItem) {
        guard allowsMultiple else { click(item); return }
        var set = Set(checked)
        if set.contains(item) { set.remove(item) } else { set.insert(item) }
        checked = items.filter { set.contains($0) }
    }

    public mutating func selectAll() { if allowsMultiple { checked = items } }
    public mutating func clearAll() { checked = [] }
}

/// The Desktop Background window's controls in Tab order, and its own keys.
public enum DesktopBackgroundModel {
    public enum Control: CaseIterable, Sendable {
        case location, browse, selectAll, clearAll, pictures, position, interval, shuffle, save, cancel, search
    }

    /// Top to bottom, left to right, then the address row's search box (Tab wraps from it to the first control).
    public static let focusOrder: [Control] = [.location, .browse, .selectAll, .clearAll, .pictures, .position,
                                               .interval, .shuffle, .save, .cancel, .search]

    public enum WindowAction: Equatable, Sendable {
        case save, cancel, selectAllPictures, focusNext, focusPrevious
    }

    /// Return saves and Esc cancels, Cmd+A checks every picture, Tab moves the focus. Return, Esc and Cmd+A belong
    /// to the search box while it is being typed in (Return there searches), and Return to a focused button, check
    /// box, link or list, which acts on it.
    public static func windowAction(_ key: ShellKey, editingText: Bool, controlHasFocus: Bool) -> WindowAction? {
        switch key {
        case .tab: return .focusNext
        case .backTab: return .focusPrevious
        case .enter: return editingText || controlHasFocus ? nil : .save
        case .escape: return editingText ? nil : .cancel
        case .selectAll: return editingText ? nil : .selectAllPictures
        default: return nil
        }
    }
}

/// The Personalization page's fixed text and links.
public enum PersonalizationModel {
    public enum Control: CaseIterable, Sendable { case tasks, themes, bottomRow, search }

    /// The task pane, the theme list, the bottom row, then the search box.
    public static let focusOrder: [Control] = [.tasks, .themes, .bottomRow, .search]

    public static let heading = "Change the visuals and sounds on your computer"
    public static let subheading = "Click a theme to change the desktop background, window color, sounds, and screen saver all at once."
    public static let bottomTitles = ["Desktop Background", "Window Color", "Sounds", "Screen Saver"]

    /// The task pane under "Control Panel Home".
    public static let tasks: [ControlPanelLink] = [
        ControlPanelLink("Change desktop icons", .win7mac(ControlPanelCatalog.desktopIconsInfo)),
        ControlPanelLink("Change mouse pointers", .win7mac(ControlPanelCatalog.mousePointersInfo)),
        ControlPanelLink("Change your account picture", .settingsPane(ControlPanelCatalog.Pane.usersGroups)),
    ]

    public static let seeAlso: [ControlPanelLink] = [
        ControlPanelLink("Display", .settingsPane(ControlPanelCatalog.Pane.displays)),
        ControlPanelLink("Taskbar and Start Menu", .win7mac(ControlPanelCatalog.taskbarInfo)),
        ControlPanelLink("Ease of Access Center", .settingsPane(ControlPanelCatalog.Pane.accessibility)),
    ]

    /// "Aero Themes": Windows 7 first, then the others in catalogue order.
    public static func aeroThemes(_ themes: [WallpaperTheme]) -> [WallpaperTheme] {
        let aero = themes.filter { !$0.isRegional }
        return aero.filter { $0.folder == "Windows" } + aero.filter { $0.folder != "Windows" }
    }

    /// "Installed Themes": the regional sets.
    public static func installedThemes(_ themes: [WallpaperTheme]) -> [WallpaperTheme] { themes.filter(\.isRegional) }

    /// "My Themes" holds "Unsaved Theme" once the background was set in Desktop Background; a theme the user clicked
    /// is shown selected where it is listed instead.
    public static func myThemeName(_ settings: WallpaperSettings?) -> String? {
        guard let settings, settings.themeName == nil else { return nil }
        return "Unsaved Theme"
    }

    /// The caption under the bottom row's Desktop Background link.
    public static func backgroundCaption(_ settings: WallpaperSettings?) -> String {
        guard let settings, let first = settings.items.first else { return "Harmony" }
        if settings.isSlideshow { return "Slide Show" }
        if case .color = first { return "Solid Color" }
        return first.name
    }
}
