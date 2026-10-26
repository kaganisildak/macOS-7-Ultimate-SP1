import AppKit
import Win7ChromeCore
import Win7Core
import Win7Theme

/// Draws the desktop icons over the wallpaper and handles selection, rubber band, drag and drop,
/// keyboard, inline rename and context menus. Flipped, so DesktopLayout's top-left coordinates apply.
@MainActor
final class DesktopView: NSView, NSDraggingSource, NSTextFieldDelegate {
    static let recycleBinType = NSPasteboard.PasteboardType("com.win7mac.desktop.recycle-bin")
    private static let bin = DesktopStore.recycleBinID

    private enum Palette {
        static let hoverFill = NSColor(white: 1, alpha: 0.18)
        static let hoverBorder = NSColor(white: 1, alpha: 0.35)
        static let selectedFill = NSColor(srgbRed: 170 / 255, green: 205 / 255, blue: 240 / 255, alpha: 0.45)
        static let selectedBorder = NSColor(srgbRed: 125 / 255, green: 162 / 255, blue: 206 / 255, alpha: 0.85)
        static let selectedInactiveFill = NSColor(white: 1, alpha: 0.25)
        static let bandFill = NSColor(srgbRed: 51 / 255, green: 153 / 255, blue: 1, alpha: 0.3)
        static let bandBorder = NSColor(srgbRed: 51 / 255, green: 153 / 255, blue: 1, alpha: 0.9)
    }

    private let store: DesktopStore
    private let actions: DesktopActions
    private var layout: DesktopLayout
    /// Shown position of every item, `[col, row]`.
    private var placed: [String: [Int]] = [:]
    private var selection = DesktopSelection()
    private var hoverID: String?
    private var dropTargetID: String?

    private var looks: [String: DesktopLook] = [:]
    private var labelCache: [String: (text: NSAttributedString, height: CGFloat)] = [:]

    // Mouse tracking
    private var downPoint: NSPoint?
    private var downItem: String?
    private var collapseOnUp: String?
    private var dragStarted = false
    private var band: (start: NSPoint, rect: NSRect, base: Set<String>)?
    private var draggingIDs: [String] = []
    private var trackingArea: NSTrackingArea?

    // Rename
    private var renameField: NSTextField?
    private var renamingID: String?

    /// Empty-space menu ▸ Gadgets: opens the gadget gallery.
    var onGadgets: (() -> Void)?

