import AppKit
import ObjectiveC
import Testing
import Win7ChromeCore

// Folder Options ▸ Browse folders. Finder opens a folder in a new window whenever a browser
// window reports its toolbar hidden; Explorer windows report it shown (same window) unless the user
// picks "Open each folder in its own window". No events are posted and the preference lives in a
// throwaway test suite, never in com.win7mac.chrome.

// MARK: - Decision

@Test func reportedToolbarVisibleTruthTable() {
    for actual in [false, true] {
        for explorer in [false, true] {
            for newWindow in [false, true] {
                let expected = explorer && !newWindow ? true : actual
                #expect(W7ExplorerReportedToolbarVisible(actual, explorer, newWindow) == expected,
                        "actual \(actual) explorer \(explorer) newWindow \(newWindow)")
            }
        }
    }
}

@Test func imageGuardAcceptsOnlyFindersExecutable() {
    #expect(W7ExplorerBrowseImageIsFinder("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"))
    #expect(!W7ExplorerBrowseImageIsFinder("/System/Library/PrivateFrameworks/FinderKit.framework/Versions/A/FinderKit"))
    #expect(!W7ExplorerBrowseImageIsFinder("/System/Library/CoreServices/Finder.app/Contents/PlugIns/FinderSync.appex/Contents/MacOS/FinderSync"))
    #expect(!W7ExplorerBrowseImageIsFinder("/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"))
    #expect(!W7ExplorerBrowseImageIsFinder("/Applications/NotFinder.app/Contents/MacOS/NotFinder"))
    #expect(!W7ExplorerBrowseImageIsFinder("/Applications/NotFinder.app/Contents/MacOS/Finder"))
    #expect(!W7ExplorerBrowseImageIsFinder(nil))
}

/// MH_EXECUTE and MH_DYLIB from <mach-o/loader.h>.
private let mhExecute: UInt32 = 0x2, mhDylib: UInt32 = 0x6

@Test func executableImageChooserPicksTheMHExecuteEntry() {
    let finder = "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
    // Under Ammonia its loader dylib is image 0; the executable is wherever dyld lists it.
    let names = ["/private/var/ammonia/core/libopener.dylib", "/usr/lib/libSystem.B.dylib", finder,
                 "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"]
    let types = [mhDylib, mhDylib, mhExecute, mhDylib].map { NSNumber(value: $0) }
    #expect(W7ExplorerExecutableImageName(types, names) == finder)
    #expect(W7ExplorerExecutableImageName([NSNumber(value: mhExecute)], [finder]) == finder)
    // No executable among them, or mismatched lists: nil (the caller falls back to the path match).
    #expect(W7ExplorerExecutableImageName([mhDylib, mhDylib].map { NSNumber(value: $0) }, Array(names.prefix(2))) == nil)
    #expect(W7ExplorerExecutableImageName([], []) == nil)
    #expect(W7ExplorerExecutableImageName(types, Array(names.prefix(2))) == nil)
}


@Test func mainImageChooserFindsTheExecutableAnywhereInTheList() {
    let finder = "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
    // Ammonia's loader is image 0 under injection: never assume the first image.
    let loaded = ["/private/var/ammonia/core/libopener.dylib", "/usr/lib/libSystem.B.dylib", finder,
                  "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"]
    #expect(W7ExplorerMainImageName(finder, loaded) == finder)
    #expect(W7ExplorerMainImageName(finder, [finder]) == finder)
    // Not loaded, or no path: nothing.
    #expect(W7ExplorerMainImageName(finder, Array(loaded.prefix(2))) == nil)
    #expect(W7ExplorerMainImageName(nil, loaded) == nil)
    #expect(W7ExplorerMainImageName("", loaded) == nil)
    #expect(W7ExplorerMainImageName(finder, []) == nil)
    // An unnormalized path matches; the runtime's own spelling is what comes back.
    #expect(W7ExplorerMainImageName("/System/Library/CoreServices/Finder.app/Contents/MacOS/../MacOS/Finder", loaded) == finder)
}

