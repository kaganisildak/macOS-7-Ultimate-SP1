import AppKit
import Testing
import Win7ChromeCore

// Finder's Computer location shown as the Windows 7 Computer view — the pure model (groups, rows,
// capacity text, details, location signal, command set) and the overlay on fake locations. Windows are never
// ordered on screen and no events are posted.

private let GB: Int64 = 1_000_000_000

/// One volume's facts as W7ComputerReadVolumeFacts gives them (URL resource values plus the path).
private func volume(_ path: String, _ name: String, root: Bool = false, internal: Bool = true, removable: Bool = false,
                    ejectable: Bool = false, local: Bool = true, browsable: Bool = true, type: String = "apfs",
                    total: Int64 = 500 * GB, free: Int64 = 200 * GB) -> [String: Any] {
    [
        W7ComputerVolumePathKey: path,
        URLResourceKey.volumeLocalizedNameKey.rawValue: name,
        URLResourceKey.volumeIsRootFileSystemKey.rawValue: root,
        URLResourceKey.volumeIsInternalKey.rawValue: `internal`,
        URLResourceKey.volumeIsRemovableKey.rawValue: removable,
        URLResourceKey.volumeIsEjectableKey.rawValue: ejectable,
        URLResourceKey.volumeIsLocalKey.rawValue: local,
        URLResourceKey.volumeIsBrowsableKey.rawValue: browsable,
        URLResourceKey.volumeTypeNameKey.rawValue: type,
        URLResourceKey.volumeTotalCapacityKey.rawValue: NSNumber(value: total),
        URLResourceKey.volumeAvailableCapacityForImportantUsageKey.rawValue: NSNumber(value: free),
        URLResourceKey.volumeLocalizedFormatDescriptionKey.rawValue: "APFS",
    ]
}

private var sampleFacts: [[String: Any]] { [
    volume("/Volumes/Data Disk", "Data Disk"),
    volume("/Volumes/server", "Projects", internal: false, local: false, type: "smbfs", total: 2000 * GB, free: 900 * GB),
    volume("/Volumes/USB", "USB Stick", internal: false, removable: true, ejectable: true, type: "msdos", total: 16 * GB, free: 1 * GB),
    volume("/", "Macintosh HD", root: true, total: 460 * GB, free: 117 * GB),
    volume("/Volumes/DVD", "Holiday DVD", internal: false, removable: true, ejectable: true, type: "cd9660", total: 4 * GB, free: 0),
    volume("/System/Volumes/Data", "Data", internal: true),                 // the system's own volumes: hidden
    volume("/private/var/vm", "VM", internal: true),
    volume("/Volumes/Hidden", "Hidden", browsable: false),                // not browsable: hidden
    volume("/Volumes/Backup", "Backup", internal: false, ejectable: true, total: 1000 * GB, free: 50 * GB),
] }

@Test func computerGroupsInWindowsSevenOrder() {
    let groups = W7ComputerGroupsFromVolumes(sampleFacts)
    #expect(groups.map(\.title) == ["Hard Disk Drives", "Devices with Removable Storage", "Network Location"])
    #expect(groups.map(\.kind) == [.hardDisks, .removable, .network])
    // The system drive first, then the others by name.
    #expect(groups[0].rows.map(\.name) == ["Macintosh HD", "Data Disk"])
    #expect(groups[0].rows.map(\.kind) == [.system, .internal])
    #expect(groups[0].rows.map(\.iconName) == ["drive-system", "drive"])
    #expect(groups[1].rows.map(\.name) == ["Backup", "Holiday DVD", "USB Stick"])
    #expect(groups[1].rows.map(\.kind) == [.removable, .optical, .removable])
    #expect(groups[1].rows.map(\.iconName) == ["drive-removable", "drive-optical", "drive-removable"])
    #expect(groups[2].rows.map(\.name) == ["Projects"])
    #expect(groups[2].rows.first?.kind == .network && groups[2].rows.first?.iconName == "network")
    let usb = groups[1].rows[2]
    #expect(usb.path == "/Volumes/USB" && usb.total == 16 * GB && usb.free == 1 * GB && usb.ejectable)
    #expect(!groups[0].rows[0].ejectable)
}

