import AppKit
import Carbon.HIToolbox
import Win7ChromeCore
import Win7Core
import Win7Theme

/// Windows Help and Support: the Windows 7 Help toolbar on the glass (Back/Forward, Home, Print,
/// Browse Help, Ask, Options), the search band with "Search Help", the page, and the footer's "More support options".
/// The pages come from HelpTopics (Win7Core), written for this project; links open other topics, Control Panel items
/// (by catalogue id) or the shell's windows. Nothing here goes online.
@MainActor
final class HelpWindow: ShellWindow, NSTextViewDelegate {
    static let shared = HelpWindow()
    static let defaultSize = NSSize(width: 700, height: 560)

    private let toolBar = HelpToolbarView()
    private let searchBand = HelpSearchBandView()
    private let footer = HelpFooterView()
    private let scroll = NSScrollView()
    private let text = HelpTextView()
    private var history = HelpHistory()
    /// Options ▸ Text Size: 0 medium, ±1, ±2.
    private var textSize = 0

    private init() {
        super.init(spec: Spec(identifier: ShellWindowTarget.help.identifier, title: ShellWindowTarget.help.title,
                              frameName: "Win7Help", defaultSize: Self.defaultSize, minSize: NSSize(width: 460, height: 340),
                              icon: { HelpWindow.icon(side: $0) }, logName: "help"))
        buildContent()
        finishSetup()
    }

    /// The toolbar's glass follows the caption's active state.
    override func keyStateChanged() { toolBar.needsDisplay = true }

    static func icon(side: CGFloat) -> NSImage { ControlPanelIcons.image(names: ["help"], glyph: .help, side: side) }

