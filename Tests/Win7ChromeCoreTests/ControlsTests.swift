import AppKit
import Testing
import Win7ChromeCore

// MARK: - Decision functions

@Suite struct ControlDecisionTests {
    @Test func buttonKind() {
        let push: [NSButton.BezelStyle] = [.automatic, .push, .flexiblePush]
        for style in push {
            #expect(W7ButtonKindFor(style, true, .momentaryPushIn) == .push, "\(style.rawValue)")
            #expect(W7ButtonKindFor(style, true, .toggle) == .push)
            #expect(W7ButtonKindFor(style, false, .momentaryPushIn) == .none, "borderless is not a push button")
        }
        for style: NSButton.BezelStyle in [.disclosure, .helpButton, .circular, .texturedRounded, .smallSquare,
                                           .recessed, .inline, .pushDisclosure, .shadowlessSquare, .texturedSquare, .badge] {
            #expect(W7ButtonKindFor(style, true, .momentaryPushIn) == .none, "\(style.rawValue)")
        }
        // Check boxes and radio buttons are recognised by type, whatever the bezel and border.
        #expect(W7ButtonKindFor(.flexiblePush, false, .switch) == .checkBox)
        #expect(W7ButtonKindFor(.push, true, .switch) == .checkBox)
        #expect(W7ButtonKindFor(.flexiblePush, false, .radio) == .radio)
    }

