import AppKit
import UniformTypeIdentifiers
import Win7ChromeCore
import Win7Core
import Win7Theme

/// Which list a program row belongs to. Pinned and recent programs get the large rows.
private enum ProgramSection { case pinned, recent, other }

/// One row of the programs pane.
private enum LeftRow {
    case program(AppEntry, ProgramSection, depth: Int)
    case folder(String, expanded: Bool)
    case file(FileHit)
    case header(String)
    case separator
    case seeMore
    case message(String)

    var isSelectable: Bool {
        switch self {
        case .program, .folder, .file, .seeMore: return true
        case .header, .separator, .message: return false
        }
    }
}

/// Something that can be clicked or highlighted.
private enum Target: Equatable {
    case row(Int)          // index into `rows`
    case allPrograms
    case place(Int)        // index into `places`
    case shutDown
    case shutDownArrow
    case clearSearch
}

private struct Hit {
    var rect: NSRect
    var target: Target
}

private enum PlaceAction {
    case open(URL)
    case run
    case controlPanel      // the shell's Windows 7 Control Panel
    case shellWindow(ShellWindowTarget)   // Devices and Printers, Help and Support
    case controlPanelItem(String)         // a Control Panel item by catalogue id: Default Programs
    case computer          // Finder's Computer location, the Windows 7 Computer view
}

private struct Place {
    var title: String
    /// Assets/icons/<icon>.png, shown in the user tile while the place is highlighted.
    var icon: String?
    var action: PlaceAction
}

@MainActor
final class StartMenuContentView: NSView, NSTextFieldDelegate {
    weak var owner: StartMenuWindow?