    private func buildContent() {
        let size = Self.defaultSize
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let barH = HelpToolbarView.height, bandH = HelpSearchBandView.height, footH = HelpFooterView.height
        toolBar.frame = NSRect(x: 0, y: size.height - barH, width: size.width, height: barH)
        toolBar.autoresizingMask = [.width, .minYMargin]
        toolBar.onCommand = { [weak self] in self?.perform($0) }
        searchBand.frame = NSRect(x: 0, y: size.height - barH - bandH, width: size.width, height: bandH)
        searchBand.autoresizingMask = [.width, .minYMargin]
        searchBand.onSearch = { [weak self] in self?.search($0) }
        footer.frame = NSRect(x: 0, y: 0, width: size.width, height: footH)
        footer.autoresizingMask = [.width, .maxYMargin]
        footer.onMoreSupport = { [weak self] in self?.follow(HelpTopics.moreSupportLink.target) }

        scroll.frame = NSRect(x: 0, y: footH, width: size.width, height: size.height - barH - bandH - footH)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.backgroundColor = .white
        scroll.drawsBackground = true
        text.frame = NSRect(origin: .zero, size: scroll.contentSize)
        text.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 26, height: 18)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.drawsBackground = true
        text.backgroundColor = .white
        text.linkTextAttributes = [.foregroundColor: HelpPage.linkColor, .cursor: NSCursor.pointingHand]
        text.delegate = self
        scroll.documentView = text
        for v in [toolBar, searchBand, scroll, footer] as [NSView] { content.addSubview(v) }
        contentView = content
        render()
    }

    // MARK: Showing

    /// Brings the window forward at the home page, or at `topic` (Device Manager's Help Topics).
    func show(topic: String? = nil) {
        if let topic, HelpTopics.topic(topic) != nil { history.navigate(to: .topic(topic)) }
        else if !isVisible { history.navigate(to: .home) }
        render()
        present(topic ?? "home")
    }

    private func navigate(to location: HelpLocation) {
        guard history.navigate(to: location) else { return }
        SoundPlayer.play(.navigation)
        render()
    }

    private func render() {
        let page: NSAttributedString
        switch history.current {
        case .home: page = HelpPage.home(scale: textSize)
        case .browse: page = HelpPage.browse(scale: textSize)
        case .topic(let id): page = HelpTopics.topic(id).map { HelpPage.topic($0, scale: textSize) } ?? HelpPage.home(scale: textSize)
        case .search(let query): page = HelpPage.results(query, HelpTopics.search(query), scale: textSize)
        }
        text.textStorage?.setAttributedString(page)
        text.scrollToBeginningOfDocument(nil)
        toolBar.update(canGoBack: history.canGoBack, canGoForward: history.canGoForward)
        if case .search(let q) = history.current { searchBand.text = q } else { searchBand.text = "" }
    }

    private func search(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        navigate(to: .search(q))
    }

    // MARK: Links and commands

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, let target = HelpLinkTarget(url: url) else { return true }   // nothing else is ever opened
        follow(target)
        return true
    }

    private func follow(_ target: HelpLinkTarget) {
        switch target {
        case .home: navigate(to: .home)
        case .browse: navigate(to: .browse)
        case .topic(let id): navigate(to: .topic(id))
        case .controlPanel(let id):
            if !ControlPanelWindow.shared.openItem(id) { NSSound.beep() }
        case .window(let t): ShellScreens.open(t)
        case .readme: Self.openReadme()
        }
    }

    /// The README `make shell` copies into the app; without it (a debug build), the support topic.
    private static func openReadme() {
        if let url = Bundle.main.url(forResource: "README", withExtension: "md") {
            NSWorkspace.shared.open(url)
        } else {
            ShellWindowButtons.log.info("help: no README in the app bundle")
            HelpWindow.shared.navigate(to: .topic("more-support"))
        }
    }

    private func perform(_ command: HelpToolbarView.Command) {
        switch command {
        case .back: if history.goBack() { SoundPlayer.play(.navigation); render() }
        case .forward: if history.goForward() { SoundPlayer.play(.navigation); render() }
        case .home: navigate(to: .home)
        case .print: printPage()
        case .browse: navigate(to: .browse)
        case .ask: navigate(to: .topic("more-support"))
        case .options(let anchor): showOptions(below: anchor)
        }
    }

    private func printPage() {
        let op = NSPrintOperation(view: text)
        op.jobTitle = ShellWindowTarget.help.title
        op.runModal(for: self, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// Options: Print, Browse Help, Text Size, Search Help.
    private func showOptions(below anchor: NSRect) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(MenuAction.item("Print…") { [weak self] in self?.printPage() })
        menu.addItem(MenuAction.item("Browse Help") { [weak self] in self?.navigate(to: .browse) })
        menu.addItem(.separator())
        for (title, size) in [("Largest", 2), ("Larger", 1), ("Medium", 0), ("Smaller", -1), ("Smallest", -2)] {
            let item = MenuAction.item("Text Size: " + title) { [weak self] in
                self?.textSize = size
                self?.render()
            }
            item.state = size == textSize ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Search Help") { [weak self] in self?.searchBand.focus() })
        let screen = convertToScreen(toolBar.convert(anchor, to: nil))
        ShellMenus.show(menu, at: NSPoint(x: screen.minX, y: screen.minY))
    }

    // MARK: Keyboard

    /// Alt+← / Alt+→ go back and forward, Alt+Home goes home (Option on a Mac keyboard); Cmd+F or F3 goes to the search
    /// box; Cmd+P prints.
    override func handleKey(_ event: NSEvent) -> Bool {
        let flags = Self.flags(event)
        switch (Int(event.keyCode), flags) {
        case (kVK_LeftArrow, [.option]), (kVK_LeftArrow, [.option, .function]): perform(.back); return true
        case (kVK_RightArrow, [.option]), (kVK_RightArrow, [.option, .function]): perform(.forward); return true
        case (kVK_Home, [.option]), (kVK_Home, [.option, .function]): perform(.home); return true
        case (kVK_ANSI_F, [.command]), (kVK_F3, []), (kVK_F3, [.function]): searchBand.focus(); return true
        case (kVK_ANSI_P, [.command]): printPage(); return true
        default: return super.handleKey(event)
        }
    }
}

// MARK: - Pages

/// The pages as attributed text: Windows 7 Help's blue headings, black text, blue links (each carrying its
/// HelpLinkTarget URL), list items with a hanging indent.
@MainActor
enum HelpPage {
    static let linkColor = NSColor(srgbRed: 0x00 / 255, green: 0x66 / 255, blue: 0xCC / 255, alpha: 1)
    private static let headingColor = NSColor(srgbRed: 0x1E / 255, green: 0x39 / 255, blue: 0x5B / 255, alpha: 1)
    private static let greyText = NSColor(srgbRed: 0x5A / 255, green: 0x5A / 255, blue: 0x5A / 255, alpha: 1)

    @MainActor private struct Builder {
        let scale: Int
        let out = NSMutableAttributedString()

        func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
            let f = W7UIFont(size + CGFloat(scale) * 1.5)
            return bold ? NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) : f
        }

        func style(before: CGFloat, after: CGFloat, indent: CGFloat = 0, head: CGFloat? = nil) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = before
            p.paragraphSpacing = after
            p.firstLineHeadIndent = head ?? indent
            p.headIndent = indent
            p.lineSpacing = 2
            return p
        }

        func heading(_ s: String) {
            out.append(NSAttributedString(string: s + "\n", attributes: [
                .font: font(18), .foregroundColor: HelpPage.headingColor, .paragraphStyle: style(before: 0, after: 10),
            ]))
        }

        func subheading(_ s: String) {
            out.append(NSAttributedString(string: s + "\n", attributes: [
                .font: font(13, bold: true), .foregroundColor: HelpPage.headingColor, .paragraphStyle: style(before: 12, after: 6),
            ]))
        }

        func paragraph(_ s: String, color: NSColor = .black) {
            if s.hasPrefix("• ") {
                out.append(NSAttributedString(string: "•\t" + s.dropFirst(2) + "\n", attributes: [
                    .font: font(12), .foregroundColor: color, .paragraphStyle: bulletStyle,
                ]))
            } else {
                out.append(NSAttributedString(string: s + "\n", attributes: [
                    .font: font(12), .foregroundColor: color, .paragraphStyle: style(before: 0, after: 8),
                ]))
            }
        }

        private var bulletStyle: NSParagraphStyle {
            let p = style(before: 0, after: 5, indent: 18, head: 4)
            let m = p.mutableCopy() as! NSMutableParagraphStyle
            m.tabStops = [NSTextTab(textAlignment: .left, location: 18)]
            return m
        }

        /// A link on a line of its own, optionally with a grey line under it.
        func link(_ l: HelpLink, note: String? = nil, bullet: Bool = false) {
            if bullet {
                out.append(NSAttributedString(string: "•\t", attributes: [.font: font(12), .foregroundColor: NSColor.black,
                                                                         .paragraphStyle: bulletStyle]))
            }
            out.append(NSAttributedString(string: l.title, attributes: [
                .font: font(12), .link: l.target.url, .paragraphStyle: bullet ? bulletStyle : style(before: 0, after: note == nil ? 6 : 1),
            ]))
            out.append(NSAttributedString(string: "\n", attributes: [.font: font(12),
                                                                     .paragraphStyle: bullet ? bulletStyle : style(before: 0, after: note == nil ? 6 : 1)]))
            if let note {
                out.append(NSAttributedString(string: note + "\n", attributes: [
                    .font: font(11), .foregroundColor: HelpPage.greyText, .paragraphStyle: style(before: 0, after: 9),
                ]))
            }
        }
    }

    static func home(scale: Int) -> NSAttributedString {
        let b = Builder(scale: scale)
        b.heading("Find an answer quickly")
        b.paragraph("Enter a few words in the search box above.")
        b.subheading("Not sure where to start?")
        for l in HelpTopics.homeStartLinks { b.link(l, bullet: true) }
        b.subheading("More on the Windows website")
        b.link(HelpTopics.websiteLink, bullet: true)
        return b.out
    }

    static func browse(scale: Int) -> NSAttributedString {
        let b = Builder(scale: scale)
        b.heading("Contents")
        for (category, topics) in HelpTopics.browse() where !topics.isEmpty {
            b.subheading(category.title)
            for t in topics { b.link(HelpLink(t.title, .topic(t.id)), note: t.summary) }
        }
        return b.out
    }

    static func topic(_ t: HelpTopic, scale: Int) -> NSAttributedString {
        let b = Builder(scale: scale)
        b.heading(t.title)
        b.paragraph(t.summary, color: greyText)
        for p in t.body { b.paragraph(p) }
        if !t.links.isEmpty {
            b.subheading("See also")
            for l in t.links { b.link(l, bullet: true) }
        }
        return b.out
    }

    static func results(_ query: String, _ found: [HelpTopic], scale: Int) -> NSAttributedString {
        let b = Builder(scale: scale)
        b.heading(found.isEmpty ? "No results for \u{201C}\(query)\u{201D}" : "Best \(found.count) results for \u{201C}\(query)\u{201D}")
        if found.isEmpty {
            b.paragraph("Check the spelling, try fewer or other words, or browse the topics instead.")
            b.link(HelpLink("Browse Help topics", .browse), bullet: true)
        }
        for (i, t) in found.enumerated() { b.link(HelpLink("\(i + 1). \(t.title)", .topic(t.id)), note: t.summary) }
        return b.out
    }
}

