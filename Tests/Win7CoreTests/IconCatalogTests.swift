import Foundation
import Testing
@testable import Win7Core

// Icons everywhere, the one list of override names the code reads, and the check that the map files
// cover them (the repo-map coverage test itself is one of them).

/// A path relative to the repository root (this file is Tests/Win7CoreTests/IconCatalogTests.swift).
private func repoURL(_ path: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(path)
}

@Suite struct IconCatalogTests {
    @Test func catalogueIsSortedUniqueAndSafe() {
        #expect(IconCatalog.all == Array(Set(IconCatalog.all)).sorted())
        #expect(IconCatalog.shell == Array(Set(IconCatalog.shell)).sorted())
        #expect(IconCatalog.chrome == Array(Set(IconCatalog.chrome)).sorted())
        for n in IconCatalog.all { #expect(IconOverrideNames.isSafeName(Substring(n + ".png"), ext: ".png"), "\(n)") }
        #expect(IconCatalog.shell.contains("cp-sync-center") && IconCatalog.shell.contains("tray-battery-4-charging"))
    }

    @Test func allIsTheUnionOfShellAndChrome() {
        #expect(Set(IconCatalog.all) == Set(IconCatalog.shell).union(IconCatalog.chrome))
        // The IE glyphs are chrome-only; the tray and Control Panel are shell-only.
        #expect(!IconCatalog.shell.contains("ie-home") && IconCatalog.chrome.contains("ie-home"))
        #expect(!IconCatalog.chrome.contains { $0.hasPrefix("tray-") || $0.hasPrefix("cp-") })
        // Finder's sidebar Recents and Shared rows, in both lists.
        for n in ["recent-places", "shared"] { #expect(IconCatalog.shell.contains(n) && IconCatalog.chrome.contains(n), "\(n)") }
    }

    @Test func controlPanelNamesComeFromTheModel() {
        let cp = Set(IconCatalog.shell.filter { $0.hasPrefix("cp-") })
        let expected = Set(ControlPanelCategory.allCases.map { $0.iconNames[0] } + ControlPanelCatalog.items.map { $0.iconNames[0] })
        #expect(cp == expected)
        for c in ["cp-system-security", "cp-user-accounts", "cp-network-internet", "cp-appearance", "cp-hardware-sound",
                  "cp-clock-region", "cp-programs", "cp-ease-of-access", "cp-action-center", "cp-sync-center"] {
            #expect(cp.contains(c), "\(c)")
        }
    }

    /// The Device Manager and Devices and Printers icons, shell-only.
    @Test func deviceNamesAreShellOnly() {
        let dev = IconCatalog.shell.filter { $0.hasPrefix("dev-") }
        #expect(dev == ["dev-audio", "dev-battery", "dev-bluetooth", "dev-camera", "dev-computer", "dev-disk", "dev-display",
                        "dev-keyboard", "dev-monitor", "dev-mouse", "dev-network", "dev-printer", "dev-processor",
                        "dev-storage", "dev-usb"])
        #expect(!IconCatalog.chrome.contains { $0.hasPrefix("dev-") })
    }

    @Test func trayNamesFollowTheTraysAssetNames() {
        let tray = IconCatalog.shell.filter { $0.hasPrefix("tray-") }
        var expected = ["tray-wired", "tray-disconnected", "tray-no-network", "tray-action-center", "tray-action-center-alert"]
        for l in 0...4 {
            expected += ["tray-wifi-\(l)", "tray-volume-\(l)", "tray-battery-\(l)", "tray-battery-\(l)-charging"]
        }
        #expect(tray == expected.sorted())
        #expect(!IconCatalog.all.contains("tray-chevron"))
    }

    @Test func chromeNamesFileMatchesCatalogue() throws {
        let text = try String(contentsOf: repoURL("scripts/chrome-icon-names.txt"), encoding: .utf8)
        #expect(text.split(separator: "\n").map(String.init) == IconCatalog.chrome)
    }

