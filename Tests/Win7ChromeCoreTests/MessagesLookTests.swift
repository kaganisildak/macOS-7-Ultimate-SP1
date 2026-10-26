import AppKit
import SwiftUI
import Testing
import Win7ChromeCore

// The Messages view-tree diagnostics behind W7MessagesVerboseLog. Names and numbers
// only: class names, frames, flags (SwiftUI host, split view panes, table/outline/collection counts), the toolbar's
// item identifiers and the window's contentLayoutRect. Never any text: a sentinel string put in every text-bearing
// place (text field values, a text view, a button title, a SwiftUI Text, tool tips, accessibility labels, view
// identifiers, the window title, toolbar labels) must never reach the dump. Synthetic views and windows that are
// never ordered on screen; Messages itself is never launched.

private let sentinel = "W7SENTINEL-Alice-says-meet-at-noon"

@MainActor private func scroll(_ document: NSView, frame: NSRect) -> NSScrollView {
    let s = NSScrollView(frame: frame)
    s.documentView = document
    return s
}

/// A Messages-like tree: a vertical split (conversation list | transcript), an outline and a table in scroll views, a
/// collection view, a SwiftUI host, and the sentinel in every text-bearing place.
@MainActor private func syntheticTree() -> NSView {
    let root = NSView(frame: .init(x: 0, y: 0, width: 800, height: 600))
    let split = NSSplitView(frame: root.bounds)
    split.isVertical = true
    let left = NSView(frame: .init(x: 0, y: 0, width: 250, height: 600))
    let right = NSView(frame: .init(x: 251, y: 0, width: 549, height: 600))
    split.addArrangedSubview(left)
    split.addArrangedSubview(right)
    root.addSubview(split)

    let outline = NSOutlineView(frame: .init(x: 0, y: 0, width: 250, height: 400))
    outline.addTableColumn(NSTableColumn(identifier: .init("c")))
    left.addSubview(scroll(outline, frame: .init(x: 0, y: 200, width: 250, height: 400)))
    let table = NSTableView(frame: .init(x: 0, y: 0, width: 250, height: 200))
    table.addTableColumn(NSTableColumn(identifier: .init("c")))
    left.addSubview(scroll(table, frame: .init(x: 0, y: 0, width: 250, height: 200)))

    let collection = NSCollectionView(frame: .init(x: 0, y: 100, width: 549, height: 400))
    right.addSubview(collection)
    let label = NSTextField(labelWithString: sentinel)
    label.toolTip = sentinel
    label.setAccessibilityLabel(sentinel)
    label.identifier = .init(sentinel)
    right.addSubview(label)
    let composer = NSTextField(string: sentinel)
    composer.placeholderString = sentinel
    composer.frame = .init(x: 0, y: 0, width: 549, height: 24)
    right.addSubview(composer)
    let textView = NSTextView(frame: .init(x: 0, y: 30, width: 549, height: 60))
    textView.string = sentinel
    right.addSubview(textView)
    let button = NSButton(title: sentinel, target: nil, action: nil)
    right.addSubview(button)
    let host = NSHostingView(rootView: Text(sentinel))
    host.frame = .init(x: 0, y: 520, width: 549, height: 80)
    right.addSubview(host)
    return root
}

@MainActor private final class MessagesToolbarDelegate: NSObject, NSToolbarDelegate {
    static let ids: [NSToolbarItem.Identifier] = [.init("w7.messages.test.compose"), .flexibleSpace, .init("w7.messages.test.info")]
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.ids }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.ids }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = sentinel
        item.paletteLabel = sentinel
        item.toolTip = sentinel
        item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: sentinel)
        return item
    }
}

@MainActor private func makeWindow(_ style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable],
                                   panel: Bool = false) -> NSWindow {
    _ = NSApplication.shared
    let rect = NSRect(x: 0, y: 0, width: 800, height: 600)
    let w = panel ? NSPanel(contentRect: rect, styleMask: style, backing: .buffered, defer: true)
                  : NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: true)
    w.isReleasedWhenClosed = false
    w.title = sentinel
    return w
}

@MainActor @Suite(.serialized) struct MessagesLookTests {
    // MARK: Decision

    @Test func dumpsOnlyMessagesMainWindowsWithTheVerboseSwitchAndNoKillSwitch() {
        let sms = "com.apple.MobileSMS"
        #expect(W7MessagesBundleIdentifier == sms)
        #expect(W7MessagesShouldDump(sms, true, false, true, false))
        #expect(!W7MessagesShouldDump(sms, true, true, true, false), "the kill switch skips even the dump")
        #expect(!W7MessagesShouldDump(sms, true, false, false, false), "verbose off: nothing")
        #expect(!W7MessagesShouldDump(sms, true, false, true, true), "once per window")
        #expect(!W7MessagesShouldDump(sms, false, false, true, false), "not a main window")
        #expect(!W7MessagesShouldDump("com.apple.Safari", true, false, true, false))
        #expect(!W7MessagesShouldDump(nil, true, false, true, false))
    }