@Test func mainImageChooserTreatsPrivateVarAsVar() {
    let loaded = ["/usr/lib/dyld", "/private/var/folders/x/App.app/Contents/MacOS/App"]
    #expect(W7ExplorerMainImageName("/var/folders/x/App.app/Contents/MacOS/App", loaded) == loaded[1])
    let loadedVar = ["/usr/lib/dyld", "/var/folders/x/App.app/Contents/MacOS/App"]
    #expect(W7ExplorerMainImageName("/private/var/folders/x/App.app/Contents/MacOS/App", loadedVar) == loadedVar[1])
    #expect(W7ExplorerMainImageName("/private/tmp/a/App", ["/tmp/a/App"]) == "/tmp/a/App")
    // Only the /private prefix of the system folders is ignored.
    #expect(W7ExplorerMainImageName("/private/varx/App", ["/varx/App"]) == nil)
}

@Test func mainImageChooserResolvesSymlinks() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("W7MainImage-\(UUID().uuidString)").resolvingSymlinksInPath()
    try fm.createDirectory(at: dir.appendingPathComponent("Real.app/Contents/MacOS"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let real = dir.appendingPathComponent("Real.app/Contents/MacOS/Real")
    try Data().write(to: real)
    let link = dir.appendingPathComponent("Link.app")
    try fm.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("Real.app"))
    let viaLink = link.appendingPathComponent("Contents/MacOS/Real").path
    #expect(W7ExplorerMainImageName(viaLink, ["/usr/lib/dyld", real.path]) == real.path)
    // The other way round: the runtime names the image through the link.
    #expect(W7ExplorerMainImageName(real.path, ["/usr/lib/dyld", viaLink]) == viaLink)
}

// MARK: - Probe classes (message-dispatched, so a replaced IMP is what callers reach)

final class BrowseProbe: NSObject {
    var actual = false
    var probeWindow: NSWindow?
    @objc dynamic var isToolbarVisible: Bool { actual }
    @objc dynamic func window() -> NSWindow? { probeWindow }
}

/// Hooked only by the idempotency test.
final class BrowseProbeTwice: NSObject {
    var probeWindow: NSWindow?
    @objc dynamic var isToolbarVisible: Bool { false }
    @objc dynamic func window() -> NSWindow? { probeWindow }
}

/// Never hooked by a test: the installer must leave it alone (not a Finder image).
final class BrowseProbeUnhooked: NSObject {
    var probeWindow: NSWindow?
    @objc dynamic var isToolbarVisible: Bool { false }
    @objc dynamic func window() -> NSWindow? { probeWindow }
}

final class BrowseProbeNoMethod: NSObject {
    @objc dynamic func window() -> NSWindow? { nil }
}

/// Inherits isToolbarVisible without owning it.
final class BrowseProbeSubclass: BrowseProbeInheritBase {}
class BrowseProbeInheritBase: NSObject {
    @objc dynamic var isToolbarVisible: Bool { false }
}

/// A method of the right name but with an argument-free object return: not a BOOL, never hooked.
final class BrowseProbeWrongType: NSObject {
    @objc dynamic func isToolbarVisible() -> NSString { "x" }
}

final class BrowseProbeWindowController: NSWindowController {
    @objc dynamic var isToolbarVisible: Bool { false }
}

final class BrowseProbeViewController: NSViewController {
    @objc dynamic var isToolbarVisible: Bool { false }
}

final class BrowseProbeWindow: NSWindow {
    @objc dynamic var isToolbarVisible: Bool { false }
}

private func ownMethodNames(_ cls: AnyClass) -> [String] {
    var count: UInt32 = 0
    guard let list = class_copyMethodList(cls, &count) else { return [] }
    defer { free(list) }
    return (0..<Int(count)).map { NSStringFromSelector(method_getName(list[$0])) }.sorted()
}

