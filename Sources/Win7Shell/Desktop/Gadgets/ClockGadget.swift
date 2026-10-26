import AppKit
import Win7Core
import Win7Theme

/// The analog Clock gadget, ticking once a second. With the user's artwork (Assets/gadgets/Clock/images/): the chosen
/// theme's face `<style>.png` at the top-left, the hour and minute hands `<style>_h/_m.png` (and the second hand
/// `<style>_s.png` when "Show the second hand" is on, else the cap `<style>_dot.png`, as clock.js shows one or the
/// other) turned about the pivot clock.js gives (ClockStyle.handRect), with the gadgets' grey hand shadow. Options
/// (toolbar button, right-click) picks the theme and the second hand; both are stored in the shell's defaults.
/// When the stored theme's face and hands are missing, the first theme that has them is drawn; with none at all,
/// Win7Theme's drawn clock, as before.
final class ClockGadgetView: GadgetContentView {
    static let styleKey = "gadgetClockStyle"
    static let secondHandKey = "gadgetClockSecondHand"

    private let art = GadgetArt(folder: "Clock", kind: .clock)
    private var timer: Timer?

    private var style: ClockStyle {
        ClockStyle(storedIndex: UserDefaults.standard.object(forKey: Self.styleKey) as? Int ?? ClockStyle.default.rawValue)
    }

    private var showsSecondHand: Bool {
        UserDefaults.standard.object(forKey: Self.secondHandKey) as? Bool ?? ClockStyle.showsSecondHandByDefault
    }

    private func files(_ s: ClockStyle) -> [String] { ["\(s.fileName).png", "\(s.fileName)_h.png", "\(s.fileName)_m.png"] }

    /// The stored theme when its files are there, else the first theme whose files are; nil (logged once) for none.
    private var shownStyle: ClockStyle? {
        let stored = style
        if art.exists(files(stored)) { return stored }
        if let other = ClockStyle.allCases.first(where: { art.exists(files($0)) }) { return other }
        _ = art.has(files(stored))
        return nil
    }

    override func start() {
        timer = gadgetTimer(1) { [weak self] in self?.needsDisplay = true }
    }

    override func stop() { timer?.invalidate(); timer = nil }

    override var hasOptions: Bool { shownStyle != nil }

    override func showOptions() {
        ClockOptionsDialog.present(art: art, style: shownStyle ?? style, secondHand: showsSecondHand) { [weak self] style, secondHand in
            UserDefaults.standard.set(style.rawValue, forKey: Self.styleKey)
            UserDefaults.standard.set(secondHand, forKey: Self.secondHandKey)
            self?.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let hands = ClockHands(date: Date())
        guard let s = shownStyle, let face = art.image("\(s.fileName).png"),
              let hour = art.image("\(s.fileName)_h.png"), let minute = art.image("\(s.fileName)_m.png") else {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            W7DrawGadgetClock(ctx, bounds.insetBy(dx: 2, dy: 2), hands.hour, hands.minute, hands.second)
            return
        }
        let canvas = GadgetCanvas(height: bounds.height)
        canvas.draw(face, at: .zero)
        canvas.draw(hour, in: s.handRect, rotated: hands.hour, shadow: true)
        canvas.draw(minute, in: s.handRect, rotated: hands.minute, shadow: true)
        if showsSecondHand, let second = art.image("\(s.fileName)_s.png") {
            canvas.draw(second, in: s.handRect, rotated: hands.second, shadow: true)
        } else if let dot = art.image("\(s.fileName)_dot.png") {   // also when the second hand's image is missing
            canvas.draw(dot, in: s.handRect)
        }
    }
}

// MARK: - Options

/// The Clock's Options dialog (settings.html): the theme's preview `<style>_settings.png` in the settings box, the
/// ◀ "1 of 8" ▶ picker (settings_left/right_rest/hover/pressed.png; it wraps around) and "Show the second hand".
/// OK applies, Cancel leaves the clock as it was. Only one is open at a time: asking again brings it forward.
@MainActor
enum ClockOptionsDialog {
    private static weak var open: ShellDialog?

    static func present(art: GadgetArt, style: ClockStyle, secondHand: Bool, onOK: @escaping (ClockStyle, Bool) -> Void) {
        if let open, open.isVisible {
            ShellWindowButtons.bringForward(open)
            return
        }
        let view = ClockOptionsView(art: art, style: style, secondHand: secondHand)
        let dialog = ShellDialog(title: "Clock", content: view, buttons: [
            .init(title: "OK", role: .default) { onOK(view.style, view.secondHand.isOn) },
            .init(title: "Cancel", role: .cancel),
        ])
        open = dialog
        dialog.present(over: nil)
    }
}

/// The dialog's body (non-flipped): the settings box (white preview area over the `#F4F4F4` picker row, framed with
/// the gadget's settings_box/corner/divider pieces) and the check box under it.
@MainActor
final class ClockOptionsView: NSView {
    static let size = NSSize(width: 220, height: 248)
    private(set) var style: ClockStyle
    let secondHand: ShellCheckBox
    private let art: GadgetArt
    private var hover: Int?      // 0 back, 1 forward
    private var pressed: Int?

    // The box (200 wide, 10 in): 4 pt border, a 165 pt white preview area (155 pt preview, padding 5), the 3 pt
    // divider, a 29 pt picker row (19 pt arrows, padding 5), the 4 pt bottom border.
    private let box = NSRect(x: 10, y: 33, width: 200, height: 205)
    private var whiteArea: NSRect { NSRect(x: box.minX + 4, y: box.minY + 36, width: box.width - 8, height: 165) }
    private var pickerRow: NSRect { NSRect(x: box.minX + 4, y: box.minY + 4, width: box.width - 8, height: 29) }

