import Foundation

public enum PeekAction: Equatable, Sendable { case begin, end }

/// Pure Show Desktop hover decision: begin after the dwell delay, end on exit or click. A click cancels a pending begin.
public struct PeekHoverState: Sendable {
    public let delay: TimeInterval
    private var intent: HoverIntent
    private var fired = false

    public init(delay: TimeInterval = 0.5) { self.delay = delay; intent = HoverIntent(delay: delay) }

    public mutating func enter(at t: TimeInterval) { intent.enter(at: t) }
    public mutating func exit() -> PeekAction? { cancel() }
    public mutating func click() -> PeekAction? { cancel() }

    public mutating func tick(now: TimeInterval) -> PeekAction? {
        guard !fired, intent.shouldFire(now: now) else { return nil }
        fired = true
        return .begin
    }

    private mutating func cancel() -> PeekAction? {
        intent.exit()
        defer { fired = false }
        return fired ? .end : nil
    }
}