    @Test func shouldDrawButtonTruthTable() {
        // (bezel, bordered, type, dark, toolbar) -> draws
        let rows: [(NSButton.BezelStyle, Bool, NSButton.ButtonType, Bool, Bool, Bool)] = [
            (.push, true, .momentaryPushIn, false, false, true),
            (.push, true, .momentaryPushIn, true, false, false),    // dark: original drawing
            (.push, true, .momentaryPushIn, false, true, false),    // toolbar buttons stay native
            (.automatic, true, .momentaryPushIn, false, false, true),
            (.flexiblePush, true, .momentaryPushIn, false, false, true),
            (.disclosure, true, .momentaryPushIn, false, false, false),
            (.push, false, .momentaryPushIn, false, false, false),
            (.flexiblePush, false, .switch, false, false, true),
            (.flexiblePush, false, .switch, true, false, false),
            (.flexiblePush, false, .radio, false, false, true),
            (.flexiblePush, false, .radio, true, false, false),
        ]
        for (style, bordered, type, dark, toolbar, expected) in rows {
            #expect(W7ShouldDrawW7Button(style, bordered, type, dark, toolbar) == expected,
                    "bezel \(style.rawValue) bordered \(bordered) type \(type.rawValue) dark \(dark) toolbar \(toolbar)")
        }
    }

    @Test func forceCellDrawingTruthTable() {
        final class AppCell: NSButtonCell {}
        #expect(W7ShouldForceCellDrawing(NSButtonCell.self, .push, true, .momentaryPushIn, false))
        #expect(W7ShouldForceCellDrawing(NSButtonCell.self, .flexiblePush, false, .switch, false))
        #expect(W7ShouldForceCellDrawing(NSButtonCell.self, .flexiblePush, false, .radio, false))
        #expect(!W7ShouldForceCellDrawing(AppCell.self, .push, true, .momentaryPushIn, false), "app subclasses keep their drawing")
        let alertCell: AnyClass? = NSClassFromString("_NSAlertButtonCell")
        #expect(alertCell != nil, "AppKit still has _NSAlertButtonCell")
        if let alertCell {
            #expect(W7ShouldForceCellDrawing(alertCell, .push, true, .momentaryPushIn, false), "NSAlert's buttons")
            #expect(!W7ShouldForceCellDrawing(alertCell, .disclosure, true, .momentaryPushIn, false))
        }
        #expect(!W7ShouldForceCellDrawing(NSPopUpButtonCell.self, .push, true, .momentaryPushIn, false), "pop-up buttons stay native")
        #expect(!W7ShouldForceCellDrawing(nil, .push, true, .momentaryPushIn, false))
        #expect(!W7ShouldForceCellDrawing(NSButtonCell.self, .disclosure, true, .momentaryPushIn, false), "out of scope stays native")
        #expect(!W7ShouldForceCellDrawing(NSButtonCell.self, .push, true, .momentaryPushIn, true), "toolbar stays native")
    }

    @Test func cellClassEligibilityTruthTable() {
        // (class name, overrides drawing) -> eligible
        let rows: [(String, Bool, Bool)] = [
            ("NSButtonCell", false, true),
            ("_NSAlertButtonCell", false, true),
            ("_NSAlertButtonCell", true, false),          // AppKit starts drawing it itself: leave it alone
            ("_NSAlertCheckboxButtonCell", false, true),
            ("_NSAlertCheckboxButtonCell", true, false),
            ("NSPopUpButtonCell", false, false),
            ("MyAppButtonCell", false, false),
            ("MyAppButtonCell", true, false),
        ]
        for (name, overrides, expected) in rows {
            #expect(W7CellClassNameEligible(name, overrides) == expected, "\(name) overrides \(overrides)")
        }
    }

    @Test func cellClassOverridesDrawing() {
        final class PlainCell: NSButtonCell {}
        final class DrawingCell: NSButtonCell {
            override func drawBezel(withFrame frame: NSRect, in controlView: NSView) { super.drawBezel(withFrame: frame, in: controlView) }
        }
        final class TitleCell: NSButtonCell {
            override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
                super.drawTitle(title, withFrame: frame, in: controlView)
            }
        }
        #expect(!W7CellClassOverridesDrawing(NSButtonCell.self))
        #expect(!W7CellClassOverridesDrawing(PlainCell.self))
        #expect(W7CellClassOverridesDrawing(DrawingCell.self))
        #expect(W7CellClassOverridesDrawing(TitleCell.self))
        #expect(!W7CellClassOverridesDrawing(nil))
        for name in ["_NSAlertButtonCell", "_NSAlertCheckboxButtonCell"] {
            if let cls = NSClassFromString(name) { #expect(!W7CellClassOverridesDrawing(cls), "\(name) draws through NSButtonCell") }
        }
    }

    @MainActor @Test func eligibleCellClasses() {
        final class PlainCell: NSButtonCell {}
        #expect(W7IsEligibleCellClass(NSButtonCell.self))
        #expect(!W7IsEligibleCellClass(PlainCell.self), "app subclasses stay native")
        #expect(!W7IsEligibleCellClass(NSPopUpButtonCell.self))
        #expect(!W7IsEligibleCellClass(NSTextFieldCell.self))
        #expect(!W7IsEligibleCellClass(nil))
        // A KVO-observed NSButtonCell is judged as NSButtonCell.
        let cell = NSButtonCell(textCell: "OK")
        let observation = cell.observe(\.title) { _, _ in }
        defer { observation.invalidate() }
        let isa: AnyClass = object_getClass(cell)!
        #expect(NSStringFromClass(isa).hasPrefix("NSKVONotifying_"), "observed: \(NSStringFromClass(isa))")
        #expect(W7IsEligibleCellClass(isa), "KVO subclass of NSButtonCell")
        #expect(W7ShouldForceCellDrawing(isa, .push, true, .momentaryPushIn, false))
    }

    @Test func scrollerDecisions() {
        final class AppScroller: NSScroller {}
        #expect(W7ShouldDrawW7Scroller(false))
        #expect(!W7ShouldDrawW7Scroller(true))
        #expect(W7ShouldAdoptScroller(NSScroller.self, false))
        #expect(!W7ShouldAdoptScroller(NSScroller.self, true), "dark: no switch")
        #expect(!W7ShouldAdoptScroller(AppScroller.self, false), "app subclasses are left alone")
        #expect(!W7ShouldAdoptScroller(nil, false))
    }

    @Test func appearanceAndSignatures() {
        #expect(W7IsDarkAppearanceName(.darkAqua))
        #expect(!W7IsDarkAppearanceName(.aqua))
        #expect(!W7IsDarkAppearanceName(nil))
        #expect(W7ControlHookSignaturesOK("#16@0:8", "Q16@0:8"))
        #expect(!W7ControlHookSignaturesOK(nil, "Q16@0:8"))
        #expect(!W7ControlHookSignaturesOK("#16@0:8", nil))
        #expect(!W7ControlHookSignaturesOK("@16@0:8", "Q16@0:8"))
        #expect(!W7ControlHookSignaturesOK("#16@0:8", "B16@0:8"))
    }

    @Test func thumbRectSpansTheScroller() {
        #expect(W7ScrollerThumbRect(CGRect(x: 0, y: 0, width: 17, height: 200), CGRect(x: 3, y: 158.5, width: 11, height: 38.5), true)
                == CGRect(x: 0, y: 158.5, width: 17, height: 38.5))
        #expect(W7ScrollerThumbRect(CGRect(x: 0, y: 0, width: 200, height: 17), CGRect(x: 20, y: 3, width: 40, height: 11), false)
                == CGRect(x: 20, y: 0, width: 40, height: 17))
    }

    @Test func titleColours() {
        func colour(_ s: NSAttributedString) -> NSColor? { s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor }
        func hex(_ c: NSColor?) -> Int {
            guard let c = c?.usingColorSpace(.sRGB) else { return -1 }
            return Int((c.redComponent * 255).rounded()) << 16 | Int((c.greenComponent * 255).rounded()) << 8 | Int((c.blueComponent * 255).rounded())
        }
        let system = NSAttributedString(string: "OK", attributes: [.foregroundColor: NSColor.alternateSelectedControlTextColor])
        #expect(hex(colour(W7ControlTitle(system, true))) == 0x000000)
        #expect(hex(colour(W7ControlTitle(system, false))) == 0x838383)
        #expect(hex(colour(W7ControlTitle(NSAttributedString(string: "OK"), true))) == 0x000000, "no colour: black")
        let custom = NSAttributedString(string: "OK", attributes: [.foregroundColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)])
        #expect(hex(colour(W7ControlTitle(custom, true))) == 0xFF0000, "the app's own colour is kept")
        #expect(W7ControlTitle(system, true).string == "OK")
    }
}