    init(store: DesktopStore, actions: DesktopActions) {
        self.store = store
        self.actions = actions
        layout = DesktopLayout(bounds: .zero, size: store.iconSize)
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, Self.recycleBinType])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reload()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// The Aero arrow (NSCursor.arrow is replaced by ShellCursors), not whatever an app left set.
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    // MARK: Model

    /// Re-lays out from the store: called after every scan and settings change.
    func reload() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        layout = DesktopLayout(bounds: bounds.size, size: store.iconSize)
        let ids = store.orderedIDs
        let arranged = layout.arrange(ids, stored: store.positions, autoArrange: store.autoArrange)
        placed = arranged.display
        if store.isLoaded { store.positions = arranged.stored }
        selection.retain(Set(ids))
        refreshLooks()
        if let r = renamingID {
            if placed[r] == nil { endRename(commit: false) } else { positionRenameField() }
        }
        needsDisplay = true
    }

    private func refreshLooks() {
        var next = store.looks
        let binIcon = store.recycleBinFull
            ? (AssetStore.shared.image("icons/recycle-bin-full.png") ?? NSImage(named: NSImage.trashFullName))
            : (AssetStore.shared.image("icons/recycle-bin-empty.png") ?? NSImage(named: NSImage.trashEmptyName))
        next[Self.bin] = DesktopLook(label: "Recycle Bin", icon: binIcon ?? NSImage(), stamp: .distantPast)
        if labelCache.count > 4000 { labelCache = [:] }
        looks = next
    }

    private var fileNames: [String] { selectedInOrder.filter { $0 != Self.bin } }
    private var selectedInOrder: [String] { DesktopLayout.layoutOrder(placed).filter(selection.selected.contains) }

    func keyStateChanged() {
        if window?.isKeyWindow != true, renamingID != nil { endRename(commit: true) }
        needsDisplay = true
    }

    // MARK: Geometry

    private func cellRect(_ id: String) -> NSRect? {
        guard let p = placed[id], p.count == 2 else { return nil }
        return layout.rect(col: p[0], row: p[1])
    }

    private func iconRect(in cell: NSRect) -> NSRect {
        let s = layout.size.iconSide
        return NSRect(x: cell.midX - s / 2, y: cell.minY + 3, width: s, height: s)
    }

    private func labelRect(in cell: NSRect, height: CGFloat) -> NSRect {
        NSRect(x: cell.minX + 3, y: iconRect(in: cell).maxY + 3, width: cell.width - 6, height: height)
    }

    /// Selected single items show their whole name, as in Windows 7.
    private func showsFullLabel(_ id: String) -> Bool { selection.selected == [id] && renamingID != id }

    private func highlightRect(_ id: String) -> NSRect? {
        guard let cell = cellRect(id) else { return nil }
        let h = labelText(id, width: cell.width - 6, full: showsFullLabel(id)).height
        let bottom = labelRect(in: cell, height: h).maxY + 2
        return NSRect(x: cell.minX + 1, y: cell.minY + 1, width: cell.width - 2, height: bottom - cell.minY - 1)
    }

    private func item(at point: NSPoint) -> String? {
        guard store.showIcons else { return nil }
        // Topmost first: selected items are drawn last.
        for id in drawOrder.reversed() {
            if let r = highlightRect(id), r.contains(point) { return id }
        }
        return nil
    }

    private var drawOrder: [String] {
        let ids = DesktopLayout.layoutOrder(placed)
        return ids.filter { !selection.selected.contains($0) } + ids.filter(selection.selected.contains)
    }

    // MARK: Labels

    private func labelAttributes() -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.8)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        return [.font: W7UIFont(12), .foregroundColor: NSColor.white, .paragraphStyle: style, .shadow: shadow]
    }

    /// The label wrapped to at most two lines with a middle ellipsis, or the full name when `full`.
    private func labelText(_ id: String, width: CGFloat, full: Bool) -> (text: NSAttributedString, height: CGFloat) {
        let name = looks[id]?.label ?? id
        let key = "\(full)|\(width)|\(name)"
        if let hit = labelCache[key] { return hit }
        let attrs = labelAttributes()
        let make = { (s: String) in NSAttributedString(string: s, attributes: attrs) }
        let limit = 2 * NSLayoutManager().defaultLineHeight(for: W7UIFont(12)) + 0.5
        func height(_ s: NSAttributedString) -> CGFloat {
            ceil(s.boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        }
        func fits(_ s: NSAttributedString) -> Bool { height(s) <= limit }
        var result = make(name)
        if !full, !fits(result) {
            let chars = Array(name)
            var lo = 0, hi = chars.count
            while lo < hi {  // largest kept-character count that still fits
                let mid = (lo + hi + 1) / 2
                if fits(make(Self.middleTruncated(chars, keep: mid))) { lo = mid } else { hi = mid - 1 }
            }
            result = make(Self.middleTruncated(chars, keep: lo))
        }
        let entry = (text: result, height: height(result))
        labelCache[key] = entry
        return entry
    }

    private static func middleTruncated(_ chars: [Character], keep: Int) -> String {
        let head = (keep + 1) / 2, tail = keep / 2
        return String(chars.prefix(head)) + "…" + String(chars.suffix(tail))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if store.showIcons {
            let cut = actions.cutNames
            for id in drawOrder {
                guard let cell = cellRect(id), cell.intersects(dirtyRect.insetBy(dx: -40, dy: -200)) else { continue }
                drawItem(id, cell: cell, dimmed: cut.contains(id))
            }
        }
        if let band {
            let r = band.rect.integral.insetBy(dx: 0.5, dy: 0.5)
            Palette.bandFill.setFill()
            r.fill()
            Palette.bandBorder.setStroke()
            let p = NSBezierPath(rect: r)
            p.lineWidth = 1
            p.stroke()
        }
    }

    private func drawItem(_ id: String, cell: NSRect, dimmed: Bool) {
        guard let look = looks[id], let box = highlightRect(id) else { return }
        let selected = selection.selected.contains(id)
        let hovered = hoverID == id || dropTargetID == id
        if selected || hovered {
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            path.lineWidth = 1
            if selected, window?.isKeyWindow == true {
                Palette.selectedFill.setFill(); path.fill()
                Palette.selectedBorder.setStroke(); path.stroke()
            } else if selected {
                Palette.selectedInactiveFill.setFill(); path.fill()
            } else {
                Palette.hoverFill.setFill(); path.fill()
                Palette.hoverBorder.setStroke(); path.stroke()
            }
        }
        let alpha: CGFloat = dimmed ? 0.5 : 1
        icon(for: look).draw(in: iconRect(in: cell), from: .zero, operation: .sourceOver, fraction: alpha,
                             respectFlipped: true, hints: nil)
        guard renamingID != id else { return }
        let text = labelText(id, width: cell.width - 6, full: showsFullLabel(id)).text
        let rect = labelRect(in: cell, height: box.maxY - 2 - (iconRect(in: cell).maxY + 3))
        if dimmed {
            NSGraphicsContext.current?.cgContext.setAlpha(alpha)
            text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            NSGraphicsContext.current?.cgContext.setAlpha(1)
        } else {
            text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    /// The user's icon override (`Assets/icons/folder.png`, `file-text.png`, `app-<bundle id>.png`, …) when its
    /// PNG exists, else the Windows 7 folder art for folders, at the current icon size; a custom icon, or an
    /// application or file without an override, draws its own icon (IconOverrideNames.choice).
    private func icon(for look: DesktopLook) -> NSImage {
        let side = layout.size.iconSide
        switch IconOverrideNames.choice(art: look.art, file: look.fileIcon, available: IconOverrides.has) {
        case .override(let name): return IconOverrides.image(name, side: side) ?? look.icon
        case .drawn(let art): return DesktopFolderIcons.image(art, side: side) ?? look.icon
        case .own: return look.icon
        }
    }

    /// The item as drawn on screen (icon, label and selection box), for the drag image.
    private func dragImage(frame: NSRect) -> NSImage {
        let image = NSImage(size: frame.size)
        if let rep = bitmapImageRepForCachingDisplay(in: frame) {
            cacheDisplay(in: frame, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        var hit = item(at: p)
        // Only hover when nothing (an app window) covers the desktop at this point.
        if hit != nil, let w = window,
           NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) != w.windowNumber {
            hit = nil
        }
        if hit != hoverID { hoverID = hit; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverID != nil { hoverID = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        window?.makeKey()
        if renamingID != nil { endRename(commit: true) }
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags
        let hit = item(at: p)
        downPoint = p
        downItem = hit
        collapseOnUp = nil
        dragStarted = false
        if let id = hit {
            if event.clickCount >= 2 {
                if !selection.selected.contains(id) { selection.click(id, order: layoutOrder) }
                openSelection()
                downItem = nil
            } else if flags.contains(.command) {
                selection.commandClick(id)
            } else if flags.contains(.shift) {
                selection.shiftClick(id, order: layoutOrder)
            } else if selection.selected.contains(id) {
                collapseOnUp = id  // keep a multi-selection so it can be dragged
            } else {
                selection.click(id, order: layoutOrder)
            }
        } else {
            if !flags.contains(.command), !flags.contains(.shift) { selection.clear() }
            band = (p, NSRect(origin: p, size: .zero), selection.selected)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if var b = band {
            b.rect = NSRect(x: min(b.start.x, p.x), y: min(b.start.y, p.y),
                            width: abs(p.x - b.start.x), height: abs(p.y - b.start.y))
            band = b
            let hits = store.showIcons ? layout.itemsIntersecting(b.rect, positions: placed) : []
            selection.set(b.base.union(hits))
            needsDisplay = true
            return
        }
        guard let id = downItem, let start = downPoint, !dragStarted, selection.selected.contains(id),
              hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        dragStarted = true
        collapseOnUp = nil
        beginDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        if band != nil {
            band = nil
            needsDisplay = true
        }
        if let id = collapseOnUp, !dragStarted {
            selection.click(id, order: layoutOrder)
            needsDisplay = true
        }
        collapseOnUp = nil
    }

    private var layoutOrder: [String] { DesktopLayout.layoutOrder(placed) }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeKey()
        if renamingID != nil { endRename(commit: true) }
        window?.makeFirstResponder(self)
        let hit = item(at: convert(event.locationInWindow, from: nil))
        let context: DesktopMenuContext
        if let id = hit {
            if !selection.selected.contains(id) { selection.click(id, order: layoutOrder) }
            context = id == Self.bin ? .recycleBin : .items(count: fileNames.count)
        } else {
            selection.clear()
            context = .empty(canPaste: actions.canPaste, undo: actions.undoLabel)
        }
        display(bounds)  // show the selection before the menu's tracking loop runs
        let menu = contextMenu(context)
        NSApp.activate()
        ShellMenus.show(menu, at: NSEvent.mouseLocation)
    }

    // MARK: Context menus

    private func contextMenu(_ context: DesktopMenuContext) -> NSMenu {
        let titles = DesktopMenuModel.titles(for: context)
        switch context {
        case .items:
            let names = fileNames
            var subs = ["Send to ▸": sendToMenu(names)]
            if names.count == 1 { subs["Open with ▸"] = openWithMenu(names[0]) }
            return actions.menu(titles, context: context, submenus: subs) { [weak self] title in
                guard let self else { return }
                switch title {
                case "Open": self.openSelection()
                case "Cut": self.actions.cut(names); self.needsDisplay = true
                case "Copy": self.actions.copy(names); self.needsDisplay = true
                case "Create shortcut": self.actions.createShortcuts(names) { created in self.place(created, at: nil) }
                case "Delete": self.confirmDelete(names)
                case "Rename": if let n = names.first { self.beginRename(n) }
                case "Properties": self.actions.properties(names)
                default: break
                }
            }
        case .recycleBin:
            return actions.menu(titles, context: context) { [weak self] title in
                guard let self else { return }
                switch title {
                case "Open": self.actions.openRecycleBin()
                case "Empty Recycle Bin": self.actions.emptyRecycleBin()
                case "Properties": self.actions.recycleBinProperties()
                default: break
                }
            }
        case .empty:
            let subs = ["View ▸": viewMenu(), "Sort by ▸": sortMenu(), "New ▸": newMenu()]
            return actions.menu(titles, context: context, submenus: subs) { [weak self] title in
                guard let self else { return }
                switch title {
                case "Refresh": self.store.rescan()
                case "Paste": self.actions.paste { names in self.place(names, at: nil) }
                case "Paste shortcut": self.actions.pasteShortcuts { names in self.place(names, at: nil) }
                case "Undo": self.undo()
                case "Screen resolution": ShellScreens.open(.screenResolution)
                case "Gadgets": self.onGadgets?()
                case "Personalize":   // The Windows 7 Personalization window
                    ShellWindowButtons.log.info("desktop: Personalize chosen")
                    ShellScreens.open(.personalization)
                default: break
                }
            }
        }
    }

    private func viewMenu() -> NSMenu {
        let sizes: [String: DesktopIconSize] = ["Large icons": .large, "Medium icons": .medium, "Small icons": .small]
        var checked: Set<String> = ["Align icons to grid"]
        if let current = sizes.first(where: { $0.value == store.iconSize })?.key { checked.insert(current) }
        if store.autoArrange { checked.insert("Auto arrange icons") }
        if store.showIcons { checked.insert("Show desktop icons") }
        // Positions are stored as grid cells, so the grid can't be turned off.
        return actions.menu(DesktopMenuModel.viewTitles, checked: checked, disabled: ["Align icons to grid"]) { [weak self] title in
            guard let self else { return }
            if let size = sizes[title] {
                self.store.iconSize = size
                self.labelCache = [:]
            } else if title == "Auto arrange icons" {
                self.store.autoArrange.toggle()
            } else if title == "Show desktop icons" {
                self.store.showIcons.toggle()
                self.selection.clear()
            }
            self.reload()
        }
    }

    private func sortMenu() -> NSMenu {
        let sorts: [String: DesktopSort] = ["Name": .name, "Size": .size, "Item type": .type, "Date modified": .dateModified]
        return actions.menu(DesktopMenuModel.sortTitles) { [weak self] title in
            guard let self, let sort = sorts[title] else { return }
            // Sorting rearranges once, Recycle Bin first; manual positions are replaced.
            self.store.sort = sort
            self.store.positions = self.layout.arrange(self.store.orderedIDs, stored: [:], autoArrange: true).display
            self.reload()
        }
    }

    private func newMenu() -> NSMenu {
        actions.menu(DesktopMenuModel.newTitles, disabled: DesktopMenuModel.newDisabled) { [weak self] title in
            guard let self else { return }
            let created: (String) -> Void = { [weak self] name in
                self?.place([name], at: nil) { self?.beginRename(name) }
            }
            switch title {
            case "Folder": self.actions.newFolder(done: created)
            case "Text Document": self.actions.newTextDocument(done: created)
            case "Rich Text Document": self.actions.newRichTextDocument(done: created)
            default: break
            }
        }
    }

    /// Open with ▸: the item's applications (default first) with their icons, then Choose default program….
    /// Filled lazily (menuNeedsUpdate) when the submenu opens, so the context menu doesn't wait on
    /// LaunchServices.
    private func openWithMenu(_ name: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let filler = OpenWithFiller(name: name, actions: actions)
        menu.delegate = filler
        objc_setAssociatedObject(menu, &OpenWithFiller.key, filler, .OBJC_ASSOCIATION_RETAIN)  // delegate is weak
        return menu
    }

    private func sendToMenu(_ names: [String]) -> NSMenu {
        actions.menu(DesktopMenuModel.sendToTitles) { [weak self] title in
            guard let self else { return }
            switch title {
            case "Compressed (zipped) folder": self.actions.compress(names) { zip in self.place([zip], at: nil) }
            case "Desktop (create shortcut)": self.actions.createShortcuts(names) { created in self.place(created, at: nil) }
            case "Mail recipient": self.actions.mail(names)
            default: break
            }
        }
    }

    /// Delete asks first, as Windows 7 does.
    private func confirmDelete(_ names: [String]) {
        guard !names.isEmpty else { return }
        let look = names.count == 1 ? looks[names[0]] : nil
        actions.confirmTrash(names, icon: look.map(icon(for:)))
    }

    /// Undo: a rename keeps the item's cell; items moved back out of a folder take free cells.
    private func undo() {
        actions.undo { [weak self] action, names in
            guard let self else { return }
            if case .rename(let from, let to) = action {
                // Keyed by the name the undo actually produced (it can differ from `from`).
                var stored = self.store.positions
                if let cell = stored.removeValue(forKey: to) { stored[names.first ?? from] = cell }
                self.store.positions = stored
                self.selection.set(Set(names))
                self.store.rescan()
            } else {
                self.place(names, at: nil)
            }
        }
    }

    /// Records grid cells for new names (first free cell from `cell`, column-major), selects them and
    /// rescans. Cells recorded for names not shown yet count as taken, so two quick batches don't
    /// collide. Rescanning right away discards any scan that started before the names existed.
    private func place(_ names: [String], at cell: (col: Int, row: Int)?, then: (() -> Void)? = nil) {
        var stored = store.positions
        let others = { (d: [String: [Int]]) in Set(d.filter { !names.contains($0.key) }.values) }
        var occupied = others(placed).union(others(stored))
        for n in names {
            let c = layout.firstFreeCell(occupied: occupied, from: cell ?? (0, 0))
            stored[n] = [c.col, c.row]
            occupied.insert([c.col, c.row])
        }
        store.positions = stored
        selection.set(Set(names))
        store.rescan(then: then)
    }

    /// Persists new cells for `ids` only, leaving other stored positions alone.
    private func storeMoved(_ ids: [String], _ moved: [String: [Int]]) {
        var stored = store.positions
        for id in ids { stored[id] = moved[id] }
        store.positions = stored
        reload()
    }

    // MARK: Opening

    private func openSelection() {
        let ids = selectedInOrder
        if ids.contains(Self.bin) { actions.openRecycleBin() }
        actions.open(ids.filter { $0 != Self.bin })
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 123: moveSelection(.left)
        case 124: moveSelection(.right)
        case 125: moveSelection(.down)
        case 126: moveSelection(.up)
        case 36, 76: openSelection()
        case 51, 117: confirmDelete(fileNames)  // Delete, Cmd+Backspace, forward delete
        case 120: if selection.selected.count == 1, let n = fileNames.first { beginRename(n) }  // F2
        default:
            if !handleCommand(event) { super.keyDown(with: event) }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        // The shell has no Edit menu, so the rename field's editor gets these directly.
        if let editor = renameField?.currentEditor() {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": editor.selectAll(nil)
            case "c": editor.copy(nil)
            case "x": editor.cut(nil)
            case "v": editor.paste(nil)
            case "z":   // Cmd+Shift+Z redoes, never undoes
                if event.modifierFlags.contains(.shift) { editor.undoManager?.redo() } else { editor.undoManager?.undo() }
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        return handleCommand(event) || super.performKeyEquivalent(with: event)
    }

    /// Cmd+A, Cmd+C, Cmd+X, Cmd+V, Cmd+Z.
    private func handleCommand(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": if store.showIcons { selection.set(Set(placed.keys)) }
        case "c": actions.copy(fileNames)
        case "x": actions.cut(fileNames)
        case "v": actions.paste { [weak self] names in self?.place(names, at: nil) }
        case "z":
            guard !event.modifierFlags.contains(.shift) else { return false }   // Cmd+Shift+Z is redo, not undo
            undo()
        default: return false
        }
        needsDisplay = true
        return true
    }

    private func moveSelection(_ direction: Arrow) {
        guard store.showIcons else { return }
        let from = selection.anchor ?? selectedInOrder.first
        guard let from else {
            if let first = layoutOrder.first { selection.click(first, order: layoutOrder) }
            needsDisplay = true
            return
        }
        if let next = DesktopLayout.neighbor(of: from, direction, positions: placed) {
            selection.click(next, order: layoutOrder)
            needsDisplay = true
        }
    }

    // MARK: Rename

    func beginRename(_ name: String) {
        guard name != Self.bin, placed[name] != nil, store.showIcons else { return }
        endRename(commit: false)
        selection.click(name, order: layoutOrder)
        renamingID = name
        let field = NSTextField(string: name)
        field.font = W7UIFont(12)
        field.alignment = .center
        field.isBordered = true
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = .white
        field.textColor = .black
        field.focusRingType = .none
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.delegate = self
        renameField = field
        addSubview(field)
        positionRenameField()
        window?.makeKey()
        window?.makeFirstResponder(field)
        let url = store.url(for: name)
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let isFolder = values?.isDirectory == true && values?.isPackage != true
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: FileNaming.baseLength(of: name, keepExtension: !isFolder))
        needsDisplay = true
    }

    private func positionRenameField() {
        guard let id = renamingID, let field = renameField, let cell = cellRect(id) else { return }
        let top = iconRect(in: cell).maxY + 2
        let lineHeight = NSLayoutManager().defaultLineHeight(for: W7UIFont(12))
        field.frame = NSRect(x: cell.minX + 1, y: top, width: cell.width - 2, height: ceil(lineHeight * 3) + 4)
    }

    private func endRename(commit: Bool) {
        guard let old = renamingID, let field = renameField else { return }
        renamingID = nil
        renameField = nil
        let newName = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
        guard commit, newName != old else { return }
        let cell = placed[old]  // captured now: a rescan may drop `old` before the rename completes
        actions.rename(old, to: newName) { [weak self] final in
            guard let self else { return }
            var stored = self.store.positions
            stored.removeValue(forKey: old)
            if let cell { stored[final] = cell }
            self.store.positions = stored
            self.selection.click(final, order: self.layoutOrder)
            self.store.rescan()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): endRename(commit: true); return true
        case #selector(NSResponder.cancelOperation(_:)): endRename(commit: false); return true
        default: return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endRename(commit: true)
    }

    // MARK: Drag source

    private func beginDrag(_ event: NSEvent) {
        let ids = selectedInOrder
        guard !ids.isEmpty else { return }
        draggingIDs = ids
        let items: [NSDraggingItem] = ids.compactMap { id in
            guard let frame = highlightRect(id) else { return nil }
            let writer: NSPasteboardWriting
            if id == Self.bin {
                let pb = NSPasteboardItem()
                pb.setString("", forType: Self.recycleBinType)
                writer = pb
            } else {
                writer = store.url(for: id) as NSURL
            }
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(frame, contents: dragImage(frame: frame))
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .withinApplication: return [.move, .copy, .link]
        default: return fileNames.isEmpty ? [] : [.copy, .move, .link]
        }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggingIDs = []
        dragStarted = false
        store.scheduleRescan()  // another app may have moved the files away
    }

    // MARK: Drop target

    /// A dropped file URL with the facts the drop policy needs, read once per drag.
    private struct DropSource { let url: URL; let fromDesktop: Bool; let sameVolume: Bool }
    private var dropSources: [DropSource]?

    private func sources(_ info: NSDraggingInfo) -> [DropSource] {
        if let dropSources { return dropSources }
        let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                        options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let found = urls.map {
            DropSource(url: $0, fromDesktop: store.files.contains($0),
                       sameVolume: DesktopFiles.sameVolume($0, store.files.directory))
        }
        dropSources = found
        return found
    }

    private func isFromSelf(_ info: NSDraggingInfo) -> Bool { (info.draggingSource as AnyObject?) === self }

    /// The folder icon under a drag of desktop items (not one being dragged), which they would move into.
    private func folderTarget(_ info: NSDraggingInfo) -> String? {
        guard isFromSelf(info), let id = item(at: convert(info.draggingLocation, from: nil)), id != Self.bin,
              !draggingIDs.contains(id), looks[id]?.isFolder == true,
              draggingIDs.contains(where: { $0 != Self.bin }) else { return nil }
        return id
    }

    /// Over the Recycle Bin, unless the Recycle Bin itself is being dragged (then it just moves).
    private func isOverBin(_ info: NSDraggingInfo) -> Bool {
        guard item(at: convert(info.draggingLocation, from: nil)) == Self.bin else { return false }
        return !(isFromSelf(info) && draggingIDs.contains(Self.bin))
    }

    /// Option held, or a source that only allows copying.
    private func optionHeld(_ info: NSDraggingInfo) -> Bool {
        NSEvent.modifierFlags.contains(.option) || !info.draggingSourceOperationMask.contains(.move)
    }

    private func action(_ s: DropSource, option: Bool) -> DesktopDropAction {
        DesktopDropPolicy.action(fromDesktop: s.fromDesktop, sameVolume: s.sameVolume, optionHeld: option, ontoRecycleBin: false)
    }

    private func dropOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        let onBin = isOverBin(info)
        let target = onBin ? Self.bin : folderTarget(info)
        if target != dropTargetID { dropTargetID = target; needsDisplay = true }
        if isFromSelf(info) { return .move }
        let srcs = sources(info)
        guard !srcs.isEmpty else { return [] }
        if onBin { return .move }
        let option = optionHeld(info)
        return srcs.contains { action($0, option: option) == .copy } ? .copy : .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropSources = nil
        return dropOperation(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropSources = nil
        if dropTargetID != nil { dropTargetID = nil; needsDisplay = true }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropSources = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropTargetID = nil
        needsDisplay = true
        let p = convert(sender.draggingLocation, from: nil)
        let onBin = isOverBin(sender)

        if isFromSelf(sender) {
            if onBin {
                actions.trash(draggingIDs)
                return true
            }
            if let folder = folderTarget(sender) {
                actions.move(draggingIDs.filter { $0 != Self.bin }, into: folder)
                return true
            }
            return reposition(draggingIDs, dropPoint: p)
        }

        let srcs = sources(sender)
        dropSources = nil
        guard !srcs.isEmpty else { return false }
        if onBin {
            actions.trash(urls: srcs.map(\.url))
            return true
        }
        let option = optionHeld(sender)
        var transfers: [DesktopTransfer] = [], here: [String] = []
        for s in srcs {
            switch action(s, option: option) {
            case .reposition: here.append(s.url.lastPathComponent)
            case .copy: transfers.append(DesktopTransfer(url: s.url, copy: true))
            case .move: transfers.append(DesktopTransfer(url: s.url, copy: false))
            case .trash: break
            }
        }
        let cell = layout.cell(at: p)
        if !here.isEmpty, !store.autoArrange {
            storeMoved(here, layout.move(here, primary: here[0], to: cell, positions: placed))
        }
        // One sequential batch, so collision names can't race; partial results are still placed.
        actions.transfer(transfers) { [weak self] names in self?.place(names, at: cell) }
        return true
    }

    /// Snaps the dragged items to the cell under the dragged primary item's new position.
    private func reposition(_ ids: [String], dropPoint p: NSPoint) -> Bool {
        guard !store.autoArrange, let start = downPoint, let primary = downItem ?? ids.first,
              let cell = cellRect(primary) else { return false }
        let moved = NSPoint(x: cell.midX + p.x - start.x, y: cell.midY + p.y - start.y)
        storeMoved(ids, layout.move(ids, primary: primary, to: layout.cell(at: moved), positions: placed))
        return true
    }
}

/// Fills the Open with ▸ submenu the first time it is about to show.
@MainActor
private final class OpenWithFiller: NSObject, NSMenuDelegate {
    nonisolated(unsafe) static var key = 0
    private let name: String
    private weak var actions: DesktopActions?
    private var filled = false

    init(name: String, actions: DesktopActions) {
        self.name = name
        self.actions = actions
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !filled, let actions else { return }
        filled = true
        let name = name
        for app in actions.applications(toOpen: name) {
            let id = Bundle(url: app)?.bundleIdentifier
            // Windows names (): TextEdit is Notepad here too.
            let title = ProgramNames.displayName(bundleID: id,
                                                 macName: (FileManager.default.displayName(atPath: app.path) as NSString).deletingPathExtension)
            // The application's `app-<bundle id>` override, else its own icon.
            let icon = IconOverrides.app(id, side: 16) ?? NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            menu.addItem(DesktopActions.item(title, image: icon) { [weak actions] in actions?.open(name, with: app) })
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        menu.addItem(DesktopActions.item(DesktopMenuModel.chooseDefaultProgram) { [weak actions] in
            actions?.chooseDefaultProgram(name)
        })
    }
}
