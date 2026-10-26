import AppKit
import Testing
import Win7ChromeCore

/// dialog-like panels (About, Preferences, Get Info) get the Aero frame and a Windows 7 dialog body.
@Suite(.serialized) struct DialogPanelTests {
    private let dialog: NSWindow.StyleMask = [.titled, .closable]

    // MARK: - Predicates

    @Test func dialogPanelTruthTable() {
        let normal = NSWindow.Level.normal.rawValue, floating = NSWindow.Level.floating.rawValue
        let plain = ["NSPanel"]
        #expect(W7IsDialogPanel(dialog, normal, false, false, false, plain))
        #expect(W7IsDialogPanel(dialog.union([.resizable, .miniaturizable]), normal, false, false, false, ["MyPrefsPanel", "NSPanel"]))
        #expect(!W7IsDialogPanel([.titled], normal, false, false, false, plain), "not closable")
        #expect(!W7IsDialogPanel([.closable], normal, false, false, false, plain), "not titled")
        #expect(!W7IsDialogPanel(dialog.union(.utilityWindow), normal, false, false, false, plain), "utility")
        #expect(!W7IsDialogPanel(dialog.union([.utilityWindow, .hudWindow]), normal, false, false, false, plain), "HUD")
        #expect(!W7IsDialogPanel(dialog.union(.hudWindow), normal, false, false, false, plain), "HUD bit alone")
        #expect(!W7IsDialogPanel(dialog.union(.nonactivatingPanel), normal, false, false, false, plain), "non-activating")
        #expect(!W7IsDialogPanel(dialog.union(.docModalWindow), normal, false, false, false, plain), "document modal")
        #expect(!W7IsDialogPanel(dialog, floating, false, false, false, plain), "floating level")
        #expect(!W7IsDialogPanel(dialog, normal, true, false, false, plain), "isFloatingPanel")
        #expect(!W7IsDialogPanel(dialog, normal, false, true, false, plain), "sheet")
        #expect(!W7IsDialogPanel(dialog, normal, false, false, true, plain), "NSAlert's window")
        let system = [["NSColorPanel", "NSPanel"], ["NSFontPanel", "NSPanel"], ["NSSavePanel", "NSPanel"],
                      ["NSOpenPanel", "NSSavePanel", "NSPanel"], ["NSPrintPanelWindow"], ["NSSharingServicePickerPanel"],
                      ["_NSAlertPanel", "NSPanel"], ["MyColorPanel", "NSColorPanel", "NSPanel"], ["NSPageLayoutPanel"]]
        for chain in system {
            #expect(!W7IsDialogPanel(dialog, normal, false, false, false, chain), "\(chain)")
        }
    }

    @Test func systemPanelClassNames() {
        #expect(W7IsSystemPanelClassName("_NSAlertPanel"))
        #expect(W7IsSystemPanelClassName("__NSSavePanelRemote"))
        #expect(W7IsSystemPanelClassName("NSSharingServicePickerWindow"))
        for name in ["NSRemoteSavePanel", "NSRemoteOpenPanel", "NSLocalSavePanel", "NSLocalOpenPanel"] {
            #expect(W7IsSystemPanelClassName(name), "\(name)")
        }
        #expect(!W7IsSystemPanelClassName("NSPanel"))
        #expect(!W7IsSystemPanelClassName("PreferencesPanel"))
        #expect(!W7IsSystemPanelClassName(nil))
    }

    @Test func decorationWithDialogPanels() {
        // Windows are unchanged: a panel or a transparent title bar is not decorated.
        #expect(W7ShouldDecorateWindowOrDialog(std, false, false, false, false))
        #expect(!W7ShouldDecorateWindowOrDialog(std, true, false, false, false))
        #expect(!W7ShouldDecorateWindowOrDialog(std, false, false, true, false))
        // Dialog panels are, even with a transparent title bar (the standard About panel), but not full size,
        // full screen, sheets or untitled.
        #expect(W7ShouldDecorateWindowOrDialog(dialog, true, true, false, false))
        #expect(W7ShouldDecorateWindowOrDialog(dialog, true, true, true, false))
        #expect(!W7ShouldDecorateWindowOrDialog(dialog.union(.fullSizeContentView), true, true, true, false))
        #expect(!W7ShouldDecorateWindowOrDialog(dialog.union(.fullScreen), true, true, false, false))
        #expect(!W7ShouldDecorateWindowOrDialog(dialog, true, true, false, true))
        #expect(!W7ShouldDecorateWindowOrDialog([.closable], true, true, false, false))
        // The old predicate is the window-only case.
        #expect(W7ShouldDecorateWindow(std, false, false, false) == W7ShouldDecorateWindowOrDialog(std, false, false, false, false))
    }

