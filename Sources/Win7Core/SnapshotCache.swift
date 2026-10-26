import Foundation

/// Time-stamped values per key that a background query refreshes (the taskbar's window
/// snapshots). A refresh is asked for with `beginRefresh`, which hands out a ticket at most every
/// `minInterval` per key and never while one is in flight; the result comes back through `complete`.
/// `invalidate` drops a key's value and voids the tickets already handed out for it, since their
/// results may predate whatever made the value stale.
public struct SnapshotCache<Key: Hashable & Sendable, Value> {
    public struct Ticket: Hashable, Sendable {
        public let key: Key
        fileprivate let generation: Generation
        /// When the query started: the value's age counts from here.
        public let startedAt: TimeInterval
    }

    /// A key's generation: `invalidateAll` bumps the epoch, `invalidate` the key's own count.
    fileprivate struct Generation: Hashable, Sendable {
        var epoch: Int
        var key: Int
    }

    public let minInterval: TimeInterval
    private var entries: [Key: (value: Value, takenAt: TimeInterval)] = [:]
    private var generations: [Key: Int] = [:]
    /// Bumped by `invalidateAll`; part of every generation.
    private var epoch = 0
    /// The generation of the refresh in flight per key.
    private var inFlight: [Key: Generation] = [:]
    /// Values taken before this time are not served (`invalidate(_:holdOff:now:)`).
    private var holdOffs: [Key: TimeInterval] = [:]

    public init(minInterval: TimeInterval = 0.25) {
        self.minInterval = minInterval
    }

    private func generation(_ key: Key) -> Generation { Generation(epoch: epoch, key: generations[key] ?? 0) }

    /// A ticket when `key` should be refreshed now: no refresh is in flight for its current
    /// generation, and its value is missing or at least `minInterval` old.
    public mutating func beginRefresh(_ key: Key, now: TimeInterval) -> Ticket? {
        let gen = generation(key)
        if inFlight[key] == gen { return nil }
        // A value that cannot be served (taken during a hold-off) does not throttle.
        if let e = entries[key], now - e.takenAt < minInterval, isServable(key, e.takenAt) { return nil }
        inFlight[key] = gen
        return Ticket(key: key, generation: gen, startedAt: now)
    }

    /// Stores a finished refresh. Returns false, and drops the value, when the key was invalidated
    /// after the ticket was handed out.
    @discardableResult
    public mutating func complete(_ ticket: Ticket, with value: Value) -> Bool {
        let gen = generation(ticket.key)
        if inFlight[ticket.key] == ticket.generation { inFlight[ticket.key] = nil }
        guard ticket.generation == gen else { return false }
        entries[ticket.key] = (value, ticket.startedAt)
        return true
    }

    /// Records a value from a synchronous query started at `takenAt`.
    public mutating func store(_ key: Key, _ value: Value, takenAt: TimeInterval) {
        entries[key] = (value, takenAt)
    }

    /// The key's value if it was taken at most `maxAge` before `now`, and not before the key's
    /// hold-off ended.
    public func value(_ key: Key, now: TimeInterval, maxAge: TimeInterval) -> Value? {
        guard let e = entries[key], now - e.takenAt <= maxAge, isServable(key, e.takenAt) else { return nil }
        return e.value
    }

    private func isServable(_ key: Key, _ takenAt: TimeInterval) -> Bool {
        guard let notBefore = holdOffs[key] else { return true }
        return takenAt >= notBefore
    }

    /// Drops the key's value and voids its refreshes in flight.
    public mutating func invalidate(_ key: Key) {
        entries[key] = nil
        generations[key, default: 0] &+= 1
    }

    /// `invalidate`, and values taken during the next `holdOff` seconds are not served either: after
    /// an action on a window its effect may take a moment to show, and a value fetched meanwhile
    /// could still have the old state.
    public mutating func invalidate(_ key: Key, holdOff: TimeInterval, now: TimeInterval) {
        invalidate(key)
        holdOffs = holdOffs.filter { $0.value > now }   // expired hold-offs (of quit apps too) go
        holdOffs[key] = now + holdOff
    }

    public mutating func invalidateAll() {
        entries.removeAll()
        epoch &+= 1
    }
}
