import Foundation
import Testing
@testable import Win7Core

/// (review of F1/F2/M1–M3): the slideshow and Cancel leave alone what was set outside the shell,
/// Cancel works per display, and the catalogue scan is bounded and totally ordered. The desktop is a fake: nothing
/// here sets a real desktop picture.
@Suite struct WallpaperSlideshowScreensTests {
    private let a = URL(fileURLWithPath: "/w/Landscapes/img7.jpg")
    private let b = URL(fileURLWithPath: "/w/Landscapes/img8.jpg")
    private let mine = URL(fileURLWithPath: "/Users/me/Pictures/beach.jpg")
    private let solidFolder = URL(fileURLWithPath: "/Users/me/Library/Application Support/Win7Mac/Wallpaper")

    @Test func onlyScreensShowingOursAreUpdated() {
        let ours: Set<URL> = [a, b]
        // Display 1 shows the slideshow's picture, display 2 a picture the user chose in System Settings.
        #expect(WallpaperSlideshow.screensToUpdate(current: [1: a, 2: mine], ours: ours) == [1])
        // Both ours: both, in display order.
        #expect(WallpaperSlideshow.screensToUpdate(current: [7: b, 3: a], ours: ours) == [3, 7])
        // A differently spelled path to the same file still counts.
        let spelled = URL(fileURLWithPath: "/w/Landscapes/../Landscapes/img7.jpg")
        #expect(WallpaperSlideshow.screensToUpdate(current: [1: spelled], ours: ours) == [1])
        // Nothing of ours shows any more: no screen, and the slideshow stops.
        #expect(WallpaperSlideshow.screensToUpdate(current: [1: mine, 2: mine], ours: ours).isEmpty)
        #expect(WallpaperSlideshow.shouldStop(current: [1: mine, 2: mine], ours: ours))
        #expect(!WallpaperSlideshow.shouldStop(current: [1: mine, 2: a], ours: ours))
        // macOS reported no picture at all (e.g. early at login): unknown, the slideshow is kept.
        #expect(!WallpaperSlideshow.shouldStop(current: [:], ours: ours))
    }

    @Test func oursHoldsTheChoiceTheCatalogueTheColourPicturesAndPreviews() {
        let catalogue = [URL(fileURLWithPath: "/w/Windows/img0.jpg")]
        let previewed: Set<URL> = [URL(fileURLWithPath: "/w/Windows/img1.jpg")]
        let ours = WallpaperSlideshow.ours(items: [.picture(a), .color(SolidColor(0x123456))], catalogue: catalogue,
                                           previewed: previewed, solidFolder: solidFolder)
        #expect(ours.contains(a) && ours.contains(catalogue[0]) && ours.contains(previewed.first!))
        // The chosen colour's picture and every palette colour's picture (one of ours whichever colour shows).
        #expect(ours.contains(solidFolder.appendingPathComponent("solid-123456.png")))
        #expect(ours.contains(solidFolder.appendingPathComponent("solid-3A6EA5.png")))
        #expect(!ours.contains(mine))
        #expect(WallpaperSlideshow.screensToUpdate(current: [1: solidFolder.appendingPathComponent("solid-000000.png"), 2: mine],
                                                   ours: ours) == [1])
    }

    /// The player resumes on the picture macOS shows, so the first Space switch after a restart does not swap it.
    @Test @MainActor func resumeStartsFromThePictureShown() {
        var applied: [WallpaperItem] = []
        let player = WallpaperPlayer { item, _ in applied.append(item); return true }
        let s = WallpaperSettings(location: .windowsBackgrounds, items: [.picture(a), .picture(b), .picture(mine)],
                                  position: .fill, interval: .seconds10, shuffle: false, themeName: nil)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        player.start(s, now: t0, applyFirst: false, showing: .picture(b))
        #expect(applied.isEmpty && player.current == .picture(b))
        player.tick(now: t0.addingTimeInterval(10))
        #expect(applied == [.picture(mine)])
        // A picture that is not part of the choice is ignored.
        player.start(s, now: t0, applyFirst: false, showing: .picture(URL(fileURLWithPath: "/elsewhere.jpg")))
        #expect(player.current == .picture(a))
    }
}

/// A fake desktop: every Space holds one picture per display; only the active Space's pictures are read or set.
private final class FakeDesktop {
    typealias Options = String
    var spaces: [[DisplayID: (URL, Options)]]
    var active = 0
    private(set) var writes: [(space: Int, display: DisplayID, url: URL)] = []

    init(_ spaces: [[DisplayID: (URL, Options)]]) { self.spaces = spaces }

    var shown: [DisplayID: WallpaperPreviewSession<Options>.Shown] {
        spaces[active].mapValues { .init(url: $0.0, options: $0.1) }
    }
    var urls: [DisplayID: URL] { spaces[active].mapValues(\.0) }

    func set(_ url: URL, options: Options, on display: DisplayID) {
        guard spaces[active][display] != nil else { return }
        spaces[active][display] = (url, options)
        writes.append((active, display, url))
    }

    /// Sets `url` on every display of the active Space, as a preview does.
    func setAll(_ url: URL, options: Options = "fill") {
        for d in spaces[active].keys { set(url, options: options, on: d) }
    }
}

@Suite struct WallpaperPreviewSessionTests {
    private let old1 = URL(fileURLWithPath: "/w/old1.jpg"), old2 = URL(fileURLWithPath: "/w/old2.jpg")
    private let tick = URL(fileURLWithPath: "/w/tick.jpg")
    private let p1 = URL(fileURLWithPath: "/w/p1.jpg"), p2 = URL(fileURLWithPath: "/w/p2.jpg")
    private let mine = URL(fileURLWithPath: "/Users/me/Pictures/mine.jpg")

