import Testing
import Foundation
@testable import Win7Core

private let finder = PinnedApp(bundleID: "com.apple.finder", name: "Finder")
private let safari = PinnedApp(bundleID: "com.apple.Safari", name: "Safari")
private func run(_ id: String, _ order: Int, active: Bool = false, pid: Int32 = 1) -> RunningApp {
    .init(bundleID: id, name: id, pid: pid, isActive: active, launchOrder: order)
}

@Suite struct TaskbarTests {
    @Test func pinnedFirstThenRunningByLaunchOrder() {
        let items = TaskbarModel.items(pinned: [finder, safari], running: [run("mail", 2), run("com.apple.finder", 1, active: true), run("term", 3)])
        #expect(items.map(\.bundleID) == ["com.apple.finder", "com.apple.Safari", "mail", "term"])
        #expect(items[0].isRunning && items[0].isActive && !items[1].isRunning)
    }

    @Test func groupsMultipleProcesses() {
        #expect(TaskbarModel.items(pinned: [], running: [run("x", 1, pid: 1), run("x", 2, pid: 2)]).count == 1)
    }

    @Test func defaultPinsOrder() {
        #expect(TaskbarModel.defaultPins.map(\.bundleID) == ["com.apple.finder", "com.apple.Safari", "com.apple.Music"])
    }

    @Test func clickActions() {
        func item(running: Bool, active: Bool) -> TaskbarItem {
            .init(bundleID: "x", name: "x", isPinned: true, isRunning: running, isActive: active)
        }
        #expect(TaskbarModel.clickAction(for: item(running: false, active: false)) == .launch)
        #expect(TaskbarModel.clickAction(for: item(running: true, active: true)) == .hide)
        #expect(TaskbarModel.clickAction(for: item(running: true, active: false)) == .activate)
    }

    @Test func clickActionsByWindowCount() {
        func item(running: Bool, active: Bool) -> TaskbarItem {
            .init(bundleID: "x", name: "x", isPinned: true, isRunning: running, isActive: active)
        }
        func action(running: Bool = true, active: Bool, total: Int, minimized: Int = 0,
                    filtered: Int = 0) -> TaskbarClickAction {
            TaskbarModel.clickAction(for: item(running: running, active: active),
                                     windows: WindowCounts(total: total, minimized: minimized, filteredOnScreen: filtered))
        }
        for total in [0, 1, 2, 5] {
            #expect(action(running: false, active: false, total: total) == .launch)
        }
        for active in [true, false] {
            // One window: today's app-level behaviour.
            #expect(action(active: active, total: 1) == (active ? .hide : .activate))
            // No window on screen and none known minimized (everything minimized without AX, a
            // hidden app without AX, or no windows open): the Dock's unhide + reopen.
            #expect(action(active: active, total: 0) == .reopen)
            // AX knows the only window is minimized: bring it back.
            #expect(action(active: active, total: 1, minimized: 1) == .unminimize)
            // Several windows, minimized or not: the list.
            #expect(action(active: active, total: 2) == .showWindowList)
            #expect(action(active: active, total: 2, minimized: 1) == .showWindowList)
            #expect(action(active: active, total: 7, minimized: 7) == .showWindowList)
        }
        // Only filtered-out windows on screen (panels, layer != 0, tiny): the active app keeps the
        // old toggle; an inactive one is reopened (which activates it).
        #expect(action(active: true, total: 0, filtered: 2) == .hide)
        #expect(action(active: false, total: 0, filtered: 2) == .reopen)
        // Filtered windows do not change the decision when real windows exist.
        #expect(action(active: true, total: 1, filtered: 3) == .hide)
        #expect(action(active: true, total: 2, filtered: 3) == .showWindowList)
    }

    @Test func showDesktopToggles() {
        var s = ShowDesktopState()
        #expect(s.toggle(visibleApps: ["a", "b"]) == .hide(["a", "b"]))
        #expect(s.toggle(visibleApps: []) == .unhide(["a", "b"]))
        _ = s.toggle(visibleApps: ["a"]); s.reset()
        #expect(s.toggle(visibleApps: ["c"]) == .hide(["c"]))
    }

    private func sampleDate() -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 14, minute: 32))!
    }

    @Test func clockTurkish() {
        let l = ClockFormatter.lines(for: sampleDate(), locale: Locale(identifier: "tr_TR"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(l.time == "14:32" && l.date == "16.10.2026")
    }

    @Test func clockUS() {
        let l = ClockFormatter.lines(for: sampleDate(), locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(l.time.replacingOccurrences(of: "\u{202F}", with: " ") == "2:32 PM")
        #expect(l.date == "10/16/2026")
    }
}