    private static let font = W7UIFont(12)
    private static let largeRowHeight: CGFloat = 38
    private static let minLargeRowHeight: CGFloat = 30
    private static let smallRowHeight: CGFloat = 24
    private static let headerHeight: CGFloat = 22
    private static let separatorHeight: CGFloat = 7
    private static let messageHeight: CGFloat = 30
    private static let indent: CGFloat = 16
    private static let allProgramsHeight: CGFloat = 30
    private static let rightRowHeight: CGFloat = 26
    private static let separatorGap: CGFloat = 12
    /// The light line between pinned and recent programs, and above All Programs.
    private static let paneLine = NSColor(srgbRed: 0xD5 / 255, green: 0xE0 / 255, blue: 0xEE / 255, alpha: 1)
    private static let headerText = NSColor(srgbRed: 0x1E / 255, green: 0x39 / 255, blue: 0x5B / 255, alpha: 1)
    private static let greyText = NSColor(srgbRed: 0x6D / 255, green: 0x6D / 255, blue: 0x6D / 255, alpha: 1)
    /// Text on the dark glass of the right column.
    private static let glassTextShadow: NSShadow = {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.6)
        s.shadowOffset = NSSize(width: 0, height: -1)
        s.shadowBlurRadius = 2
        return s
    }()

    private let search = NSTextField()
    private let programs = StartMenuPrograms()
    private let fileSearch = StartMenuFileSearch()
    private var catalog: [AppEntry] = []
    private var tree: [ProgramNode] = []
    private var showAll = false
    private var expanded: Set<String> = []
    private var rows: [LeftRow] = []
    /// Each row's top and height, measured from the top of the list before scrolling.
    private var rowTops: [CGFloat] = []
    private var rowHeights: [CGFloat] = []
    private var scroll: CGFloat = 0
    private var hits: [Hit] = []
    private var focus = StartMenuFocus()
    private var iconCache: [String: NSImage] = [:]
    /// The right column; nil is a separator.
    private let places = StartMenuContentView.makePlaces()
    /// The program row whose jump-list ▸ the pointer is over, and the dwell that opens its list. A
    /// list closed with the pointer still on its ▸ does not reopen until the pointer leaves it.
    private var arrowState = StartMenuJumpList.ArrowHover()
    private var arrowHover: Int? { arrowState.row }
    private var arrowTimer: Timer?
    /// The line between a highlighted row and its ▸ (the menu highlight's border colour).
    private static let arrowLine = NSColor(srgbRed: 0xAE / 255, green: 0xCF / 255, blue: 0xF7 / 255, alpha: 1)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A plain field drawn inside the Windows 7 search box (W7DrawSearchBox), with the grey italic hint.
        search.isBordered = false
        search.isBezeled = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.font = StartMenuContentView.font
        search.cell?.isScrollable = true
        search.cell?.usesSingleLineMode = true
        let italic = NSFontManager.shared.convert(StartMenuContentView.font, toHaveTrait: .italicFontMask)
        search.placeholderAttributedString = NSAttributedString(string: "Search programs and files", attributes: [
            .font: italic, .foregroundColor: StartMenuContentView.greyText,
        ])
        let box = searchBoxRect
        let h = ceil(search.intrinsicContentSize.height)
        search.frame = NSRect(x: box.minX + 5, y: box.midY - h / 2, width: box.width - 26, height: h)
        search.delegate = self
        addSubview(search)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        fileSearch.onResults = { [weak self] in self?.refreshRows(keepFocus: true) }
        AppCatalogCache.shared.onChange = { [weak self] in self?.catalogChanged() }
        catalogChanged()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: State

    func reset() {
        showAll = false
        expanded = []
        scroll = 0
        focus = StartMenuFocus()
        search.stringValue = ""
        fileSearch.cancel()
        programs.forgetJumpLists()
        catalogChanged()
    }

    /// The menu closed: no search keeps running behind it, no jump list waits to open.
    func stop() {
        fileSearch.cancel()
        cancelArrowHover()
    }

    func focusSearch() { window?.makeFirstResponder(search) }

    private func catalogChanged() {
        catalog = ProgramNames.renamed(AppCatalogCache.shared.apps)   // Windows names
        tree = ProgramTree.build(catalog, roots: AppCatalogCache.shared.roots)
        refreshRows(keepFocus: true)
    }

    private var query: String { search.stringValue.trimmingCharacters(in: .whitespaces) }
    private var isSearching: Bool { !query.isEmpty }

    /// Rebuilds the programs pane for the current mode: search results, All Programs, or pinned and
    /// recent programs.
    private func refreshRows(keepFocus: Bool) {
        cancelArrowHover()   // row indexes change; the next mouse move finds the arrow again
        rows = []
        if isSearching {
            let found = AppCatalog.search(query, in: catalog, extraTerms: ProgramNames.searchTerms)
            let files = fileSearch.resultsText == query ? fileSearch.results : []
            var sections = StartMenuSearchResults.sections(programs: found, files: files, limit: .max)
            if !sections.isEmpty {
                // As many results per group as the pane shows without scrolling.
                let free = searchListHeight - StartMenuContentView.smallRowHeight
                    - CGFloat(sections.count) * StartMenuContentView.headerHeight
                let capacity = Int(free / StartMenuContentView.smallRowHeight)
                sections = StartMenuSearchResults.sections(programs: found, files: files,
                                                           limit: max(3, capacity / sections.count))
            }
            for section in sections {
                rows.append(.header(section.title))
                for item in section.items {
                    switch item {
                    case .program(let e): rows.append(.program(e, .other, depth: 0))
                    case .file(let f): rows.append(.file(f))
                    }
                }
            }
            if sections.isEmpty, fileSearch.resultsText == query { rows.append(.message("No items match your search.")) }
            rows.append(.seeMore)
        } else if showAll {
            for row in ProgramTree.rows(tree, expanded: expanded) {
                switch row.kind {
                case .app(let e): rows.append(.program(e, .other, depth: row.depth))
                case .folder(let name, let open): rows.append(.folder(name, expanded: open))
                }
            }
        } else {
            let s = programs.sections(catalog: catalog)
            rows += s.pinned.map { .program($0, .pinned, depth: 0) }
            if !s.pinned.isEmpty && !s.recent.isEmpty { rows.append(.separator) }
            rows += s.recent.map { .program($0, .recent, depth: 0) }
        }
        layoutRows()
        if keepFocus { focus.clamp(focusCounts) }
        needsDisplay = true
    }

    private func layoutRows() {
        let large: CGFloat = {
            let count = rows.filter { if case .program(_, let s, _) = $0 { return s != .other } else { return false } }.count
            guard count > 0 else { return StartMenuContentView.largeRowHeight }
            let seps = CGFloat(rows.filter { if case .separator = $0 { return true } else { return false } }.count)
            // Windows 7 shrinks the rows rather than scroll the recent programs.
            let fit = floor((listRect.height - seps * StartMenuContentView.separatorHeight) / CGFloat(count))
            return min(StartMenuContentView.largeRowHeight, max(StartMenuContentView.minLargeRowHeight, fit))
        }()
        rowTops = []
        rowHeights = []
        var y: CGFloat = 0
        for row in rows {
            let h: CGFloat
            switch row {
            case .program(_, let s, _): h = s == .other ? StartMenuContentView.smallRowHeight : large
            case .folder, .file, .seeMore: h = StartMenuContentView.smallRowHeight
            case .header: h = StartMenuContentView.headerHeight
            case .separator: h = StartMenuContentView.separatorHeight
            case .message: h = StartMenuContentView.messageHeight
            }
            rowTops.append(y)
            rowHeights.append(h)
            y += h
        }
    }

    // MARK: Focus

    private var selectableRows: [Int] { rows.indices.filter { rows[$0].isSelectable } }

    private var placeCount: Int { places.compactMap { $0 }.count }

    private var focusCounts: StartMenuFocus.Counts {
        StartMenuFocus.Counts(programs: selectableRows.count + (isSearching ? 0 : 1), places: placeCount, power: 2)
    }

    private func target(for f: StartMenuFocus) -> Target? {
        guard let zone = f.zone else { return nil }
        switch zone {
        case .programs:
            let selectable = selectableRows
            return f.index < selectable.count ? .row(selectable[f.index]) : .allPrograms
        case .places: return .place(f.index)
        case .power: return f.index == 0 ? .shutDown : .shutDownArrow
        }
    }

    private func focus(for t: Target) -> StartMenuFocus? {
        switch t {
        case .row(let i): return selectableRows.firstIndex(of: i).map { StartMenuFocus(zone: .programs, index: $0) }
        case .allPrograms: return StartMenuFocus(zone: .programs, index: selectableRows.count)
        case .place(let i): return StartMenuFocus(zone: .places, index: i)
        case .shutDown: return StartMenuFocus(zone: .power, index: 0)
        case .shutDownArrow: return StartMenuFocus(zone: .power, index: 1)
        case .clearSearch: return nil
        }
    }

    private var highlighted: Target? { target(for: focus) }

    /// Scrolls the programs list so the focused row shows.
    private func scrollToFocus() {
        guard case .row(let i)? = highlighted, rowTops.indices.contains(i) else { return }
        let h = listRect.height
        if rowTops[i] < scroll { scroll = rowTops[i] }
        if rowTops[i] + rowHeights[i] > scroll + h { scroll = rowTops[i] + rowHeights[i] - h }
    }

    // MARK: Layout (flipped)

    /// The white programs pane, inset in the glass.
    private var paneRect: NSRect { unflip(W7StartMenuProgramsRect(bounds, StartMenuWindow.leftPaneWidth)) }

    private var searchBoxRect: NSRect { unflip(W7StartMenuSearchBoxRect(bounds, StartMenuWindow.leftPaneWidth)) }

    private var listRect: NSRect {
        let pane = paneRect
        let bottom = pane.maxY - W7StartMenuSearchBandHeight
            - (isSearching ? 0 : StartMenuContentView.allProgramsHeight)
        return NSRect(x: pane.minX, y: pane.minY + 4, width: pane.width, height: bottom - pane.minY - 4)
    }

    private var searchListHeight: CGFloat { paneRect.height - W7StartMenuSearchBandHeight - 4 }

    /// Converts between this flipped view and the non-flipped coordinates the theme draws in.
    private func unflip(_ r: NSRect) -> NSRect { NSRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height) }

    /// Runs `draw` with the context flipped back to the theme's bottom-left origin.
    private func unflipped(_ ctx: CGContext, _ draw: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        draw()
        ctx.restoreGState()
    }

    private var hasUserPicture: Bool { AssetStore.shared.image("icons/user.png") != nil }

    /// The right column in Windows 7 order. Windows 7 starts it with the user's name, which opens their
    /// folder. Computer, Default Programs and Help and Support open their Windows 7 screens.
    private static func makePlaces() -> [Place?] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            Place(title: NSFullUserName(), icon: nil, action: .open(home)),
            Place(title: "Documents", icon: "documents", action: .open(home.appendingPathComponent("Documents"))),
            Place(title: "Pictures", icon: "pictures", action: .open(home.appendingPathComponent("Pictures"))),
            Place(title: "Music", icon: "music", action: .open(home.appendingPathComponent("Music"))),
            Place(title: "Downloads", icon: "folder-downloads", action: .open(home.appendingPathComponent("Downloads"))),
            nil,
            Place(title: "Computer", icon: "computer", action: .computer),
            nil,
            Place(title: "Control Panel", icon: "control-panel", action: .controlPanel),
            Place(title: "Devices and Printers", icon: "devices", action: .shellWindow(.devicesAndPrinters)),
            // The Control Panel item (the default web browser is chosen in Desktop & Dock).
            Place(title: "Default Programs", icon: "cp-" + StartMenuPlaces.defaultProgramsItemID,
                  action: .controlPanelItem(StartMenuPlaces.defaultProgramsItemID)),
            Place(title: "Help and Support", icon: "help", action: .shellWindow(.help)),
            nil,
            Place(title: "Run…", icon: nil, action: .run),
        ]
    }

    /// Where the right column's separators go (flipped y).
    private var separatorYs: [CGFloat] = []

    private func buildHits() {
        hits = []
        separatorYs = []
        let list = listRect
        let total = (rowTops.last ?? 0) + (rowHeights.last ?? 0)
        scroll = max(0, min(scroll, total - list.height))
        for i in rows.indices where rows[i].isSelectable {
            let r = rowRect(i)
            if r.maxY < list.minY || r.minY > list.maxY { continue }
            hits.append(Hit(rect: r, target: .row(i)))
        }
        if !isSearching {
            hits.append(Hit(rect: NSRect(x: list.minX + 4, y: list.maxY + 1, width: list.width - 8,
                                         height: StartMenuContentView.allProgramsHeight - 2),
                            target: .allPrograms))
        }
        var y = W7StartMenuPlacesTop(hasUserPicture)
        let rx = StartMenuWindow.leftPaneWidth + 8
        var index = 0
        for place in places {
            if place != nil {
                hits.append(Hit(rect: NSRect(x: rx, y: y, width: bounds.width - rx - 8, height: StartMenuContentView.rightRowHeight),
                                target: .place(index)))
                index += 1
                y += StartMenuContentView.rightRowHeight
            } else {
                separatorYs.append(y + StartMenuContentView.separatorGap / 2)
                y += StartMenuContentView.separatorGap
            }
        }
        let by = searchBoxRect.midY - 13
        hits.append(Hit(rect: NSRect(x: rx, y: by, width: 92, height: 26), target: .shutDown))
        hits.append(Hit(rect: NSRect(x: rx + 92, y: by, width: 24, height: 26), target: .shutDownArrow))
        if isSearching {
            // The × that replaces the magnifier, right of the text field.
            let box = searchBoxRect
            hits.append(Hit(rect: NSRect(x: box.maxX - 21, y: box.minY, width: 21, height: box.height), target: .clearSearch))
        }
    }

    private func rowRect(_ i: Int) -> NSRect {
        let list = listRect
        return NSRect(x: list.minX + 4, y: list.minY + rowTops[i] - scroll, width: list.width - 8, height: rowHeights[i])
    }

    private func place(_ i: Int) -> Place? {
        let list = places.compactMap { $0 }
        return list.indices.contains(i) ? list[i] : nil
    }

    // MARK: Drawing

    private func icon(for path: String) -> NSImage {
        if let i = iconCache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = i
        return i
    }

    /// A program's `app-<bundle id>` override (Assets/icons), else its own icon.
    private func icon(for entry: AppEntry, side: CGFloat) -> NSImage {
        IconOverrides.app(entry.bundleID, side: side) ?? icon(for: entry.path)
    }

    /// A folder row's icon: the user's `folder.png`, else the system folder icon.
    private func folderIcon(side: CGFloat) -> NSImage {
        IconOverrides.image("folder", side: side) ?? systemFolderIcon
    }

    private lazy var systemFolderIcon = NSWorkspace.shared.icon(for: .folder)

    /// A search hit's icon comes from its type, so the file itself is never touched: the user's override for
    /// the type (`folder.png` for folders, `file-text.png`, …), else the system icon for it. Applications and
    /// packages (`.rtfd`, `.pages`) always keep the system icon.
    private func icon(for file: FileHit, side: CGFloat) -> NSImage {
        let type = file.contentType.flatMap { UTType($0) }
        if let override = IconOverrideNames.typeIcon(type).flatMap({ IconOverrides.image($0, side: side) }) { return override }
        let key = "type:" + (file.contentType ?? "")
        if let i = iconCache[key] { return i }
        let i = NSWorkspace.shared.icon(for: type ?? .data)
        iconCache[key] = i
        return i
    }

    private func text(_ s: String, at p: NSPoint, color: NSColor, font: NSFont = StartMenuContentView.font,
                      shadow: NSShadow? = nil, maxWidth: CGFloat? = nil) {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let shadow { attrs[.shadow] = shadow }
        let h = (s as NSString).size(withAttributes: attrs).height
        if let maxWidth {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            attrs[.paragraphStyle] = style
            (s as NSString).draw(in: NSRect(x: p.x, y: p.y - h / 2, width: maxWidth, height: h), withAttributes: attrs)
        } else {
            (s as NSString).draw(at: NSPoint(x: p.x, y: p.y - h / 2), withAttributes: attrs)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        ShellPerf.measure("startMenuDraw") { drawContent(dirtyRect) }
    }

    /// An icon at the size it is drawn, rendered once per key, size and scale, instead of
    /// scaling NSWorkspace's full icon on every draw.
    private func drawn(_ key: String, side: CGFloat, _ source: () -> NSImage) -> NSImage {
        ScaledIconCache.shared.icon(key, side: side, scale: window?.backingScaleFactor ?? 2, source: source)
    }

    private func drawContent(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        buildHits()
        let lw = StartMenuWindow.leftPaneWidth
        let pane = paneRect
        unflipped(ctx) {
            W7DrawStartMenuBackground(ctx, bounds, lw, W7StartMenuSearchBandHeight)
            W7DrawSearchBox(ctx, unflip(searchBoxRect), search.currentEditor() != nil, isSearching)
            for y in separatorYs { W7DrawStartMenuSeparator(ctx, lw + 12, bounds.width - 12, bounds.height - y) }
        }

        // Programs pane
        let list = listRect
        ctx.saveGState()
        ctx.clip(to: list)
        for i in rows.indices {
            let r = rowRect(i)
            if r.maxY < list.minY || r.minY > list.maxY { continue }
            let lit = highlighted == .row(i)
            let arrow = lit && jumpSections(row: i) != nil   // Windows 7 shows the ▸ on the highlighted program
            drawRow(ctx, rows[i], in: r, highlighted: lit, arrow: arrow)
            if arrow { drawJumpArrow(ctx, r, hot: arrowHover == i) }
        }
        ctx.restoreGState()

        // Right column: the user picture in its glass frame, then the places.
        if let user = AssetStore.shared.image("icons/user.png") {
            // Windows 7 shows the user picture, or the highlighted place's icon, in a framed tile.
            var picture = user
            if case .place(let i)? = highlighted,
               let name = place(i)?.icon.flatMap({ IconOverrideNames.placeIcon($0, available: IconOverrides.has) }),
               let image = AssetStore.shared.image("icons/\(name).png") {
                picture = image
            }
            let tile = unflip(W7StartMenuUserTileRect(bounds, lw))
            unflipped(ctx) { W7DrawUserTileFrame(ctx, unflip(tile)) }
            let clip = NSBezierPath(roundedRect: tile, xRadius: 2, yRadius: 2)
            ctx.saveGState()
            clip.addClip()
            picture.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            ctx.restoreGState()
        }
        for h in hits {
            let lit = highlighted == h.target
            switch h.target {
            case .allPrograms:
                StartMenuContentView.paneLine.setFill()
                NSRect(x: pane.minX + 8, y: h.rect.minY - 1, width: pane.width - 16, height: 1).fill()
                if lit { drawHighlight(ctx, h.rect) }
                W7DrawChevron(ctx, CGPoint(x: h.rect.minX + 16, y: h.rect.midY), showAll ? .left : .right, 0x000000, 1)
                text(showAll ? "Back" : "All Programs", at: NSPoint(x: h.rect.minX + 42, y: h.rect.midY), color: .black)
            case .place(let i):
                if lit { unflipped(ctx) { W7DrawTaskbarButton(ctx, unflip(h.rect), true, false, true) } }
                text(place(i)?.title ?? "", at: NSPoint(x: h.rect.minX + 10, y: h.rect.midY), color: .white,
                     shadow: StartMenuContentView.glassTextShadow, maxWidth: h.rect.width - 14)
            case .shutDown:
                drawButton(ctx, h.rect, "Shut down", hover: lit)
            case .shutDownArrow:
                drawButton(ctx, h.rect, nil, hover: lit)
            case .row, .clearSearch: break
            }
        }
    }

    /// The ▸ at the right end of a highlighted program with a jump list, after a thin line; its own highlight while
    /// the pointer is on it.
    private func drawJumpArrow(_ ctx: CGContext, _ r: NSRect, hot: Bool) {
        let a = arrowRect(r)
        if hot { drawHighlight(ctx, a) }
        StartMenuContentView.arrowLine.setFill()
        NSRect(x: a.minX, y: r.minY + 4, width: 1, height: r.height - 8).fill()
        W7DrawChevron(ctx, CGPoint(x: a.midX + 0.5, y: a.midY), .right, 0x000000, 0.8)
    }

    private func drawRow(_ ctx: CGContext, _ row: LeftRow, in r: NSRect, highlighted lit: Bool, arrow: Bool = false) {
        if lit { drawHighlight(ctx, r) }
        let small: CGFloat = 16
        func smallItem(_ image: NSImage, _ title: String, depth: Int) {
            let x = r.minX + 6 + CGFloat(depth) * StartMenuContentView.indent
            image.draw(in: NSRect(x: x, y: r.midY - small / 2, width: small, height: small))
            text(title, at: NSPoint(x: x + small + 6, y: r.midY), color: .black, maxWidth: r.maxX - x - small - 10)
        }
        switch row {
        case .program(let e, let section, let depth):
            if section == .other {
                smallItem(drawn("path:" + e.path, side: small) { icon(for: e, side: small) }, e.name, depth: depth)
            } else {
                let side = min(28, r.height - 6)
                drawn("path:" + e.path, side: side) { icon(for: e, side: side) }
                    .draw(in: NSRect(x: r.minX + 6, y: r.midY - side / 2, width: side, height: side))
                text(e.name, at: NSPoint(x: r.minX + 42, y: r.midY), color: .black,
                     maxWidth: r.width - 46 - (arrow ? StartMenuJumpList.arrowWidth : 0))
            }
        case .folder(let name, _):
            smallItem(drawn("folder", side: small) { folderIcon(side: small) }, name, depth: 0)
        case .file(let f):
            smallItem(drawn("type:" + (f.contentType ?? ""), side: small) { icon(for: f, side: small) }, f.name, depth: 0)
        case .header(let title):
            let bold = NSFontManager.shared.convert(StartMenuContentView.font, toHaveTrait: .boldFontMask)
            text(title, at: NSPoint(x: r.minX + 6, y: r.midY), color: StartMenuContentView.headerText, font: bold)
            let w = (title as NSString).size(withAttributes: [.font: bold]).width
            StartMenuContentView.paneLine.setFill()
            NSRect(x: r.minX + 12 + w, y: floor(r.midY), width: max(0, r.maxX - 4 - (r.minX + 12 + w)), height: 1).fill()
        case .separator:
            StartMenuContentView.paneLine.setFill()
            NSRect(x: r.minX + 4, y: floor(r.midY), width: r.width - 8, height: 1).fill()
        case .seeMore:
            text("See more results", at: NSPoint(x: r.minX + 28, y: r.midY), color: .black)
        case .message(let message):
            text(message, at: NSPoint(x: r.minX + 8, y: r.midY), color: StartMenuContentView.greyText)
        }
    }

    private func drawHighlight(_ ctx: CGContext, _ r: NSRect) {
        unflipped(ctx) { W7DrawMenuHighlight(ctx, unflip(r)) }
    }

    /// The Shut down button and its arrow: framed glass, brighter on hover. `title` nil draws the ▸.
    private func drawButton(_ ctx: CGContext, _ r: NSRect, _ title: String?, hover: Bool) {
        unflipped(ctx) { W7DrawTaskbarButton(ctx, unflip(r), true, false, hover) }
        guard let title else {
            W7DrawChevron(ctx, CGPoint(x: r.midX, y: r.midY), .right, 0xFFFFFF, 1)
            return
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: StartMenuContentView.font, .foregroundColor: NSColor.white,
                                                    .shadow: StartMenuContentView.glassTextShadow]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
    }

    // MARK: Mouse

    private func hit(at p: NSPoint) -> Hit? {
        hits.first { h in
            guard h.rect.contains(p) else { return false }
            if case .row = h.target { return listRect.contains(p) }
            return true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        buildHits()
        let p = convert(event.locationInWindow, from: nil)
        let target = hit(at: p)?.target
        let f = target.flatMap { focus(for: $0) } ?? StartMenuFocus()
        if f != focus { focus = f; needsDisplay = true }
        updateArrowHover(target: target, at: p)
    }

    override func mouseExited(with event: NSEvent) {
        cancelArrowHover()
        focus = StartMenuFocus()
        needsDisplay = true
    }

    // MARK: Jump-list arrows

    /// Program row `i`'s jump-list rows when it shows the ▸: a pinned or recent program in the normal list (not search
    /// results or All Programs) with recent documents or, for Windows Explorer, frequent folders.
    private func jumpSections(row i: Int) -> [JumpListSection]? {
        guard !isSearching, !showAll, rows.indices.contains(i), case .program(let e, let section, _) = rows[i] else { return nil }
        let sections = programs.jumpSections(e)
        return StartMenuJumpList.showsArrow(listed: section != .other, sections: sections) ? sections : nil
    }

    private func arrowRect(_ row: NSRect) -> NSRect {
        NSRect(x: row.maxX - StartMenuJumpList.arrowWidth, y: row.minY, width: StartMenuJumpList.arrowWidth, height: row.height)
    }

    /// Pointing at a row's ▸ highlights it and, after the dwell, opens its list.
    private func updateArrowHover(target: Target?, at p: NSPoint) {
        var over: Int?
        if case .row(let i)? = target, jumpSections(row: i) != nil, arrowRect(rowRect(i)).contains(p) { over = i }
        let before = arrowState.row
        let arm = arrowState.pointer(over: over)
        guard arrowState.row != before else { return }
        arrowTimer?.invalidate()
        arrowTimer = nil
        needsDisplay = true
        guard arm, let i = over else { return }
        arrowTimer = Timer.scheduledTimer(withTimeInterval: StartMenuJumpList.hoverDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.arrowHover == i, self.window?.isVisible == true else { return }
                self.openJumpList(row: i)
            }
        }
    }

    private func cancelArrowHover() {
        arrowTimer?.invalidate()
        arrowTimer = nil
        if arrowHover != nil { needsDisplay = true }
        arrowState.reset()
    }

    /// Shows program row `i`'s Frequent and Recent rows (the taskbar jump list's) right of the programs pane, over the
    /// right column, as Windows 7 does; choosing one opens it with the program.
    private func openJumpList(row i: Int) {
        guard let sections = jumpSections(row: i), case .program(let e, _, _) = rows[i], let window else { return }
        arrowTimer?.invalidate()
        arrowTimer = nil
        arrowState.open(row: i)
        focus = focus(for: .row(i)) ?? focus
        display()
        let menu = NSMenu()
        menu.autoenablesItems = false
        W7MenuSetLeftClosesRoot(menu, true)   // Left closes the list, as in Windows 7
        for section in sections {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            if let title = section.title { menu.addItem(MenuAction.item(title, enabled: false) {}) }
            for item in section.items {
                let row = MenuAction.item(item.title) { [weak self] in self?.performJump(item.action, entry: e) }
                row.image = jumpIcon(item.action)
                menu.addItem(row)
            }
        }
        let top = window.convertPoint(toScreen: convert(NSPoint(x: paneRect.maxX - 1, y: rowRect(i).minY), to: nil))
        popUp(menu, topLeft: top)
        // Closed (Esc, Left, a click outside): resting on the same ▸ does not open it again.
        arrowTimer?.invalidate()
        arrowTimer = nil
        arrowState.listClosed(row: i)
        needsDisplay = true
    }

    private func performJump(_ action: JumpListAction, entry e: AppEntry) {
        owner?.close()
        switch action {
        case .openRecent(let path):
            if let id = e.bundleID { TaskbarLaunch.open(path: path, bundleID: id) } else { StartMenuPrograms.open(path) }
        case .openFolder(let path): TaskbarLaunch.openFolder(path: path)
        default: break
        }
    }

    /// A row's icon from its type only (the file itself is never touched), as search hits get theirs.
    private func jumpIcon(_ action: JumpListAction) -> NSImage? {
        switch action {
        case .openFolder: return drawn("folder", side: 16) { folderIcon(side: 16) }
        case .openRecent(let path):
            let type = UTType(filenameExtension: (path as NSString).pathExtension)?.identifier
            let hit = FileHit(name: "", path: path, kind: .document, contentType: type)
            return drawn("type:" + (type ?? ""), side: 16) { icon(for: hit, side: 16) }
        default: return nil
        }
    }

    override func scrollWheel(with event: NSEvent) {
        scroll -= event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10)
        needsDisplay = true
    }

    /// The menu may not be the key window when the shell's activation was refused (another app stayed
    /// frontmost): the first click must still choose the item instead of only activating the shell.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // The rows may have changed since the last draw (file results, a pin): hit-test the current ones.
        buildHits()
        let p = convert(event.locationInWindow, from: nil)
        guard let h = hit(at: p) else { return }
        // A click on the ▸ opens the jump list at once instead of starting the program.
        if case .row(let i) = h.target, jumpSections(row: i) != nil, arrowRect(h.rect).contains(p) {
            openJumpList(row: i)
            return
        }
        activate(h.target, anchor: h.rect)
    }

    override func rightMouseDown(with event: NSEvent) {
        buildHits()
        guard let h = hit(at: convert(event.locationInWindow, from: nil)), case .row(let i) = h.target,
              rows.indices.contains(i) else { return }
        focus = focus(for: h.target) ?? focus
        needsDisplay = true
        switch rows[i] {
        case .program(let e, let section, _): showContextMenu(programMenu(e, removable: section == .recent))
        case .file(let f): showContextMenu(fileMenu(f))
        default: break
        }
    }

    // MARK: Actions

    private func activate(_ target: Target, anchor: NSRect) {
        switch target {
        case .row(let i): activateRow(i)
        case .allPrograms:
            let keyboard = focus.zone == .programs
            showAll.toggle()
            expanded = []
            scroll = 0
            refreshRows(keepFocus: false)
            if keyboard { focus = StartMenuFocus(zone: .programs, index: focusCounts.programs - 1) }
        case .place(let i):
            guard let p = place(i) else { return }
            owner?.close()
            switch p.action {
            case .open(let url): NSWorkspace.shared.open(url)
            case .run: RunDialog.shared.present()
            case .controlPanel:
                ShellWindowButtons.log.info("start menu: Control Panel chosen")
                ControlPanelWindow.shared.show()
            case .shellWindow(let target):
                ShellScreens.open(target)
            case .controlPanelItem(let id):
                // An item this Mac can't open: the Control Panel's Programs page, where it would be.
                if !ControlPanelWindow.shared.openItem(id) { ControlPanelWindow.shared.show(.category(.programs)) }
            case .computer:
                StartMenuPrograms.openComputer()
            }
        case .shutDown:
            owner?.close()
            PowerActions.perform(.shutDown)
        case .shutDownArrow: showPowerMenu(anchor: anchor)
        case .clearSearch:
            // Windows 7: the × clears the search and shows the program list again.
            search.abortEditing()
            search.stringValue = ""
            fileSearch.cancel()
            showAll = false
            scroll = 0
            focus = StartMenuFocus()
            refreshRows(keepFocus: false)
            window?.makeFirstResponder(search)
        }
    }

    private func activateRow(_ i: Int) {
        guard rows.indices.contains(i) else { return }
        switch rows[i] {
        case .program(let e, _, _): launch(e)
        case .folder(let name, _):
            SoundPlayer.play(.navigation)   // Windows Navigation Start
            ProgramTree.toggle(name, in: &expanded)
            let wasFocused = highlighted == .row(i)
            refreshRows(keepFocus: true)
            if wasFocused, let f = focus(for: .row(i)) { focus = f }
            buildHits()
            scrollToFocus()
        case .file(let f):
            owner?.close()
            StartMenuPrograms.open(f.path)
        case .seeMore:
            let text = query
            owner?.close()
            StartMenuFileSearch.openMoreResults(text)
        case .header, .separator, .message: break
        }
    }

    private func launch(_ e: AppEntry) {
        let inAllPrograms = showAll && !isSearching
        owner?.close()
        programs.launch(e, inAllPrograms: inAllPrograms)
    }

    // MARK: Menus

    /// Windows 7's context menu for a program in the Start menu.
    private func programMenu(_ e: AppEntry, removable: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(MenuAction.item("Open") { [weak self] in self?.launch(e) })
        menu.addItem(MenuAction.item("Open file location") { [weak self] in
            self?.owner?.close()
            StartMenuPrograms.reveal(e.path)
        })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item(programs.isTaskbarPinned(e) ? "Unpin from Taskbar" : "Pin to Taskbar",
                                     enabled: e.bundleID != nil) { [weak self] in
            self?.programs.toggleTaskbarPin(e)
        })
        menu.addItem(MenuAction.item(programs.isPinned(e) ? "Unpin from Start menu" : "Pin to Start menu") { [weak self] in
            self?.programs.togglePin(e)
            self?.refreshRows(keepFocus: true)
        })
        if removable {
            menu.addItem(.separator())
            menu.addItem(MenuAction.item("Remove from this list") { [weak self] in
                self?.programs.removeFromList(e)
                self?.refreshRows(keepFocus: true)
            })
        }
        return menu
    }

    private func fileMenu(_ f: FileHit) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(MenuAction.item("Open") { [weak self] in
            self?.owner?.close()
            StartMenuPrograms.open(f.path)
        })
        menu.addItem(MenuAction.item("Open file location") { [weak self] in
            self?.owner?.close()
            StartMenuPrograms.reveal(f.path)
        })
        return menu
    }

    private func showContextMenu(_ menu: NSMenu) {
        popUp(menu, topLeft: NSEvent.mouseLocation)
    }

    /// Tracks `menu` (synchronously) while the Start menu stays open behind it.
    private func popUp(_ menu: NSMenu, topLeft: NSPoint) {
        guard let owner, let window else { return }
        owner.popupActive = true
        NSApp.activate()
        ShellMenus.show(menu, at: topLeft)
        owner.popupActive = false
        if !window.isKeyWindow { owner.close() } else { window.makeFirstResponder(search) }
        needsDisplay = true
    }

    private static var submenuActions: [(String, PowerAction)] {
        var list: [(String, PowerAction)] = []
        if PowerActions.canSwitchUser { list.append(("Switch user", .switchUser)) }
        return list + [("Log off", .logOff), ("Lock", .lock), ("Restart", .restart), ("Sleep", .sleep)]
    }

    private func showPowerMenu(anchor: NSRect) {
        guard let window else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, action) in StartMenuContentView.submenuActions {
            menu.addItem(MenuAction.item(title) { [weak self] in
                self?.owner?.close()
                PowerActions.perform(action)
            })
        }
        let screenRect = window.convertToScreen(convert(anchor, to: nil))
        let height = W7MenuItemHeight * CGFloat(menu.numberOfItems) + 4
        popUp(menu, topLeft: NSPoint(x: screenRect.maxX, y: screenRect.maxY + height - 4))
    }

    // MARK: Search field and keyboard

    func controlTextDidChange(_ obj: Notification) {
        scroll = 0
        if !isSearching { showAll = false }
        fileSearch.update(query)
        refreshRows(keepFocus: false)
        // Windows 7 highlights the first result as you type, so Enter opens it.
        focus = StartMenuFocus()
        if isSearching, let first = selectableRows.first {
            if case .seeMore = rows[first] {} else { focus = StartMenuFocus(zone: .programs, index: 0) }
        }
        needsDisplay = true
    }

    func controlTextDidBeginEditing(_ obj: Notification) { needsDisplay = true }   // the box's focus border
    func controlTextDidEndEditing(_ obj: Notification) { needsDisplay = true }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let key: StartMenuFocus.Key
        switch selector {
        case #selector(NSResponder.moveUp(_:)): key = .up
        case #selector(NSResponder.moveDown(_:)): key = .down
        case #selector(NSResponder.moveLeft(_:)): key = .left
        case #selector(NSResponder.moveRight(_:)): key = .right
        case #selector(NSResponder.insertTab(_:)): key = .tab
        case #selector(NSResponder.insertBacktab(_:)): key = .backTab
        case #selector(NSResponder.insertNewline(_:)):
            if let t = highlighted {
                buildHits()
                activate(t, anchor: hits.first { $0.target == t }?.rect ?? .zero)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            owner?.close()
            return true
        default: return false
        }
        // Right on a program with a jump list opens it, as in Windows 7 (no list: on to the right column).
        if key == .right, case .row(let i)? = highlighted, jumpSections(row: i) != nil {
            openJumpList(row: i)
            return true
        }
        // While a search is typed, Left and Right move the caret unless the right column has the focus.
        if key == .left || key == .right, isSearching, focus.zone == nil || focus.zone == .programs { return false }
        guard focus.handle(key, focusCounts) else { return false }
        buildHits()
        scrollToFocus()
        needsDisplay = true
        return true
    }
}
