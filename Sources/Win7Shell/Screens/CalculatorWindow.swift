import AppKit
import Carbon.HIToolbox
import Win7Core
import Win7Theme

/// The shell's own Windows 7 Calculator, Standard mode: the menu strip (View, Edit, Help), the
/// display box with its memory indicator, and the 6 × 5 keys. The arithmetic is CalculatorEngine's; the faces are
/// W7CalculatorDrawing's. macOS Calculator's buttons are SwiftUI content the dylib cannot restyle, so the Start menu's
/// Calculator and Programs ▸ Calculator open this window instead; the macOS app stays in All Programs.
@MainActor
final class CalculatorWindow: ShellWindow {
    static let shared = CalculatorWindow()
    /// 220 × 320 with the 30 pt caption, as Windows 7's Standard calculator.
    static let contentSize = NSSize(width: 220, height: 290)
    static let groupingKey = "calculatorDigitGrouping"

    private let strip = ShellMenuStripView()
    private let pad = CalculatorPadView()

    private init() {
        super.init(spec: Spec(identifier: ShellWindowTarget.calculator.identifier, title: ShellWindowTarget.calculator.title,
                              frameName: "Win7Calculator", defaultSize: Self.contentSize, minSize: Self.contentSize,
                              resizable: false, icon: { CalculatorWindow.icon(side: $0) }, logName: "calculator"))
        buildContent()
        finishSetup()
    }

    private func buildContent() {
        let size = Self.contentSize
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let stripH = W7MenuStripHeight
        strip.frame = NSRect(x: 0, y: size.height - stripH, width: size.width, height: stripH)
        strip.autoresizingMask = [.width, .minYMargin]
        strip.entries = [
            .init(title: "View") { [weak self] in self?.viewMenu() ?? NSMenu() },
            .init(title: "Edit") { [weak self] in self?.editMenu() ?? NSMenu() },
            .init(title: "Help") { Self.helpMenu() },
        ]
        pad.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height - stripH)
        pad.autoresizingMask = [.width, .height]
        pad.engine.digitGrouping = UserDefaults.standard.bool(forKey: Self.groupingKey)
        content.addSubview(strip)
        content.addSubview(pad)
        contentView = content
    }

    /// The Calculator's window and taskbar icon: the user's imported calc.exe icon, else macOS Calculator's.
    static func icon(side: CGFloat) -> NSImage {
        if let own = IconOverrides.app(StartMenuLaunch.calculatorBundleID, side: side) { return own }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: StartMenuLaunch.calculatorBundleID) {
            let img = NSWorkspace.shared.icon(forFile: url.path)
            img.size = NSSize(width: side, height: side)
            return img
        }
        return ControlPanelIcons.image(names: ["cp-calculator"], glyph: .nav(.appBadge), side: side)
    }

    // MARK: Showing

    func show() {
        present("standard")
        makeFirstResponder(pad)
    }

    // MARK: Menus

    private func viewMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let standard = MenuAction.item("Standard") {}
        standard.state = .on
        menu.addItem(standard)
        for title in ["Scientific", "Programmer", "Statistics"] { menu.addItem(MenuAction.item(title, enabled: false) {}) }
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("History", enabled: false) {})
        let grouping = MenuAction.item("Digit grouping") { [weak self] in self?.toggleGrouping() }
        grouping.state = pad.engine.digitGrouping ? .on : .off
        menu.addItem(grouping)
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(MenuAction.item("Copy") { [weak self] in self?.copyDisplay() })
        menu.addItem(MenuAction.item("Paste", enabled: NSPasteboard.general.string(forType: .string) != nil) { [weak self] in
            self?.pasteNumber()
        })
        return menu
    }

    /// View Help: the Control Panel's info page about this Calculator (until the shell has Help and Support).
    private static func helpMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(MenuAction.item("View Help") {
            ControlPanelWindow.shared.show(.info(title: "Calculator", text: ControlPanelCatalog.calculatorInfo, category: .programs))
        })
        return menu
    }

    private func toggleGrouping() {
        pad.engine.digitGrouping.toggle()
        UserDefaults.standard.set(pad.engine.digitGrouping, forKey: Self.groupingKey)
        pad.needsDisplay = true
    }

    private func copyDisplay() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pad.engine.copyText, forType: .string)
    }

    /// A number on the pasteboard becomes the operand; anything else is ignored, as Windows does.
    private func pasteNumber() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        if pad.engine.paste(text) { pad.needsDisplay = true }
    }

    // MARK: Keyboard

    /// Windows 7's keys (CalculatorEngine.key(characters:charactersIgnoringModifiers:modifiers:)): digits, operators,
    /// Enter or =, Esc = C, Backspace, Delete = CE, @ = √ (however the layout types it, Option+Q included), R = 1/x,
    /// F9 = ±, Ctrl+L/R/M/P/Q = MC/MR/MS/M+/M−. Cmd+C / Cmd+V (or Ctrl) copy and paste the display; Alt+V, Alt+E,
    /// Alt+H open the menus (Option on a Mac keyboard).
    override func handleKey(_ event: NSEvent) -> Bool {
        let flags = Self.flags(event)
        let letter = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command || flags == .control {
            if letter == "c" { copyDisplay(); return true }
            if letter == "v" { pasteNumber(); return true }
        }
        if flags == .option {
            let menus = [kVK_ANSI_V: 0, kVK_ANSI_E: 1, kVK_ANSI_H: 2]
            if let i = menus[Int(event.keyCode)] { strip.popUp(i); return true }
        }
        if let key = CalculatorEngine.key(characters: event.characters, charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                                          modifiers: Self.calculatorModifiers(flags)) {
            pad.press(key, flash: true)
            return true
        }
        return super.handleKey(event)
    }

    private static func calculatorModifiers(_ flags: NSEvent.ModifierFlags) -> CalculatorEngine.KeyModifiers {
        var m: CalculatorEngine.KeyModifiers = []
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        return m
    }
}