@Test func computerEmptyGroupsAreHidden() {
    let groups = W7ComputerGroupsFromVolumes([volume("/", "Macintosh HD", root: true)])
    #expect(groups.map(\.title) == ["Hard Disk Drives"])
    #expect(W7ComputerGroupsFromVolumes([]).isEmpty)
    // Facts without a path or a name are skipped; the name falls back to the path's last component.
    var noName = volume("/Volumes/Thing", "x")
    noName.removeValue(forKey: URLResourceKey.volumeLocalizedNameKey.rawValue)
    var noPath = volume("/Volumes/Other", "Other")
    noPath.removeValue(forKey: W7ComputerVolumePathKey)
    #expect(W7ComputerGroupsFromVolumes([noName, noPath]).flatMap(\.rows).map(\.name) == ["Thing"])
}

@Test func computerHiddenVolumes() {
    #expect(W7ComputerVolumeIsHidden(volume("/System/Volumes/Preboot", "Preboot")))
    #expect(W7ComputerVolumeIsHidden(volume("/private/var/vm", "VM")))
    #expect(W7ComputerVolumeIsHidden(volume("/Volumes/X", "X", browsable: false)))
    #expect(W7ComputerVolumeIsHidden(volume("/dev", "devfs", type: "devfs")))
    #expect(!W7ComputerVolumeIsHidden(volume("/", "Macintosh HD", root: true)))
    #expect(!W7ComputerVolumeIsHidden(volume("/Volumes/USB", "USB")))
    #expect(!W7ComputerVolumeIsHidden(volume("/Volumes/SystemVolumesLookalike", "S")))
}

@Test func computerLowSpaceUnderTenPercent() {
    #expect(W7ComputerCapacityIsLow(9 * GB, 100 * GB))
    #expect(!W7ComputerCapacityIsLow(10 * GB, 100 * GB))
    #expect(!W7ComputerCapacityIsLow(0, 0))           // unknown total: not low
    let rows = W7ComputerGroupsFromVolumes(sampleFacts).flatMap(\.rows)
    #expect(rows.filter(\.low).map(\.name) == ["Backup", "Holiday DVD", "USB Stick"])
}

@Test func computerCapacityTextUsesWholeGigabytesRoundedDown() {
    #expect(W7ComputerCapacityText(117_900_000_000, 460_400_000_000) == "117 GB free of 460 GB")
    #expect(W7ComputerCapacityText(0, 4 * GB) == "0 GB free of 4 GB")
    #expect(W7ComputerCapacityText(999_999_999, 1 * GB) == "0 GB free of 1 GB")
    // Under 1 GB in all: megabytes, still whole and rounded down.
    #expect(W7ComputerCapacityText(312_700_000, 512_000_000) == "312 MB free of 512 MB")
    #expect(W7ComputerCapacityText(-1, 0) == "")
    // 1000 GB and up: terabytes with one decimal, rounded down, as Windows 7 shows them; each value on its own.
    #expect(W7ComputerCapacityText(3_950_000_000_000, 4_000_000_000_000) == "3.9 TB free of 4.0 TB")
    #expect(W7ComputerCapacityText(900 * GB, 2000 * GB) == "900 GB free of 2.0 TB")
    #expect(W7ComputerCapacityText(999_999_999_999, 1000 * GB) == "999 GB free of 1.0 TB")
    #expect(W7ComputerCapacityText(1000 * GB, 1_234_567_000_000) == "1.0 TB free of 1.2 TB")
    #expect(W7ComputerCapacityText(117 * GB, 999 * GB) == "117 GB free of 999 GB")
    #expect(W7ComputerCapacityText(5, -1) == "")
    #expect(W7ComputerUsedFraction(25 * GB, 100 * GB) == 0.75)
    #expect(W7ComputerUsedFraction(0, 0) < 0)          // unknown: no bar
    #expect(W7ComputerUsedFraction(200, 100) == 0)     // more free than total: clamped
}

