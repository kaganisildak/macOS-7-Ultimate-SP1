import Testing
import Foundation
import CoreGraphics
@testable import Win7Core

/// scripts/fixtures/control-panel-pane-ids.txt: bundle id -> appex name.
private func fixturePanes() throws -> [String: String] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("scripts/fixtures/control-panel-pane-ids.txt")
    var panes: [String: String] = [:]
    for line in try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    where !line.isEmpty && !line.hasPrefix("#") {
        let fields = line.components(separatedBy: "\t")
        #expect(fields.count == 2, "fixture line \(line)")
        if fields.count == 2 { panes[fields[0]] = fields[1] }
    }
    return panes
}

/// Every action of the catalog: items, their tasks, the home sub-links and the task pane's See also.
private func allActions() -> [ControlPanelAction] {
    ControlPanelCatalog.items.flatMap { [$0.action] + $0.tasks.map(\.action) }
        + ControlPanelCategory.allCases.flatMap { ControlPanelCatalog.homeLinks($0).map(\.action) }
        + [ControlPanelCatalog.systemSettings]
}

private func item(_ id: String) -> ControlPanelItem { ControlPanelCatalog.items.first { $0.id == id }! }

@Suite struct ControlPanelMappingTests {
    @Test func everyPaneIdIsAVerifiedSettingsExtension() throws {
        let fixture = try fixturePanes()
        #expect(fixture.count > 30)
        var panes = Set<String>()
        for case .settingsPane(let id) in allActions() { panes.insert(id) }
        #expect(panes.count >= 25)
        for id in panes {
            #expect(fixture[id] != nil, "\(id) is not in the verified list")
            #expect(ControlPanelCatalog.paneBundles[id] == fixture[id], "\(id): appex name")
        }
        // The table holds no pane the catalog doesn't use, and each entry matches the fixture.
        for (id, appex) in ControlPanelCatalog.paneBundles {
            #expect(panes.contains(id), "\(id) unused")
            #expect(fixture[id] == appex, "\(id)")
        }
    }

    @Test func everyItemHasAnActionAndTheOtherTargetsAreSafe() {
        let items = ControlPanelCatalog.items
        #expect(Set(items.map(\.id)).count == items.count)
        for item in items {
            #expect(!item.title.isEmpty && !item.id.isEmpty)
            #expect(item.iconNames.first == "cp-\(item.id)")
        }
        for action in allActions() {
            switch action {
            case .settingsPane(let id): #expect(id.hasPrefix("com.apple."))
            case .app(let path):
                #expect(path.hasSuffix(".app") && (path.hasPrefix("/System/Applications/") || path == "/Applications/Safari.app"), "\(path)")
            case .finder(let path): #expect(path == "~" || path.hasPrefix("/"), "\(path)")
            case .url(let s): #expect(s.hasPrefix("x-apple.systempreferences:"), "\(s)")
            case .win7mac(let text): #expect(text.count > 40)
            case .shellWindow: break
            }
        }
    }

