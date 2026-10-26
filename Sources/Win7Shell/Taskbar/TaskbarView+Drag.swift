import AppKit
import Win7Core
import Win7Theme

/// Button presses that become drags (reorder pinned buttons, drag up for the jump list), and the
/// overflow paging arrows.
extension TaskbarView {
    // MARK: Paging

    var paging: TaskbarPaging {
        TaskbarPaging(count: items.count, available: max(0, trayMinX - TaskbarView.orbWidth), buttonWidth: TaskbarView.buttonWidth)
    }
    var visibleRange: Range<Int> { paging.range(page: page) }

    /// The up/down paging arrows at the right end of the button area, when the buttons overflow.
    var pagerRect: NSRect? {
        guard paging.showsArrows else { return nil }
        return NSRect(x: trayMinX - TaskbarPaging.arrowWidth, y: 0, width: TaskbarPaging.arrowWidth, height: bounds.height)
    }

    /// 0: the up arrow (top half), 1: the down arrow.
    func arrowRect(_ arrow: Int) -> NSRect? {
        guard let r = pagerRect else { return nil }
        let h = (r.height / 2).rounded(.down)
        return arrow == 0 ? NSRect(x: r.minX, y: r.maxY - h, width: r.width, height: h)
                          : NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height - h)
    }

    func drawPager(_ ctx: CGContext) {
        guard let up = arrowRect(0), let down = arrowRect(1) else { return }
        for (arrow, r) in [(0, up), (1, down)] {
            let enabled = arrow == 0 ? paging.canPageUp(page) : paging.canPageDown(page)
            if enabled && hoverArrow == arrow { W7DrawTaskbarButton(ctx, r.insetBy(dx: 1, dy: 1), false, false, true) }
            W7DrawChevron(ctx, CGPoint(x: r.midX, y: r.midY), arrow == 0 ? .up : .down, 0xFFFFFF, enabled ? 1 : 0.35)
        }
    }

    /// A press on a paging arrow turns the page; false when `p` is not on one.
    func pagerClick(at p: NSPoint) -> Bool {
        guard let arrow = [0, 1].first(where: { arrowRect($0)?.contains(p) == true }) else { return false }
        turn(to: paging.clamped(page + (arrow == 0 ? -1 : 1)))
        return true
    }

    /// Brings button `i` onto the current page (a keyboard click or focus on a button paged away).
    func show(index i: Int) {
        turn(to: paging.page(containing: i))
    }

    private func turn(to next: Int) {
        guard next != page else { return }
        page = next
        hoverIndex = nil
        cancelThumbnailHover()
        onThumbnailHoverEnd?()
        needsDisplay = true
    }

    // MARK: Drags

    override func mouseDragged(with event: NSEvent) {
        guard var press, let i = items.firstIndex(where: { $0.bundleID == press.bundleID }) else { return }
        let p = convert(event.locationInWindow, from: nil)
        if press.gesture == nil {
            switch TaskbarDrag.gesture(dx: p.x - press.start.x, dy: p.y - press.start.y, isPinned: items[i].isPinned) {
            case .jumpList?:
                self.press = nil
                openJumpList(i)
                return
            case .reorder?:
                press.gesture = .reorder
                press.remembered = rememberedApp()
                cancelThumbnailHover()
                onButtonClick?()   // closes any preview
            case nil:
                return
            }
        }
        self.press = press
        // Live reorder among the pinned buttons on this page (pinned buttons come first, so they
        // run from the page's first slot to its last pinned one).
        let pinCount = items.prefix { $0.isPinned }.count
        let firstX = TaskbarView.orbWidth
        let maxX = buttonRect(min(pinCount - 1, visibleRange.upperBound - 1)).minX
        let x = min(max(p.x - press.grab, firstX), max(firstX, maxX))
        dragX = x
        let slot = TaskbarPinOrder.slot(centerX: x + TaskbarView.buttonWidth / 2, firstX: firstX, buttonWidth: TaskbarView.buttonWidth,
                                        firstIndex: visibleRange.lowerBound, pinCount: pinCount)
        if slot != i {
            pins = TaskbarPinOrder.moved(pins, bundleID: press.bundleID, to: slot)
            items = currentItems()
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let press else { return }
        self.press = nil
        if press.gesture == .reorder {
            dragX = nil
            TaskbarPinList.save(pins, .standard)
            reload()
            // A reorder opens nothing: if the press closed a pinned popup (which had activated the
            // shell), focus goes back to the app it would have restored.
            if NSApp.isActive, let app = press.remembered, !app.isTerminated { app.activate() }
            return
        }
        // Released off the button: no click.
        let p = convert(event.locationInWindow, from: nil)
        guard let i = buttonIndex(at: p), items[i].bundleID == press.bundleID else { return }
        let item = items[i]
        // Shift+click on a running button: a new window, as a middle click.
        if event.modifierFlags.contains(.shift) && item.isRunning {
            onButtonClick?()
            TaskbarLaunch.newWindow(bundleID: item.bundleID)
            return
        }
        click(buttonAt: i)
    }
}

extension TaskbarMouseButton {
    /// Button number 2 is the middle button; higher numbers are `.other`.
    init(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged: self = .left
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: self = .right
        default: self = event.buttonNumber == 2 ? .middle : .other
        }
    }
}