/// Volumes without the important-usage value (some network and FAT volumes) fall back to the plain available capacity.
@Test func computerFreeSpaceFallsBackToAvailableCapacity() {
    let important = URLResourceKey.volumeAvailableCapacityForImportantUsageKey.rawValue
    let available = URLResourceKey.volumeAvailableCapacityKey.rawValue
    var fat = volume("/Volumes/FAT", "FAT", internal: false, removable: true, ejectable: true, type: "msdos", total: 32 * GB)
    fat.removeValue(forKey: important)
    fat[available] = NSNumber(value: 12 * GB)
    var neither = volume("/Volumes/Odd", "Odd", internal: false, removable: true, ejectable: true)
    neither.removeValue(forKey: important)
    var both = volume("/Volumes/Both", "Both", internal: false, removable: true, ejectable: true, free: 30 * GB)
    both[available] = NSNumber(value: 20 * GB)
    let rows = W7ComputerGroupsFromVolumes([fat, neither, both]).flatMap(\.rows)
    #expect(rows.map(\.name) == ["Both", "FAT", "Odd"])
    #expect(rows.map(\.free) == [30 * GB, 12 * GB, -1])   // the important-usage value wins when there is one
    #expect(W7ComputerVolumeResourceKeys().contains(.volumeAvailableCapacityKey))
}

@Test func computerDetailsForADrive() throws {
    let row = try #require(W7ComputerGroupsFromVolumes(sampleFacts).first?.rows.first)
    let d = W7ComputerDetailsForRow(row, Locale(identifier: "en_US"))
    #expect(d.title == "Macintosh HD" && d.titleStyle == .name)
    #expect(d.subtitle == "Local Disk")
    #expect(d.labels == ["Total size:", "Free space:", "File system:"])
    #expect(d.values == ["460 GB", "117 GB", "APFS"])
    #expect(W7ComputerDriveTypeName(.removable) == "Removable Disk")
    #expect(W7ComputerDriveTypeName(.optical) == "CD Drive")
    #expect(W7ComputerDriveTypeName(.network) == "Network Drive")
    #expect(W7ComputerDriveTypeName(.internal) == "Local Disk")
    let text = W7ComputerPropertiesText(row, Locale(identifier: "en_US"))
    #expect(text.contains("Type: Local Disk") && text.contains("Total size: 460 GB") && text.contains("Free space: 117 GB")
            && text.contains("Used space: 343 GB") && text.contains("File system: APFS"))
}

@Test func computerDetailsWithNothingSelected() {
    let d = W7ComputerDetailsForComputer("Studio Mac", "Apple M2", 16 * 1_073_741_824)
    #expect(d.title == "Studio Mac" && d.titleStyle == .name)
    #expect(d.labels == ["Processor:", "Memory:"])
    #expect(d.values == ["Apple M2", "16 GB"])
    let unknown = W7ComputerDetailsForComputer("Studio Mac", nil, 0)
    #expect(unknown.labels.isEmpty)
    #expect(W7ComputerDetailsForComputer("Mac", nil, 8_589_934_592 + 536_870_912).values == ["8.5 GB"])
}

