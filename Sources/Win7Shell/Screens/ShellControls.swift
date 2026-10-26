import AppKit
import Carbon.HIToolbox
import Win7Core
import Win7Theme

/// Windows 7's keyboard focus rectangle: a 1 pt dotted line, drawn by the shell's controls and lists while they
/// have the focus and the window shows focus cues (ShellWindow.showsFocusCues, after the keyboard was used).
@MainActor
enum ShellFocusRing {
    /// Whether `view` should draw its focus rectangle now.
    static func shows(in view: NSView) -> Bool {
        guard let window = view.window, window.firstResponder === view else { return false }
        return (window as? ShellWindow)?.showsFocusCues ?? true
    }

    static func draw(_ rect: NSRect) {
        let r = NSRect(x: floor(rect.minX) + 0.5, y: floor(rect.minY) + 0.5,
                       width: max(1, floor(rect.width) - 1), height: max(1, floor(rect.height) - 1))
        let path = NSBezierPath(rect: r)
        path.lineWidth = 1
        path.setLineDash([1, 1], count: 2, phase: 0)
        NSColor(white: 0.1, alpha: 0.9).setStroke()
        path.stroke()
    }
}

/// An accessibility child of a drawn list (a picture, a theme tile, a task link): its role, label, value and
/// frame in the parent view, and what pressing it does.
final class ShellAccessibilityItem: NSAccessibilityElement {
    private let press: () -> Void

    init(parent: NSView, role: NSAccessibility.Role, label: String, value: Any? = nil, frame: NSRect,
         selected: Bool = false, press: @escaping () -> Void) {
        self.press = press
        super.init()
        setAccessibilityParent(parent)
        setAccessibilityRole(role)
        setAccessibilityLabel(label)
        setAccessibilityValue(value)
        setAccessibilityFrameInParentSpace(frame)
        setAccessibilitySelected(selected)
        setAccessibilityEnabled(true)
    }

    override func accessibilityPerformPress() -> Bool { press(); return true }
}

/// Windows 7 controls for the shell's own windows, drawn with Win7Theme: the shell is denylisted
/// from the dylib, so AppKit's own buttons and popups would look like macOS. Non-flipped; a click acts even while
/// the shell isn't the active app. they take the keyboard focus (Tab, ShellWindow.cycleFocus), act on
/// Space and Return (a drop-down list also on the arrows, ShellKeyboard), draw Windows 7's dotted focus rectangle,
/// and tell VoiceOver what they are.
@MainActor
class ShellControl: NSView {
    var isEnabled = true {
        didSet {
            needsDisplay = true
            if !isEnabled, window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }
    }
    var hover = false
    var pressed = false
    static let font = W7UIFont(12)

    override init(frame: NSRect) {
        super.init(frame: frame)
        focusRingType = .none   // the dotted Windows 7 rectangle instead
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Keyboard

    /// What the keys mean for this control.
    var kind: ShellControlKind { .pushButton }

    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, let key = ShellWindow.shellKey(event), let action = ShellKeyboard.action(key, for: kind) else {
            super.keyDown(with: event)
            return
        }
        (window as? ShellWindow)?.setShowsFocusCues(true)
        perform(action)
    }

    /// A key's action; buttons, check boxes and links only activate.
    func perform(_ action: ShellKeyAction) {
        if action == .activate { activate() }
    }

    /// Draws the focus rectangle around `rect` when the control has the focus.
    func drawFocus(_ rect: NSRect) {
        if ShellFocusRing.shows(in: self) { ShellFocusRing.draw(rect) }
    }

    // MARK: Accessibility