/// The display and the keys, drawn with W7CalculatorDrawing (non-flipped). The key under the mouse is hot; a key
/// acts when the button is released over it, as Windows' buttons do.
@MainActor
final class CalculatorPadView: NSView {
    struct Key {
        var label: String
        var key: CalculatorEngine.Key
        var row: Int, column: Int
        var rowSpan = 1, columnSpan = 1
    }

    /// Windows 7's Standard keys, row by row from the top.
    static let keys: [Key] = {
        typealias K = CalculatorEngine.Key
        let rows: [[(String, K)]] = [
            [("MC", .memoryClear), ("MR", .memoryRecall), ("MS", .memoryStore), ("M+", .memoryAdd), ("M-", .memorySubtract)],
            [("←", .backspace), ("CE", .clearEntry), ("C", .clear), ("±", .negate), ("√", .sqrt)],
            [("7", .digit(7)), ("8", .digit(8)), ("9", .digit(9)), ("/", .divide), ("%", .percent)],
            [("4", .digit(4)), ("5", .digit(5)), ("6", .digit(6)), ("*", .multiply), ("1/x", .reciprocal)],
            [("1", .digit(1)), ("2", .digit(2)), ("3", .digit(3)), ("-", .subtract), ("=", .equals)],
            [("0", .digit(0)), (".", .point), ("+", .add)],
        ]
        var keys: [Key] = []
        for (r, row) in rows.enumerated() {
            for (c, item) in row.enumerated() {
                var k = Key(label: item.0, key: item.1, row: r, column: c)
                if r == 4 && c == 4 { k.rowSpan = 2 }                       // = spans the last two rows
                if r == 5 { if c == 0 { k.columnSpan = 2 } else { k.column = c + 1 } }   // 0 is two keys wide
                keys.append(k)
            }
        }
        return keys
    }()

    static let margin: CGFloat = 13
    static let keySize = NSSize(width: 34, height: 29)
    static let gap: CGFloat = 6
    static let displayTop: CGFloat = 12
    static let bottomMargin: CGFloat = 14

    var engine = CalculatorEngine()
    private var hover: Int?
    private var pressed: Int?
    private var flashed: Int?
    private var flashTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var displayRect: NSRect {
        NSRect(x: Self.margin, y: bounds.height - Self.displayTop - W7CalculatorDisplayHeight,
               width: bounds.width - 2 * Self.margin, height: W7CalculatorDisplayHeight)
    }

    func keyRect(_ k: Key) -> NSRect {
        let w = Self.keySize.width, h = Self.keySize.height, g = Self.gap
        let top = Self.bottomMargin + 6 * h + 5 * g
        let x = Self.margin + CGFloat(k.column) * (w + g)
        let maxY = top - CGFloat(k.row) * (h + g)
        let height = CGFloat(k.rowSpan) * h + CGFloat(k.rowSpan - 1) * g
        return NSRect(x: x, y: maxY - height, width: CGFloat(k.columnSpan) * w + CGFloat(k.columnSpan - 1) * g, height: height)
    }

    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return Self.keys.indices.first { keyRect(Self.keys[$0]).contains(p) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        W7DrawCalculatorBody(ctx, bounds)
        W7DrawCalculatorDisplay(ctx, displayRect, engine.display, engine.hasMemory)
        for (i, k) in Self.keys.enumerated() {
            let r = keyRect(k)
            guard r.intersects(dirtyRect) else { continue }
            let state: W7ControlState
            if i == flashed || (i == pressed && i == hover) { state = .pressed }   // held down over it
            else if i == hover && pressed == nil { state = .hover }
            else { state = .normal }
            W7DrawCalculatorKey(ctx, r, k.label, state)
        }
    }

    /// Presses `key`; from the keyboard, its on-screen key shows pressed for a moment.
    func press(_ key: CalculatorEngine.Key, flash: Bool) {
        engine.press(key)
        if flash, let i = Self.keys.firstIndex(where: { $0.key == key }) {
            flashed = i
            flashTimer?.invalidate()
            flashTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.flashed = nil
                    self?.needsDisplay = true
                }
            }
        }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let i = index(at: event)
        if i != hover { hover = i; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hover != nil { hover = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pressed = index(at: event)
        hover = pressed
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let i = index(at: event)
        if i != hover { hover = i; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let i = index(at: event)
        if let p = pressed, p == i { engine.press(Self.keys[p].key) }
        pressed = nil
        hover = i
        needsDisplay = true
    }
}
