import Foundation

/// Pure hover-delay state: fires once the pointer has dwelt for `delay` seconds.
public struct HoverIntent: Sendable {
    public let delay: TimeInterval
    private var enteredAt: TimeInterval?

    public init(delay: TimeInterval) { self.delay = delay }

    public mutating func enter(at t: TimeInterval) { enteredAt = t }
    public mutating func exit() { enteredAt = nil }

    public func shouldFire(now: TimeInterval) -> Bool {
        guard let enteredAt else { return false }
        return now - enteredAt >= delay
    }
}