// MARK: - AppKit: controls draw through the hooks

/// Snapshot of `view` in sRGB; `at(x, y)` takes points in the view's (non-flipped) coordinates.
@MainActor struct Snapshot {
    let width: Int, height: Int, scale: CGFloat
    let data: [UInt8]
    init(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let img = rep.cgImage!
        width = img.width; height = img.height
        scale = CGFloat(img.width) / view.bounds.width
        var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
        buf.withUnsafeMutableBytes { b in
            let ctx = CGContext(data: b.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8,
                                bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
        data = buf
    }
    func at(_ x: CGFloat, _ y: CGFloat) -> (r: Int, g: Int, b: Int, a: Int) {
        let px = Int(x * scale), row = height - 1 - Int(y * scale)
        let i = (row * width + px) * 4, a = Int(data[i + 3])
        func un(_ v: UInt8) -> Int { a == 0 ? 0 : min(255, Int((Double(v) * 255 / Double(a)).rounded())) }
        return (un(data[i]), un(data[i + 1]), un(data[i + 2]), a)
    }
}

private func near(_ p: (r: Int, g: Int, b: Int, a: Int), _ hex: Int, _ tol: Int = 8) -> Bool {
    abs(p.r - (hex >> 16 & 0xFF)) <= tol && abs(p.g - (hex >> 8 & 0xFF)) <= tol && abs(p.b - (hex & 0xFF)) <= tol
}

/// A plain (never decorated) offscreen window with a fixed appearance.
@MainActor private func plainWindow(dark: Bool) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 400, height: 300),
                     styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    return w
}

@MainActor @Suite(.serialized) struct ControlHookTests {
    init() {
        _ = NSApplication.shared
        #expect(W7InstallControlHooks(), "hooks install on this macOS")
    }

    @Test func lightPushButtonInAPlainWindowDrawsWin7() {
        let w = plainWindow(dark: false)
        defer { w.close() }
        let b = NSButton(title: "OK", target: nil, action: nil)
        b.frame = NSRect(x: 20, y: 20, width: 100, height: 24)
        w.contentView!.addSubview(b)
        let snap = Snapshot(w.contentView!)
        #expect(near(snap.at(70, 20.5), 0x707070), "bottom border \(snap.at(70, 20.5))")
        let top = snap.at(70, 38)
        #expect(top.r >= 0xE4 && abs(top.r - top.b) <= 4, "light top band \(top)")
    }

    @Test func darkPushButtonKeepsItsOwnDrawing() {
        let w = plainWindow(dark: true)
        defer { w.close() }
        let b = NSButton(title: "OK", target: nil, action: nil)
        b.frame = NSRect(x: 20, y: 20, width: 100, height: 24)
        w.contentView!.addSubview(b)
        let snap = Snapshot(w.contentView!)
        let border = snap.at(70, 20.5), top = snap.at(70, 38), bottom = snap.at(70, 24)
        #expect(!near(border, 0x707070), "no Win7 border \(border)")
        // AppKit's own dark drawing may be light in places (the first run read white at (70, 38)), so
        // only the Win7 band colours are ruled out: #F2F2F2→#EBEBEB on top, #DDDDDD→#CFCFCF below.
        #expect(!near(top, 0xEEEEEE, 4), "no Win7 top band \(top)")
        #expect(!near(bottom, 0xD6D6D6, 6), "no Win7 bottom band \(bottom)")
    }