    @Test func mainWindowShapeIsATitledResizableTopLevelWindow() {
        let main: NSWindow.StyleMask = [.titled, .closable, .resizable]
        #expect(W7MessagesIsMainWindowShape(main, false, false))
        #expect(!W7MessagesIsMainWindowShape(main, true, false), "panels")
        #expect(!W7MessagesIsMainWindowShape(main, false, true), "sheets")
        #expect(!W7MessagesIsMainWindowShape([.titled, .closable], false, false), "not resizable (Settings)")
        #expect(!W7MessagesIsMainWindowShape([.borderless, .resizable], false, false), "untitled")
    }

    // MARK: The formatter on a synthetic tree

    @Test func treeDumpHasClassNamesFramesAndFlags() {
        let lines = W7MessagesViewTreeLines(syntheticTree(), 30, 400)
        let dump = lines.joined(separator: "\n")
        #expect(dump.contains("NSSplitView"))
        #expect(dump.contains("split vertical=1 panes=2"), "split view panes")
        #expect(dump.contains("(251,0 549x600)"), "frames as (x,y wxh)")
        #expect(lines.contains { $0.contains("NSOutlineView") && $0.contains("outline rows=0 cols=1") })
        #expect(lines.contains { $0.contains("NSTableView") && $0.contains("table rows=0 cols=1") })
        #expect(lines.contains { $0.contains("NSCollectionView") && $0.contains("collection sections=") })
        #expect(lines.contains { $0.contains("text-field editable=0") }, "a label is flagged, never read")
        #expect(lines.contains { $0.contains("text-field editable=1") })
        #expect(lines.contains { $0.contains("text-view editable=1") })
        #expect(lines.contains { $0.contains("HostingView") && $0.contains("SwiftUI-host") }, "the SwiftUI host is flagged")
        #expect(lines.allSatisfy { !$0.contains("NSSplitView") || !$0.contains("SwiftUI-host") }, "AppKit views are not")
        #expect(lines.allSatisfy { !$0.contains("CoreHostingView") || $0.contains("AppKit-core-host") },
                "AppKit's internal _NSCoreHostingView is told apart from a SwiftUI host")
        #expect(lines.allSatisfy { !$0.contains("CoreHostingView") || !$0.contains("SwiftUI-host") })
        // Indentation follows depth: the split view's panes are one level under it.
        let splitLine = try! #require(lines.first { $0.contains("NSSplitView") })
        let splitIndent = splitLine.prefix { $0 == " " }.count
        #expect(lines.contains { $0.hasPrefix(String(repeating: " ", count: splitIndent + 2) + "NSView (251,0 549x600)") })
    }

    @Test func noTextContentReachesTheTreeDump() {
        let dump = W7MessagesViewTreeLines(syntheticTree(), 30, 400).joined(separator: "\n")
        #expect(!dump.contains(sentinel), "no stringValue, string, title, tool tip, accessibility label or identifier")
        #expect(!dump.contains("W7SENTINEL"))
        #expect(!dump.contains("Alice"))
    }

    @Test func treeDumpIsBoundedInDepthViewsAndSiblings() {
        // Depth: a chain of 40 nested views, 5 levels at most.
        let top = NSView(frame: .init(x: 0, y: 0, width: 10, height: 10))
        var v = top
        for _ in 0..<40 { let c = NSView(frame: v.bounds); v.addSubview(c); v = c }
        let deep = W7MessagesViewTreeLines(top, 5, 400)
        #expect(deep.allSatisfy { $0.prefix { $0 == " " }.count <= 10 }, "depth 5 = 10 spaces")
        #expect(deep.filter { $0.contains("NSView (") }.count == 6)

        // Siblings: 30 children, the first 12 and a count of the rest.
        let wide = NSView(frame: .init(x: 0, y: 0, width: 10, height: 10))
        for i in 0..<30 { wide.addSubview(NSView(frame: .init(x: CGFloat(i), y: 0, width: 1, height: 1))) }
        let siblings = W7MessagesViewTreeLines(wide, 30, 400)
        #expect(siblings.filter { $0.contains("NSView (") }.count == 13)
        #expect(siblings.contains { $0.contains("+18 more subviews") })

        // Views: at most `maxViews` view lines, and a note that the dump stopped.
        let many = NSView(frame: .init(x: 0, y: 0, width: 10, height: 10))
        for _ in 0..<10 {
            let group = NSView(frame: many.bounds)
            for _ in 0..<10 { group.addSubview(NSView(frame: group.bounds)) }
            many.addSubview(group)
        }
        let capped = W7MessagesViewTreeLines(many, 30, 20)
        #expect(capped.filter { $0.contains("NSView (") }.count == 20)
        #expect(capped.contains { $0.contains("stopped at 20 views") })
    }

    @Test func treeDumpOfNothingIsEmpty() {
        #expect(W7MessagesViewTreeLines(nil, 30, 400).isEmpty)
    }

    // MARK: The window dump

    @Test func windowDumpHasLayoutRectToolbarIdentifiersAndInventoryButNoText() {
        let w = makeWindow()
        defer { w.close() }
        let delegate = MessagesToolbarDelegate()
        let toolbar = NSToolbar(identifier: "w7.messages.test.toolbar")
        toolbar.delegate = delegate
        toolbar.autosavesConfiguration = false
        w.toolbar = toolbar
        w.contentView = syntheticTree()
        w.layoutIfNeeded()
        let lines = W7MessagesWindowDump(w)
        let dump = lines.joined(separator: "\n")
        #expect(dump.contains("contentLayoutRect=("))
        #expect(dump.contains("toolbar=w7.messages.test.toolbar"))
        #expect(dump.contains("toolbar items: w7.messages.test.compose, NSToolbarFlexibleSpaceItem, w7.messages.test.info"))
        // The panes' frames as the split view laid them out in the window (AppKit resizes them to its own bounds).
        let splitLine = try! #require(lines.first { $0.hasPrefix("split NSSplitView") })
        #expect(splitLine.contains("vertical=1 panes: (0,0 "))
        #expect(splitLine.components(separatedBy: "), (").count == 2, "two panes")
        #expect(lines.filter { $0.hasPrefix("host ") }.count == 1, "the one SwiftUI host; AppKit's own core hosts are only counted")
        #expect(lines.contains { $0.hasPrefix("host ") && $0.contains("SwiftUI") && $0.contains("inWindow=(") })
        #expect(lines.contains { $0.hasPrefix("table NSTableView") })
        #expect(lines.contains { $0.hasPrefix("outline NSOutlineView") })
        #expect(lines.contains { $0.hasPrefix("collection NSCollectionView") })
        #expect(lines.contains { $0.hasPrefix("summary: views ") && $0.contains("SwiftUI hosts 1,") && $0.contains("splits 1,")
                                 && $0.contains("AppKit core hosts ") })
        #expect(lines.allSatisfy { !$0.contains("NSKVONotifying_") }, "the class, not its KVO subclass")
        #expect(dump.contains("NSThemeFrame") || dump.contains("Frame"), "from the window's root view, title bar included")
        #expect(!dump.contains(sentinel), "never the title, a label, a tool tip or any text")
        #expect(!dump.contains("W7SENTINEL"))
    }

    @Test func windowDumpOfNilIsEmpty() {
        #expect(W7MessagesWindowDump(nil).isEmpty)
    }

    // MARK: The window path (W7ChromeController)

    @Test func updateSchedulesOneDumpPerMessagesMainWindowOnlyWhenVerboseAndEnabled() {
        defer { W7MessagesLookUseDisabledOverride(-1); W7MessagesUseVerboseLogOverride(-1) }
        let sms = "com.apple.MobileSMS"

        W7MessagesLookUseDisabledOverride(1)
        W7MessagesUseVerboseLogOverride(1)
        let killed = makeWindow()
        defer { killed.close() }
        #expect(!W7MessagesLookUpdateForBundle(killed, sms), "W7MessagesLookDisabled skips even the dump")

        W7MessagesLookUseDisabledOverride(0)
        W7MessagesUseVerboseLogOverride(0)
        let quiet = makeWindow()
        defer { quiet.close() }
        #expect(!W7MessagesLookUpdateForBundle(quiet, sms), "no dump without W7MessagesVerboseLog")

        W7MessagesUseVerboseLogOverride(1)
        let other = makeWindow()
        defer { other.close() }
        #expect(!W7MessagesLookUpdateForBundle(other, "com.apple.Notes"), "Messages only")

        let panel = makeWindow([.titled, .closable, .resizable], panel: true)
        defer { panel.close() }
        #expect(!W7MessagesLookUpdateForBundle(panel, sms), "main windows only")

        let main = makeWindow()
        defer { main.close() }
        #expect(W7MessagesLookUpdateForBundle(main, sms))
        #expect(!W7MessagesLookUpdateForBundle(main, sms), "one dump per window")
        #expect(!W7MessagesLookUpdateForBundle(nil, sms))
    }
}
