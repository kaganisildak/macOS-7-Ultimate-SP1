import AppKit
import Testing
import Win7ChromeCore

// Item I/O limits, unread selections, the dark appearance, and the selection
// tracker against a fake host and browser. No window is ordered on screen and no events are posted.

// MARK: - Item I/O and unread selections

@Test func datalessFilesAreRecognised() {
    #expect(W7ExplorerFileIsDataless(URLUbiquitousItemDownloadingStatus.notDownloaded.rawValue, 0))
    #expect(!W7ExplorerFileIsDataless(URLUbiquitousItemDownloadingStatus.current.rawValue, 0))
    #expect(!W7ExplorerFileIsDataless(nil, 0))
    #expect(W7ExplorerFileIsDataless(nil, 0x4000_0000))   // SF_DATALESS
}

@Test func onlyADetailedReadOpensTheImageHeader() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("W7ExplorerInfo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let url = dir.appendingPathComponent("tiny.png")
    try rep.representation(using: .png, properties: [:])!.write(to: url)
    let brief = W7ExplorerItemInfo(for: url, detailed: false)
    #expect(brief.isImage && brief.isPrintable && brief.fileSize > 0 && brief.modified != nil)
    #expect(brief.pixelSize == .zero && !brief.hasDefaultApp && brief.created == nil && brief.typeName == nil)
    let full = W7ExplorerItemInfo(for: url, detailed: true)
    #expect(full.pixelSize == NSSize(width: 2, height: 3))
    #expect(full.created != nil && full.typeName != nil)
    let nameOnly = W7ExplorerItemInfo.nameOnlyInfo(for: url)
    #expect(nameOnly.name == "tiny.png" && nameOnly.fileSize == -1 && !nameOnly.isImage)
}

@Test func unreadSelectionsShowOnlyTheirCount() {
    #expect(W7ExplorerSelectionReadLimit == 1000)
    let d = W7ExplorerDetailsForUnreadSelection(1500)
    #expect(d.title == "1500 items selected" && d.titleStyle == .heading && d.labels.isEmpty && d.subtitle == nil)
    #expect(W7ExplorerCommandsForUnreadSelection().map { W7ExplorerCommand(rawValue: $0.intValue)! }
            == [.organize, .open, .burn, .newFolder])   // no Share with: no files to share
}

// MARK: - Dark appearance

@MainActor @Test func darkAppearanceIsRecognised() {
    #expect(W7ExplorerAppearanceIsDark(NSAppearance(named: .darkAqua)))
    #expect(W7ExplorerAppearanceIsDark(NSAppearance(named: .vibrantDark)))
    #expect(!W7ExplorerAppearanceIsDark(NSAppearance(named: .aqua)))
    #expect(!W7ExplorerAppearanceIsDark(nil))
}

final class W7TestDarkListRowView: NSTableRowView {}
final class W7TestDarkIconSelectionView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.systemBlue.cgColor }
}
final class W7TestDarkIconView: NSView {
    @objc dynamic var titleBubbleViewIsSelected: Bool { true }
    @objc(_titleFontColor) dynamic var w7TitleFontColor: NSColor { .white }
}

