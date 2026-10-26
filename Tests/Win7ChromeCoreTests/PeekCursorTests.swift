import AppKit
import Testing
import Win7ChromeCore

@MainActor @Test func peekRestoresOriginalAlpha() {
    _ = NSApplication.shared
    let a = NSWindow(); let b = NSWindow()
    a.isReleasedWhenClosed = false; b.isReleasedWhenClosed = false
    b.alphaValue = 0.5
    let p = W7PeekController(windowsProvider: { [a, b] }, timeout: 30)
    p.begin()
    #expect(abs(a.alphaValue - 0.08) < 0.001 && abs(b.alphaValue - 0.08) < 0.001)
    p.begin() // idempotent: must not store 0.08 as the original
    p.end()
    #expect(a.alphaValue == 1.0 && b.alphaValue == 0.5)
    p.end()
    #expect(a.alphaValue == 1.0)
}

@MainActor @Test func peekMidPeekWindowIsNotRestoredWrongly() {
    _ = NSApplication.shared
    let a = NSWindow(); let late = NSWindow()
    a.isReleasedWhenClosed = false; late.isReleasedWhenClosed = false
    late.alphaValue = 0.7
    var windows = [a]
    let p = W7PeekController(windowsProvider: { windows }, timeout: 30)
    p.begin()
    windows.append(late)
    p.end()
    #expect(a.alphaValue == 1.0)
    #expect(abs(late.alphaValue - 0.7) < 0.001)
}

@MainActor @Test func peekAutoEnds() {
    _ = NSApplication.shared
    let a = NSWindow(); a.isReleasedWhenClosed = false
    let p = W7PeekController(windowsProvider: { [a] }, timeout: 0.1)
    p.begin()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
    #expect(a.alphaValue == 1.0)
}

@Test func cursorsFromPlist() throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let png = rep.representation(using: .png, properties: [:])!
    let plist: [String: Any] = [
        "arrow": ["png": png, "x": 1, "y": 0],
        "bogus": [String: Any](),
        "hand": ["png": Data("notpng".utf8), "x": 0, "y": 0],
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    let cursors = W7CursorsFromPlistData(data)
    #expect(Array(cursors.keys) == ["arrow"])
    #expect(cursors["arrow"]?.hotSpot == NSPoint(x: 1, y: 0))
    #expect(W7CursorsFromPlistData(nil).isEmpty)
    #expect(W7CursorsFromPlistData(Data("junk".utf8)).isEmpty)
}

@MainActor @Test func peekNotificationHandlersBeginAndEnd() {
    _ = NSApplication.shared
    let a = NSWindow(); a.isReleasedWhenClosed = false
    let p = W7PeekController(windowsProvider: { [a] }, timeout: 30)
    let n = Notification(name: Notification.Name("com.win7mac.peek.begin"))
    p.handleBegin(n)
    #expect(abs(a.alphaValue - 0.08) < 0.001)
    p.handleEnd(n)
    #expect(a.alphaValue == 1.0)
}

@MainActor @Test func repeatedBeginKeepsFirstDeadline() {
    _ = NSApplication.shared
    let a = NSWindow(); a.isReleasedWhenClosed = false
    let p = W7PeekController(windowsProvider: { [a] }, timeout: 0.3)
    p.begin()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    p.begin()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
    #expect(a.alphaValue == 1.0)
}
