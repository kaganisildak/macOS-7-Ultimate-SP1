import AppKit
import Win7Core
import Win7Theme

/// What the white body of the Control Panel shows.
enum ControlPanelBodyPage {
    /// The home page by category: each category with its sub-links.
    case categories([(category: ControlPanelCategory, links: [ControlPanelLink])])
    /// The home page as Large or Small icons: every item in a flat grid.
    case icons([ControlPanelItem], ControlPanelViewMode)
    /// A category page or search results: items with their task links.
    case items([ControlPanelItem])
    /// One of the shell's info pages.
    case info(title: String, text: String)
    /// A grey line of text (no search results).
    case message(String)
}

/// The body: white, flipped, laid out by ControlPanelLayout; links underline on hover and show the hand.
@MainActor
final class ControlPanelBodyView: NSView {
    var onTarget: ((ControlPanelTarget) -> Void)?
    var onViewMode: ((ControlPanelViewMode) -> Void)?
    /// The height the scroll view should give the body (at least its visible height).
    private(set) var contentHeight: CGFloat = 0

    private var page: ControlPanelBodyPage = .message("")
    private var viewMode: ControlPanelViewMode = .category
    private struct Run { var text: String; var rect: NSRect; var font: NSFont; var color: NSColor; var hot: Int? }
    private var runs: [Run] = []
    private var icons: [(image: NSImage, rect: NSRect)] = []
    /// Icon-view cells, highlighted while hovered.
    private var cells: [(rect: NSRect, hot: Int)] = []
    private var hots: [ControlPanelHot] = []
    private var viewByRect = NSRect.zero
    private var hover: Int?
    private var pressed: Int?
    private var pressedViewBy = false
    private let infoText = NSTextField(wrappingLabelWithString: "")