@MainActor @Test func highlightDefersToFinderInDarkAppearance() {
    // List rows: in dark the background style is Finder's own (no forced black text).
    let plain = NSTableRowView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
    let row = W7TestDarkListRowView(frame: plain.frame)
    #expect(W7ExplorerHookListRowClass(W7TestDarkListRowView.self))
    for r in [plain, row] { r.appearance = NSAppearance(named: .darkAqua); r.isSelected = true; r.isEmphasized = true }
    _ = row.bitmapImageRepForCachingDisplay(in: row.bounds).map { row.cacheDisplay(in: row.bounds, to: $0) }
    #expect(row.interiorBackgroundStyle == plain.interiorBackgroundStyle)   // dark: nothing painted, Finder's style
    // A light row of the same class (fresh, so its effective appearance is aqua from the start).
    let light = W7TestDarkListRowView(frame: plain.frame)
    let lightPlain = NSTableRowView(frame: plain.frame)
    for r in [light, lightPlain] { r.appearance = NSAppearance(named: .aqua); r.isSelected = true; r.isEmphasized = true }
    #expect(light.interiorBackgroundStyle == lightPlain.interiorBackgroundStyle)   // light, but not painted yet
    _ = light.bitmapImageRepForCachingDisplay(in: light.bounds).map { light.cacheDisplay(in: light.bounds, to: $0) }
    #expect(light.interiorBackgroundStyle == .normal)                              // light and painted
    light.selectionHighlightStyle = .none   // the draw hook would not draw: no forced style either
    lightPlain.selectionHighlightStyle = .none
    #expect(light.interiorBackgroundStyle == lightPlain.interiorBackgroundStyle)

    // Icon view: a highlight drawn while light comes off again in dark.
    #expect(W7ExplorerHookIconSelectionClass(W7TestDarkIconSelectionView.self))
    let host = W7TestIconHost(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
    host.appearance = NSAppearance(named: .aqua)
    let sel = W7TestDarkIconSelectionView(frame: NSRect(x: 10, y: 10, width: 60, height: 60))
    sel.wantsLayer = true
    host.addSubview(sel)
    sel.perform(#selector(NSView.updateLayer))
    let layer = sel.layer!
    #expect(layer.sublayers?.contains { $0 is CAGradientLayer } == true)
    host.appearance = NSAppearance(named: .darkAqua)
    sel.perform(#selector(NSView.updateLayer))
    #expect(layer.sublayers?.contains { $0 is CAGradientLayer } != true)
    #expect(layer.borderWidth == 0 && layer.cornerRadius == 0)   // what the original had
    #expect(layer.backgroundColor != nil)                        // the original's own colour stays

    // Icon titles: Finder's own answer in dark.
    #expect(W7ExplorerHookIconTitleClass(W7TestDarkIconView.self))
    let title = W7TestDarkIconView(frame: .zero)
    title.appearance = NSAppearance(named: .aqua)
    #expect(!title.titleBubbleViewIsSelected)
    title.appearance = NSAppearance(named: .darkAqua)
    #expect(title.titleBubbleViewIsSelected)
}

// MARK: - Selection tracker

final class W7FakeSelectionHost: NSObject, W7ExplorerSelectionHost {
    @objc weak var window: NSWindow?
    @objc var currentFolder: URL?
}

/// Stands in for a Finder browser view controller: a selected count and a Services requestor.
final class W7FakeBrowserVC: NSViewController {
    var count: UInt = 0
    var urls: [URL] = []
    var legacyOnly = false
    var writes = 0
    @objc func selectedNodesCount() -> UInt { count }
    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)) }
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? { self }
    @objc(writeSelectionToPasteboard:types:)
    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        writes += 1
        if legacyOnly {
            pboard.setPropertyList(urls.map(\.path), forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        } else {
            pboard.writeObjects(urls.map { $0 as NSURL })
        }
        return true
    }
}

@MainActor private final class TrackerRig {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
                          backing: .buffered, defer: true)
    let host = W7FakeSelectionHost()
    let browser = W7FakeBrowserVC()
    var changes = 0
    var tracker: W7ExplorerSelectionTracker!

    init() {
        _ = NSApplication.shared
        window.isReleasedWhenClosed = false
        window.contentView = browser.view
        host.window = window
        tracker = W7ExplorerSelectionTracker(host: host) { [unowned self] in self.changes += 1 }
        tracker.debounceInterval = 0.02
        tracker.maxDebounceWait = 0.2
        tracker.infoLoader = { @Sendable url, _ in W7ExplorerItemInfo.nameOnlyInfo(for: url) }
        tracker.noteBrowser(browser)
    }

    /// Spins the main run loop until `condition` holds (at most `timeout`).
    func wait(_ timeout: TimeInterval = 2, until condition: () -> Bool) {
        let end = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < end { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    }
}

