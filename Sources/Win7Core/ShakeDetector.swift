import CoreGraphics
import Foundation

/// Aero Shake: fed the cursor's x during one title-bar drag, it fires once when the window has
/// been shaken left and right — at least `reversals` turns, every leg at least `minLeg` long, the
/// latest turns within `window` seconds — while the drag has never strayed more than `maxDrift`
/// from where it started.
public struct ShakeDetector: Sendable {
    public static let reversals = 3
    public static let minLeg: CGFloat = 40
    public static let window: TimeInterval = 0.6
    public static let maxDrift: CGFloat = 120

    private let startX: CGFloat
    /// +1 / -1 once the current leg is `minLeg` long; 0 before the first leg.
    private var direction: CGFloat = 0
    /// The farthest point of the current leg, a candidate turn.
    private var extremeX: CGFloat = 0
    private var extremeTime: TimeInterval = 0
    private var turnTimes: [TimeInterval] = []
    /// Fired, or strayed too far: nothing more fires in this drag.
    private var done = false

    public init(startX: CGFloat) {
        self.startX = startX
    }

    /// Returns true exactly once, on the sample that completes a shake.
    public mutating func add(x: CGFloat, time: TimeInterval) -> Bool {
        guard !done else { return false }
        if abs(x - startX) > Self.maxDrift { done = true; return false }
        if direction == 0 {
            guard abs(x - startX) >= Self.minLeg else { return false }
            direction = x > startX ? 1 : -1
            extremeX = x; extremeTime = time
            return false
        }
        if (x - extremeX) * direction > 0 {
            extremeX = x; extremeTime = time
            return false
        }
        // A turn counts once the leg back from it is `minLeg` long too.
        guard (extremeX - x) * direction >= Self.minLeg else { return false }
        turnTimes.append(extremeTime)
        direction = -direction
        extremeX = x; extremeTime = time
        guard turnTimes.count >= Self.reversals,
              turnSpan() <= Self.window else { return false }
        done = true
        return true
    }

    private func turnSpan() -> TimeInterval {
        let recent = turnTimes.suffix(Self.reversals)
        return (recent.last ?? 0) - (recent.first ?? 0)
    }
}
