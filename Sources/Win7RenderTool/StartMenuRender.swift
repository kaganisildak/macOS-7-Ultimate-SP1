import AppKit
import Win7Theme

/// The Start menu's static layout with sample entries, drawn with the same theme calls and layout as
/// StartMenuContentView (Win7Shell), in the non-flipped coordinates the theme uses. The second program
/// row and the "Documents" place are shown hovered.
@MainActor
enum StartMenuRender {
    static let leftPaneWidth: CGFloat = 250
    static let rowHeight: CGFloat = 38
    static let allProgramsHeight: CGFloat = 30
    static let rightRowHeight: CGFloat = 26
    static let separatorGap: CGFloat = 12

    private static let font = W7UIFont(12)
    private static let shadow: NSShadow = {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.6)
        s.shadowOffset = NSSize(width: 0, height: -1)
        s.shadowBlurRadius = 2
        return s
    }()

    /// `y` is measured from the top, as in the flipped shell view.
    private static func text(_ s: String, x: CGFloat, top y: CGFloat, height: CGFloat, color: NSColor,
                             font: NSFont = font, glass: Bool = false) {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if glass { attrs[.shadow] = shadow }
        let h = (s as NSString).size(withAttributes: attrs).height
        (s as NSString).draw(at: NSPoint(x: x, y: height - y - h / 2), withAttributes: attrs)
    }

    static func draw(_ ctx: CGContext, _ size: NSSize) {
        let bounds = CGRect(origin: .zero, size: size)
        let H = size.height, lw = leftPaneWidth
        /// A rect given top-down (as the shell lays it out) in the theme's bottom-up coordinates.
        func r(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: H - top - h, width: w, height: h) }

        W7DrawWallpaper(ctx, bounds)
        Renderer.drawBlurStandIn(ctx, bounds)
        W7DrawStartMenuBackground(ctx, bounds, lw, W7StartMenuSearchBandHeight)
        let paneU = W7StartMenuProgramsRect(bounds, lw)
        let paneTop = H - paneU.maxY, paneBottom = H - paneU.minY
        let box = W7StartMenuSearchBoxRect(bounds, lw)
        W7DrawSearchBox(ctx, box, false, false)
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        text("Search programs and files", x: box.minX + 7, top: H - box.midY, height: H,
             color: NSColor(srgbRed: 0x6D / 255, green: 0x6D / 255, blue: 0x6D / 255, alpha: 1), font: italic)

        let apps = [("Finder", "/System/Library/CoreServices/Finder.app"), ("Safari", "/Applications/Safari.app"),
                    ("Music", "/System/Applications/Music.app"), ("Calculator", "/System/Applications/Calculator.app"),
                    ("TextEdit", "/System/Applications/TextEdit.app")]
        let listTop = paneTop + 4, listBottom = paneBottom - W7StartMenuSearchBandHeight - allProgramsHeight
        for (i, (name, path)) in apps.enumerated() {
            let top = listTop + CGFloat(i) * rowHeight
            let row = r(paneU.minX + 4, top, paneU.width - 8, rowHeight)
            if i == 1 { W7DrawMenuHighlight(ctx, row) }
            NSWorkspace.shared.icon(forFile: path).draw(in: NSRect(x: row.minX + 6, y: row.midY - 14, width: 28, height: 28))
            text(name, x: row.minX + 42, top: top + rowHeight / 2, height: H, color: .black)
        }
        // All Programs, under a light line.
        ctx.setFillColor(CGColor(srgbRed: 0xD5 / 255, green: 0xE0 / 255, blue: 0xEE / 255, alpha: 1))
        ctx.fill(r(paneU.minX + 8, listBottom, paneU.width - 16, 1))
        let allTop = listBottom + 1, allH = allProgramsHeight - 2
        W7DrawChevron(ctx, CGPoint(x: paneU.minX + 4 + 16, y: H - allTop - allH / 2), .right, 0x000000, 1)
        text("All Programs", x: paneU.minX + 4 + 42, top: allTop + allH / 2, height: H, color: .black)

        // Right column: the user tile (a stock picture here), the places with separators, Shut down.
        let tile = W7StartMenuUserTileRect(bounds, lw)
        W7DrawUserTileFrame(ctx, tile)
        if let pic = NSImage(named: NSImage.userName) {   // fills the tile, as the shell draws icons/user.png
            ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.9, blue: 0.95, alpha: 1))
            ctx.fill(tile)
            pic.draw(in: tile)
        }
        let rx = lw + 8
        var y = W7StartMenuPlacesTop(true)
        for title in [NSFullUserName(), "Documents", "Pictures", "Music", "", "Computer", "", "Control Panel", "Devices and Printers"] {
            if title.isEmpty {
                W7DrawStartMenuSeparator(ctx, lw + 12, size.width - 12, H - (y + separatorGap / 2))
                y += separatorGap
                continue
            }
            if title == "Documents" { W7DrawTaskbarButton(ctx, r(rx, y, size.width - rx - 8, rightRowHeight), true, false, true) }
            text(title, x: rx + 10, top: y + rightRowHeight / 2, height: H, color: .white, glass: true)
            y += rightRowHeight
        }
        let by = H - box.midY - 13
        let shut = r(rx, by, 92, 26), arrow = r(rx + 92, by, 24, 26)
        W7DrawTaskbarButton(ctx, shut, true, false, false)
        W7DrawTaskbarButton(ctx, arrow, true, false, false)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .shadow: shadow]
        let s = ("Shut down" as NSString).size(withAttributes: attrs)
        ("Shut down" as NSString).draw(at: NSPoint(x: shut.midX - s.width / 2, y: shut.midY - s.height / 2), withAttributes: attrs)
        W7DrawChevron(ctx, CGPoint(x: arrow.midX, y: arrow.midY), .right, 0xFFFFFF, 1)
    }
}