private func fileURL(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/w7-tracker-test/\(name)") }

@MainActor @Test func trackerTrustsACountOfZero() {
    let rig = TrackerRig()
    rig.browser.count = 0
    rig.browser.urls = [fileURL("folder-itself")]   // what a requestor might hand over for an empty selection
    rig.tracker.setNeedsUpdate()
    rig.wait { rig.tracker.snapshot != nil }
    #expect(rig.tracker.snapshot?.urls.isEmpty == true)
    #expect(rig.tracker.snapshot?.selectedCount == 0 && rig.tracker.snapshot?.known == true)
    #expect(rig.browser.writes == 0)
    rig.window.close()
}

@MainActor @Test func trackerReadsFileURLsAndTheLegacyFilenamesType() {
    let rig = TrackerRig()
    rig.browser.count = 2
    rig.browser.urls = [fileURL("a.txt"), fileURL("b.txt")]
    rig.tracker.setNeedsUpdate()
    rig.wait { rig.tracker.snapshot != nil }
    #expect(rig.tracker.snapshot?.urls.map(\.path) == rig.browser.urls.map(\.path))
    rig.browser.legacyOnly = true
    rig.browser.urls = [fileURL("c.txt"), fileURL("d.txt")]
    rig.tracker.setNeedsUpdate()
    rig.wait { rig.tracker.snapshot?.urls.first?.lastPathComponent == "c.txt" }
    #expect(rig.tracker.snapshot?.urls.map(\.path) == rig.browser.urls.map(\.path))
    #expect(rig.tracker.snapshot?.items.map(\.name) == ["c.txt", "d.txt"])
    rig.window.close()
}

@MainActor @Test func trackerShowsLargeSelectionsUnread() {
    let rig = TrackerRig()
    rig.browser.count = 1500
    rig.browser.urls = [fileURL("x")]
    rig.tracker.setNeedsUpdate()
    rig.wait { rig.tracker.snapshot != nil }
    #expect(rig.tracker.snapshot?.unread == true && rig.tracker.snapshot?.selectedCount == 1500)
    #expect(rig.tracker.snapshot?.urls.isEmpty == true && rig.browser.writes == 0)
    rig.window.close()
}

@MainActor @Test func trackerDebouncesBurstsButCapsTheWait() {
    let rig = TrackerRig()
    rig.tracker.debounceInterval = 0.3
    rig.tracker.maxDebounceWait = 0.6
    rig.browser.count = 1
    rig.browser.urls = [fileURL("a.txt")]
    // A burst of four triggers 30 ms apart (about 0.1 s): far inside one 0.3 s wait.
    for _ in 0..<4 { rig.tracker.setNeedsUpdate(); RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03)) }
    #expect(rig.tracker.readCount == 0)    // each call restarted the wait
    rig.wait(1.5) { rig.tracker.readCount > 0 }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
    #expect(rig.tracker.readCount == 1)    // one read for the burst
    // Triggers every 30 ms never let a 0.3 s wait finish; the 0.6 s cap still reads within 1 s.
    let before = rig.tracker.readCount
    let start = Date()
    while Date().timeIntervalSince(start) < 1.0 {
        rig.tracker.setNeedsUpdate()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
    }
    #expect(rig.tracker.readCount > before)
    rig.window.close()
}

@MainActor @Test func trackerDropsASupersededRead() {
    let rig = TrackerRig()
    let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    rig.tracker.infoLoader = { @Sendable url, _ in
        if url.lastPathComponent == "slow" { started.signal(); release.wait() }
        return W7ExplorerItemInfo.nameOnlyInfo(for: url)
    }
    rig.browser.count = 1
    rig.browser.urls = [fileURL("slow")]
    rig.tracker.setNeedsUpdate()
    rig.wait { started.wait(timeout: .now()) == .success }
    rig.browser.urls = [fileURL("fast")]
    rig.tracker.setNeedsUpdate()
    rig.wait { rig.tracker.snapshot != nil }
    release.signal()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    #expect(rig.tracker.snapshot?.urls.map(\.lastPathComponent) == ["fast"])
    #expect(rig.changes == 1)   // the slow read was never published
    rig.window.close()
}