    private static let headingFont = W7UIFont(15)
    private static let titleFont = W7UIFont(14)
    private static let linkFont = W7UIFont(12)
    private static let headingTop: CGFloat = 16
    private static let listTop: CGFloat = 60

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        infoText.font = Self.linkFont
        infoText.textColor = .black
        infoText.isSelectable = true
        infoText.drawsBackground = true
        infoText.backgroundColor = .white
        infoText.isHidden = true
        addSubview(infoText)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A click acts even while the shell isn't the active app (as the taskbar's do).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ page: ControlPanelBodyPage, viewMode: ControlPanelViewMode, width: CGFloat) {
        self.page = page
        self.viewMode = viewMode
        rebuild(width: width)
    }

    /// Lays the page out for `width` and records its height.
    func rebuild(width: CGFloat) {
        runs = []; icons = []; cells = []; hots = []; iconHots = [:]; hover = nil; viewByRect = .zero
        infoText.isHidden = true
        var bottom: CGFloat = 0
        switch page {
        case .categories(let list):
            homeHeader(width: width)
            let frames = ControlPanelLayout.listFrames(linkCounts: list.map(\.links.count), width: width, top: Self.listTop,
                                                       icon: ControlPanelLayout.categoryIcon)
            for (entry, frame) in zip(list, frames) {
                let target = ControlPanelTarget.navigate(.category(entry.category))
                addEntry(frame, icon: ControlPanelIcons.category(entry.category, side: ControlPanelLayout.categoryIcon),
                         iconSide: ControlPanelLayout.categoryIcon, title: entry.category.title, target: target, links: entry.links)
            }
            bottom = ControlPanelLayout.contentHeight(frames, top: Self.listTop)
        case .icons(let items, let mode):
            homeHeader(width: width)
            let frames = ControlPanelLayout.iconFrames(count: items.count, width: width, mode: mode, top: Self.listTop)
            let side = ControlPanelLayout.iconSide(mode)
            for (item, cell) in zip(items, frames) {
                let hot = addHot(cell, .perform(ControlPanelLink(item.title, item.action)))
                cells.append((cell, hot))
                icons.append((ControlPanelIcons.item(item, side: side), NSRect(x: cell.minX + 4, y: cell.midY - side / 2, width: side, height: side)))
                let x = cell.minX + 4 + side + 8
                let h = ceil(Self.linkFont.ascender - Self.linkFont.descender + Self.linkFont.leading) + 1
                runs.append(Run(text: item.title, rect: NSRect(x: x, y: cell.midY - h / 2, width: cell.maxX - 4 - x, height: h),
                                font: Self.linkFont, color: ControlPanelText.linkBlue, hot: hot))
            }
            bottom = ControlPanelLayout.contentHeight(frames, top: Self.listTop)
        case .items(let items):
            let top = Self.headingTop + 2
            let frames = ControlPanelLayout.listFrames(linkCounts: items.map(\.tasks.count), width: width, top: top,
                                                       icon: ControlPanelLayout.itemIcon)
            for (item, frame) in zip(items, frames) {
                addEntry(frame, icon: ControlPanelIcons.item(item, side: ControlPanelLayout.itemIcon), iconSide: ControlPanelLayout.itemIcon,
                         title: item.title, target: .perform(ControlPanelLink(item.title, item.action)), links: item.tasks)
            }
            bottom = ControlPanelLayout.contentHeight(frames, top: top)
        case .info(let title, let text):
            let m = ControlPanelLayout.margin
            runs.append(Run(text: title, rect: NSRect(x: m, y: Self.headingTop, width: width - 2 * m, height: 22),
                            font: Self.headingFont, color: ControlPanelText.navy, hot: nil))
            let w = max(100, min(600, width - 2 * m))
            infoText.stringValue = text
            infoText.preferredMaxLayoutWidth = w
            let h = ceil(infoText.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 10_000)).height ?? 100)
            infoText.frame = NSRect(x: m, y: Self.headingTop + 34, width: w, height: h)
            infoText.isHidden = false
            bottom = infoText.frame.maxY + m
        case .message(let text):
            let m = ControlPanelLayout.margin
            runs.append(Run(text: text, rect: NSRect(x: m, y: Self.headingTop + 2, width: width - 2 * m, height: 18),
                            font: Self.linkFont, color: ControlPanelText.grey, hot: nil))
            bottom = Self.headingTop + 40
        }
        contentHeight = bottom
        // A text cut short shows in full as its tooltip (the view doesn't retain a tooltip's owner).
        removeAllToolTips()
        let cut = runs.filter { ControlPanelText.width($0.text, $0.font) > $0.rect.width + 0.5 }
        tooltipOwners = cut.map { NSString(string: $0.text) }
        for (run, owner) in zip(cut, tooltipOwners) {
            addToolTip(run.rect, owner: owner, userData: nil)
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func addHot(_ rect: NSRect, _ target: ControlPanelTarget) -> Int {
        hots.append(ControlPanelHot(rect: rect, target: target))
        return hots.count - 1
    }

    /// "Adjust your computer's settings" and, at the right, "View by: Category ▾".
    private func homeHeader(width: CGFloat) {
        let m = ControlPanelLayout.margin
        let label = "View by:", mode = viewMode.title + " ▾"
        let lw = ControlPanelText.width(label, Self.linkFont), mw = ControlPanelText.width(mode, Self.linkFont)
        let x = max(m + 220, width - m - mw)
        viewByRect = NSRect(x: x - 2, y: Self.headingTop + 2, width: mw + 4, height: 20)
        runs.append(Run(text: "Adjust your computer's settings", rect: NSRect(x: m, y: Self.headingTop, width: max(0, x - lw - 12 - m), height: 22),
                        font: Self.headingFont, color: ControlPanelText.navy, hot: nil))
        runs.append(Run(text: label, rect: NSRect(x: x - lw - 6, y: Self.headingTop + 4, width: lw, height: 18),
                        font: Self.linkFont, color: ControlPanelText.navy, hot: nil))
    }

    /// An icon, a blue title and its sub-links under it, inside `frame`.
    private func addEntry(_ frame: NSRect, icon: NSImage, iconSide: CGFloat, title: String, target: ControlPanelTarget,
                          links: [ControlPanelLink]) {
        let hot = addHot(NSRect(x: frame.minX, y: frame.minY, width: iconSide, height: iconSide), target)
        icons.append((icon, NSRect(x: frame.minX, y: frame.minY, width: iconSide, height: iconSide)))
        let x = frame.minX + iconSide + ControlPanelLayout.iconTextGap, avail = max(0, frame.maxX - x)
        let titleRect = NSRect(x: x, y: frame.minY, width: min(avail, ControlPanelText.width(title, Self.titleFont)),
                               height: ControlPanelLayout.titleLine)
        hots.append(ControlPanelHot(rect: titleRect, target: target))
        runs.append(Run(text: title, rect: titleRect, font: Self.titleFont, color: ControlPanelText.linkBlue, hot: hots.count - 1))
        iconHots[hot] = hots.count - 1   // the icon and the title are one link: hovering either underlines the title
        for (k, link) in links.enumerated() {
            let r = NSRect(x: x, y: frame.minY + ControlPanelLayout.titleLine + CGFloat(k) * ControlPanelLayout.linkLine,
                           width: min(avail, ControlPanelText.width(link.title, Self.linkFont)), height: ControlPanelLayout.linkLine)
            let h = addHot(r, .perform(link))
            runs.append(Run(text: link.title, rect: r, font: Self.linkFont, color: ControlPanelText.navy, hot: h))
        }
    }

    private var tooltipOwners: [NSString] = []
    /// Icon hot index -> its title's hot index.
    private var iconHots: [Int: Int] = [:]

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let hovered = hover.map { iconHots[$0] ?? $0 }
        for cell in cells where cell.hot == hover {
            W7DrawNavPaneRow(ctx, cell.rect, false, true)
        }
        for icon in icons where icon.rect.intersects(dirtyRect) {
            icon.image.draw(in: icon.rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        for run in runs where run.rect.intersects(dirtyRect) {
            let underline = run.hot != nil && run.hot == hovered && cells.isEmpty
            (run.text as NSString).draw(with: run.rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                        attributes: ControlPanelText.attributes(run.font, run.color, underline: underline))
        }
        if viewByRect != .zero {   // the "View by" choice, a link with a ▾
            let r = viewByRect
            (viewMode.title + " ▾" as NSString).draw(with: NSRect(x: r.minX + 2, y: r.minY + 2, width: r.width - 4, height: 18),
                                                     options: [.usesLineFragmentOrigin],
                                                     attributes: ControlPanelText.attributes(Self.linkFont, ControlPanelText.linkBlue,
                                                                                             underline: pressedViewBy || hoverViewBy))
        }
    }

    private var hoverViewBy = false

    override func resetCursorRects() {
        for h in hots { addCursorRect(h.rect, cursor: .pointingHand) }
        if viewByRect != .zero { addCursorRect(viewByRect, cursor: .pointingHand) }
    }

    // MARK: Mouse

    private func point(_ event: NSEvent) -> NSPoint { convert(event.locationInWindow, from: nil) }
    private func hot(at p: NSPoint) -> Int? { hots.indices.first { hots[$0].rect.contains(p) } }

    override func mouseMoved(with event: NSEvent) {
        let p = point(event)
        let h = hot(at: p), v = viewByRect.contains(p)
        if h != hover || v != hoverViewBy { hover = h; hoverViewBy = v; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hover != nil || hoverViewBy { hover = nil; hoverViewBy = false; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let p = point(event)
        if viewByRect.contains(p) { showViewMenu(); return }
        pressed = hot(at: p)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard let h = hot(at: point(event)), h == pressed else { return }
        onTarget?(hots[h].target)
    }

    /// "View by" choices: Category, Large icons, Small icons; the current one checked.
    private func showViewMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for mode in ControlPanelViewMode.allCases {
            let item = MenuAction.item(mode.title) { [weak self] in self?.onViewMode?(mode) }
            item.state = mode == viewMode ? .on : .off
            menu.addItem(item)
        }
        pressedViewBy = true
        needsDisplay = true
        if let window {
            let below = window.convertPoint(toScreen: convert(NSPoint(x: viewByRect.minX, y: viewByRect.maxY + 2), to: nil))
            ShellMenus.show(menu, at: below)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: viewByRect.minX, y: viewByRect.maxY + 2), in: self)
        }
        pressedViewBy = false
        needsDisplay = true
    }
}