/// The location signal: Finder's Computer location has no folder path, and its window is titled with the computer's
/// name (Finder never titles it "Computer", so a folder or saved search named "Computer" is not covered); a
/// represented x-finder:Computer URL counts too. A title that changed since the location was read is a navigation in
/// flight.
@Test func computerLocationSignal() {
    #expect(W7ExplorerIsComputerLocation(nil, "Studio Mac", "Studio Mac", "Studio Mac", nil))
    #expect(!W7ExplorerIsComputerLocation(nil, "Computer", "Computer", nil, nil))
    #expect(!W7ExplorerIsComputerLocation(nil, "Computer", "Computer", "Studio Mac", nil))
    #expect(!W7ExplorerIsComputerLocation("/Users/k", "Studio Mac", "Studio Mac", "Studio Mac", nil))   // a folder named so
    #expect(!W7ExplorerIsComputerLocation(nil, "Recents", "Recents", "Studio Mac", nil))
    #expect(!W7ExplorerIsComputerLocation(nil, "Studio Mac", "Documents", "Studio Mac", nil))         // navigating away
    #expect(!W7ExplorerIsComputerLocation(nil, "", "", "", nil))
    #expect(!W7ExplorerIsComputerLocation(nil, "Studio Mac", "Studio Mac", nil, nil))                 // name not known yet
    #expect(W7ExplorerIsComputerLocation(nil, "Whatever", "Whatever", nil, URL(string: "x-finder:Computer")))
    #expect(W7ExplorerIsComputerLocation(nil, "Whatever", "Whatever", nil, URL(string: "X-FINDER:computer")))
    #expect(!W7ExplorerIsComputerLocation(nil, "Whatever", "Other", nil, URL(string: "x-finder:Computer")))
    #expect(!W7ExplorerIsComputerLocation(nil, "Whatever", "Whatever", nil, URL(string: "x-finder:Network")))
}

@Test func computerCommandSet() {
    let set = W7ExplorerCommandsForComputer().map { W7ExplorerCommand(rawValue: $0.intValue)! }
    #expect(set == [.systemProperties, .uninstallProgram, .mapNetworkDrive, .openControlPanel])
    #expect(set.map { W7ExplorerCommandTitle($0) }
            == ["System properties", "Uninstall or change a program", "Map network drive", "Open Control Panel"])
    #expect(!set.contains { W7ExplorerCommandHasMenu($0) })
    #expect(W7ControlPanelShowNotificationName == "com.win7mac.controlpanel.show")
    #expect(W7ComputerSystemPropertiesURL().absoluteString == "x-apple.systempreferences:com.apple.SystemProfiler.AboutExtension")
}

/// The real volume read: the root file system is there, as the system drive, with its capacity.
@Test func computerReadsTheRootVolume() throws {
    let facts = W7ComputerReadVolumeFacts()
    let root = try #require(facts.first { ($0[W7ComputerVolumePathKey] as? String) == "/" })
    #expect((root[URLResourceKey.volumeIsRootFileSystemKey.rawValue] as? Bool) == true)
    #expect(((root[URLResourceKey.volumeTotalCapacityKey.rawValue] as? NSNumber)?.int64Value ?? 0) > 0)
    let system = W7ComputerGroupsFromVolumes(facts).first?.rows.first
    #expect(system?.kind == .system && system?.path == "/")
}

// MARK: - The overlay

@MainActor private func computerWindow(title: String) -> (NSWindow, browser: NSView) {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 500),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                     backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.titlebarAppearsTransparent = true
    w.toolbar = NSToolbar(identifier: "W7ComputerViewTestToolbar")
    w.title = title
    let split = NSSplitView(frame: w.contentView!.bounds)
    split.isVertical = true
    let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 500))
    let browser = NSView(frame: NSRect(x: 201, y: 0, width: 699, height: 500))
    let finderView = NSScrollView(frame: browser.bounds)
    finderView.autoresizingMask = [.width, .height]
    browser.addSubview(finderView)
    split.addArrangedSubview(sidebar)
    split.addArrangedSubview(browser)
    w.contentView = split
    return (w, browser)
}

