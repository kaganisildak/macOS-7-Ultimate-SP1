import Foundation
import Testing
@testable import Win7Core

/// The Desktop Background catalogue, picture positions, the slideshow and the Personalization page.
/// Every folder is a temporary tree; nothing here touches the real Assets/ or the desktop picture.
@Suite struct WallpaperCatalogTests {
    /// A temporary folder tree: `files` are paths relative to the root, each written with a few bytes.
    private func tree(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("w7wall-\(UUID().uuidString)")
        for f in files {
            let url = root.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func themesFromTheAssetsFolder() throws {
        let root = try tree([
            "wallpapers/Windows/img0.jpg",
            "wallpapers/Landscapes/img8.jpg", "wallpapers/Landscapes/img7.jpg", "wallpapers/Landscapes/img10.jpg",
            "wallpapers/Landscapes/Desktop.ini", "wallpapers/Landscapes/.hidden.jpg",
            "wallpapers/Architecture/img13.JPG",
            "wallpapers/US/US-wp1.jpg", "wallpapers/GB/GB-wp1.jpg", "wallpapers/XX/XX-wp1.jpg",
            "wallpapers/Empty/readme.txt", "wallpapers/stray.jpg",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let themes = WallpaperCatalog.themes(in: root.appendingPathComponent("wallpapers"))
        // Aero themes alphabetically, then the regional sets by their country's name; empty folders and files skipped.
        #expect(themes.map(\.folder) == ["Architecture", "Landscapes", "Windows", "GB", "US", "XX"])
        #expect(themes.map(\.title) == ["Architecture", "Landscapes", "Windows", "Great Britain", "United States", "XX"])
        #expect(themes.map(\.isRegional) == [false, false, false, true, true, true])
        // The theme's name on the Personalization page: "Windows 7" for the Windows folder.
        #expect(themes.first { $0.folder == "Windows" }?.themeName == "Windows 7")
        #expect(themes.first { $0.folder == "Landscapes" }?.themeName == "Landscapes")
        // Pictures in Explorer's name order (img7, img8, img10), jpg in any letter case, no hidden files.
        #expect(themes.first { $0.folder == "Landscapes" }?.pictures.map(\.lastPathComponent) == ["img7.jpg", "img8.jpg", "img10.jpg"])
        #expect(themes.first { $0.folder == "Architecture" }?.pictures.count == 1)
        #expect(WallpaperCatalog.regionName("AU") == "Australia" && WallpaperCatalog.regionName("CA") == "Canada"
                && WallpaperCatalog.regionName("ZA") == "South Africa")
        #expect(WallpaperCatalog.themes(in: root.appendingPathComponent("missing")).isEmpty)
    }

    @Test func locationsFromASyntheticTree() throws {
        let root = try tree([
            "Assets/wallpapers/Windows/img0.jpg", "Assets/wallpapers/Landscapes/img7.jpg", "Assets/wallpapers/US/US-wp1.jpg",
            "Pictures/b.png", "Pictures/A.jpeg", "Pictures/c.heic", "Pictures/notes.txt", "Pictures/.DS_Store",
            "Pictures/Sub/deep.jpg",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = WallpaperCatalog.locations(assetsRoot: root.appendingPathComponent("Assets"),
                                                   pictures: root.appendingPathComponent("Pictures"))
        #expect(locations.map(\.kind) == [.windowsBackgrounds, .picturesLibrary, .solidColors])
        #expect(locations.map(\.title) == ["Windows Desktop Backgrounds", "Pictures Library", "Solid Colors"])
        let windows = locations[0]
        #expect(windows.groups.map(\.title) == ["Landscapes", "Windows", "United States"])
        #expect(windows.items.count == 3)
        // Pictures Library: the top level of ~/Pictures only, pictures only, by name.
        #expect(locations[1].items.compactMap(\.pictureURL).map(\.lastPathComponent) == ["A.jpeg", "b.png", "c.heic"])
        #expect(locations[2].items == WallpaperCatalog.solidColors.map(WallpaperItem.color))
        // Browse…: a folder of the user's, titled by its name; a settings value keeps it.
        let browsed = WallpaperCatalog.folderLocation(root.appendingPathComponent("Pictures"))
        #expect(browsed.kind == .folder && browsed.title == "Pictures" && browsed.items.count == 3)
        #expect(WallpaperCatalog.folderLocation(root.appendingPathComponent("nope")).items.isEmpty)
        let s = WallpaperSettings(location: .folder, items: browsed.items, position: .fit, interval: .hour1, shuffle: false,
                                  themeName: nil, folder: browsed.folder)
        #expect(WallpaperSettings(data: s.data())?.folder == browsed.folder)
        // No assets and no Pictures folder: every location is still listed, the picture ones empty.
        let bare = WallpaperCatalog.locations(assetsRoot: nil, pictures: nil)
        #expect(bare.map(\.kind) == [.windowsBackgrounds, .picturesLibrary, .solidColors])
        #expect(bare[0].items.isEmpty && bare[1].items.isEmpty && bare[2].items.count == 16)
    }

    @Test func solidColorsAreWindows7s() {
        let colors = WallpaperCatalog.solidColors
        #expect(colors.count == 16)
        #expect(Set(colors).count == 16)
        #expect(colors.map(\.hexString) == [
            "#3A6EA5", "#004E98", "#0A246A", "#5A7EDC", "#008080", "#2E8B57", "#6B8E23", "#808000",
            "#8B4513", "#800000", "#800080", "#4B0082", "#696969", "#A9A9A9", "#FFFFFF", "#000000",
        ])
        let blue = SolidColor(0x3A6EA5)
        #expect(abs(blue.red - 0x3A / 255.0) < 1e-9 && abs(blue.green - 0x6E / 255.0) < 1e-9 && abs(blue.blue - 0xA5 / 255.0) < 1e-9)
        #expect(blue.fileName == "solid-3A6EA5.png")
    }

    /// Fill, Fit, Stretch, Tile, Center (Windows 7's order) → NSImageScaling raw values and clipping. Tile has no
    /// macOS counterpart and is shown as Fill.
    @Test func positionMapping() {
        #expect(WallpaperPosition.allCases.map(\.title) == ["Fill", "Fit", "Stretch", "Tile", "Center"])
        // NSImageScaling: proportionallyDown 0, axesIndependently 1, none 2, proportionallyUpOrDown 3.
        #expect(WallpaperScaling.proportionallyUpOrDown.rawValue == 3 && WallpaperScaling.axesIndependently.rawValue == 1
                && WallpaperScaling.none.rawValue == 2)
        #expect(WallpaperPosition.fill.scaling == .proportionallyUpOrDown && WallpaperPosition.fill.allowsClipping)
        #expect(WallpaperPosition.fit.scaling == .proportionallyUpOrDown && !WallpaperPosition.fit.allowsClipping)
        #expect(WallpaperPosition.stretch.scaling == .axesIndependently)
        #expect(WallpaperPosition.center.scaling == .none)
        #expect(WallpaperPosition.tile.scaling == WallpaperPosition.fill.scaling && WallpaperPosition.tile.allowsClipping)
        #expect(!WallpaperPosition.tile.isSupported && WallpaperPosition.allCases.filter(\.isSupported).count == 4)
    }
}

@Suite struct SlideshowTests {
    @Test func intervalsAreTheBriefs() {
        #expect(SlideshowInterval.allCases.map(\.seconds) == [10, 30, 60, 300, 600, 1800, 3600, 21600, 86400])
        #expect(SlideshowInterval.allCases.map(\.title) == [
            "10 seconds", "30 seconds", "1 minute", "5 minutes", "10 minutes", "30 minutes", "1 hour", "6 hours", "1 day",
        ])
    }