    var accessibilityTitle: String { "" }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? {
        switch kind {
        case .pushButton: .button
        case .checkBox: .checkBox
        case .link: .link
        case .popUp: .popUpButton
        }
    }
    override func accessibilityLabel() -> String? { accessibilityTitle }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        perform(kind == .popUp ? .open : .activate)
        return true
    }

    var state: W7ControlState {
        if !isEnabled { return .disabled }
        if pressed && hover { return .pressed }
        return hover ? .hover : .normal
    }

    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != hover { hover = inside; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let fire = pressed && isEnabled && bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        needsDisplay = true
        if fire { activate() }
    }

    /// The click (mouse up inside).
    func activate() {}

    func drawText(_ text: String, in rect: NSRect, color: NSColor = .black, alignment: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: isEnabled ? color : ControlPanelText.grey,
                                                     .paragraphStyle: style]
        let h = ceil((text as NSString).size(withAttributes: attrs).height)
        (text as NSString).draw(in: NSRect(x: rect.minX, y: floor(rect.midY - h / 2), width: rect.width, height: h), withAttributes: attrs)
    }
}

/// A Windows 7 push button ("Save changes", "Cancel", "Browse..."); the default one has the blue glow and takes
/// Return.
@MainActor
final class ShellPushButton: ShellControl {
    var title: String { didSet { needsDisplay = true } }
    var isDefault = false { didSet { needsDisplay = true } }
    var action: (() -> Void)?

    init(_ title: String, isDefault: Bool = false, action: (() -> Void)? = nil) {
        self.title = title
        self.isDefault = isDefault
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width(title), height: 23))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Windows 7's 75 pt minimum, wider for a long title.
    static func width(_ title: String) -> CGFloat { max(75, ControlPanelText.width(title, font) + 24) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        W7DrawPushButton(ctx, bounds, state, isDefault && isEnabled)
        drawText(title, in: bounds.insetBy(dx: 6, dy: 0), alignment: .center)
        drawFocus(bounds.insetBy(dx: 3, dy: 3))
    }

    override func activate() { action?() }
    override var accessibilityTitle: String { title }
}

/// A Windows 7 drop-down list (the combo box look): the chosen title and a ▾ well; a click opens the choices as a
/// Windows 7 menu under it (ShellMenus).
@MainActor
final class ShellPopUpButton: ShellControl {
    var titles: [String] = [] { didSet { needsDisplay = true } }
    var selectedIndex = 0 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        W7DrawComboBox(ctx, bounds, state)
        let title = titles.indices.contains(selectedIndex) ? titles[selectedIndex] : ""
        drawText(title, in: NSRect(x: 5, y: 0, width: bounds.width - 26, height: bounds.height))
        drawFocus(NSRect(x: 3, y: 3, width: bounds.width - 24, height: bounds.height - 6))
    }

    override var kind: ShellControlKind { .popUp }
    override var accessibilityTitle: String { accessibilityName }
    /// What VoiceOver calls the list ("Picture position"); its value is the chosen title.
    var accessibilityName = ""
    override func accessibilityValue() -> Any? { titles.indices.contains(selectedIndex) ? titles[selectedIndex] : nil }

    /// Space, Return, Alt+↓ or F4 open the choices; the arrows step the choice while closed, as Windows does.
    override func perform(_ action: ShellKeyAction) {
        switch action {
        case .open: openMenu()
        case .previous, .next:
            let i = ShellKeyboard.stepped(selectedIndex, by: action, count: titles.count)
            guard i != selectedIndex, titles.indices.contains(i) else { return }
            selectedIndex = i
            onSelect?(i)
        case .activate: break
        }
    }

    /// Opens on mouse down, as a Windows list does.
    override func mouseDown(with event: NSEvent) { openMenu() }

    private func openMenu() {
        guard isEnabled, !titles.isEmpty, let window else { return }
        pressed = true
        display()
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (i, t) in titles.enumerated() {
            let item = MenuAction.item(t) { [weak self] in
                guard let self else { return }
                self.selectedIndex = i
                self.onSelect?(i)
            }
            item.state = i == selectedIndex ? .on : .off
            menu.addItem(item)
        }
        let bottomLeft = window.convertPoint(toScreen: convert(NSPoint(x: 0, y: 0), to: nil))
        ShellMenus.show(menu, at: bottomLeft, minWidth: bounds.width)
        pressed = false
        hover = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {}
}

/// A Windows 7 check box with its label on the right.
@MainActor
final class ShellCheckBox: ShellControl {
    var title: String { didSet { needsDisplay = true } }
    var isOn = false { didSet { needsDisplay = true } }
    var onChange: ((Bool) -> Void)?

