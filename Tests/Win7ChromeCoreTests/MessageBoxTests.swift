import AppKit
import Testing
import Win7ChromeCore

/// NSAlert windows restyled as Windows 7 message boxes.
@Suite(.serialized) struct MessageBoxTests {
    @Test func stripTopLeavesPaddingAboveTheButtons() {
        let buttons = CGRect(x: 16, y: 16, width: 228, height: 96)
        #expect(W7MessageBoxStripTop(buttons, 128) == 120)            // half the gap to the text above
        #expect(W7MessageBoxStripTop(buttons, 200) == 128)            // at most 16
        #expect(W7MessageBoxStripTop(buttons, .greatestFiniteMagnitude) == 128)
        #expect(W7MessageBoxStripTop(buttons, 100) == 112)            // overlapping content: no padding
        #expect(W7MessageBoxStripTop(.null, 128) == 0)
    }

    @Test func captionUsesTheMarginAboveTheContent() {
        #expect(W7MessageBoxCaptionHeight(302, 282) == 18)
        #expect(W7MessageBoxCaptionHeight(302, 200) == 30)
        #expect(W7MessageBoxCaptionHeight(302, 290) == 0)
        #expect(W7MessageBoxCaptionHeight(302, 310) == 0)
    }

    @Test func styleDecision() {
        #expect(W7ShouldStyleMessageBox(true, true, true, false, false))
        #expect(!W7ShouldStyleMessageBox(false, true, true, false, false))
        #expect(!W7ShouldStyleMessageBox(true, false, true, false, false))
        #expect(!W7ShouldStyleMessageBox(true, true, false, false, false))
        #expect(!W7ShouldStyleMessageBox(true, true, true, true, false))
        #expect(!W7ShouldStyleMessageBox(true, true, true, false, true))
    }

    @MainActor private func makeAlert(dark: Bool = false) -> NSAlert {
        _ = NSApplication.shared
        let a = NSAlert()
        a.messageText = "Do you want to save the changes?"
        a.informativeText = "Your changes will be lost if you don't save them."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        a.layout()
        return a
    }

    @MainActor private func snapshot(_ v: NSView) -> NSBitmapImageRep {
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep
    }