    init(art: GadgetArt, style: ClockStyle, secondHand on: Bool) {
        self.art = art
        self.style = style
        secondHand = ShellCheckBox("Show the second hand")
        secondHand.isOn = on
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        secondHand.setFrameOrigin(NSPoint(x: 12, y: 4))
        addSubview(secondHand)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private static let font = W7UIFont(12)
    private var indexText: String { "\(style.position) of \(ClockStyle.allCases.count)" }

    /// The two 19 pt arrows either side of "N of 8" (11 pt apart from it), centred in the picker row.
    private var arrowRects: [NSRect] {
        let w = (indexText as NSString).size(withAttributes: [.font: Self.font]).width
        let total = 19 + 11 + w + 11 + 19
        let x = (pickerRow.midX - total / 2).rounded()
        let y = (pickerRow.midY - 9.5).rounded()
        return [NSRect(x: x, y: y, width: 19, height: 19), NSRect(x: x + total - 19, y: y, width: 19, height: 19)]
    }

    private func arrow(at p: NSPoint) -> Int? { arrowRects.firstIndex { $0.contains(p) } }

    override func mouseMoved(with event: NSEvent) { setHover(arrow(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { setHover(nil) }
    private func setHover(_ h: Int?) { if h != hover { hover = h; needsDisplay = true } }

    /// settings.html steps on mouse down.
    override func mouseDown(with event: NSEvent) {
        guard let i = arrow(at: convert(event.locationInWindow, from: nil)) else { return }
        pressed = i
        style = style.stepped(by: i == 0 ? -1 : 1)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        pressed = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        whiteArea.fill()
        NSColor(srgbRed: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF4 / 255, alpha: 1).setFill()
        pickerRow.fill()
        drawFrame()
        if let preview = art.image("\(style.fileName)_settings.png") {
            let s = preview.size
            preview.draw(in: NSRect(x: (whiteArea.midX - s.width / 2).rounded(), y: (whiteArea.midY - s.height / 2).rounded(),
                                    width: s.width, height: s.height))
        }
        let rects = arrowRects
        for (i, r) in rects.enumerated() {
            let side = i == 0 ? "left" : "right"
            let state = pressed == i ? "pressed" : (hover == i ? "hover" : "rest")
            if let img = art.image("settings_\(side)_\(state).png") ?? art.image("settings_\(side)_rest.png") {
                img.draw(in: r)
            } else {
                let glyph = (i == 0 ? "◀" : "▶") as NSString
                let size = glyph.size(withAttributes: [.font: Self.font])
                glyph.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: [.font: Self.font])
            }
        }
        let text = indexText as NSString
        let size = text.size(withAttributes: [.font: Self.font])
        text.draw(at: NSPoint(x: rects[0].maxX + 11, y: (pickerRow.midY - size.height / 2).rounded()),
                  withAttributes: [.font: Self.font, .foregroundColor: NSColor.black])
    }

    /// settings.html's table of border pieces: 4 pt corners, 1 pt edges stretched along the sides, the 3 pt divider
    /// row. A plain grey line when a piece is missing.
    private func drawFrame() {
        let names = ["settings_corner_top_left", "settings_box_top", "settings_corner_top_right", "settings_box_left",
                     "settings_box_right", "settings_divider_left", "settings_divider", "settings_divider_right",
                     "settings_box_divider_left", "settings_box_divider_right", "settings_corner_bottom_left",
                     "settings_box_bottom", "settings_corner_bottom_right"]
        let pieces = names.compactMap { art.image("\($0).png") }
        guard pieces.count == names.count else {
            NSColor(srgbRed: 0xB9 / 255, green: 0xB9 / 255, blue: 0xB9 / 255, alpha: 1).setStroke()
            NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
            return
        }
        let (l, r, b, t) = (box.minX, box.maxX, box.minY, box.maxY)
        let inner = box.width - 8
        let divider = whiteArea.minY - 3
        func put(_ i: Int, _ rect: NSRect) { pieces[i].draw(in: rect) }
        put(0, NSRect(x: l, y: t - 4, width: 4, height: 4))
        put(1, NSRect(x: l + 4, y: t - 4, width: inner, height: 4))
        put(2, NSRect(x: r - 4, y: t - 4, width: 4, height: 4))
        put(3, NSRect(x: l, y: whiteArea.minY, width: 4, height: whiteArea.height))
        put(4, NSRect(x: r - 4, y: whiteArea.minY, width: 4, height: whiteArea.height))
        put(5, NSRect(x: l, y: divider, width: 4, height: 3))
        put(6, NSRect(x: l + 4, y: divider, width: inner, height: 3))
        put(7, NSRect(x: r - 4, y: divider, width: 4, height: 3))
        put(8, NSRect(x: l, y: pickerRow.minY, width: 4, height: pickerRow.height))
        put(9, NSRect(x: r - 4, y: pickerRow.minY, width: 4, height: pickerRow.height))
        put(10, NSRect(x: l, y: b, width: 4, height: 4))
        put(11, NSRect(x: l + 4, y: b, width: inner, height: 4))
        put(12, NSRect(x: r - 4, y: b, width: 4, height: 4))
    }
}