    init(_ title: String) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: W7CheckBoxSize + 6 + ControlPanelText.width(title, Self.font) + 4, height: 18))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let box = NSRect(x: 0, y: floor((bounds.height - W7CheckBoxSize) / 2), width: W7CheckBoxSize, height: W7CheckBoxSize)
        W7DrawCheckBox(ctx, box, state, isOn ? .on : .off)
        drawText(title, in: NSRect(x: box.maxX + 6, y: 0, width: bounds.width - box.maxX - 6, height: bounds.height))
        drawFocus(NSRect(x: box.maxX + 3, y: 0, width: bounds.width - box.maxX - 3, height: bounds.height))
    }

    override var kind: ShellControlKind { .checkBox }
    override var accessibilityTitle: String { title }
    override func accessibilityValue() -> Any? { NSNumber(value: isOn ? 1 : 0) }

    override func activate() {
        isOn.toggle()
        onChange?(isOn)
    }
}

/// A Control Panel link: blue `#0066CC` text, underlined while hovered, the hand cursor.
@MainActor
final class ShellLink: ShellControl {
    var title: String { didSet { needsDisplay = true } }
    var font: NSFont = ShellControl.font
    var action: (() -> Void)?

    init(_ title: String, action: (() -> Void)? = nil) {
        self.title = title
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: ControlPanelText.width(title, ShellControl.font) + 2, height: 17))
    }
    required init?(coder: NSCoder) { fatalError() }

    func sizeToFit() { setFrameSize(NSSize(width: ControlPanelText.width(title, font) + 2, height: max(17, ceil(font.ascender - font.descender) + 2))) }

    override func draw(_ dirtyRect: NSRect) {
        let attrs = ControlPanelText.attributes(font, isEnabled ? ControlPanelText.linkBlue : ControlPanelText.grey,
                                                underline: hover && isEnabled)
        let h = ceil((title as NSString).size(withAttributes: attrs).height)
        (title as NSString).draw(in: NSRect(x: 0, y: floor((bounds.height - h) / 2), width: bounds.width, height: h), withAttributes: attrs)
        drawFocus(bounds)
    }

    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }

    override var kind: ShellControlKind { .link }
    override var accessibilityTitle: String { title }
    override func activate() { action?() }
}

/// A plain label (black 12 pt, or a heading).
@MainActor
final class ShellLabel: NSView {
    var text: String { didSet { needsDisplay = true } }
    var font: NSFont
    var color: NSColor
    var wraps = false

    init(_ text: String, font: NSFont = W7UIFont(12), color: NSColor = .black) {
        self.text = text
        self.font = font
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: ControlPanelText.width(text, font) + 2, height: ceil(font.ascender - font.descender) + 3))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let attrs = ControlPanelText.attributes(font, color, wrap: wraps)
        if wraps {
            (text as NSString).draw(with: bounds, options: [.usesLineFragmentOrigin], attributes: attrs)
        } else {
            let h = ceil((text as NSString).size(withAttributes: attrs).height)
            (text as NSString).draw(in: NSRect(x: 0, y: floor((bounds.height - h) / 2), width: bounds.width, height: h), withAttributes: attrs)
        }
    }

    override var isFlipped: Bool { wraps }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text }
}

/// A light task pane like the Control Panel's (gradient `#E9F1FA→#D7E4F2`, `#A8BED6` right border): "Control Panel
/// Home" first, the window's tasks, then "See also" and its links at the bottom.
@MainActor
final class ShellTaskPane: NSView {
    struct Entry {
        var title: String
        var action: () -> Void
    }
    var home: Entry? { didSet { rebuild() } }
    var tasks: [Entry] = [] { didSet { rebuild() } }
    var seeAlso: [Entry] = [] { didSet { rebuild() } }