    @Test func defaultButtonHasABlueBorderAndBlackTitle() {
        let w = plainWindow(dark: false)
        defer { w.close() }
        let b = NSButton(title: "OK", target: nil, action: nil)
        b.keyEquivalent = "\r"
        b.frame = NSRect(x: 20, y: 20, width: 100, height: 24)
        w.contentView!.addSubview(b)
        let snap = Snapshot(w.contentView!)
        #expect(near(snap.at(70, 20.5), 0x3C7FB1), "default border \(snap.at(70, 20.5))")
        var darkest = 255
        for x in stride(from: 60.0, to: 80.0, by: 0.5) { for y in stride(from: 28.0, to: 37.0, by: 0.5) {
            let p = snap.at(CGFloat(x), CGFloat(y)); darkest = min(darkest, max(p.r, p.g, p.b))
        } }
        #expect(darkest < 0x50, "the title is dark, not white (darkest channel max \(darkest))")
    }

    @Test func checkBoxAndRadioDrawWin7() {
        let w = plainWindow(dark: false)
        defer { w.close() }
        let c = NSButton(checkboxWithTitle: "Check", target: nil, action: nil)
        c.state = .on
        c.frame = NSRect(x: 20, y: 60, width: 100, height: 20)
        let r = NSButton(radioButtonWithTitle: "Radio", target: nil, action: nil)
        r.state = .on
        r.frame = NSRect(x: 20, y: 100, width: 100, height: 20)
        w.contentView!.addSubview(c)
        w.contentView!.addSubview(r)
        let snap = Snapshot(w.contentView!)
        // The 13×13 box is centred in AppKit's 16×16 image rect at the left of the 20 pt row: x 22–35, y 63–76.
        #expect(near(snap.at(22.5, 69.5), 0x8E8F8F), "check box left border \(snap.at(22.5, 69.5))")
        #expect(near(snap.at(28.5, 63.5), 0x8E8F8F), "check box bottom border \(snap.at(28.5, 63.5))")
        let glyph = snap.at(27.5, 66.5)   // the check's bottom vertex (box (5.5, 3.5))
        #expect(glyph.r < 0x90 && glyph.b > glyph.r, "check glyph \(glyph)")
        let dot = snap.at(28.5, 109.5)    // centre of the radio's selected dot
        #expect(dot.b > dot.r + 50, "radio dot \(dot)")
    }