@MainActor private func commandTitles(_ w: NSWindow) -> [String] {
    let bar = w.titlebarAccessoryViewControllers[1].view
    let commands = (bar.value(forKey: "commands") as? [NSNumber]) ?? []
    return commands.map { W7ExplorerCommandTitle(W7ExplorerCommand(rawValue: $0.intValue)!) }
}

@MainActor private func withComputerSeams(_ body: () throws -> Void) rethrows {
    W7ComputerViewUseComputerName("Studio Mac")
    W7ComputerViewUseVolumeFacts { sampleFacts }
    W7ComputerViewUseDisabledOverride(0)
    defer {
        W7ComputerViewUseComputerName(nil)
        W7ComputerViewUseVolumeFacts(nil)
        W7ComputerViewUseVolumeReader(nil)
        W7ComputerViewUseReadBudget(0)
        W7ComputerViewUseCommandSink(-1, nil)
        W7ComputerViewUseDisabledOverride(-1)
    }
    try body()
}

@MainActor @Test func computerOverlayShowsOnTheComputerLocationAndHidesOnNavigation() throws {
    try withComputerSeams {
        let (w, browser) = computerWindow(title: "Studio Mac")
        let finderViews = browser.subviews
        W7ExplorerAdopt(w)   // titled with the computer's name, but the adoption seed is no location read from Finder
        #expect(W7ExplorerComputerViewForWindow(w) == nil)
        W7ExplorerSetLocationForTesting(w, nil, "Studio Mac")
        let view = try #require(W7ExplorerComputerViewForWindow(w))
        #expect(view.groups.map(\.title) == ["Hard Disk Drives", "Devices with Removable Storage", "Network Location"])
        // Over Finder's view (which stays where it was) and under the details pane, which floats at the bottom.
        let overlay = try #require(view.enclosingScrollView)
        #expect(overlay.superview === browser)
        #expect(overlay.appearance?.name == .aqua)   // the scroller matches the always-white page in a dark window
        #expect(finderViews.allSatisfy { $0.superview === browser && !$0.isHidden })
        let pane = try #require(browser.subviews.first { $0 is W7ExplorerDetailsView })
        #expect(browser.subviews.last === pane)
        #expect(overlay.frame == NSRect(x: 0, y: pane.frame.height, width: browser.bounds.width,
                                        height: browser.bounds.height - pane.frame.height))
        #expect(commandTitles(w) == ["System properties", "Uninstall or change a program", "Map network drive", "Open Control Panel"])
        // Details: the computer with nothing selected, the drive once one is selected.
        let details = try #require(pane as? W7ExplorerDetailsView)
        #expect(details.content?.title == "Studio Mac")
        view.selectRow(at: 0)   // the details pane follows at once
        #expect(details.content?.title == "Macintosh HD" && details.content?.subtitle == "Local Disk")
        // Navigating: the title changes first (the location query follows), and the overlay goes at once.
        w.title = "Documents"
        #expect(W7ExplorerComputerViewForWindow(w) == nil)
        #expect(overlay.superview == nil)
        #expect(finderViews.allSatisfy { $0.superview === browser })
        #expect(commandTitles(w).first == "Organize")
        W7ExplorerSetLocationForTesting(w, "/Users/k/Documents", "Documents")
        #expect(W7ExplorerComputerViewForWindow(w) == nil)
        #expect(details.content?.title != "Macintosh HD")
        // Back to Computer.
        w.title = "Studio Mac"
        W7ExplorerSetLocationForTesting(w, nil, "Studio Mac")
        #expect(W7ExplorerComputerViewForWindow(w) != nil)
        w.close()
    }
}

@MainActor @Test func computerOverlayStaysOffWithTheKillSwitch() {
    withComputerSeams {
        W7ComputerViewUseDisabledOverride(1)
        let (w, _) = computerWindow(title: "Studio Mac")
        W7ExplorerAdopt(w)
        W7ExplorerSetLocationForTesting(w, nil, "Studio Mac")
        #expect(W7ExplorerComputerViewForWindow(w) == nil)
        #expect(commandTitles(w).first == "Organize")
        w.close()
    }
}