    private var placed: [(title: String, rect: NSRect, action: (() -> Void)?, grey: Bool)] = []
    private var hover: Int?
    /// The link with the keyboard focus (an index into `placed`; ↑/↓ move it, Space/Return follow it).
    private var focused: Int?
    private static let font = W7UIFont(12)
    private static let inset: CGFloat = 14

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuild()
    }

    private func rebuild() {
        placed = []
        hover = nil
        let width = bounds.width - 2 * Self.inset
        var y: CGFloat = 16
        func add(_ title: String, _ action: (() -> Void)?, grey: Bool = false, gap: CGFloat = 8) {
            let h = ControlPanelText.height(title, Self.font, width: width)
            let w = min(width, ControlPanelText.width(title, Self.font))
            placed.append((title, NSRect(x: Self.inset, y: y, width: h > 18 ? width : w, height: h), action, grey))
            y += h + gap
        }
        if let home { add(home.title, home.action, gap: 14) }
        for t in tasks { add(t.title, t.action) }
        if !seeAlso.isEmpty {
            y = max(y + 16, bounds.height - 30 - CGFloat(seeAlso.count) * 25)
            add("See also", nil, grey: true, gap: 6)
            for t in seeAlso { add(t.title, t.action) }
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: NSColor(srgbRed: 0xE9 / 255, green: 0xF1 / 255, blue: 0xFA / 255, alpha: 1),
                   ending: NSColor(srgbRed: 0xD7 / 255, green: 0xE4 / 255, blue: 0xF2 / 255, alpha: 1))?.draw(in: bounds, angle: 90)
        NSColor(srgbRed: 0xA8 / 255, green: 0xBE / 255, blue: 0xD6 / 255, alpha: 1).setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        for (i, p) in placed.enumerated() {
            let color = p.grey ? ControlPanelText.grey : ControlPanelText.navy
            (p.title as NSString).draw(with: p.rect, options: [.usesLineFragmentOrigin],
                                       attributes: ControlPanelText.attributes(Self.font, color, underline: i == hover, wrap: true))
        }
        if let f = focused, placed.indices.contains(f), ShellFocusRing.shows(in: self) {
            ShellFocusRing.draw(placed[f].rect.insetBy(dx: -2, dy: -1))
        }
    }

    // MARK: Keyboard and accessibility

    private var links: [Int] { placed.indices.filter { placed[$0].action != nil } }

    override var acceptsFirstResponder: Bool { !links.isEmpty }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func becomeFirstResponder() -> Bool {
        if focused == nil { focused = links.first }
        needsDisplay = true
        return true
    }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func keyDown(with event: NSEvent) {
        guard let key = ShellWindow.shellKey(event) else { super.keyDown(with: event); return }
        let order = links
        let at = focused.flatMap { order.firstIndex(of: $0) }
        if let next = ShellKeyboard.moveInList(key, from: at, count: order.count, vertical: true) {
            (window as? ShellWindow)?.setShowsFocusCues(true)
            focused = order[next]
            needsDisplay = true
        } else if ShellKeyboard.action(key, for: .link) == .activate, let f = focused, placed.indices.contains(f) {
            placed[f].action?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Tasks" }
    override func accessibilityChildren() -> [Any]? {
        placed.map { p in
            if let action = p.action {
                return ShellAccessibilityItem(parent: self, role: .link, label: p.title, frame: p.rect, press: action)
            }
            return ShellAccessibilityItem(parent: self, role: .staticText, label: p.title, value: p.title, frame: p.rect, press: {})
        }
    }

    override func resetCursorRects() {
        for p in placed where p.action != nil { addCursorRect(p.rect, cursor: .pointingHand) }
    }

    private func index(at event: NSEvent) -> Int? {
        let pt = convert(event.locationInWindow, from: nil)
        return placed.indices.first { placed[$0].action != nil && placed[$0].rect.contains(pt) }
    }

    override func mouseMoved(with event: NSEvent) {
        let h = index(at: event)
        if h != hover { hover = h; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hover != nil { hover = nil; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: event) else { return }
        placed[i].action?()
    }
}

/// A container that lays its subviews out again whenever it is resized (the window's live resize too).
@MainActor
final class ShellLayoutView: NSView {
    var onLayout: (() -> Void)?
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        onLayout?()
    }
}