    @Test func repoMapsCoverTheCatalogue() throws {
        let iconMap = try IconOverrideNames.parseMap(String(contentsOf: repoURL("scripts/win7-icon-map.txt"), encoding: .utf8))
        let assetMap = try String(contentsOf: repoURL("scripts/win7-asset-map.txt"), encoding: .utf8)
        #expect(IconCatalog.uncovered(names: IconCatalog.all, iconMap: iconMap, assetMapText: assetMap) == [])
    }

    /// Assets/README.md's icon list keeps up with the catalogue: every name outside the families it lists
    /// as a pattern appears as `<name>.png`, each family is described, and `ICON/-` is explained.
    @Test func assetsReadmeListsTheCatalogue() throws {
        let readme = try String(contentsOf: repoURL("Assets/README.md"), encoding: .utf8)
        let families = ["app-", "tray-", "cp-", "dev-", "folder-", "file-", "msgbox-", "ie-"]
        for name in IconCatalog.all where !families.contains(where: name.hasPrefix) {
            #expect(readme.contains("\(name).png"), "\(name)")
        }
        for pattern in ["`app-<bundle id>.png`", "`tray-<name>.png`", "`cp-<name>.png`", "`dev-<name>.png`", "`folder-{", "`file-text.png`",
                        "`msgbox-{", "`ie-{", "`ICON/-`"] {
            #expect(readme.contains(pattern), "\(pattern)")
        }
    }

    @Test func uncoveredTreatsUnchosenIdsAsCovered() {
        let text = "icons/help.png  Windows/System32/shell32.dll ICON/?\nCONTACT Windows/System32/imageres.dll\n"
        #expect(IconCatalog.uncovered(names: ["help", "run"], iconMap: IconMap(), assetMapText: text) == ["run"])
    }

    @Test func uncoveredTreatsNoIconOnThisMediaAsCovered() {
        // ICON/- marks an icon the media cannot provide (the drawn icon stays): covered, like ICON/?.
        let text = "icons/tray-battery-0.png  Windows/System32/batmeter.dll ICON/-   # no icon resource\n"
            + "icons/help.png Windows/System32/imageres.dll ICON/?\n"
        #expect(IconCatalog.uncovered(names: ["help", "run", "tray-battery-0"], iconMap: IconMap(), assetMapText: text) == ["run"])
    }

    @Test func repoMapMarksOnlyRealUnknownsWithAQuestionMark() throws {
        // Only cp-location-sensors is still to be chosen; icons this media lacks say ICON/-.
        let text = try String(contentsOf: repoURL("scripts/win7-asset-map.txt"), encoding: .utf8)
        var unchosen: [String] = [], absent: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let f = IconOverrideNames.stripComment(raw).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = f.first, let last = f.last, f.count >= 3 else { continue }
            if last == "ICON/?" { unchosen.append(first) }
            if last == "ICON/-" { absent.append(first) }
        }
        // The Bluetooth and USB device-class icons were chosen off the contact sheets (bthprops 151, setupapi 20).
        #expect(unchosen == ["icons/cp-location-sensors.png"])
        let battery = (0...4).flatMap { ["icons/tray-battery-\($0).png", "icons/tray-battery-\($0)-charging.png"] }
        #expect(Set(absent) == Set(battery + ["icons/ie-add-favorite.png", "icons/app-com.apple.Notes.png",
                                              "icons/cp-mobility-center.png"]))
        #expect(absent.count == 13)
    }

    @Test func uncoveredAcceptsEitherMap() throws {
        let iconMap = try IconOverrideNames.parseMap("shell32:24 help.png\nexplorer.ico app-com.apple.finder.png")
        let text = """
        # icons/run.png in a comment does not count
        icons/folder.png   Windows/System32/imageres.dll ICON/3   # trailing comment
        icons/user.png     ProgramData/Microsoft/User Account Pictures/Default Pictures/usertile11.bmp
        cursors/arrow.png  Windows/Cursors/aero_arrow.cur
        """
        let names = ["app-com.apple.finder", "arrow", "folder", "help", "run", "user"]
        #expect(IconCatalog.uncovered(names: names, iconMap: iconMap, assetMapText: text) == ["arrow", "run"])
    }
}