@MainActor @Test func computerOverlayFailsOpenWithoutABrowserPane() {
    withComputerSeams {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable],
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.title = "Studio Mac"
        W7ExplorerAdopt(w)
        W7ExplorerSetLocationForTesting(w, nil, "Studio Mac")
        #expect(W7ExplorerComputerViewForWindow(w) == nil)   // no split view: Finder's view stays as it is
        #expect(commandTitles(w).first == "Organize")
        w.close()
    }
}

@MainActor @Test func computerViewLaysOutTilesInGroupsAndHitTests() {
    let view = W7ExplorerComputerView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    view.groups = W7ComputerGroupsFromVolumes(sampleFacts)
    #expect(view.isFlipped)
    let rows = view.groups.flatMap(\.rows)
    let frames = (0..<rows.count).map { view.frameOfRow(at: $0) }
    #expect(frames.allSatisfy { $0.width == W7ComputerTileWidth && $0.height == W7ComputerTileHeight })
    // Two tiles per line at 600 pt; each group starts on a new line below its header.
    #expect(frames[0].minY == frames[1].minY && frames[1].minX > frames[0].maxX)
    #expect(frames[2].minY > frames[1].maxY)                  // first removable: the next group
    #expect(frames[4].minY > frames[3].maxY)                  // the third removable wraps
    #expect(frames[5].minY > frames[4].maxY)                  // network: its own group
    for (i, f) in frames.enumerated() { #expect(view.rowIndex(at: NSPoint(x: f.midX, y: f.midY)) == i) }
    #expect(view.rowIndex(at: NSPoint(x: 590, y: 2)) == NSNotFound)
    #expect(view.height(forWidth: 600) >= frames.last!.maxY)
    // Narrow: one tile per line.
    #expect(view.height(forWidth: 280) > view.height(forWidth: 600))
    view.selectRow(at: 3)
    #expect(view.selectedRow?.name == rows[3].name)
    view.selectRow(at: 99)
    #expect(view.selectedRow == nil)
}

@MainActor @Test func computerViewDrawsTilesWithoutThrowing() {
    let view = W7ExplorerComputerView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    view.groups = W7ComputerGroupsFromVolumes(sampleFacts)
    view.selectRow(at: 0)
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    // The selected first tile's background is the selection blue; the page itself is white.
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width   // colorAt counts pixels from the top, as the flipped view
    let f = view.frameOfRow(at: 0)
    let sel = rep.colorAt(x: Int((f.maxX - 4) * scale), y: Int(f.midY * scale))!.usingColorSpace(.sRGB)!
    #expect(abs(sel.blueComponent - 1) < 0.02 && sel.redComponent < 0.85, "\(sel)")
    let page = rep.colorAt(x: Int(595 * scale), y: Int(395 * scale))!.usingColorSpace(.sRGB)!
    #expect(page.redComponent > 0.98 && page.greenComponent > 0.98 && page.blueComponent > 0.98)
}

/// Every drive icon the view asks for is one the dylib loads (embedded by `make chrome`, or the user's PNG).
@Test func computerIconNamesAreChromeIconNames() {
    let names = Set(W7ComputerGroupsFromVolumes(sampleFacts).flatMap(\.rows).map(\.iconName))
    #expect(names == ["drive-system", "drive", "drive-removable", "drive-optical", "network"])
    #expect(names.isSubset(of: Set(W7UserIconNames())))
    #expect(W7UserIconNames().contains("computer"))
}

/// Go ▸ Computer is Finder's own menu item; without one (or outside an Explorer window) nothing happens.
@MainActor @Test func goToComputerNeedsFindersMenuItem() {
    _ = NSApplication.shared
    let saved = NSApp.mainMenu
    defer { NSApp.mainMenu = saved }
    NSApp.mainMenu = NSMenu()
    #expect(!W7ExplorerGoToComputer(nil))
    let (w, _) = computerWindow(title: "Elsewhere")
    #expect(!W7ExplorerGoToComputer(w))   // not adopted
    W7ExplorerAdopt(w)
    #expect(!W7ExplorerGoToComputer(w))   // no Go ▸ Computer item
    w.close()
}

// MARK: - the adoption seed, mount reloads, single-flight bounded reads, Open Control Panel

/// A folder named like the computer, in a window whose location was never read (the adoption seed, a background
/// window without an id): not covered.
@MainActor @Test func computerOverlayIgnoresTheAdoptionSeed() {
    withComputerSeams {
        let (w, browser) = computerWindow(title: "Studio Mac")
        W7ExplorerAdopt(w)
        #expect(W7ExplorerComputerViewForWindow(w) == nil)
        #expect(!browser.subviews.contains { ($0 as? NSScrollView)?.documentView is W7ExplorerComputerView })
        #expect(commandTitles(w).first == "Organize")
        w.close()
    }
}

/// Mount and unmount notifications read the volumes again while the view shows.
@MainActor @Test func computerOverlayReloadsOnMountAndUnmount() throws {
    try withComputerSeams {
        var facts = sampleFacts
        W7ComputerViewUseVolumeFacts { facts }
        let (w, _) = computerWindow(title: "Studio Mac")
        W7ExplorerAdopt(w)
        W7ExplorerSetLocationForTesting(w, nil, "Studio Mac")
        let view = try #require(W7ExplorerComputerViewForWindow(w))
        #expect(view.groups.count == 3)
        let center = NSWorkspace.shared.notificationCenter
        facts = [volume("/", "Macintosh HD", root: true)]
        center.post(name: NSWorkspace.didUnmountNotification, object: NSWorkspace.shared)
        #expect(view.groups.map(\.title) == ["Hard Disk Drives"])
        facts.append(volume("/Volumes/USB", "USB Stick", internal: false, removable: true, ejectable: true))
        center.post(name: NSWorkspace.didMountNotification, object: NSWorkspace.shared)
        #expect(view.groups.map(\.title) == ["Hard Disk Drives", "Devices with Removable Storage"])
        // Hidden: no more reads.
        w.title = "Documents"
        facts = sampleFacts
        center.post(name: NSWorkspace.didMountNotification, object: NSWorkspace.shared)
        #expect(view.groups.count == 2)
        w.close()
    }
}

/// One read at a time: notifications during a read ask for one more read after it, never a second worker; the
/// answer of a read that was overtaken is dropped.
@MainActor @Test func computerVolumeReadsAreSingleFlight() throws {
    try withComputerSeams {
        var pending: [([[String: Any]]) -> Void] = []
        W7ComputerViewUseVolumeReader { done in pending.append(done) }
        let (w, _) = computerWindow(title: "Studio Mac")
        W7ExplorerAdopt(w)
        W7ExplorerSetLocationForTesting(w, nil, "Studio Mac")
        let view = try #require(W7ExplorerComputerViewForWindow(w))
        #expect(pending.count == 1 && view.groups.isEmpty)
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.didMountNotification, object: NSWorkspace.shared)
        center.post(name: NSWorkspace.didUnmountNotification, object: NSWorkspace.shared)
        center.post(name: NSWorkspace.didRenameVolumeNotification, object: NSWorkspace.shared)
        #expect(pending.count == 1)                       // still the one read in flight
        pending[0](sampleFacts)                           // overtaken by the notifications: dropped
        #expect(view.groups.isEmpty)
        #expect(pending.count == 2)                       // exactly one more read
        pending[1]([volume("/", "Macintosh HD", root: true)])
        #expect(view.groups.map(\.title) == ["Hard Disk Drives"])
        #expect(pending.count == 2)                       // nothing asked meanwhile: no further read
        // A read whose overlay went away is dropped too.
        center.post(name: NSWorkspace.didMountNotification, object: NSWorkspace.shared)
        #expect(pending.count == 3)
        w.title = "Documents"
        pending[2](sampleFacts)
        #expect(W7ExplorerComputerViewForWindow(w) == nil)
        #expect(pending.count == 3)
        w.close()
    }
}