private func toolbarVisibleIMP(_ cls: AnyClass) -> IMP? {
    class_getInstanceMethod(cls, NSSelectorFromString("isToolbarVisible")).map(method_getImplementation)
}

// MARK: - Preference and hook (shared global state: serialized)

@MainActor @Suite(.serialized) struct ExplorerBrowseTests {
    /// Points the preference at an emptied throwaway suite for `body`, then removes the suite and its
    /// plist (cfprefsd leaves an empty file behind). One fixed name: these tests are serialized.
    private func withTestSuite(_ body: (String) throws -> Void) rethrows {
        let suite = "com.win7mac.chrome.tests"
        UserDefaults().removePersistentDomain(forName: suite)
        W7ExplorerUseBrowseDefaultsSuite(suite)
        defer {
            W7ExplorerUseBrowseDefaultsSuite(nil)
            UserDefaults().removePersistentDomain(forName: suite)
            // Flush to cfprefsd before deleting, or it writes the empty file back afterwards.
            CFPreferencesAppSynchronize(suite as CFString)
            let plist = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suite).plist")
            try? FileManager.default.removeItem(at: plist)
        }
        try body(suite)
    }

    @Test func defaultsNames() {
        #expect(W7ExplorerBrowseSuiteName == "com.win7mac.chrome")
        #expect(W7ExplorerOpenFoldersInNewWindowKey == "ExplorerOpenFoldersInNewWindow")
    }

    @Test func preferenceDefaultsToSameWindowAndRoundTrips() {
        withTestSuite { suite in
            #expect(!W7ExplorerOpensFoldersInNewWindow())
            W7ExplorerSetOpensFoldersInNewWindow(true)
            #expect(W7ExplorerOpensFoldersInNewWindow())
            #expect(UserDefaults(suiteName: suite)?.bool(forKey: W7ExplorerOpenFoldersInNewWindowKey) == true)
            W7ExplorerSetOpensFoldersInNewWindow(false)
            #expect(!W7ExplorerOpensFoldersInNewWindow())
            #expect(UserDefaults(suiteName: suite)?.object(forKey: W7ExplorerOpenFoldersInNewWindowKey) as? Bool == false)
        }
    }

    @Test func cachedPreferenceFollowsOutsideWrites() {
        withTestSuite { suite in
            #expect(!W7ExplorerOpensFoldersInNewWindow())
            // Another defaults instance (as `defaults write` from another process would) changes it.
            let other = UserDefaults(suiteName: suite)!
            other.set(true, forKey: W7ExplorerOpenFoldersInNewWindowKey)
            #expect(W7ExplorerOpensFoldersInNewWindow())
            other.removeObject(forKey: W7ExplorerOpenFoldersInNewWindowKey)
            #expect(!W7ExplorerOpensFoldersInNewWindow())
        }
    }

    @Test func hookedClassReportsShownToolbarForExplorerWindows() {
        withTestSuite { _ in
            let explorer = finderLikeWindow()
            W7ExplorerAdopt(explorer)
            let plain = finderLikeWindow()
            let probe = BrowseProbe()
            probe.probeWindow = explorer
            #expect(!probe.isToolbarVisible)   // before the hook: the original

            #expect(W7ExplorerHookToolbarVisibleOnClass(BrowseProbe.self))
            #expect(probe.isToolbarVisible)    // same window: Finder sees a shown toolbar
            W7ExplorerSetOpensFoldersInNewWindow(true)
            #expect(!probe.isToolbarVisible)   // own window: the real (hidden) state
            probe.actual = true
            #expect(probe.isToolbarVisible)
            W7ExplorerSetOpensFoldersInNewWindow(false)
            probe.actual = false

            // A window that is not an Explorer window, or none at all: the original value.
            probe.probeWindow = plain
            #expect(!probe.isToolbarVisible)
            probe.probeWindow = nil
            #expect(!probe.isToolbarVisible)
            explorer.close()
            plain.close()
        }
    }

    @Test func hookingTwiceIsIdempotent() {
        withTestSuite { _ in
            let original = toolbarVisibleIMP(BrowseProbeTwice.self)
            #expect(W7ExplorerHookToolbarVisibleOnClass(BrowseProbeTwice.self))
            let imp = toolbarVisibleIMP(BrowseProbeTwice.self)
            #expect(imp != original)
            #expect(W7ExplorerHookToolbarVisibleOnClass(BrowseProbeTwice.self))
            #expect(toolbarVisibleIMP(BrowseProbeTwice.self) == imp)
            let explorer = finderLikeWindow()
            W7ExplorerAdopt(explorer)
            let probe = BrowseProbeTwice()
            probe.probeWindow = explorer
            #expect(probe.isToolbarVisible)
            W7ExplorerSetOpensFoldersInNewWindow(true)
            #expect(!probe.isToolbarVisible)
            explorer.close()
        }
    }

    @Test func classesWithoutAnOwnBoolMethodAreNotTouched() {
        let before = ownMethodNames(BrowseProbeNoMethod.self)
        #expect(!W7ExplorerHookToolbarVisibleOnClass(BrowseProbeNoMethod.self))
        #expect(ownMethodNames(BrowseProbeNoMethod.self) == before)
        #expect(!BrowseProbeNoMethod().responds(to: NSSelectorFromString("isToolbarVisible")))

        let inherited = toolbarVisibleIMP(BrowseProbeSubclass.self)
        #expect(!W7ExplorerHookToolbarVisibleOnClass(BrowseProbeSubclass.self))
        #expect(!ownMethodNames(BrowseProbeSubclass.self).contains("isToolbarVisible"))
        #expect(toolbarVisibleIMP(BrowseProbeSubclass.self) == inherited)

        let wrong = toolbarVisibleIMP(BrowseProbeWrongType.self)
        #expect(!W7ExplorerHookToolbarVisibleOnClass(BrowseProbeWrongType.self))
        #expect(toolbarVisibleIMP(BrowseProbeWrongType.self) == wrong)
    }

    @Test func receiverMapsToItsWindow() {
        withTestSuite { _ in
            let explorer = finderLikeWindow()
            W7ExplorerAdopt(explorer)
            #expect(W7ExplorerHookToolbarVisibleOnClass(BrowseProbeWindowController.self))
            #expect(W7ExplorerHookToolbarVisibleOnClass(BrowseProbeViewController.self))
            #expect(W7ExplorerHookToolbarVisibleOnClass(BrowseProbeWindow.self))

            let wc = BrowseProbeWindowController(window: explorer)
            #expect(wc.isToolbarVisible)
            #expect(!BrowseProbeWindowController(window: finderLikeWindow()).isToolbarVisible)

            let vc = BrowseProbeViewController()
            #expect(!vc.isToolbarVisible)       // no view loaded: never loads one, original value
            vc.view = NSView()
            explorer.contentView?.addSubview(vc.view)
            #expect(vc.isToolbarVisible)

            let w = BrowseProbeWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: true)
            w.isReleasedWhenClosed = false
            w.toolbar = NSToolbar(identifier: "W7BrowseProbeWindowToolbar")
            #expect(!w.isToolbarVisible)
            W7ExplorerAdopt(w)
            #expect(w.isToolbarVisible)
            w.close()
            explorer.close()
        }
    }

    @Test func imageScanFindsOnlyThatImagesOwnBoolGetters() throws {
        // The test bundle's image: every probe that owns a BOOL -isToolbarVisible, nothing else.
        let image = String(cString: try #require(class_getImageName(BrowseProbe.self)))
        let before = toolbarVisibleIMP(BrowseProbeUnhooked.self)
        let names = Set(W7ExplorerBrowseHookCandidates(image).map { NSStringFromClass($0) })
        let owners = [BrowseProbe.self, BrowseProbeTwice.self, BrowseProbeUnhooked.self, BrowseProbeInheritBase.self,
                      BrowseProbeWindowController.self, BrowseProbeViewController.self, BrowseProbeWindow.self]
            .map { NSStringFromClass($0) }
        #expect(names == Set(owners))
        // Another image's scan never sees the test classes (and AppKit owns no such method).
        let appKit = String(cString: try #require(class_getImageName(NSWindow.self)))
        #expect(W7ExplorerBrowseHookCandidates(appKit).isEmpty)
        #expect(W7ExplorerBrowseHookCandidates("/no/such/image").isEmpty)
        // The scan only lists: nothing was hooked.
        #expect(toolbarVisibleIMP(BrowseProbeUnhooked.self) == before)
    }

    @Test func installerHooksNoClassOutsideFinder() {
        withTestSuite { _ in
            let imp = toolbarVisibleIMP(BrowseProbeUnhooked.self)
            W7ExplorerInstallBrowseHook()
            W7ExplorerInstallBrowseHook()
            #expect(toolbarVisibleIMP(BrowseProbeUnhooked.self) == imp)
            let explorer = finderLikeWindow()
            W7ExplorerAdopt(explorer)
            let probe = BrowseProbeUnhooked()
            probe.probeWindow = explorer
            #expect(!probe.isToolbarVisible)
            explorer.close()
        }
    }

    // MARK: Organize menu

    private func browseItems(_ menu: NSMenu?) -> (same: NSMenuItem?, own: NSMenuItem?) {
        (menu?.items.first { $0.title == "Open each folder in the same window" },
         menu?.items.first { $0.title == "Open each folder in its own window" })
    }

    @Test func organizeMenuHasTheBrowseOptions() throws {
        try withTestSuite { _ in
            let w = finderLikeWindow()
            W7ExplorerAdopt(w)
            let menu = try #require(W7ExplorerOrganizeMenu(w))
            let (same, own) = browseItems(menu)
            let s = try #require(same), o = try #require(own)
            // After the Finder entries, behind their own separator, last.
            let si = menu.index(of: s), oi = menu.index(of: o)
            #expect(oi == menu.numberOfItems - 1 && si == oi - 1)
            #expect(menu.item(at: si - 1)?.isSeparatorItem == true)
            #expect(menu.items.first?.title == "Cut")
            #expect(s.isEnabled && o.isEnabled)
            #expect(s.keyEquivalent.isEmpty && o.keyEquivalent.isEmpty)
            // Their own action, not the Finder shortcut proxy.
            #expect(s.representedObject == nil && o.representedObject == nil)
            #expect(s.action != NSSelectorFromString("w7PerformProxy:"))
            #expect(s.state == .on && o.state == .off)
            w.close()
        }
        // Not an Explorer window: no menu.
        #expect(W7ExplorerOrganizeMenu(finderLikeWindow()) == nil)
    }

    @Test func choosingABrowseOptionFlipsThePreference() throws {
        try withTestSuite { suite in
            let w = finderLikeWindow()
            W7ExplorerAdopt(w)
            var menu = try #require(W7ExplorerOrganizeMenu(w))
            var (same, own) = browseItems(menu)
            menu.performActionForItem(at: menu.index(of: try #require(own)))
            #expect(W7ExplorerOpensFoldersInNewWindow())
            #expect(UserDefaults(suiteName: suite)?.bool(forKey: W7ExplorerOpenFoldersInNewWindowKey) == true)

            menu = try #require(W7ExplorerOrganizeMenu(w))
            (same, own) = browseItems(menu)
            #expect(same?.state == .off && own?.state == .on)
            menu.performActionForItem(at: menu.index(of: try #require(same)))
            #expect(!W7ExplorerOpensFoldersInNewWindow())
            (same, own) = browseItems(W7ExplorerOrganizeMenu(w))
            #expect(same?.state == .on && own?.state == .off)
            w.close()
        }
    }
}