/// The page's text view: links show the pointing hand, nothing can be typed.
@MainActor
final class HelpTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Toolbar

/// Windows 7 Help's toolbar on the glass under the caption: the back and forward orbs in their trough at the left;
/// Home, Print and Browse Help as icon buttons, then "Ask" and "Options ▾" at the right. Non-flipped.
@MainActor
final class HelpToolbarView: NSView {
    enum Command { case back, forward, home, print, browse, ask, options(NSRect) }
    static let height: CGFloat = 36
    var onCommand: ((Command) -> Void)?

    private enum Part: Equatable { case back, forward, home, print, browse, ask, options }
    private var hover: Part?
    private var pressed: Part?
    private var canGoBack = false
    private var canGoForward = false
    private static let backSize: CGFloat = 28, forwardSize: CGFloat = 24
    private static let font = W7UIFont(12)
    private static let separatorLine = NSColor(srgbRed: 0xA0 / 255, green: 0xAF / 255, blue: 0xC3 / 255, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func update(canGoBack: Bool, canGoForward: Bool) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        needsDisplay = true
    }

    private static func title(_ p: Part) -> String {
        switch p {
        case .back: "Back"
        case .forward: "Forward"
        case .home: "Help and Support home"
        case .print: "Print"
        case .browse: "Browse Help"
        case .ask: "Ask"
        case .options: "Options"
        }
    }