    @Test func outOfScopeButtonsStayNative() {
        let w = plainWindow(dark: false)
        defer { w.close() }
        let push = NSButton(title: "OK", target: nil, action: nil)
        let disclosure = NSButton(title: "", target: nil, action: nil)
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.onOff)
        let help = NSButton(title: "", target: nil, action: nil)
        help.bezelStyle = .helpButton
        for (i, b) in [push, disclosure, help].enumerated() {
            b.frame = NSRect(x: 20, y: 20 + CGFloat(i) * 40, width: 100, height: 24)
            w.contentView!.addSubview(b)
        }
        _ = Snapshot(w.contentView!)
        #expect(push.subviews.isEmpty, "the in-scope push button draws through its cell")
        #expect(!disclosure.subviews.isEmpty, "disclosure keeps AppKit's own rendering")
        #expect(!help.subviews.isEmpty, "help button keeps AppKit's own rendering")
    }

    // MARK: Review fixes: class gate, multi-cell hover, custom images, KVO

    /// Whether `r` (content coordinates) shows the Win7 normal push bezel: #707070 bottom border, the
    /// #DDDDDD→#CFCFCF band at a quarter height and the #F2F2F2→#EBEBEB band at three quarters.
    private func looksWin7Push(_ snap: Snapshot, _ r: NSRect) -> Bool {
        func grey(_ p: (r: Int, g: Int, b: Int, a: Int), _ lo: Int, _ hi: Int) -> Bool {
            p.r >= lo - 3 && p.r <= hi + 3 && abs(p.r - p.g) <= 2 && abs(p.g - p.b) <= 2
        }
        let x = r.minX + r.width / 4
        return near(snap.at(x, r.minY + 0.5), 0x707070, 6) && grey(snap.at(x, r.minY + r.height * 0.25), 0xCF, 0xDD)
            && grey(snap.at(x, r.minY + r.height * 0.75), 0xEB, 0xF2)
    }

    @Test func appSubclassThatDrawsThroughSuperStaysNative() {
        final class DrawingCell: NSButtonCell {
            override func drawBezel(withFrame frame: NSRect, in controlView: NSView) { super.drawBezel(withFrame: frame, in: controlView) }
        }
        let w = plainWindow(dark: false)
        defer { w.close() }
        let plain = NSButton(title: "OK", target: nil, action: nil)
        plain.frame = NSRect(x: 20, y: 20, width: 100, height: 24)
        let custom = NSButton(frame: NSRect(x: 20, y: 60, width: 100, height: 24))
        let cell = DrawingCell(textCell: "OK")
        cell.setButtonType(.momentaryPushIn)
        cell.bezelStyle = .push
        cell.isBordered = true
        custom.cell = cell
        for b in [plain, custom] { w.contentView!.addSubview(b) }
        let snap = Snapshot(w.contentView!)
        #expect(looksWin7Push(snap, plain.frame), "positive control: a plain button is Win7")
        #expect(!looksWin7Push(snap, custom.frame), "an app subclass calling super keeps AppKit's drawing")
    }

    /// A table data source with three rows (cell-based columns read the object value).
    private final class ThreeRows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 3 }
        func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { 0 }
    }

    @Test func popUpCellInACellBasedTableStaysNative() {
        let w = plainWindow(dark: false)
        defer { w.close() }
        let source = ThreeRows()
        let table = NSTableView(frame: NSRect(x: 20, y: 150, width: 300, height: 100))
        let column = NSTableColumn(identifier: .init("p"))
        column.width = 140
        let popUp = NSPopUpButtonCell(textCell: "", pullsDown: false)
        popUp.addItems(withTitles: ["Alpha", "Beta"])
        column.dataCell = popUp
        table.addTableColumn(column)
        table.dataSource = source
        w.contentView!.addSubview(table)
        table.reloadData()
        let snap = Snapshot(w.contentView!)
        let cellRect = table.convert(table.frameOfCell(atColumn: 0, row: 0), to: w.contentView!)
        #expect(!looksWin7Push(snap, cellRect), "no Win7 push bezel in the pop-up cell \(cellRect)")
        var borderRows = 0
        for y in stride(from: cellRect.minY + 2, to: cellRect.maxY - 2, by: 1) where near(snap.at(cellRect.minX + 0.5, y), 0x707070, 10) {
            borderRows += 1
        }
        #expect(borderRows == 0, "no Win7 left border in the pop-up cell (\(borderRows) rows)")
    }

    private func hasHoverTracker(_ v: NSView) -> Bool {
        v.trackingAreas.contains { area in area.owner.flatMap { object_getClass($0) }.map(NSStringFromClass) == "W7HoverTracker" }
    }

    @Test func matrixRadiosDrawWin7WithoutViewWideHover() {
        let w = plainWindow(dark: false)
        defer { w.close() }
        let matrix = NSMatrix(frame: NSRect(x: 20, y: 20, width: 100, height: 60), mode: .radioModeMatrix,
                              cellClass: NSButtonCell.self, numberOfRows: 2, numberOfColumns: 1)
        for case let cell as NSButtonCell in matrix.cells { cell.setButtonType(.radio); cell.title = "R" }
        let radio = NSButton(radioButtonWithTitle: "Alone", target: nil, action: nil)
        radio.frame = NSRect(x: 20, y: 120, width: 100, height: 20)
        w.contentView!.addSubview(matrix)
        w.contentView!.addSubview(radio)
        let snap = Snapshot(w.contentView!)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))   // trackers are attached asynchronously
        #expect(!hasHoverTracker(matrix), "no tracker on the matrix: its mouse-inside is not a cell's")
        #expect(hasHoverTracker(radio), "positive control: a radio button owning its cell is tracked")
        // The matrix's cells still draw the Win7 radio (normal border, not the hover blue).
        let cell = matrix.cell(atRow: 1, column: 0) as! NSButtonCell
        let frame = matrix.cellFrame(atRow: 1, column: 0)
        let image = cell.imageRect(forBounds: frame)
        let box = NSRect(x: (image.midX - 6.5).rounded(), y: (image.midY - 6.5).rounded(), width: 13, height: 13)
        let boxInContent = matrix.convert(box, to: w.contentView!)
        let border = snap.at(boxInContent.minX + 0.5, boxInContent.midY)
        #expect(near(border, 0x8E8F8F, 20), "matrix radio border \(border) at \(boxInContent)")
    }

    @Test func checkBoxWithAnAppImageStaysNative() {
        let w = plainWindow(dark: false)
        defer { w.close() }
        let stock = NSButton(checkboxWithTitle: "Stock", target: nil, action: nil)
        stock.frame = NSRect(x: 20, y: 60, width: 100, height: 20)
        let star = NSButton(checkboxWithTitle: "Star", target: nil, action: nil)
        star.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        star.frame = NSRect(x: 20, y: 100, width: 100, height: 20)
        for b in [stock, star] { w.contentView!.addSubview(b) }
        let snap = Snapshot(w.contentView!)
        func boxBorder(_ b: NSButton) -> (r: Int, g: Int, b: Int, a: Int) {
            let cell = b.cell as! NSButtonCell
            let image = cell.imageRect(forBounds: b.bounds)
            let box = NSRect(x: (image.midX - 6.5).rounded(), y: (image.midY - 6.5).rounded(), width: 13, height: 13)
            let r = b.convert(box, to: w.contentView!)
            return snap.at(r.minX + 0.5, r.midY)
        }
        #expect(near(boxBorder(stock), 0x8E8F8F), "positive control: stock check box is Win7 \(boxBorder(stock))")
        #expect(!near(boxBorder(star), 0x8E8F8F, 4), "a check box with the app's own image keeps it \(boxBorder(star))")
    }

    @Test func kvoObservedButtonCellStillDrawsWin7() {
        let w = plainWindow(dark: false)
        defer { w.close() }
        let b = NSButton(title: "OK", target: nil, action: nil)
        let observation = b.cell!.observe(\.title) { _, _ in }
        defer { observation.invalidate() }
        b.frame = NSRect(x: 20, y: 20, width: 100, height: 24)
        w.contentView!.addSubview(b)
        let snap = Snapshot(w.contentView!)
        #expect(NSStringFromClass(object_getClass(b.cell!)!).hasPrefix("NSKVONotifying_"))
        #expect(looksWin7Push(snap, b.frame), "an observed NSButtonCell is still drawn as Win7")
    }

    @MainActor private func scrollView(in w: NSWindow) -> NSScrollView {
        let sv = NSScrollView(frame: NSRect(x: 150, y: 20, width: 200, height: 200))
        sv.hasVerticalScroller = true
        sv.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 1000))
        w.contentView!.addSubview(sv)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))   // the legacy style is applied asynchronously
        return sv
    }

    @Test func lightScrollerIsSwitchedAndDrawsWin7() throws {
        let w = plainWindow(dark: false)
        defer { w.close() }
        let sv = scrollView(in: w)
        let scroller = try #require(sv.verticalScroller)
        #expect(NSStringFromClass(object_getClass(scroller)!).hasPrefix("W7"), "switched class")
        #expect(scroller.isKind(of: NSScroller.self), "still an NSScroller")
        #expect(sv.scrollerStyle == .legacy, "always-visible scroll bars")
        sv.scrollerStyle = .overlay   // what the system preference (or an app) sets
        #expect(sv.scrollerStyle == .legacy, "Overlay is coerced back to Legacy for a Win7 scroller")
        W7AdoptScrollersInView(w.contentView!)   // a second pass must not switch twice
        #expect(class_getSuperclass(object_getClass(scroller)!) == NSScroller.self)
        let snap = Snapshot(w.contentView!)
        // Everything in the content view's (unflipped) coordinates.
        let content = w.contentView!
        let f = scroller.convert(scroller.bounds, to: content)
        let knob = scroller.convert(scroller.rect(for: .knob), to: content)
        // Sample the track at whichever end of the scroller the knob is not.
        let trackY = knob.minY - f.minY > 40 ? f.minY + 10 : f.maxY - 10
        let track = snap.at(f.midX, trackY), edge = snap.at(f.minX + 0.5, trackY)
        let thumbBorder = snap.at(f.minX + 1.5, knob.midY + 6.5), thumbFill = snap.at(f.minX + 4, knob.midY + 6.5)
        #expect(near(track, 0xF0F0F0, 3), "track \(track)")
        #expect(near(edge, 0xE3E3E3, 3), "track edge line \(edge)")
        #expect(near(thumbBorder, 0x979797), "thumb border \(thumbBorder)")
        #expect(thumbFill.r >= 0xD8 && thumbFill.r <= 0xF6 && abs(thumbFill.r - thumbFill.b) <= 4, "thumb fill \(thumbFill)")
    }

    /// KVO on a switched scroller subclasses W7AeroScroller; the scroller still draws Win7.
    @Test func switchedScrollerSurvivesKVO() throws {
        let w = plainWindow(dark: false)
        defer { w.close() }
        let sv = scrollView(in: w)
        let scroller = try #require(sv.verticalScroller)
        let observation = scroller.observe(\.knobProportion) { _, _ in }
        defer { observation.invalidate() }
        var chain: [String] = []
        var cls: AnyClass? = object_getClass(scroller)
        while let c = cls { chain.append(NSStringFromClass(c)); cls = class_getSuperclass(c) }
        let snap = Snapshot(w.contentView!)
        let f = scroller.convert(scroller.bounds, to: w.contentView!)
        let knob = scroller.convert(scroller.rect(for: .knob), to: w.contentView!)
        let trackY = knob.minY - f.minY > 40 ? f.minY + 10 : f.maxY - 10
        let track = snap.at(f.midX, trackY)
        #expect(chain.contains("W7AeroScroller"), "class chain \(chain.prefix(4))")
        #expect(near(track, 0xF0F0F0, 3), "track after KVO \(track)")
    }

    @Test func darkScrollerIsLeftAlone() throws {
        let w = plainWindow(dark: true)
        defer { w.close() }
        let sv = scrollView(in: w)
        let scroller = try #require(sv.verticalScroller)
        #expect(object_getClass(scroller) == NSScroller.self)
        sv.scrollerStyle = .overlay
        #expect(sv.scrollerStyle == .overlay, "a dark scroll view keeps the style it is given")
    }

    @Test func kvoObservedScrollerIsLeftAlone() throws {
        let scroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 17, height: 100))
        let observation = scroller.observe(\.knobProportion) { _, _ in }
        defer { observation.invalidate() }
        let observedClass: AnyClass? = object_getClass(scroller)
        let w = plainWindow(dark: false)
        defer { w.close() }
        w.contentView!.addSubview(scroller)
        #expect(object_getClass(scroller) == observedClass, "a KVO-observed scroller is not switched")
    }

    // MARK: With the message box and the dialog panel (background-only; the buttons are ours)

    /// The Win7 bezel rect of `b` as the push-button hook draws it (alignment rect), in `content`'s coordinates.
    private func bezelRect(_ b: NSButton, in content: NSView) -> NSRect {
        let ins = b.alignmentRectInsets
        let r = NSRect(x: ins.left, y: b.isFlipped ? ins.top : ins.bottom,
                       width: b.bounds.width - ins.left - ins.right, height: b.bounds.height - ins.top - ins.bottom)
        return b.convert(r, to: content)
    }

    /// Bottom-border colour of `b`'s Win7 bezel, sampled 0.5 pt inside its bottom edge at the left quarter
    /// (clear of the title).
    private func bottomBorder(_ b: NSButton, _ snap: Snapshot, _ content: NSView) -> (r: Int, g: Int, b: Int, a: Int) {
        let r = bezelRect(b, in: content)
        return snap.at(r.minX + r.width / 4, r.minY + 0.5)
    }

    private func isStripGrey(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
        abs(p.r - 0xF0) <= 8 && abs(p.r - p.g) <= 2 && abs(p.g - p.b) <= 2
    }

    @Test func alertMessageBoxButtonsDrawWin7OverTheStrip() throws {
        W7MessageBoxUseDisabledOverride(0)
        defer { W7MessageBoxUseDisabledOverride(-1) }
        let alert = NSAlert()
        alert.messageText = "Do you want to save changes to Untitled?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.window.appearance = NSAppearance(named: .aqua)
        alert.layout()
        defer { alert.window.close() }
        #expect(W7StyleMessageBoxIfNeeded(alert.window), "the alert gets the Windows 7 message box backdrop")
        let content = try #require(alert.window.contentView)
        let snap = Snapshot(content)
        let save = alert.buttons[0], cancel = alert.buttons[1]
        #expect(save.subviews.isEmpty && cancel.subviews.isEmpty,
                "alert buttons draw through their cells (\(save.subviews.count), \(cancel.subviews.count) subviews)")
        let saveBorder = bottomBorder(save, snap, content), cancelBorder = bottomBorder(cancel, snap, content)
        #expect(near(saveBorder, 0x3C7FB1), "default (Save) border \(saveBorder), bezel \(bezelRect(save, in: content))")
        #expect(near(cancelBorder, 0x707070), "Cancel border \(cancelBorder), bezel \(bezelRect(cancel, in: content))")
        let strip = snap.at(4, 4)
        #expect(isStripGrey(strip), "the message box's grey strip is still under the buttons \(strip)")
        // The suppression check box (_NSAlertCheckboxButtonCell) is a Win7 check box too.
        let suppress = try #require(alert.suppressionButton)
        let cell = try #require(suppress.cell as? NSButtonCell)
        let image = cell.imageRect(forBounds: suppress.bounds)
        let box = suppress.convert(NSRect(x: (image.midX - 6.5).rounded(), y: (image.midY - 6.5).rounded(), width: 13, height: 13),
                                   to: content)
        let boxBorder = snap.at(box.minX + 0.5, box.midY)
        #expect(near(boxBorder, 0x8E8F8F), "suppression check box border \(boxBorder) (\(NSStringFromClass(object_getClass(cell)!)))")
    }

    @Test func dialogPanelButtonsDrawWin7OverTheStrip() throws {
        W7DialogPanelUseDisabledOverride(0)
        defer { W7DialogPanelUseDisabledOverride(-1) }
        let p = NSPanel(contentRect: NSRect(x: -9000, y: -9000, width: 400, height: 200), styleMask: [.titled, .closable],
                        backing: .buffered, defer: true)
        p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: .aqua)
        defer { p.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        p.contentView = content
        let ok = NSButton(title: "OK", target: nil, action: nil)
        ok.keyEquivalent = "\r"
        ok.frame = NSRect(x: 296, y: 12, width: 90, height: 24)
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        cancel.frame = NSRect(x: 200, y: 12, width: 90, height: 24)
        let label = NSTextField(labelWithString: "Preferences text")
        label.frame = NSRect(x: 20, y: 120, width: 200, height: 17)
        for v in [ok, cancel, label] { content.addSubview(v) }
        W7ChromeController.decorateWindow(p)
        #expect(W7DialogPanelIsStyled(p), "the panel gets the Windows 7 dialog body")
        #expect(W7DialogPanelStripTop(content) > 0, "with a button strip")
        let snap = Snapshot(content)
        let okBorder = bottomBorder(ok, snap, content), cancelBorder = bottomBorder(cancel, snap, content)
        #expect(near(okBorder, 0x3C7FB1), "default (OK) border \(okBorder), bezel \(bezelRect(ok, in: content))")
        #expect(near(cancelBorder, 0x707070), "Cancel border \(cancelBorder), bezel \(bezelRect(cancel, in: content))")
        let strip = snap.at(4, 4)
        #expect(isStripGrey(strip), "the dialog's grey strip is under the buttons \(strip)")
        let fill = snap.at(cancel.frame.minX + 8, cancel.frame.midY + 6)
        #expect(fill.r >= 0xE4 && abs(fill.r - fill.b) <= 4, "Cancel's Win7 top band, not the strip \(fill)")
    }

    /// Option B crashed at exit after cells were swapped; the override-check approach must not: build,
    /// draw and tear down many windows of controls.
    @Test func windowsAndControlsComeAndGo() {
        weak var lastWindow: NSWindow?
        weak var lastButton: NSButton?
        for i in 0..<20 {
            autoreleasepool {
                let w = plainWindow(dark: i % 2 == 1)
                let b = NSButton(title: "OK", target: w, action: #selector(NSWindow.performClose(_:)))
                b.keyEquivalent = "\r"
                b.frame = NSRect(x: 20, y: 20, width: 100, height: 24)
                let c = NSButton(checkboxWithTitle: "Check", target: nil, action: nil)
                c.frame = NSRect(x: 20, y: 60, width: 100, height: 20)
                let sv = NSScrollView(frame: NSRect(x: 150, y: 20, width: 200, height: 200))
                sv.hasVerticalScroller = true
                sv.hasHorizontalScroller = true
                sv.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000))
                for v in [b, c, sv] { w.contentView!.addSubview(v) }
                _ = Snapshot(w.contentView!)
                b.removeFromSuperview()
                sv.removeFromSuperview()
                w.close()
                lastWindow = w
                lastButton = b
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(lastWindow == nil && lastButton == nil, "windows and buttons are released")
    }
}
