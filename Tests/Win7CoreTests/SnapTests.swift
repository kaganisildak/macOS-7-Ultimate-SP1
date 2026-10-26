import CoreGraphics
import Testing
@testable import Win7Core

private let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
private let leftDisplay = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
private let aboveDisplay = CGRect(x: 0, y: -1080, width: 1920, height: 1080)

@Test func coordinates() {
    let ax = Coordinates.ax(fromAppKit: CGRect(x: 0, y: 0, width: 1440, height: 40), primaryHeight: 900)
    #expect(ax == CGRect(x: 0, y: 860, width: 1440, height: 40))
    #expect(Coordinates.appKit(fromAX: ax, primaryHeight: 900) == CGRect(x: 0, y: 0, width: 1440, height: 40))
}

@Test func singleScreenEdges() {
    #expect(SnapGeometry.target(cursor: CGPoint(x: 0, y: 400), screens: [primary])?.target == .leftHalf)
    #expect(SnapGeometry.target(cursor: CGPoint(x: 1439, y: 400), screens: [primary])?.target == .rightHalf)
    #expect(SnapGeometry.target(cursor: CGPoint(x: 700, y: 0), screens: [primary])?.target == .maximize)
    #expect(SnapGeometry.target(cursor: CGPoint(x: 0, y: 0), screens: [primary])?.target == .leftHalf)
    #expect(SnapGeometry.target(cursor: CGPoint(x: 700, y: 400), screens: [primary]) == nil)
}

@Test func sharedEdgesDoNotSnap() {
    #expect(SnapGeometry.target(cursor: CGPoint(x: 0, y: 400), screens: [primary, leftDisplay]) == nil)
    #expect(SnapGeometry.target(cursor: CGPoint(x: 700, y: 0), screens: [primary, aboveDisplay]) == nil)
}

@Test func negativeCoordinateDisplay() {
    let r = SnapGeometry.target(cursor: CGPoint(x: -1920, y: 300), screens: [primary, leftDisplay])
    #expect(r?.target == .leftHalf && r?.screenIndex == 1)
}

@Test func frames() {
    let u = SnapGeometry.usableRect(screenVisible: primary, bar: CGRect(x: 0, y: 860, width: 1440, height: 40))
    #expect(u == CGRect(x: 0, y: 0, width: 1440, height: 860))
    #expect(SnapGeometry.frame(for: .leftHalf, usable: u) == CGRect(x: 0, y: 0, width: 720, height: 860))
    #expect(SnapGeometry.frame(for: .maximize, usable: u) == u)
    #expect(SnapGeometry.frame(for: .rightHalf, usable: CGRect(x: 0, y: 0, width: 1441, height: 860))
            == CGRect(x: 720, y: 0, width: 721, height: 860))
    #expect(SnapGeometry.usableRect(screenVisible: leftDisplay, bar: nil) == leftDisplay)
}

@Test func keyboard() {
    #expect(SnapGeometry.keyboardAction(current: nil, arrow: .left) == .snap(.leftHalf))
    #expect(SnapGeometry.keyboardAction(current: .leftHalf, arrow: .right) == .restore)
    #expect(SnapGeometry.keyboardAction(current: .leftHalf, arrow: .left) == nil)
    #expect(SnapGeometry.keyboardAction(current: .rightHalf, arrow: .up) == .snap(.maximize))
    #expect(SnapGeometry.keyboardAction(current: .maximize, arrow: .down) == .restore)
    #expect(SnapGeometry.keyboardAction(current: nil, arrow: .down) == .minimize)
}

@Test func gate() {
    let none = PermissionGate(isAXTrusted: { false }, hasScreenCapture: { false })
    #expect(none.enabled().isEmpty)
    #expect(PermissionGate(isAXTrusted: { true }, hasScreenCapture: { false }).enabled() == [.snap, .switcher])
    #expect(PermissionGate(isAXTrusted: { true }, hasScreenCapture: { true }).enabled()
            == [.snap, .switcher, .thumbnails, .windowTitles])
}