    private func textWidth(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: Self.font]).width) }

    private func rect(_ p: Part) -> NSRect {
        let h: CGFloat = 26, y = floor((bounds.height - h) / 2)
        switch p {
        case .back: return NSRect(x: 6, y: floor((bounds.height - Self.backSize) / 2), width: Self.backSize, height: Self.backSize)
        case .forward:
            return NSRect(x: 6 + Self.backSize - 1, y: floor((bounds.height - Self.forwardSize) / 2),
                          width: Self.forwardSize, height: Self.forwardSize)
        case .options:
            let w = textWidth("Options") + 26
            return NSRect(x: bounds.width - 8 - w, y: y, width: w, height: h)
        case .ask:
            let w = textWidth("Ask") + 16
            return NSRect(x: rect(.options).minX - 2 - w, y: y, width: w, height: h)
        case .browse: return NSRect(x: rect(.ask).minX - 10 - 30, y: y, width: 30, height: h)
        case .print: return NSRect(x: rect(.browse).minX - 2 - 30, y: y, width: 30, height: h)
        case .home: return NSRect(x: rect(.print).minX - 2 - 30, y: y, width: 30, height: h)
        }
    }

    private func enabled(_ p: Part) -> Bool {
        switch p {
        case .back: canGoBack
        case .forward: canGoForward
        default: true
        }
    }

    private func state(_ p: Part) -> W7ControlState {
        guard enabled(p) else { return .disabled }
        if pressed == p && hover == p { return .pressed }
        return hover == p && pressed == nil ? .hover : .normal
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let active = window?.isKeyWindow ?? true
        ctx.saveGState()
        ctx.clip(to: bounds)
        W7DrawGlassFill(ctx, CGRect(x: 0, y: 0, width: bounds.width, height: 10_000), active)
        ctx.restoreGState()
        Self.separatorLine.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        let back = rect(.back), forward = rect(.forward)
        W7DrawNavTrough(ctx, NSRect(x: back.minX + 2, y: floor((bounds.height - 22) / 2), width: forward.maxX - back.minX - 1, height: 22))
        W7DrawNavButton(ctx, forward, true, state(.forward))
        W7DrawNavButton(ctx, back, false, state(.back))

        for p in [Part.home, .print, .browse, .ask, .options] {
            let r = rect(p)
            guard r.minX > forward.maxX + 8 else { continue }
            let st = state(p)
            if st == .hover || st == .pressed { W7DrawCommandButton(ctx, r, st) }
            switch p {
            case .home, .print, .browse:
                HelpGlyph.draw(p == .home ? .home : p == .print ? .print : .browse, ctx,
                               NSRect(x: r.midX - 8, y: r.midY - 8, width: 16, height: 16))
            case .ask, .options:
                let s = Self.title(p) as NSString
                let size = s.size(withAttributes: [.font: Self.font])
                s.draw(at: NSPoint(x: r.minX + 8, y: r.midY - size.height / 2),
                       withAttributes: [.font: Self.font, .foregroundColor: NSColor.black])
                if p == .options { W7DrawChevron(ctx, CGPoint(x: r.maxX - 10, y: r.midY), .down, 0x000000, 0.8) }
            default: break
            }
        }
    }

    // MARK: Mouse

    private func part(at p: NSPoint) -> Part? {
        for orb in [Part.back, .forward] {
            let r = rect(orb)
            if hypot(p.x - r.midX, p.y - r.midY) <= r.width / 2 { return orb }
        }
        return [Part.home, .print, .browse, .ask, .options].first { rect($0).contains(p) && rect($0).minX > rect(.forward).maxX + 8 }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = part(at: convert(event.locationInWindow, from: nil))
        if p != hover { hover = p; needsDisplay = true; toolTip = p.map(Self.title) }
    }

    override func mouseExited(with event: NSEvent) {
        if hover != nil { hover = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        pressed = part(at: convert(event.locationInWindow, from: nil))
        hover = pressed
        needsDisplay = true
        if pressed == .options {   // a menu opens on the press, as Windows 7's
            pressed = nil
            onCommand?(.options(rect(.options)))
            hover = nil
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = part(at: convert(event.locationInWindow, from: nil))
        if p != hover { hover = p; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let hit = part(at: convert(event.locationInWindow, from: nil))
        let was = pressed
        pressed = nil
        needsDisplay = true
        guard let hit, hit == was, enabled(hit) else { return }
        switch hit {
        case .back: onCommand?(.back)
        case .forward: onCommand?(.forward)
        case .home: onCommand?(.home)
        case .print: onCommand?(.print)
        case .browse: onCommand?(.browse)
        case .ask: onCommand?(.ask)
        case .options: break
        }
    }
}

/// The Help toolbar's 16 pt glyphs, drawn (non-flipped): a house, a printer, an open book.
enum HelpGlyph {
    case home, print, browse

    static func draw(_ g: HelpGlyph, _ ctx: CGContext, _ r: CGRect) {
        let outline = CGColor(srgbRed: 0x2B / 255, green: 0x3E / 255, blue: 0x5A / 255, alpha: 1)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineWidth(1)
        ctx.setStrokeColor(outline)
        switch g {
        case .home:
            let roof = CGMutablePath()
            roof.move(to: CGPoint(x: r.minX + 1, y: r.minY + 8))
            roof.addLine(to: CGPoint(x: r.midX, y: r.maxY - 1.5))
            roof.addLine(to: CGPoint(x: r.maxX - 1, y: r.minY + 8))
            roof.closeSubpath()
            ctx.addPath(roof)
            ctx.setFillColor(CGColor(srgbRed: 0xC8 / 255, green: 0x4B / 255, blue: 0x31 / 255, alpha: 1))
            ctx.drawPath(using: .fillStroke)
            let wall = CGRect(x: r.minX + 3.5, y: r.minY + 1.5, width: 9, height: 7)
            ctx.setFillColor(CGColor(srgbRed: 0xF4 / 255, green: 0xE7 / 255, blue: 0xC8 / 255, alpha: 1))
            ctx.fill(wall)
            ctx.stroke(wall)
            ctx.setFillColor(CGColor(srgbRed: 0x2F / 255, green: 0x6D / 255, blue: 0xB5 / 255, alpha: 1))
            ctx.fill(CGRect(x: r.midX - 1.5, y: r.minY + 1.5, width: 3, height: 4.5))
        case .print:
            let paper = CGRect(x: r.minX + 4, y: r.minY + 8, width: 8, height: 7)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(paper)
            ctx.stroke(paper.insetBy(dx: 0.5, dy: 0.5))
            let body = CGRect(x: r.minX + 1, y: r.minY + 3, width: 14, height: 6.5)
            ctx.setFillColor(CGColor(srgbRed: 0x9A / 255, green: 0xA6 / 255, blue: 0xB4 / 255, alpha: 1))
            ctx.fill(body)
            ctx.stroke(body.insetBy(dx: 0.5, dy: 0.5))
            let out = CGRect(x: r.minX + 4, y: r.minY + 1, width: 8, height: 4)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(out)
            ctx.stroke(out.insetBy(dx: 0.5, dy: 0.5))
        case .browse:
            for x in [r.minX + 1, r.midX] {   // the two open pages
                ctx.addRect(CGRect(x: x + 0.5, y: r.minY + 3.5, width: 6.5, height: r.height - 5.5))
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.drawPath(using: .fillStroke)
            }
            ctx.setFillColor(CGColor(srgbRed: 0x2F / 255, green: 0x6D / 255, blue: 0xB5 / 255, alpha: 1))
            ctx.fill(CGRect(x: r.minX + 1, y: r.minY + 1.5, width: 14, height: 1.5))
            ctx.setStrokeColor(CGColor(srgbRed: 0x7A / 255, green: 0x96 / 255, blue: 0xB8 / 255, alpha: 1))
            for i in 0..<3 {
                let y = r.maxY - 5 - CGFloat(i) * 2.5
                ctx.move(to: CGPoint(x: r.minX + 2.5, y: y)); ctx.addLine(to: CGPoint(x: r.minX + 6.5, y: y))
                ctx.move(to: CGPoint(x: r.midX + 1.5, y: y)); ctx.addLine(to: CGPoint(x: r.midX + 5.5, y: y))
            }
            ctx.strokePath()
        }
    }
}

// MARK: - Search band

/// The light band under the toolbar with the "Search Help" box in the middle (the Explorer search box). Return
/// searches; the × (shown while there is text) clears the box; the magnifier of an empty box focuses it. Non-flipped.
@MainActor
final class HelpSearchBandView: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 46
    var onSearch: ((String) -> Void)?
    private let field = NSTextField()
    private static let font = W7UIFont(12)
    private static let top = NSColor(srgbRed: 0xE9 / 255, green: 0xF1 / 255, blue: 0xFB / 255, alpha: 1)
    private static let bottom = NSColor(srgbRed: 0xD6 / 255, green: 0xE4 / 255, blue: 0xF5 / 255, alpha: 1)
    private static let line = NSColor(srgbRed: 0xB6 / 255, green: 0xC8 / 255, blue: 0xDF / 255, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Self.font
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        let italic = NSFontManager.shared.convert(Self.font, toHaveTrait: .italicFontMask)
        field.placeholderAttributedString = NSAttributedString(string: "Search Help", attributes: [
            .font: italic, .foregroundColor: NSColor(srgbRed: 0x6D / 255, green: 0x6D / 255, blue: 0x6D / 255, alpha: 1),
        ])
        field.delegate = self
        addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue; needsDisplay = true }
    }

    func focus() { window?.makeFirstResponder(field) }

    private var box: NSRect {
        let w = min(440, bounds.width - 40)
        return NSRect(x: floor((bounds.width - w) / 2), y: floor((bounds.height - 24) / 2), width: w, height: 24)
    }
    private var buttonRect: NSRect { NSRect(x: box.maxX - 22, y: box.minY, width: 22, height: box.height) }

    override func layout() {
        super.layout()
        let h = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: box.minX + 5, y: box.midY - h / 2, width: box.width - 28, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSGradient(starting: Self.top, ending: Self.bottom)?.draw(in: bounds, angle: -90)
        Self.line.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        W7DrawSearchBox(ctx, box, field.currentEditor() != nil, !field.stringValue.isEmpty)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard buttonRect.contains(p) else { return }
        // The glyph is × whenever there is text (W7DrawSearchBox): it clears the box, editing or not; Return
        // searches. An empty box shows the magnifier, which puts the caret in it.
        if !field.stringValue.isEmpty { text = "" }
        focus()
    }

    func controlTextDidChange(_ obj: Notification) { needsDisplay = true }
    func controlTextDidBeginEditing(_ obj: Notification) { needsDisplay = true }
    func controlTextDidEndEditing(_ obj: Notification) { needsDisplay = true }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSearch?(field.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            text = ""
            return true
        default: return false
        }
    }
}