/// A read that has not answered within the budget (a hung network mount) shows Finder's view instead of an empty
/// page; it is not joined by more workers, and its late answer is dropped.
@MainActor @Test func computerVolumeReadOverBudgetFailsOpen() throws {
    #expect(W7ComputerVolumeReadBudget() == 10)
    try withComputerSeams {
        var pending: [([[String: Any]]) -> Void] = []
        W7ComputerViewUseVolumeReader { done in pending.append(done) }
        W7ComputerViewUseReadBudget(0.05)
        #expect(W7ComputerVolumeReadBudget() == 0.05)
        let (w, browser) = computerWindow(title: "Studio Mac")
        let finderViews = browser.subviews
        W7ExplorerAdopt(w)
        W7ExplorerSetLocationForTesting(w, nil, "Studio Mac")
        #expect(W7ExplorerComputerViewForWindow(w) != nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didMountNotification, object: NSWorkspace.shared)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        #expect(W7ExplorerComputerViewForWindow(w) == nil)   // fail open: Finder's view
        #expect(finderViews.allSatisfy { $0.superview === browser && !$0.isHidden })
        #expect(pending.count == 1)
        pending[0](sampleFacts)                              // late: dropped, and the overlay stays away on this title
        #expect(W7ExplorerComputerViewForWindow(w) == nil)
        #expect(pending.count == 1)
        // A navigation and back shows it again, with a fresh read.
        w.title = "Documents"
        W7ExplorerSetLocationForTesting(w, "/Users/k/Documents", "Documents")
        w.title = "Studio Mac"
        W7ExplorerSetLocationForTesting(w, nil, "Studio Mac")
        let view = try #require(W7ExplorerComputerViewForWindow(w))
        #expect(pending.count == 2)
        pending[1](sampleFacts)
        #expect(view.groups.count == 3)
        w.close()
    }
}