    @Test func categoriesAndHomeSubLinksAreWindows7s() {
        #expect(ControlPanelCategory.allCases.map(\.title) == [
            "System and Security", "User Accounts", "Network and Internet", "Appearance and Personalization",
            "Hardware and Sound", "Clock, Language, and Region", "Programs", "Ease of Access",
        ])
        func links(_ c: ControlPanelCategory) -> [String] { ControlPanelCatalog.homeLinks(c).map(\.title) }
        #expect(links(.systemAndSecurity) == ["Review your computer's status", "Back up your computer", "Find and fix problems"])
        #expect(links(.userAccounts) == ["Change account type", "Add or remove user accounts"])
        #expect(links(.networkAndInternet) == ["View network status and tasks", "Choose homegroup and sharing options"])
        #expect(links(.appearance) == ["Change the theme", "Change desktop background", "Adjust screen resolution"])
        #expect(links(.hardwareAndSound) == ["View devices and printers", "Add a device", "Adjust commonly used mobility settings"])
        #expect(links(.clockLanguageRegion) == ["Change keyboards or other input methods", "Change display language"])
        #expect(links(.programs) == ["Uninstall a program"])
        #expect(links(.easeOfAccess) == ["Let Windows suggest settings", "Optimize visual display"])
        for c in ControlPanelCategory.allCases {
            #expect(!ControlPanelCatalog.items(in: c).isEmpty, "\(c)")
            #expect(c.iconNames.first?.hasPrefix("cp-") == true)
        }
    }

    @Test func theBriefsTargets() {
        typealias P = ControlPanelCatalog.Pane
        #expect(item("windows-update").action == .settingsPane(P.softwareUpdate))
        #expect(item("backup-restore").action == .settingsPane(P.timeMachine))
        #expect(item("bitlocker").action == .settingsPane(P.privacySecurity))
        #expect(item("system").action == .settingsPane(P.about))
        #expect(item("system").tasks.contains { $0.action == .app("/System/Applications/Utilities/System Information.app") })
        #expect(item("user-accounts").action == .settingsPane(P.usersGroups))
        #expect(item("parental-controls").action == .settingsPane(P.screenTime))
        #expect(item("network-sharing-center").action == .settingsPane(P.network))
        #expect(item("internet-options").action == .app("/Applications/Safari.app"))
        #expect(item("homegroup").action == .settingsPane(P.sharing))
        #expect(item("personalization").tasks.map(\.action).contains(.settingsPane(P.wallpaper)))
        #expect(item("personalization").tasks.contains { if case .win7mac = $0.action { true } else { false } })
        #expect(item("taskbar-start-menu").action == .win7mac(ControlPanelCatalog.taskbarInfo))
        #expect(item("folder-options").action == .finder("~"))
        #expect(item("fonts").action == .app("/System/Applications/Font Book.app"))
        // The shell's own Devices and Printers window; "Add a printer" still opens the pane.
        #expect(item("devices-printers").action == .shellWindow(.devicesAndPrinters))
        #expect(item("devices-printers").tasks.map(\.action).contains(.settingsPane(P.printers)))
        #expect(item("autoplay").action == .settingsPane(P.cdsAndDVDs))
        #expect(item("date-time").action == .settingsPane(P.dateTime))
        #expect(item("programs-features").action == .finder("/Applications"))
        #expect(item("ease-of-access-center").action == .settingsPane(P.accessibility))
        #expect(item("action-center").action == .settingsPane(P.notifications))
        #expect(ControlPanelCatalog.taskbarInfo.contains("com.win7mac.shell"))
        #expect(ControlPanelCatalog.lookInfo.contains("make wallpaper SRC=") && ControlPanelCatalog.lookInfo.contains("make import-icons SRC="))
        // the full import, the dylib's embedded copies, and how ids are chosen.
        for s in ["make import-assets SRC=", "7zz", "make install", "make chrome", "make install-chrome", "ICON/?",
                  "Assets/_contact/", "ICON/-"] {
            #expect(ControlPanelCatalog.lookInfo.contains(s), "\(s)")
        }
        // the files, not the folder (`cp -R Assets/icons …/icons` makes icons/icons), as README.md says.
        #expect(ControlPanelCatalog.lookInfo.contains(
            "copy the files in Assets/icons into ~/Library/Application Support/Win7Mac/Assets/icons"))
    }

    /// System's and Devices and Printers' "Device Manager" links, the Devices and Printers item and the
    /// home page's "View devices and printers" open the shell's windows, which always exist.
    /// Display ▸ "Adjust resolution" and the home page's "Adjust screen resolution" open the shell's
    /// Screen Resolution window.
    @Test func adjustResolutionOpensTheScreenResolutionWindow() {
        #expect(item("display").tasks.first { $0.title == "Adjust resolution" }?.action == .shellWindow(.screenResolution))
        #expect(ControlPanelCatalog.homeLinks(.appearance).last?.action == .shellWindow(.screenResolution))
        #expect(ShellWindowTarget.screenResolution.identifier == "win7.screenresolution")
        #expect(ShellWindowTarget.screenResolution.title == "Screen Resolution")
        #expect(ControlPanelCatalog.displaySettingsInfo.count > 40)
        // "Make text and other items larger or smaller" opens Accessibility (as in the Screen Resolution
        // window), not Displays.
        #expect(item("display").tasks.first { $0.title == "Make text and other items larger or smaller" }?.action
            == .settingsPane(ControlPanelCatalog.Pane.accessibility))
    }

    @Test func deviceWindowsAreShellWindows() {
        #expect(item("system").tasks.first { $0.title == "Device Manager" }?.action == .shellWindow(.deviceManager))
        #expect(item("devices-printers").tasks.first { $0.title == "Device Manager" }?.action == .shellWindow(.deviceManager))
        #expect(ControlPanelCatalog.homeLinks(.hardwareAndSound).first?.action == .shellWindow(.devicesAndPrinters))
        for target in ShellWindowTarget.allCases {
            #expect(ControlPanelAvailability.isAvailable(.shellWindow(target), fileExists: { _ in false }, bundleID: { _ in nil }))
        }
        #expect(ShellWindowTarget.deviceManager.identifier == "win7.devicemanager")
        #expect(ShellWindowTarget.devicesAndPrinters.identifier == "win7.devicesprinters")
        #expect(ShellWindowTarget.deviceManager.title == "Device Manager")
        #expect(ShellWindowTarget.devicesAndPrinters.title == "Devices and Printers")
        #expect(ControlPanelCatalog.deviceManagerInfo.contains("system_profiler"))
    }

    @Test func missingTargetsAreHidden() {
        // Nothing but the Sound extension and Font Book is installed.
        let soundPath = ControlPanelAvailability.extensionsDirectory + "/Sound.appex"
        let available: (ControlPanelAction) -> Bool = {
            ControlPanelAvailability.isAvailable($0, fileExists: { $0 == "/System/Applications/Font Book.app" },
                                                 bundleID: { $0 == soundPath ? ControlPanelCatalog.Pane.sound : nil })
        }
        let visible = ControlPanelAvailability.filter(ControlPanelCatalog.items, available: available)
        #expect(Set(visible.map(\.id)).isSuperset(of: ["sound", "fonts", "taskbar-start-menu", "desktop-gadgets", "getting-started"]))
        #expect(!visible.contains { $0.id == "autoplay" || $0.id == "display" })
        // Sound's Audio MIDI Setup task is gone; its pane tasks stay.
        #expect(visible.first { $0.id == "sound" }?.tasks.map(\.title) == ["Adjust system volume", "Change system sounds"])
        // A pane whose bundle id doesn't match, or that the table doesn't know, is unavailable.
        #expect(!ControlPanelAvailability.isAvailable(.settingsPane(ControlPanelCatalog.Pane.sound), fileExists: { _ in true },
                                                      bundleID: { _ in "com.example.other" }))
        #expect(!ControlPanelAvailability.isAvailable(.settingsPane("com.apple.Unknown"), fileExists: { _ in true },
                                                      bundleID: { _ in "com.apple.Unknown" }))
        #expect(ControlPanelAvailability.isAvailable(.finder("~"), fileExists: { $0 == NSHomeDirectory() }, bundleID: { _ in nil }))
        #expect(ControlPanelAvailability.isAvailable(.url("x-apple.systempreferences:"), fileExists: { _ in false }, bundleID: { _ in nil }))
    }
}

