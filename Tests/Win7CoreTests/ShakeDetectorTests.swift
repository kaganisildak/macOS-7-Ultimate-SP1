import CoreGraphics
import Foundation
import Testing
@testable import Win7Core

/// Feeds `xs` at `dt` spacing, starting the drag at xs[0]; returns the indices at which the detector fired.
private func feed(_ xs: [CGFloat], dt: TimeInterval) -> [Int] {
    var d = ShakeDetector(startX: xs[0])
    var fired: [Int] = []
    for (i, x) in xs.enumerated().dropFirst() where d.add(x: x, time: Double(i) * dt) { fired.append(i) }
    return fired
}

private let shake: [CGFloat] = [0, 25, 50, 25, 0, -25, -50, -25, 0, 25, 50, 25, 0]

@Test func shakeFires() {
    // Turns at 50 (t 0.08), -50 (t 0.24) and 50 (t 0.40); the third is confirmed back at 0.
    #expect(feed(shake, dt: 0.04) == [12])
}

@Test func slowShakeDoesNotFire() {
    // The same path with its turns 0.8 s apart.
    #expect(feed(shake, dt: 0.1).isEmpty)
}

@Test func smallShakeDoesNotFire() {
    let small: [CGFloat] = [0, 15, 30, 15, 0, -15, -30, -15, 0, 15, 30, 15, 0, -15, -30]
    #expect(feed(small, dt: 0.03).isEmpty)
}

@Test func driftingShakeDoesNotFire() {
    // Fast turns at 60, 20 and 130, but by the third the window is over 120 pt from the drag start.
    let drift: [CGFloat] = [0, 30, 60, 20, 70, 130, 90, 60, 100, 140, 100]
    #expect(feed(drift, dt: 0.03).isEmpty)
    // Once the window has been moved away, a shake no longer counts in this drag.
    let moved: [CGFloat] = [0, 60, 125] + shake.map { $0 + 125 }
    #expect(feed(moved, dt: 0.03).isEmpty)
}

@Test func firesOncePerDrag() {
    let three = shake + shake.dropFirst() + shake.dropFirst()
    #expect(feed(three, dt: 0.04) == [12])
}

@Test func onlyTheLatestThreeTurnsMustFitTheWindow() {
    // Turns at 50 (t 0.1), -50 (t 0.8) and 50 (t 1.0) span 0.9 s: no shake yet. A fourth turn at
    // -50 (t 1.2) makes the latest three span 0.4 s.
    let xs: [CGFloat] = [0, 50, 0, 0, 0, 0, 0, 0, -50, 0, 50, 0, -50, 0]
    #expect(feed(xs, dt: 0.1) == [13])
}