    @Test func dialogCaptionButtons() {
        let minimize = 1 << W7CaptionKind.minimize.rawValue, maximize = 1 << W7CaptionKind.maximize.rawValue
        let close = 1 << W7CaptionKind.close.rawValue
        #expect(W7CaptionVisibleButtons(false, dialog) == UInt(minimize | maximize | close))
        #expect(W7CaptionVisibleButtons(true, dialog) == UInt(close))
        #expect(W7CaptionVisibleButtons(true, dialog.union(.resizable)) == UInt(close | maximize))
        #expect(W7CaptionVisibleButtons(true, dialog.union(.miniaturizable)) == UInt(close), "no minimize in a dialog")
        let r = W7CaptionLayout(CGRect(x: 0, y: 0, width: 800, height: 30))
        let onMinimize = CGPoint(x: r.minimize.midX, y: r.minimize.midY), onMaximize = CGPoint(x: r.maximize.midX, y: r.maximize.midY)
        let onClose = CGPoint(x: r.close.midX, y: r.close.midY)
        #expect(W7CaptionHitTestVisible(r, onMinimize, UInt(close)) == -1)
        #expect(W7CaptionHitTestVisible(r, onMaximize, UInt(close)) == -1)
        #expect(W7CaptionHitTestVisible(r, onMaximize, UInt(close | maximize)) == W7CaptionKind.maximize.rawValue)
        #expect(W7CaptionHitTestVisible(r, onClose, UInt(close)) == W7CaptionKind.close.rawValue)
        #expect(W7CaptionTitleMaxX(r, UInt(minimize | maximize | close)) == r.minimize.minX)
        #expect(W7CaptionTitleMaxX(r, UInt(close | maximize)) == r.maximize.minX)
        #expect(W7CaptionTitleMaxX(r, UInt(close)) == r.close.minX)
    }

    // MARK: - Bottom strip detection

    private final class FlippedView: NSView { override var isFlipped: Bool { true } }