@Suite struct ControlPanelSearchTests {
    private let items = ControlPanelCatalog.items

    @Test func prefixThenWordThenSubstringThenTasks() {
        let ids = ControlPanelSearch.search("power", in: items).map(\.id)
        #expect(ids.first == "power-options")
        // "sound": the Sound item first, then items whose tasks or keywords mention it.
        let sound = ControlPanelSearch.search("sound", in: items).map(\.id)
        #expect(sound.first == "sound")
        #expect(sound.contains("personalization") && sound.contains("ease-of-access-center"))
        // A word inside the title ranks before a task match.
        let options = ControlPanelSearch.search("options", in: items).map(\.id)
        #expect(Array(options.prefix(4)).allSatisfy { ["power-options", "internet-options", "folder-options", "indexing-options"].contains($0) })
        #expect(ControlPanelSearch.search("ound", in: items).first?.id == "sound")   // a title substring
    }

    @Test func caseAndDiacriticInsensitiveAlsoInTurkish() {
        #expect(ControlPanelSearch.search("DÍSPLAY", in: items).first?.id == "display")
        #expect(ControlPanelSearch.search("ındexing", in: items).first?.id == "indexing-options")
        #expect(ControlPanelSearch.search("INDEX", in: items).first?.id == "indexing-options")
        #expect(ControlPanelSearch.search("filevault", in: items).map(\.id) == ["bitlocker"])
        #expect(ControlPanelSearch.search("   ", in: items).isEmpty)
        #expect(ControlPanelSearch.search("zzzz", in: items).isEmpty)
    }
}