    private func restore(_ s: WallpaperPreviewSession<String>, on desk: FakeDesktop) {
        for (display, shown) in s.restorePlan(current: desk.urls) { desk.set(shown.url, options: shown.options, on: display) }
    }

    /// The snapshot is taken at the first preview, so a slideshow change between opening the window and the first
    /// click is what Cancel puts back; later previews do not retake it.
    @Test func snapshotIsTakenAtTheFirstPreview() {
        let desk = FakeDesktop([[1: (old1, "fit"), 2: (old2, "fill")]])
        var session = WallpaperPreviewSession<String>()
        #expect(!session.isActive)
        desk.setAll(tick)                     // the slideshow ticks while the window is open
        session.willPreview(p1, current: desk.shown)
        desk.setAll(p1)
        session.willPreview(p2, current: desk.shown)
        desk.setAll(p2)
        #expect(session.isActive && session.previewed == [p1, p2])
        #expect(session.snapshot?[1]?.url == tick && session.snapshot?[2]?.url == tick)
        restore(session, on: desk)
        #expect(desk.urls == [1: tick, 2: tick])
    }

    /// Per display, by CGDirectDisplayID: options come back with their picture.
    @Test func cancelRestoresEachDisplaysOwnPicture() {
        let desk = FakeDesktop([[1: (old1, "fit"), 2: (old2, "center")]])
        var session = WallpaperPreviewSession<String>()
        session.willPreview(p1, current: desk.shown)
        desk.setAll(p1)
        restore(session, on: desk)
        #expect(desk.spaces[0][1]?.0 == old1 && desk.spaces[0][1]?.1 == "fit")
        #expect(desk.spaces[0][2]?.0 == old2 && desk.spaces[0][2]?.1 == "center")
    }

    /// The user switched Space during the preview: Space B shows its own picture (set outside the shell), so Cancel
    /// leaves it alone; Space A keeps the preview until it comes forward (then `previewed` marks it as ours).
    @Test func cancelOnAnotherSpaceLeavesItsPicturesAlone() {
        let desk = FakeDesktop([[1: (old1, "fit")], [1: (mine, "fill")]])
        var session = WallpaperPreviewSession<String>()
        session.willPreview(p1, current: desk.shown)
        desk.setAll(p1)
        desk.active = 1
        restore(session, on: desk)
        #expect(desk.urls == [1: mine])
        #expect(desk.writes.filter { $0.space == 1 }.isEmpty)
        // Space A comes forward still showing the preview: the session's restore puts its picture back.
        desk.active = 0
        restore(session, on: desk)
        #expect(desk.urls == [1: old1])
    }

    /// A display connected during the preview keeps what macOS gave it; one disconnected is skipped; a display whose
    /// picture was changed elsewhere meanwhile is left alone.
    @Test func addedRemovedAndChangedDisplaysAreSkipped() {
        let desk = FakeDesktop([[1: (old1, "fit"), 2: (old2, "fill"), 3: (old2, "fill")]])
        var session = WallpaperPreviewSession<String>()
        session.willPreview(p1, current: desk.shown)
        desk.setAll(p1)
        desk.spaces[0][2] = nil                      // unplugged
        desk.spaces[0][4] = (p1, "fill")             // plugged in, happens to show the preview
        desk.spaces[0][3] = (mine, "fill")           // changed in System Settings meanwhile
        let plan = session.restorePlan(current: desk.urls)
        #expect(plan.map(\.display) == [1])
        restore(session, on: desk)
        #expect(desk.urls == [1: old1, 3: mine, 4: p1])
    }

    @Test func noPreviewNoRestore() {
        let desk = FakeDesktop([[1: (old1, "fit")]])
        let session = WallpaperPreviewSession<String>()
        #expect(session.restorePlan(current: desk.urls).isEmpty)
    }
}

@Suite struct WallpaperCatalogBoundsTests {
    private func tree(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("w7wall82-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for f in files { try Data("x".utf8).write(to: root.appendingPathComponent(f)) }
        return root
    }

    @Test func scanIsCappedAfterSorting() throws {
        #expect(WallpaperCatalog.maxPicturesPerFolder == 2000)
        let root = try tree((1...12).map { "img\($0).jpg" })
        defer { try? FileManager.default.removeItem(at: root) }
        let capped = WallpaperCatalog.pictures(in: root, limit: 5)
        // The first five in Explorer's order, not five in directory order.
        #expect(capped.map(\.lastPathComponent) == ["img1.jpg", "img2.jpg", "img3.jpg", "img4.jpg", "img5.jpg"])
        #expect(WallpaperCatalog.pictures(in: root).count == 12)
    }

    @Test func sortIsTotal() {
        // localizedStandardCompare calls these equal; the plain comparison breaks the tie, whatever the input order.
        let names = ["b.jpg", "A.jpg", "a.jpg", "ａ.jpg"]
        let sorted = WallpaperCatalog.explorerOrder(names)
        #expect(WallpaperCatalog.explorerOrder(names.reversed()) == sorted)
        #expect(WallpaperCatalog.explorerOrder(["a.jpg", "A.jpg"]) == WallpaperCatalog.explorerOrder(["A.jpg", "a.jpg"]))
        #expect(sorted.last == "b.jpg")
    }
}