// MARK: - Footer

/// The footer: "More support options" at the left (a link), "Offline Help" at the right, as Windows 7 shows its
/// online/offline state; this Help is always offline. Non-flipped.
@MainActor
final class HelpFooterView: NSView {
    static let height: CGFloat = 30
    var onMoreSupport: (() -> Void)?
    private var hover = false
    private static let font = W7UIFont(12)
    private static let title = HelpTopics.moreSupportLink.title

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var linkRect: NSRect {
        let size = (Self.title as NSString).size(withAttributes: [.font: Self.font])
        return NSRect(x: 30, y: floor((bounds.height - size.height) / 2), width: ceil(size.width), height: ceil(size.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: NSColor(srgbRed: 0xF7 / 255, green: 0xF9 / 255, blue: 0xFC / 255, alpha: 1),
                   ending: NSColor(srgbRed: 0xE6 / 255, green: 0xEC / 255, blue: 0xF4 / 255, alpha: 1))?.draw(in: bounds, angle: -90)
        NSColor(srgbRed: 0xC5 / 255, green: 0xD2 / 255, blue: 0xE1 / 255, alpha: 1).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        HelpWindow.icon(side: 16).draw(in: NSRect(x: 9, y: floor((bounds.height - 16) / 2), width: 16, height: 16))
        var attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: HelpPage.linkColor]
        if hover { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        (Self.title as NSString).draw(at: linkRect.origin, withAttributes: attrs)
        let offline = "Offline Help" as NSString
        let size = offline.size(withAttributes: [.font: Self.font])
        offline.draw(at: NSPoint(x: bounds.width - 12 - size.width, y: floor((bounds.height - size.height) / 2)),
                     withAttributes: [.font: Self.font, .foregroundColor: NSColor(srgbRed: 0x4C / 255, green: 0x60 / 255, blue: 0x7A / 255, alpha: 1)])
    }

    override func resetCursorRects() { addCursorRect(linkRect, cursor: .pointingHand) }

    override func mouseMoved(with event: NSEvent) {
        let h = linkRect.contains(convert(event.locationInWindow, from: nil))
        if h != hover { hover = h; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hover { hover = false; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        if linkRect.contains(convert(event.locationInWindow, from: nil)) { onMoreSupport?() }
    }
}