@Suite struct ControlPanelHistoryTests {
    @Test func backAndForwardEnableStates() {
        var h = ControlPanelHistory()
        #expect(h.current == .home && !h.canGoBack && !h.canGoForward)
        var moved = h.navigate(to: .category(.programs))
        #expect(moved)
        moved = h.navigate(to: .category(.programs))   // the current page again: no new entry
        #expect(!moved)
        #expect(h.canGoBack && !h.canGoForward)
        h.navigate(to: .category(.easeOfAccess))
        moved = h.goBack()
        #expect(moved && h.current == .category(.programs))
        #expect(h.canGoBack && h.canGoForward)
        moved = h.goBack()
        #expect(moved && h.current == .home)
        moved = h.goBack()
        #expect(!h.canGoBack && h.canGoForward && !moved)
        moved = h.goForward()
        #expect(moved && h.current == .category(.programs))
        // Going somewhere new drops the forward list.
        h.navigate(to: .category(.userAccounts))
        moved = h.goForward()
        #expect(!h.canGoForward && !moved)
        #expect(h.back == [.home, .category(.programs)])
    }

    @Test func historyIsBounded() {
        var h = ControlPanelHistory()
        for i in 0..<120 { h.navigate(to: .info(title: "\(i)", text: "", category: nil)) }
        #expect(h.back.count == ControlPanelHistory.limit)
    }

    @Test func breadcrumbs() {
        func titles(_ l: ControlPanelLocation, _ m: ControlPanelViewMode = .category, searching: Bool = false) -> [String] {
            ControlPanelHistory.breadcrumbs(l, viewMode: m, searching: searching).map(\.title)
        }
        #expect(titles(.home) == ["Control Panel"])
        #expect(titles(.home, .largeIcons) == ["Control Panel", "All Control Panel Items"])
        #expect(titles(.category(.hardwareAndSound)) == ["Control Panel", "Hardware and Sound"])
        #expect(titles(.info(title: "Taskbar and Start Menu", text: "x", category: .appearance))
                == ["Control Panel", "Appearance and Personalization", "Taskbar and Start Menu"])
        #expect(titles(.info(title: "Getting Started", text: "x", category: nil)) == ["Control Panel", "Getting Started"])
        #expect(titles(.category(.programs), searching: true) == ["Control Panel", "Search Results"])
        // Each crumb goes where it says.
        let crumbs = ControlPanelHistory.breadcrumbs(.info(title: "T", text: "x", category: .programs), viewMode: .category)
        #expect(crumbs.map(\.location) == [.home, .category(.programs), .info(title: "T", text: "x", category: .programs)])
    }
}