@Test func memory() {
    var m = SnapMemory()
    let f = CGRect(x: 10, y: 20, width: 300, height: 200)
    m.remember(7, frame: f, snapped: .leftHalf)
    #expect(m.original(7) == f)
    #expect(m.current(7) == .leftHalf)
    m.forget(7)
    #expect(m.original(7) == nil && m.current(7) == nil)
}

@Test func balloonShowsOncePerUntrustedPeriod() {
    var b = BalloonPolicy()
    let first = b.shouldShow(trusted: false)
    let second = b.shouldShow(trusted: false)
    let trusted = b.shouldShow(trusted: true)
    let again = b.shouldShow(trusted: false)
    #expect(first && !second && !trusted && again)
}

@Test func restoreDecision() {
    let snapped = CGRect(x: 0, y: 0, width: 720, height: 860)
    #expect(SnapGeometry.shouldRestore(snapped: snapped, current: snapped.offsetBy(dx: 11, dy: 0)))
    #expect(!SnapGeometry.shouldRestore(snapped: snapped, current: snapped.offsetBy(dx: 5, dy: 0)))
    #expect(!SnapGeometry.shouldRestore(snapped: snapped, current: CGRect(x: 50, y: 0, width: 670, height: 860)))
}

// MARK: Vertical maximize and moving between screens

@Test func verticalMaximizeKeepsXAndWidth() {
    let u = SnapGeometry.usableRect(screenVisible: primary, bar: CGRect(x: 0, y: 860, width: 1440, height: 40))
    let f = CGRect(x: 200, y: 300, width: 640, height: 400)
    #expect(WindowMoves.verticallyMaximized(f, usable: u) == CGRect(x: 200, y: 0, width: 640, height: 860))
    // A secondary display has no taskbar and may sit at negative coordinates.
    let g = CGRect(x: -1500, y: 0, width: 800, height: 500)
    #expect(WindowMoves.verticallyMaximized(g, usable: leftDisplay) == CGRect(x: -1500, y: -200, width: 800, height: 1080))
}

@Test func neighborScreensGoLeftToRightAndWrap() {
    let right = CGRect(x: 1440, y: 0, width: 1280, height: 800)
    // NSScreen order puts the primary first; left to right it is leftDisplay, primary, right.
    let screens = [primary, right, leftDisplay]
    #expect(WindowMoves.neighborScreen(of: 0, screens: screens, forward: true) == 1)
    #expect(WindowMoves.neighborScreen(of: 0, screens: screens, forward: false) == 2)
    #expect(WindowMoves.neighborScreen(of: 1, screens: screens, forward: true) == 2)
    #expect(WindowMoves.neighborScreen(of: 2, screens: screens, forward: false) == 1)
    // Stacked screens share a left edge: the higher one comes first.
    let below = CGRect(x: 0, y: 900, width: 1440, height: 900)
    #expect(WindowMoves.neighborScreen(of: 0, screens: [primary, below, aboveDisplay], forward: true) == 1)
    #expect(WindowMoves.neighborScreen(of: 0, screens: [primary, below, aboveDisplay], forward: false) == 2)
    #expect(WindowMoves.neighborScreen(of: 0, screens: [primary], forward: true) == nil)
}

@Test func moveKeepsRelativeFrame() {
    let from = CGRect(x: 0, y: 0, width: 1440, height: 860)
    // A quarter in and a tenth down, half as wide and half as high.
    let f = CGRect(x: 360, y: 86, width: 720, height: 430)
    #expect(WindowMoves.frame(f, movedFrom: from, to: leftDisplay) == CGRect(x: -1440, y: -92, width: 960, height: 540))
    // A maximized window stays maximized on the other screen.
    #expect(WindowMoves.frame(from, movedFrom: from, to: leftDisplay) == leftDisplay)
    #expect(WindowMoves.frame(leftDisplay, movedFrom: leftDisplay, to: from) == from)
    // Fractions round to whole points.
    #expect(WindowMoves.frame(CGRect(x: 1, y: 1, width: 100, height: 100), movedFrom: from,
                              to: CGRect(x: 0, y: 0, width: 1000, height: 600)).integral
            == WindowMoves.frame(CGRect(x: 1, y: 1, width: 100, height: 100), movedFrom: from,
                                 to: CGRect(x: 0, y: 0, width: 1000, height: 600)))
}