@MainActor @Test func trackerKeepsFailedItemsByName() {
    let rig = TrackerRig()
    rig.tracker.infoLoader = { @Sendable url, _ in
        if url.lastPathComponent == "bad.txt" { return nil }   // a loader that failed (an exception is handled alike)
        let i = W7ExplorerItemInfo.nameOnlyInfo(for: url)
        i.fileSize = 10
        return i
    }
    rig.browser.count = 2
    rig.browser.urls = [fileURL("good.txt"), fileURL("bad.txt")]
    rig.tracker.setNeedsUpdate()
    rig.wait { rig.tracker.snapshot != nil }
    let items = rig.tracker.snapshot?.items ?? []
    #expect(items.map(\.name) == ["good.txt", "bad.txt"])
    #expect(items.map(\.fileSize) == [10, -1])
    rig.window.close()
}

@MainActor @Test func trackerReportsTheLiveCount() {
    let rig = TrackerRig()
    rig.browser.count = 3
    #expect(rig.tracker.liveSelectedCount() == 3)
    rig.window.contentView = NSView()   // the browser view left the window: nobody to ask
    #expect(rig.tracker.liveSelectedCount() == -1)
    rig.window.close()
}

// MARK: - Share with and Slide show decisions

private func snapshot(_ urls: [URL] = [], count: Int, unread: Bool = false, known: Bool = true) -> W7ExplorerSelectionSnapshot {
    W7ExplorerSelectionSnapshot(urls: urls, items: urls.map { W7ExplorerItemInfo.nameOnlyInfo(for: $0) }, count: count,
                                unread: unread, folderHasImages: false, folderPath: "/Users/k/Pictures", known: known)
}

@Test func shareNeverSubstitutesTheFolderForAnUnreadSelection() {
    #expect(W7ExplorerShareDecisionFor(snapshot(count: 1500, unread: true), "/Users/k/Pictures") == .beep)
    #expect(W7ExplorerShareDecisionFor(snapshot([fileURL("a")], count: 1), "/Users/k/Pictures") == .selection)
    #expect(W7ExplorerShareDecisionFor(snapshot(count: 0), "/Users/k/Pictures") == .folder)
    #expect(W7ExplorerShareDecisionFor(snapshot(count: 0), nil) == .beep)
    #expect(W7ExplorerShareDecisionFor(snapshot(count: -1, known: false), "/Users/k/Pictures") == .askFinder)
    #expect(W7ExplorerShareDecisionFor(nil, "/Users/k/Pictures") == .askFinder)
}

@Test func slideShowSelectsAllOnlyForAKnownEmptySelection() {
    // Known empty, Finder agrees right now, and the selection can be restored: the whole folder.
    #expect(W7ExplorerSlideShowPlanFor(snapshot(count: 0), 0, true) == .wholeFolder)
    // Everything else only sends ⌥⌘Y.
    #expect(W7ExplorerSlideShowPlanFor(snapshot(count: 0, known: false), 0, true) == .selection)   // known == NO
    #expect(W7ExplorerSlideShowPlanFor(snapshot(count: -1), 0, true) == .selection)                // a count of -1
    #expect(W7ExplorerSlideShowPlanFor(nil, 0, true) == .selection)                                 // no snapshot
    #expect(W7ExplorerSlideShowPlanFor(snapshot(count: 0), 2, true) == .selection)                 // stale: Finder has 2
    #expect(W7ExplorerSlideShowPlanFor(snapshot(count: 0), -1, true) == .selection)                // live count unknown
    #expect(W7ExplorerSlideShowPlanFor(snapshot(count: 0), 0, false) == .selection)                // no Deselect All / panel
    #expect(W7ExplorerSlideShowPlanFor(snapshot([fileURL("a.jpg")], count: 1), 1, true) == .selection)
    #expect(W7ExplorerSlideShowPlanFor(snapshot(count: 1500, unread: true), 1500, true) == .selection)
}