@Suite struct ControlPanelLayoutTests {
    typealias L = ControlPanelLayout

    @Test func categoryHomeAtThreeWidths() {
        let counts = ControlPanelCategory.allCases.map { ControlPanelCatalog.homeLinks($0).count }
        // 580 (the default 780 window minus the task pane): two columns of 256.
        let wide = L.listFrames(linkCounts: counts, width: 580, top: 60, icon: L.categoryIcon)
        #expect(L.columnCount(width: 580) == 2 && wide.count == 8)
        #expect(wide[0].minX == L.margin && wide[1].minX == L.margin + wide[0].width + L.columnGap)
        #expect(wide[0].width == (580 - 2 * L.margin - L.columnGap) / 2)
        #expect(wide[0].minY == 60 && wide[0].minY == wide[1].minY)
        // Row 1: System and Security (3 links) next to User Accounts (2): the row is the taller one's height.
        #expect(wide[2].minY == 60 + L.cellHeight(links: 3, icon: 48) + L.rowGap)
        #expect(wide[2].minX == wide[0].minX && wide[3].minX == wide[1].minX)
        // 1200: still two columns, capped at the maximum width.
        let wider = L.listFrames(linkCounts: counts, width: 1200, top: 0, icon: L.categoryIcon)
        #expect(L.columnCount(width: 1200) == 2 && wider[0].width == L.maxColumnWidth)
        #expect(wider[1].minX == L.margin + L.maxColumnWidth + L.columnGap)
        // 400: one column, entries stacked.
        let narrow = L.listFrames(linkCounts: counts, width: 400, top: 0, icon: L.categoryIcon)
        #expect(L.columnCount(width: 400) == 1 && narrow.allSatisfy { $0.minX == L.margin && $0.width == min(L.maxColumnWidth, 400 - 2 * L.margin) })
        #expect(zip(narrow, narrow.dropFirst()).allSatisfy { $1.minY == $0.maxY + L.rowGap })
        #expect(L.contentHeight(narrow, top: 0) == narrow.last!.maxY + L.margin)
        // A cell is at least as tall as its icon.
        #expect(L.cellHeight(links: 0, icon: 48) == 48 && L.cellHeight(links: 4, icon: 32) == L.titleLine + 4 * L.linkLine)
    }

    @Test func iconViewsAtThreeWidths() {
        let large = L.iconCellSize(.largeIcons), small = L.iconCellSize(.smallIcons)
        // 580: two large columns, two small; 1200: four large, five small; 200: one each.
        for (width, nLarge, nSmall) in [(CGFloat(580), 2, 2), (1200, 4, 5), (200, 1, 1)] {
            #expect(L.iconColumnCount(width: width, mode: .largeIcons) == nLarge, "\(width)")
            #expect(L.iconColumnCount(width: width, mode: .smallIcons) == nSmall, "\(width)")
            let frames = L.iconFrames(count: 7, width: width, mode: .largeIcons, top: 50)
            #expect(frames.count == 7)
            #expect(frames[0] == CGRect(x: L.margin, y: 50, width: large.width, height: large.height))
            // Row by row: item n is in column n % columns.
            let last = frames[6]
            #expect(last.minX == L.margin + CGFloat(6 % nLarge) * (large.width + L.iconGap))
            #expect(last.minY == 50 + CGFloat(6 / nLarge) * large.height)
            // Every cell fits inside the margins (one column may be clipped when even one doesn't fit).
            if nLarge > 1 { #expect(frames.allSatisfy { $0.maxX <= width - L.margin + 0.001 }) }
        }
        #expect(L.iconSide(.largeIcons) == 32 && L.iconSide(.smallIcons) == 16 && small.height == 24)
        #expect(L.iconFrames(count: 0, width: 580, mode: .smallIcons, top: 0).isEmpty)
    }
}