/// Open Control Panel: with the shell running, Finder hands it activation and posts the shell's notification (no
/// userInfo); without it, System Settings opens. Nothing is performed here: the effects go to the test sink.
@MainActor @Test func computerOpenControlPanelDispatch() {
    withComputerSeams {
        var effects: [String] = []
        let (w, _) = computerWindow(title: "Studio Mac")
        W7ExplorerAdopt(w)
        W7ComputerViewUseCommandSink(1) { effect, argument in effects.append("\(effect) \(argument)") }
        W7ExplorerPerformComputerCommandForTesting(w, .openControlPanel)
        #expect(effects == ["yield com.win7mac.shell", "post com.win7mac.controlpanel.show"])
        effects = []
        W7ComputerViewUseCommandSink(0) { effect, argument in effects.append("\(effect) \(argument)") }
        W7ExplorerPerformComputerCommandForTesting(w, .openControlPanel)
        #expect(effects == ["open x-apple.systempreferences:"])
        effects = []
        W7ExplorerPerformComputerCommandForTesting(w, .systemProperties)
        #expect(effects == ["open x-apple.systempreferences:com.apple.SystemProfiler.AboutExtension"])
        w.close()
    }
}

/// Control-click on the nav pane's Locations header is a right-click (Finder's context menu), not Go ▸ Computer.
@Test func navPaneComputerHeaderControlClickIsARightClick() {
    #expect(W7NavPaneComputerClickNavigates([]))
    #expect(W7NavPaneComputerClickNavigates(.option))
    #expect(!W7NavPaneComputerClickNavigates(.control))
    #expect(!W7NavPaneComputerClickNavigates([.control, .shift]))
}
