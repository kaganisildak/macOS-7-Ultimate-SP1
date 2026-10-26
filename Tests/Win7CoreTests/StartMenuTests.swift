import Testing
import Foundation
@testable import Win7Core

private let apps = ["Instruments", "System Settings", "Safari", "İletişim Aracı", "Mail"].map {
    AppEntry(name: $0, path: "/x/\($0).app", bundleID: nil)
}

@Suite struct StartMenuTests {
    @Test func scanFindsAppsOneLevelDeep() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("w7scan-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for p in ["A.app", "Utilities/B.app", "A.app/Contents/Inner.app", "Utilities/Deep/C.app"] {
            try fm.createDirectory(at: root.appendingPathComponent(p), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("notes.txt"))
        let found = AppCatalog.scan(directories: [root, root], fileManager: fm)
        #expect(found.map(\.name) == ["A", "B"])
    }

    @Test func turkishSafeSearch() {
        #expect(AppCatalog.search("ins", in: apps).map(\.name) == ["Instruments"])
        #expect(AppCatalog.search("İns", in: apps).map(\.name) == ["Instruments"])
        #expect(AppCatalog.search("ılet", in: apps).map(\.name) == ["İletişim Aracı"])
    }

    @Test func rankingPrefixThenWordStartThenSubstring() {
        #expect(AppCatalog.search("s", in: apps).map(\.name) == ["System Settings", "Safari", "Instruments", "İletişim Aracı"])
        #expect(AppCatalog.search("set", in: apps).map(\.name) == ["System Settings"])
        #expect(AppCatalog.search("", in: apps).isEmpty)
    }

    @Test func recentMRU() {
        var r = RecentApps()
        r.record("a"); r.record("b"); r.record("a")
        #expect(r.paths == ["a", "b"])
        for i in 0..<12 { r.record("p\(i)") }
        #expect(r.paths.count == 10)
        #expect(r.paths.first == "p11" && r.paths.last == "p2")
    }

    @Test func powerCommands() {
        #expect(PowerAction.shutDown.command == ["/usr/bin/osascript", "-e", "tell application \"System Events\" to shut down"])
        #expect(PowerAction.restart.command == ["/usr/bin/osascript", "-e", "tell application \"System Events\" to restart"])
        #expect(PowerAction.logOff.command == ["/usr/bin/osascript", "-e", "tell application \"System Events\" to log out"])
        #expect(PowerAction.sleep.command == ["/usr/bin/pmset", "sleepnow"])
        #expect(PowerAction.lock.command == nil)
    }
}