    /// `explicitPush` false keeps the bezel +buttonWithTitle: gives (automatic, 0, on macOS 26 and later).
    @MainActor private func pushButton(_ title: String, x: CGFloat, y: CGFloat, explicitPush: Bool = true) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        if explicitPush { b.bezelStyle = .push }
        b.frame = NSRect(x: x, y: y, width: 90, height: 32)
        return b
    }

    @MainActor private func label(_ text: String, y: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.frame = NSRect(x: 20, y: y, width: 200, height: 17)
        return l
    }

    @MainActor @Test func stripUnderBottomButtons() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        content.addSubview(pushButton("Cancel", x: 200, y: 10, explicitPush: false))
        content.addSubview(pushButton("OK", x: 300, y: 10))
        content.addSubview(label("Text above the buttons", y: 100))
        // Buttons' top 42, the text 58 higher: half the gap, at most 16.
        #expect(W7DialogPanelStripTop(content) == 58)
        #expect(W7DialogPanelStripDiagnostics(content) == "top=58.0")
        // A toggle button shows its state: not a push button.
        let toggle = pushButton("Toggle", x: 100, y: 10, explicitPush: false)
        toggle.setButtonType(.pushOnPushOff)
        content.addSubview(toggle)
        #expect(W7DialogPanelStripTop(content) == 0)
        toggle.removeFromSuperview()
        // Pop-up buttons and image-only buttons are not dialog buttons either.
        let popUp = NSPopUpButton(frame: NSRect(x: 20, y: 12, width: 120, height: 25), pullsDown: false)
        popUp.addItem(withTitle: "Choice")
        content.addSubview(popUp)
        #expect(W7DialogPanelStripTop(content) == 0, "pop-up button")
        popUp.removeFromSuperview()
        let imageOnly = NSButton(image: NSImage(size: NSSize(width: 16, height: 16)), target: nil, action: nil)
        imageOnly.frame = NSRect(x: 20, y: 12, width: 32, height: 32)
        content.addSubview(imageOnly)
        #expect(W7DialogPanelStripTop(content) == 0, "image-only button")
        imageOnly.imagePosition = .imageLeft
        imageOnly.title = ""
        #expect(W7DialogPanelStripTop(content) == 0, "untitled button")
        imageOnly.removeFromSuperview()
        #expect(W7DialogPanelStripTop(content) == 58)
        // A separator line and a hidden label in the band do not count.
        let separator = NSBox(frame: NSRect(x: 0, y: 46, width: 400, height: 1))
        separator.boxType = .separator
        content.addSubview(separator)
        let hidden = label("hidden", y: 12)
        hidden.isHidden = true
        content.addSubview(hidden)
        #expect(W7DialogPanelStripTop(content) > 0)
        // A label in the band means the strip does not hold only buttons.
        content.addSubview(label("Status", y: 14))
        #expect(W7DialogPanelStripTop(content) == 0)
        #expect(W7DialogPanelStripDiagnostics(content).hasPrefix("none (a non-button view"))
    }

    @MainActor @Test func stripLooksIntoContainersAndFlippedViews() {
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let row = NSView(frame: NSRect(x: 0, y: 150, width: 400, height: 50))   // the bottom 50 pt (flipped)
        row.addSubview(pushButton("OK", x: 300, y: 8))
        content.addSubview(row)
        let top = W7DialogPanelStripTop(content)
        #expect(top > 40 && top <= 58, "\(top)")
        // A checkbox in the strip is not a push button.
        let checkbox = NSButton(checkboxWithTitle: "Don't show again", target: nil, action: nil)
        checkbox.frame = NSRect(x: 10, y: 14, width: 150, height: 18)
        row.addSubview(checkbox)
        #expect(W7DialogPanelStripTop(content) == 0)
    }

    @MainActor @Test func noStripWithoutButtons() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        content.addSubview(label("About text", y: 120))
        #expect(W7DialogPanelStripTop(content) == 0)
        #expect(W7DialogPanelStripDiagnostics(content) == "none (no push buttons in the bottom strip)")
        #expect(W7DialogPanelStripTop(nil) == 0)
    }

    // MARK: - Live panels

    @MainActor private func makePanel(_ mask: NSWindow.StyleMask = [.titled, .closable]) -> NSPanel {
        _ = NSApplication.shared
        let p = NSPanel(contentRect: .init(x: 0, y: 0, width: 400, height: 200), styleMask: mask, backing: .buffered, defer: true)
        p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: .aqua)
        return p
    }

    @MainActor private func bar(_ w: NSWindow) -> W7TitlebarView? {
        w.standardWindowButton(.closeButton)?.superview?.subviews.compactMap { $0 as? W7TitlebarView }.first
    }

    @MainActor @Test func dialogPanelIsDecoratedWithCloseOnlyAndFrame() throws {
        W7DialogPanelUseDisabledOverride(0)
        W7FrameBorderUseDisabledOverride(0)
        defer { W7DialogPanelUseDisabledOverride(-1); W7FrameBorderUseDisabledOverride(-1) }
        let p = makePanel()
        defer { p.close() }
        p.titlebarAppearsTransparent = true   // as the standard About panel has it
        #expect(W7IsDialogPanelWindow(p))
        W7ChromeController.decorateWindow(p)
        let view = try #require(bar(p))
        #expect(view.w7DialogCaption)
        let hidden = view.w7CaptionButtonViews.map(\.isHidden)
        #expect(hidden == [true, true, false], "minimize and maximize hidden, close shown")
        #expect(p.titlebarAccessoryViewControllers.isEmpty, "no menu strip in a dialog")
        #expect(W7FrameBorderOverlay(p) != nil, "dialog panels get the glass frame too")
        #expect(W7DialogPanelIsStyled(p))
        var light: NSColor?, dark: NSColor?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { light = p.backgroundColor.usingColorSpace(.sRGB) }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { dark = p.backgroundColor.usingColorSpace(.sRGB) }
        let bg = try #require(light)
        #expect(bg.redComponent == 1 && bg.greenComponent == 1 && bg.blueComponent == 1, "white body in light appearance")
        #expect(dark.map { $0.redComponent < 0.5 } == true, "the panel's own colour in dark appearance")
        // Resizable: maximize comes back.
        p.styleMask.insert(.resizable)
        view.refresh()
        #expect(view.w7CaptionButtonViews.map(\.isHidden) == [true, false, false])
    }

    /// A content view that paints its own background (a branded About or Preferences panel).
    private final class PaintedView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).setFill()
            bounds.fill()
        }
    }

    @MainActor private func rgb(_ content: NSView) throws -> (CGFloat, CGFloat) -> (Int, Int, Int) {
        let rep = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / content.bounds.width
        return { x, y in   // y from the bottom, in points
            let c = rep.colorAt(x: Int(x * scale), y: rep.pixelsHigh - 1 - Int(y * scale))!.usingColorSpace(.sRGB)!
            return (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                    Int((c.blueComponent * 255).rounded()))
        }
    }

    /// The backdrop draws only the strip and its line: the content view's own background stays above it, and the
    /// white body comes from the window's background colour.
    @MainActor @Test func dialogBodyDrawsTheButtonStrip() throws {
        W7DialogPanelUseDisabledOverride(0)
        defer { W7DialogPanelUseDisabledOverride(-1) }
        let p = makePanel()
        defer { p.close() }
        let content = PaintedView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        p.contentView = content
        content.addSubview(pushButton("OK", x: 300, y: 10))
        content.addSubview(label("Some text", y: 120))
        W7ChromeController.decorateWindow(p)
        #expect(content.subviews.filter { NSStringFromClass(type(of: $0)).contains("W7DialogPanelBackdrop") }.count == 1)
        #expect(content.subviews.first.map { NSStringFromClass(type(of: $0)).contains("W7DialogPanelBackdrop") } == true,
                "the backdrop is under the panel's views")
        let top = W7DialogPanelStripTop(content)
        #expect(top == 58)
        let color = try rgb(content)
        let strip = color(4, 4), line = color(4, top + 0.5), above = color(4, top + 20)
        func grey(_ c: (Int, Int, Int), _ v: Int) -> Bool { abs(c.0 - v) <= 8 && c.0 == c.1 && c.1 == c.2 }
        #expect(grey(strip, 0xF0), "strip \(strip)")
        #expect(grey(line, 0xDF) && line.0 < strip.0, "the #DFDFDF line \(line)")
        #expect(above.2 > 200 && above.0 < 100 && above.1 < 100, "the content view's own background above the strip \(above)")
        var light: NSColor?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { light = p.backgroundColor.usingColorSpace(.sRGB) }
        #expect(light.map { $0.redComponent == 1 && $0.greenComponent == 1 && $0.blueComponent == 1 } == true,
                "the white body is the window background")
    }

    /// Without a strip the backdrop draws nothing at all.
    @MainActor @Test func dialogBodyWithoutStripDrawsNothing() throws {
        W7DialogPanelUseDisabledOverride(0)
        defer { W7DialogPanelUseDisabledOverride(-1) }
        let p = makePanel()
        defer { p.close() }
        let content = PaintedView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        p.contentView = content
        content.addSubview(label("About text", y: 12))
        W7ChromeController.decorateWindow(p)
        #expect(W7DialogPanelIsStyled(p) && W7DialogPanelStripTop(content) == 0)
        let color = try rgb(content)
        for y: CGFloat in [2, 30, 100, 190] {
            let c = color(300, y)
            #expect(c.2 > 200 && c.0 < 100 && c.1 < 100, "y \(y): \(c)")
        }
    }

    /// A panel hosting another process's content (open/save panels: an NSRemoteView) is never a dialog.
    @objc(NSRemoteViewW7TestStub) private final class RemoteViewStub: NSView {}

    @MainActor @Test func remoteViewPanelsStayNative() {
        W7DialogPanelUseDisabledOverride(0)
        defer { W7DialogPanelUseDisabledOverride(-1) }
        let p = makePanel()
        defer { p.close() }
        #expect(W7IsDialogPanelWindow(p))
        p.contentView = RemoteViewStub(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        #expect(!W7IsDialogPanelWindow(p))
        W7ChromeController.decorateWindow(p)
        #expect(bar(p) == nil)
    }

    @MainActor @Test func nonDialogPanelsAndAlertsStayNative() {
        W7DialogPanelUseDisabledOverride(0)
        defer { W7DialogPanelUseDisabledOverride(-1) }
        let floating = makePanel()
        floating.isFloatingPanel = true
        let utility = makePanel([.titled, .closable, .utilityWindow])
        let untitled = makePanel([.titled])
        defer { floating.close(); utility.close(); untitled.close() }
        for p in [floating, utility, untitled] {
            W7ChromeController.decorateWindow(p)
            #expect(bar(p) == nil, "\(p.styleMask)")
            #expect(!W7DialogPanelIsStyled(p))
        }
        let a = NSAlert()
        a.messageText = "Message"
        a.addButton(withTitle: "OK")
        a.layout()
        defer { a.window.close() }
        #expect(W7WindowIsAlertPanel(a.window))
        W7ChromeController.decorateWindow(a.window)
        #expect(bar(a.window) == nil, "alerts are message boxes, never decorated as dialogs")
        #expect(!W7DialogPanelIsStyled(a.window))
    }

    @MainActor @Test func killSwitchLeavesDialogPanelsNative() {
        W7DialogPanelUseDisabledOverride(1)
        defer { W7DialogPanelUseDisabledOverride(-1) }
        let p = makePanel()
        defer { p.close() }
        #expect(!W7IsDialogPanelWindow(p))
        W7ChromeController.decorateWindow(p)
        #expect(bar(p) == nil)
        #expect(!W7StyleDialogPanel(p))
    }
}
