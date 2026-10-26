import Testing
import Foundation
@testable import Win7Core

// The Windows names the shell shows for Mac programs, the Command Prompt launch and the Start
// menu's launch targets.

@Suite struct ProgramNamesTests {
    @Test func theTableIsExactlyThePlans() {
        let expected = [
            "com.apple.finder": "Windows Explorer",
            "com.apple.Safari": "Internet Explorer",
            "com.apple.Terminal": "Command Prompt",
            "com.apple.Notes": "Sticky Notes",
            "com.apple.TextEdit": "Notepad",
            "com.apple.ActivityMonitor": "Task Manager",
            "com.apple.Music": "Windows Media Player",
            "com.apple.Preview": "Windows Photo Viewer",
            "com.apple.calculator": "Calculator",
            "com.apple.systempreferences": "Control Panel",
            "com.apple.mail": "Windows Live Mail",
            "com.apple.MobileSMS": "Windows Live Messenger",
            "com.apple.Photos": "Windows Live Photo Gallery",
        ]
        #expect(ProgramNames.table == expected)
        for (id, name) in expected { #expect(ProgramNames.windowsName(bundleID: id) == name, "\(id)") }
    }

    @Test func otherProgramsKeepTheirMacName() {
        #expect(ProgramNames.windowsName(bundleID: "com.apple.Maps") == nil)
        #expect(ProgramNames.windowsName(bundleID: "") == nil)
        // Bundle IDs are matched exactly (LaunchServices' own case).
        #expect(ProgramNames.windowsName(bundleID: "com.apple.terminal") == nil)
        #expect(ProgramNames.displayName(bundleID: "com.apple.Maps", macName: "Maps") == "Maps")
        #expect(ProgramNames.displayName(bundleID: nil, macName: "Loose") == "Loose")
        #expect(ProgramNames.displayName(bundleID: "com.apple.Terminal", macName: "Terminal") == "Command Prompt")
    }

    /// The Start menu's catalog: Windows names, re-sorted by them; entries without a mapping are untouched.
    @Test func renamedCatalogIsSortedByTheWindowsNames() {
        let apps = [
            AppEntry(name: "Calculator", path: "/System/Applications/Calculator.app", bundleID: "com.apple.calculator"),
            AppEntry(name: "Maps", path: "/System/Applications/Maps.app", bundleID: "com.apple.Maps"),
            AppEntry(name: "Safari", path: "/Applications/Safari.app", bundleID: "com.apple.Safari"),
            AppEntry(name: "Terminal", path: "/System/Applications/Utilities/Terminal.app", bundleID: "com.apple.Terminal"),
        ]
        let renamed = ProgramNames.renamed(apps)
        #expect(renamed.map(\.name) == ["Calculator", "Command Prompt", "Internet Explorer", "Maps"])
        #expect(renamed.map(\.path) == [apps[0].path, apps[3].path, apps[2].path, apps[1].path])
    }

    /// Search finds a renamed program by its Windows name, its macOS name, and Command Prompt by "cmd".
    @Test func searchTermsKeepTheMacNameAndCmd() {
        let apps = ProgramNames.renamed([
            AppEntry(name: "Terminal", path: "/System/Applications/Utilities/Terminal.app", bundleID: "com.apple.Terminal"),
            AppEntry(name: "TextEdit", path: "/System/Applications/TextEdit.app", bundleID: "com.apple.TextEdit"),
            AppEntry(name: "Maps", path: "/System/Applications/Maps.app", bundleID: "com.apple.Maps"),
        ])
        let terms = ProgramNames.searchTerms
        #expect(AppCatalog.search("cmd", in: apps, extraTerms: terms).map(\.name) == ["Command Prompt"])
        #expect(AppCatalog.search("command", in: apps, extraTerms: terms).map(\.name) == ["Command Prompt"])
        #expect(AppCatalog.search("termi", in: apps, extraTerms: terms).map(\.name) == ["Command Prompt"])
        #expect(AppCatalog.search("note", in: apps, extraTerms: terms).map(\.name) == ["Notepad"])
        #expect(AppCatalog.search("textedit", in: apps, extraTerms: terms).map(\.name) == ["Notepad"])
        // A Windows-name prefix ranks before an alias match.
        let both = ProgramNames.renamed([
            AppEntry(name: "Terminal", path: "/System/Applications/Utilities/Terminal.app", bundleID: "com.apple.Terminal"),
            AppEntry(name: "Cmdr", path: "/Applications/Cmdr.app", bundleID: "org.example.cmdr"),
        ])
        #expect(AppCatalog.search("cmd", in: both, extraTerms: terms).map(\.name) == ["Cmdr", "Command Prompt"])
        // Without extra terms the search is as before.
        #expect(AppCatalog.search("cmd", in: apps).isEmpty)
    }

    /// Command Prompt: the "Win7 Command Prompt" profile file when one exists (opening it opens a Terminal window
    /// with that profile), else plain Terminal.
    @Test func commandPromptOpensTheProfileFileWhenItExists() {
        let support = URL(fileURLWithPath: "/Users/me/Library/Application Support/Win7Mac/Assets/terminal/Win7 Command Prompt.terminal")
        let repo = URL(fileURLWithPath: "/repo/Assets/terminal/Win7 Command Prompt.terminal")
        #expect(CommandPromptLaunch.profileRelativePath == "terminal/Win7 Command Prompt.terminal")
        #expect(CommandPromptLaunch.target(candidates: [support, repo], fileExists: { $0 == repo.path }) == .profile(repo))
        #expect(CommandPromptLaunch.target(candidates: [support, repo], fileExists: { _ in true }) == .profile(support))
        #expect(CommandPromptLaunch.target(candidates: [support, repo], fileExists: { _ in false }) == .terminal)
        #expect(CommandPromptLaunch.target(candidates: [], fileExists: { _ in true }) == .terminal)
        #expect(CommandPromptLaunch.terminalBundleID == "com.apple.Terminal")
    }

    /// The Start menu: Terminal is Command Prompt everywhere; Calculator in the left pane and search hits is the
    /// shell's Windows 7 Calculator, while All Programs keeps the macOS Calculator.
    @Test func startMenuLaunchTargets() {
        #expect(StartMenuLaunch.target(bundleID: "com.apple.Terminal", inAllPrograms: false) == .commandPrompt)
        #expect(StartMenuLaunch.target(bundleID: "com.apple.Terminal", inAllPrograms: true) == .commandPrompt)
        #expect(StartMenuLaunch.target(bundleID: "com.apple.calculator", inAllPrograms: false) == .shellCalculator)
        #expect(StartMenuLaunch.target(bundleID: "com.apple.calculator", inAllPrograms: true) == .application)
        #expect(StartMenuLaunch.target(bundleID: "com.apple.Safari", inAllPrograms: false) == .application)
        #expect(StartMenuLaunch.target(bundleID: nil, inAllPrograms: false) == .application)
    }

    /// The taskbar: a pin or the jump list's program row starts Terminal as Command Prompt too (the profile file);
    /// everything else, Calculator included, starts as itself.
    @Test func taskbarLaunchesTerminalAsCommandPrompt() {
        #expect(CommandPromptLaunch.isCommandPrompt(bundleID: "com.apple.Terminal"))
        #expect(!CommandPromptLaunch.isCommandPrompt(bundleID: "com.apple.terminal"))
        #expect(!CommandPromptLaunch.isCommandPrompt(bundleID: "com.apple.calculator"))
        #expect(!CommandPromptLaunch.isCommandPrompt(bundleID: nil))
    }

    /// Taskbar buttons (a reload and every step of a drag reorder) get the Windows names, in their own order.
    @Test func taskbarItemsGetWindowsNamesInPlace() {
        let items = [
            TaskbarItem(bundleID: "com.apple.Terminal", name: "Terminal", isPinned: true, isRunning: false, isActive: false),
            TaskbarItem(bundleID: "com.apple.Maps", name: "Maps", isPinned: true, isRunning: true, isActive: true),
            TaskbarItem(bundleID: "com.apple.finder", name: "Finder", isPinned: true, isRunning: true, isActive: false),
        ]
        let renamed = ProgramNames.renamed(items)
        #expect(renamed.map(\.name) == ["Command Prompt", "Maps", "Windows Explorer"])
        #expect(renamed.map(\.bundleID) == items.map(\.bundleID))
        #expect(renamed.map(\.isActive) == items.map(\.isActive))
    }
}

/// The Calculator is one of the shell's framed windows, opened from Programs ▸ Calculator.
@Suite struct CalculatorWindowTargetTests {
    @Test func targetAndControlPanelItem() {
        #expect(ShellWindowTarget.calculator.identifier == "win7.calculator")
        #expect(ShellWindowTarget.calculator.title == "Calculator")
        let item = ControlPanelCatalog.items.first { $0.id == "calculator" }
        #expect(item?.title == "Calculator" && item?.categories == [.programs])
        #expect(item?.action == .shellWindow(.calculator))
        #expect(item?.iconNames == ["cp-calculator", "app-com.apple.calculator"])
        #expect(ControlPanelAvailability.isAvailable(.shellWindow(.calculator), fileExists: { _ in false }, bundleID: { _ in nil }))
        #expect(ControlPanelCatalog.calculatorInfo.contains("All Programs"))
    }
}