    /// White message area, a #F0F0F0 strip under the buttons with a #DFDFDF line, styled once.
    @MainActor @Test func alertGetsTheMessageBoxBackground() throws {
        W7MessageBoxUseDisabledOverride(0)
        defer { W7MessageBoxUseDisabledOverride(-1) }
        let a = makeAlert()
        defer { a.window.close() }
        #expect(W7StyleMessageBoxIfNeeded(a.window))
        #expect(!W7StyleMessageBoxIfNeeded(a.window), "styled once")
        let content = try #require(a.window.contentView)
        #expect(content.subviews.filter { NSStringFromClass(type(of: $0)).contains("W7MessageBox") }.count == 1)
        let geometry = W7MessageBoxGeometry(a.window)
        #expect(geometry.stripTop > 0 && geometry.stripTop < content.bounds.height / 2, "\(geometry)")
        let rep = snapshot(content)
        let scale = CGFloat(rep.pixelsWide) / content.bounds.width
        func color(_ x: CGFloat, _ y: CGFloat) -> (Int, Int, Int) {   // y from the bottom, in points
            let c = rep.colorAt(x: Int(x * scale), y: rep.pixelsHigh - 1 - Int(y * scale))!.usingColorSpace(.sRGB)!
            return (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
        }
        // cacheDisplay's bitmap is in the display's colour space: grey levels come back a few steps lighter.
        func near(_ c: (Int, Int, Int), _ v: Int) -> Bool { abs(c.0 - v) <= 8 && c.0 == c.1 && c.1 == c.2 }
        let strip = color(4, 4), line = color(4, geometry.stripTop + 0.5), message = color(4, geometry.stripTop + 6)
        #expect(near(strip, 0xF0), "strip \(strip)")
        #expect(near(line, 0xDF) && line.0 < strip.0, "line \(line)")
        #expect(message == (0xFF, 0xFF, 0xFF), "message area \(message)")
        #expect(geometry.captionHeight >= 16, "the alert's top margin holds a caption band")
        let glass = color(content.bounds.width - 4, content.bounds.height - geometry.captionHeight / 2)
        #expect(glass.2 > glass.0 + 20, "caption glass (inactive: the window is not key) \(glass)")
    }

    @MainActor @Test func darkAlertsAndPlainPanelsAreLeftAlone() {
        W7MessageBoxUseDisabledOverride(0)
        defer { W7MessageBoxUseDisabledOverride(-1) }
        let dark = makeAlert(dark: true)
        defer { dark.window.close() }
        #expect(!W7StyleMessageBoxIfNeeded(dark.window))
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        #expect(!W7StyleMessageBoxIfNeeded(panel))
    }

    @MainActor @Test func killSwitchLeavesAlertsAlone() {
        W7MessageBoxUseDisabledOverride(1)
        defer { W7MessageBoxUseDisabledOverride(-1) }
        let a = makeAlert()
        defer { a.window.close() }
        #expect(!W7StyleMessageBoxIfNeeded(a.window))
    }

    // MARK: (plan "icons everywhere" ): the message box icons from the user's Windows 7 set

    /// A plain coloured square PNG (synthetic; nothing from Windows).
    private func squarePNG(px: Int, r: CGFloat, g: CGFloat, b: CGFloat) -> Data {
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
        return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    }

    /// Runs `body` with a temp asset root holding `icons` and no embedded icons; the defaults come back after.
    private func withIconRoot(_ icons: [String: Data], _ body: () throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("w7msgbox-icons-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("icons"), withIntermediateDirectories: true)
        for (name, png) in icons { try? png.write(to: root.appendingPathComponent("icons/\(name).png")) }
        W7UserIconsUseEmbedded([:])
        W7FolderIconUseAssetRoot(root.path)
        defer {
            W7UserIconsUseEmbedded(nil)
            W7FolderIconUseAssetRoot(nil)
            try? FileManager.default.removeItem(at: root)
        }
        try body()
    }

    /// The centre pixel of `image` drawn 64 × 64.
    @MainActor private func centre(_ image: NSImage?) -> (r: Int, g: Int, b: Int, a: Int) {
        guard let image else { return (0, 0, 0, 0) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        let c = rep.colorAt(x: 32, y: 32)!.usingColorSpace(.sRGB)!
        return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255), Int(c.alphaComponent * 255))
    }

    @Test func iconNameByStyle() {
        #expect(W7MessageBoxIconName(.critical) == "msgbox-warning")
        #expect(W7MessageBoxIconName(.informational) == "msgbox-info")
        #expect(W7MessageBoxIconName(.warning) == nil)   // the app's own icon (W7AppIconOverrideInstall's)
        #expect(W7UserIconNames().contains("msgbox-warning") && W7UserIconNames().contains("msgbox-info"))
    }

    @MainActor @Test func replacesOnlyTheApplicationIcon() {
        _ = NSApplication.shared
        let a = NSAlert()
        #expect(W7MessageBoxShouldReplaceIcon(a, false))           // NSApplicationIcon: the default
        #expect(!W7MessageBoxShouldReplaceIcon(NSAlert(), true))   // the kill switch
        a.icon = NSImage(size: NSSize(width: 4, height: 4))
        #expect(!W7MessageBoxShouldReplaceIcon(a, false))          // the app's own picture stays
        let b = NSAlert()
        b.icon = NSApp.applicationIconImage
        #expect(W7MessageBoxShouldReplaceIcon(b, false))
    }

    /// Safari's alerts keep their icons; other apps get them.
    @Test func safariAlertIconsAreLeftAlone() {
        #expect(!W7MessageBoxIconsApplyInApp("com.apple.Safari"))
        #expect(W7MessageBoxIconsApplyInApp("com.apple.TextEdit"))
        #expect(W7MessageBoxIconsApplyInApp(nil))
    }

    /// The picture by style: msgbox-warning / msgbox-info when the user has them, else (and for .warning) a copy of the
    /// app icon the override applied, else nil (AppKit's icon stays).
    @MainActor @Test func iconImageByStyleFallsBackToTheAppIcon() {
        let app = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { r in NSColor.blue.setFill(); r.fill(); return true }
        withIconRoot(["msgbox-warning": squarePNG(px: 48, r: 0, g: 1, b: 0)]) {
            let critical = W7MessageBoxIconImage(.critical, nil)
            #expect(critical?.size == NSSize(width: 64, height: 64) && centre(critical).g > 200 && centre(critical).r < 60)
            #expect(critical !== W7UserIconImage("msgbox-warning", 64), "never the shared cached image")
            #expect(W7MessageBoxIconImage(.informational, nil) == nil)
            let info = W7MessageBoxIconImage(.informational, app)
            #expect(info != nil && info !== app && centre(info).b > 200)
            let warning = W7MessageBoxIconImage(.warning, app)
            #expect(warning != nil && warning !== app && centre(warning).b > 200)
            #expect(W7MessageBoxIconImage(.warning, nil) == nil)
        }
    }

    /// A `.warning` alert gets the icon the override applied only while it is still the
    /// application's icon; once the app sets its own (Activity Monitor's Dock graph), AppKit's choice stays.
    @MainActor @Test func appIconForAlertsOnlyWhileStillApplied() {
        let applied = NSImage(size: NSSize(width: 128, height: 128))
        let appsOwn = NSImage(size: NSSize(width: 128, height: 128))
        #expect(W7MessageBoxAppIcon(applied, applied) === applied)
        #expect(W7MessageBoxAppIcon(applied, appsOwn) == nil)
        #expect(W7MessageBoxAppIcon(applied, nil) == nil)
        #expect(W7MessageBoxAppIcon(nil, appsOwn) == nil)   // no override applied: nothing of ours to show
        #expect(W7MessageBoxAppIcon(nil, nil) == nil)
    }

    /// When the alert window becomes key: a critical alert gets msgbox-warning.png, once; an alert with the app's own
    /// picture, a disabled switch and a missing PNG change nothing.
    @MainActor @Test func alertWindowGetsTheUserIcon() {
        withIconRoot(["msgbox-warning": squarePNG(px: 48, r: 0, g: 1, b: 0), "msgbox-info": squarePNG(px: 48, r: 1, g: 0, b: 0)]) {
            W7MessageBoxIconsUseDisabledOverride(0)
            defer { W7MessageBoxIconsUseDisabledOverride(-1) }
            let critical = makeAlert()
            critical.alertStyle = .critical
            defer { critical.window.close() }
            #expect(W7MessageBoxApplyUserIcon(critical.window))
            #expect(centre(critical.icon).g > 200 && centre(critical.icon).r < 60)
            #expect(!W7MessageBoxApplyUserIcon(critical.window), "once: the icon is no longer the app's")
            let info = makeAlert()
            info.alertStyle = .informational
            defer { info.window.close() }
            #expect(W7MessageBoxApplyUserIcon(info.window) && centre(info.icon).r > 200)
            let own = makeAlert()
            own.alertStyle = .critical
            own.icon = NSImage(size: NSSize(width: 4, height: 4))
            defer { own.window.close() }
            #expect(!W7MessageBoxApplyUserIcon(own.window))
            let warning = makeAlert()   // .warning, and no app icon override in the test process
            defer { warning.window.close() }
            #expect(!W7MessageBoxApplyUserIcon(warning.window) && warning.icon?.name() == NSImage.applicationIconName)
            W7MessageBoxIconsUseDisabledOverride(1)
            let off = makeAlert()
            off.alertStyle = .critical
            defer { off.window.close() }
            #expect(!W7MessageBoxApplyUserIcon(off.window) && off.icon?.name() == NSImage.applicationIconName)
            let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
            panel.isReleasedWhenClosed = false
            defer { panel.close() }
            W7MessageBoxIconsUseDisabledOverride(0)
            #expect(!W7MessageBoxApplyUserIcon(panel))
        }
        W7MessageBoxIconsUseDisabledOverride(0)
        defer { W7MessageBoxIconsUseDisabledOverride(-1) }
        withIconRoot([:]) {
            let critical = makeAlert()
            critical.alertStyle = .critical
            defer { critical.window.close() }
            #expect(!W7MessageBoxApplyUserIcon(critical.window) && critical.icon?.name() == NSImage.applicationIconName)
        }
    }
}