    @Test func nextFireMath() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let s = SlideshowSchedule(interval: .seconds10)
        #expect(s.fireDate(lastChange: t0, now: t0) == t0.addingTimeInterval(10))
        #expect(s.fireDate(lastChange: t0, now: t0.addingTimeInterval(4)) == t0.addingTimeInterval(10))
        // Overdue (the Mac slept): fire now, once, not a burst of missed changes.
        #expect(s.fireDate(lastChange: t0, now: t0.addingTimeInterval(500)) == t0.addingTimeInterval(500))
        #expect(SlideshowSchedule(interval: .day1).fireDate(lastChange: t0, now: t0) == t0.addingTimeInterval(86400))
    }

    @Test func sequentialOrderWraps() {
        var order = SlideshowOrder(count: 3, current: 0, shuffle: false)
        let steps: [Int] = (0..<4).map { _ in order.next() }
        #expect(steps == [1, 2, 0, 1])
        var one = SlideshowOrder(count: 1, current: 0, shuffle: true)
        #expect(one.next() == 0 && one.next() == 0)
    }

    @Test func shuffleShowsEveryPictureOncePerRoundAndNeverRepeats() {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        let random: (Int) -> Int = { bound in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        var order = SlideshowOrder(count: 6, current: 2, shuffle: true, random: random)
        var shown = [2]
        for _ in 0..<(6 * 5 - 1) { shown.append(order.next()) }
        for i in 1..<shown.count { #expect(shown[i] != shown[i - 1], "repeat at \(i)") }
        // The first round (the start picture and the next five) holds every picture once; so does each later round.
        #expect(Set(shown[0..<6]) == Set(0..<6))
        for round in 1..<5 { #expect(Set(shown[(round * 6)..<(round * 6 + 6)]) == Set(0..<6), "round \(round)") }
        // Shuffled, not sequential.
        #expect(shown != (0..<30).map { ($0 + 2) % 6 })
    }

    @Test func settingsRoundTripAndThemes() throws {
        let theme = WallpaperTheme(folder: "Landscapes", title: "Landscapes", isRegional: false,
                                   pictures: [URL(fileURLWithPath: "/a/img7.jpg"), URL(fileURLWithPath: "/a/img8.jpg")])
        let s = WallpaperSettings.theme(theme)
        // A Windows 7 Aero theme: all its pictures, Fill, every 30 minutes, shuffled.
        #expect(s.items.count == 2 && s.position == .fill && s.interval == .minutes30 && s.shuffle)
        #expect(s.themeName == "Landscapes" && s.location == .windowsBackgrounds && s.isSlideshow)
        let back = try #require(WallpaperSettings(data: s.data()))
        #expect(back == s)
        #expect(WallpaperSettings(data: Data("junk".utf8)) == nil)
        let color = WallpaperSettings(location: .solidColors, items: [.color(SolidColor(0x008080))], position: .fill,
                                      interval: .minutes30, shuffle: false, themeName: nil)
        #expect(!color.isSlideshow)
        #expect(WallpaperSettings(data: color.data()) == color)
    }
}

@Suite @MainActor struct WallpaperPlayerTests {
    private let a = WallpaperItem.picture(URL(fileURLWithPath: "/w/a.jpg"))
    private let b = WallpaperItem.picture(URL(fileURLWithPath: "/w/b.jpg"))
    private let c = WallpaperItem.picture(URL(fileURLWithPath: "/w/c.jpg"))

    private func settings(_ items: [WallpaperItem], shuffle: Bool = false) -> WallpaperSettings {
        WallpaperSettings(location: .windowsBackgrounds, items: items, position: .fit, interval: .seconds10,
                          shuffle: shuffle, themeName: nil)
    }

    /// The desktop is never touched: `apply` is a fake that records what would be set.
    @Test func startAppliesTheFirstPictureAndTicksThroughTheRest() {
        var applied: [(WallpaperItem, WallpaperPosition)] = []
        let player = WallpaperPlayer { item, position in applied.append((item, position)); return true }
        let t0 = Date(timeIntervalSinceReferenceDate: 5000)
        player.start(settings([a, b, c]), now: t0)
        #expect(applied.map(\.0) == [a] && applied.first?.1 == .fit)
        #expect(player.current == a && player.nextFire == t0.addingTimeInterval(10))
        #expect(!player.tick(now: t0.addingTimeInterval(9)))   // not yet
        #expect(player.tick(now: t0.addingTimeInterval(10)))
        #expect(player.tick(now: t0.addingTimeInterval(20)))
        #expect(player.tick(now: t0.addingTimeInterval(30)))
        #expect(applied.map(\.0) == [a, b, c, a])
        // After a long sleep: one change, then the next one interval later.
        #expect(player.tick(now: t0.addingTimeInterval(1000)))
        #expect(applied.count == 5 && player.nextFire == t0.addingTimeInterval(1010))
    }

    @Test func oneItemIsNoSlideshowAndStopEndsIt() {
        var applied: [WallpaperItem] = []
        let player = WallpaperPlayer { item, _ in applied.append(item); return true }
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        player.start(settings([.color(SolidColor(0))]), now: t0)
        #expect(applied == [.color(SolidColor(0))] && player.nextFire == nil)
        #expect(!player.tick(now: t0.addingTimeInterval(1e6)))
        player.start(settings([a, b]), now: t0)
        player.stop()
        #expect(player.nextFire == nil && !player.tick(now: t0.addingTimeInterval(100)))
        // Nothing to show: nothing applied.
        player.start(settings([]), now: t0)
        #expect(applied.count == 2 && player.current == nil)
    }

    /// At launch the slideshow resumes without changing the picture macOS still shows; the next change comes an
    /// interval later.
    @Test func resumeDoesNotApplyAtOnce() {
        var applied: [WallpaperItem] = []
        let player = WallpaperPlayer { item, _ in applied.append(item); return true }
        let t0 = Date(timeIntervalSinceReferenceDate: 100)
        player.start(settings([a, b]), now: t0, applyFirst: false)
        #expect(applied.isEmpty && player.nextFire == t0.addingTimeInterval(10))
        #expect(player.tick(now: t0.addingTimeInterval(10)) && applied.count == 1)
    }

    @Test func aFailedApplyKeepsTheSlideshowGoing() {
        var calls = 0
        let player = WallpaperPlayer { _, _ in calls += 1; return false }
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        player.start(settings([a, b]), now: t0)
        #expect(player.nextFire == t0.addingTimeInterval(10))
        #expect(!player.tick(now: t0.addingTimeInterval(10)))   // nothing changed on screen
        #expect(calls == 2 && player.nextFire == t0.addingTimeInterval(20))
    }
}

@Suite struct WallpaperSelectionTests {
    private let pics = (1...4).map { WallpaperItem.picture(URL(fileURLWithPath: "/p/\($0).jpg")) }

    @Test func clickSelectsOneCheckBoxAddsAndOrderFollowsTheGrid() {
        var s = WallpaperSelection(items: pics, checked: [])
        #expect(!s.canSave && !s.isSlideshow)
        s.click(pics[2])
        #expect(s.checked == [pics[2]] && s.canSave && !s.isSlideshow)
        s.toggle(pics[0])
        #expect(s.checked == [pics[0], pics[2]] && s.isSlideshow)   // grid order, not click order
        s.toggle(pics[2])
        #expect(s.checked == [pics[0]])
        s.selectAll()
        #expect(s.checked == pics)
        s.clearAll()
        #expect(s.checked.isEmpty && !s.canSave)
        // Items no longer in the location are dropped.
        let gone = WallpaperItem.picture(URL(fileURLWithPath: "/p/gone.jpg"))
        #expect(WallpaperSelection(items: pics, checked: [gone, pics[1]]).checked == [pics[1]])
    }

    @Test func solidColorsAreSingleSelection() {
        let colors = WallpaperCatalog.solidColors.map(WallpaperItem.color)
        var s = WallpaperSelection(items: colors, checked: [])
        #expect(!s.allowsMultiple)
        s.toggle(colors[1])
        s.toggle(colors[3])
        #expect(s.checked == [colors[3]])
        s.selectAll()
        #expect(s.checked == [colors[3]])
    }
}

@Suite struct PersonalizationModelTests {
    private let themes = [
        WallpaperTheme(folder: "Landscapes", title: "Landscapes", isRegional: false, pictures: [URL(fileURLWithPath: "/l/1.jpg")]),
        WallpaperTheme(folder: "Windows", title: "Windows", isRegional: false, pictures: [URL(fileURLWithPath: "/w/img0.jpg")]),
        WallpaperTheme(folder: "US", title: "United States", isRegional: true, pictures: [URL(fileURLWithPath: "/u/1.jpg")]),
    ]

    @Test func sectionsAndTaskLinks() {
        // Aero Themes: Windows 7 first, as Windows 7 lists it; the regional sets under Installed Themes.
        #expect(PersonalizationModel.aeroThemes(themes).map(\.themeName) == ["Windows 7", "Landscapes"])
        #expect(PersonalizationModel.installedThemes(themes).map(\.themeName) == ["United States"])
        #expect(PersonalizationModel.tasks.map(\.title) == ["Change desktop icons", "Change mouse pointers", "Change your account picture"])
        #expect(PersonalizationModel.tasks[2].action == .settingsPane(ControlPanelCatalog.Pane.usersGroups))
        #expect(PersonalizationModel.seeAlso.map(\.title) == ["Display", "Taskbar and Start Menu", "Ease of Access Center"])
        #expect(PersonalizationModel.bottomTitles == ["Desktop Background", "Window Color", "Sounds", "Screen Saver"])
        #expect(PersonalizationModel.heading == "Change the visuals and sounds on your computer")
        // My Themes: the current theme, or "Unsaved Theme" once the background was changed by hand.
        #expect(PersonalizationModel.myThemeName(nil) == nil)
        let mine = WallpaperSettings(location: .picturesLibrary, items: [], position: .fill, interval: .minutes30, shuffle: false, themeName: nil)
        #expect(PersonalizationModel.myThemeName(mine) == "Unsaved Theme")
        #expect(PersonalizationModel.myThemeName(WallpaperSettings.theme(themes[0])) == nil)   // shown selected in Aero Themes
        // The Desktop Background tile's caption: the picture's name, "Slide Show", or "Solid Color".
        #expect(PersonalizationModel.backgroundCaption(WallpaperSettings.theme(themes[1])) == "img0")
        #expect(PersonalizationModel.backgroundCaption(WallpaperSettings.theme(WallpaperTheme(
            folder: "L", title: "L", isRegional: false, pictures: [URL(fileURLWithPath: "/1.jpg"), URL(fileURLWithPath: "/2.jpg")]))) == "Slide Show")
        #expect(PersonalizationModel.backgroundCaption(WallpaperSettings(location: .solidColors, items: [.color(SolidColor(0))],
                                                                          position: .fill, interval: .minutes30, shuffle: false,
                                                                          themeName: nil)) == "Solid Color")
        #expect(PersonalizationModel.backgroundCaption(nil) == "Harmony")
    }

    /// Desktop Personalize, the Personalization item and the Appearance category's links open the
    /// shell's windows.
    @Test func controlPanelOpensTheShellWindows() {
        typealias P = ControlPanelCatalog.Pane
        let item = ControlPanelCatalog.items.first { $0.id == "personalization" }!
        #expect(item.action == .shellWindow(.personalization))
        #expect(item.tasks.first { $0.title == "Change the theme" }?.action == .shellWindow(.personalization))
        #expect(item.tasks.first { $0.title == "Change desktop background" }?.action == .shellWindow(.desktopBackground))
        #expect(item.tasks.first { $0.title == "Change screen saver" }?.action == .settingsPane(P.wallpaper))
        #expect(item.tasks.first { $0.title == "Change window glass colors" }?.action == .settingsPane(P.appearance))
        let home = ControlPanelCatalog.homeLinks(.appearance)
        #expect(home.first { $0.title == "Change the theme" }?.action == .shellWindow(.personalization))
        #expect(home.first { $0.title == "Change desktop background" }?.action == .shellWindow(.desktopBackground))
        #expect(ShellWindowTarget.personalization.identifier == "win7.personalization")
        #expect(ShellWindowTarget.desktopBackground.identifier == "win7.desktopbackground")
        #expect(ShellWindowTarget.personalization.title == "Personalization")
        #expect(ShellWindowTarget.desktopBackground.title == "Desktop Background")
        for text in [ControlPanelCatalog.windowColorInfo, ControlPanelCatalog.desktopIconsInfo, ControlPanelCatalog.mousePointersInfo] {
            #expect(text.count > 40)
        }
    }
}
