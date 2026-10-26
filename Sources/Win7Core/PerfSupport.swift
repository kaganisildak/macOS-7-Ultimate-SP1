import Foundation

/// A small least-recently-used cache.
public struct BoundedCache<Key: Hashable, Value> {
    public let capacity: Int
    private var entries: [Key: (value: Value, used: UInt64)] = [:]
    private var clock: UInt64 = 0

    public init(capacity: Int) { self.capacity = max(1, capacity) }

    public var count: Int { entries.count }

    /// A look without counting as a use (tests, diagnostics).
    public subscript(key: Key) -> Value? { entries[key]?.value }

    /// The cached value, counted as a use (it becomes the most recently used); nil on a miss.
    public mutating func hit(_ key: Key) -> Value? {
        guard let e = entries[key] else { return nil }
        clock &+= 1
        entries[key] = (e.value, clock)
        return e.value
    }

    /// The cached value for `key`, made (and the least recently used entry evicted when full) on a miss.
    public mutating func value(for key: Key, orInsert make: () -> Value) -> Value {
        clock &+= 1
        if let e = entries[key] {
            entries[key] = (e.value, clock)
            return e.value
        }
        if entries.count >= capacity, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
            entries[oldest] = nil
        }
        let v = make()
        entries[key] = (v, clock)
        return v
    }

    public mutating func removeAll() { entries.removeAll() }
}

/// Timer tolerance: a fraction of the interval, within the agreed 10–20 %, so the system can
/// coalesce wake-ups.
public enum TimerTolerance {
    public static let minFraction = 0.10
    public static let maxFraction = 0.20

    public static func `for`(_ interval: TimeInterval, fraction: Double = minFraction) -> TimeInterval {
        max(0, interval) * min(max(fraction, minFraction), maxFraction)
    }
}

/// When a measured interval is worth a log line (`defaults write -g W7PerfLog -bool YES`): only on
/// the main thread and only past one 60 Hz frame.
public enum PerfBudget {
    public static let mainThreadBudget: TimeInterval = 0.016
    /// The debug default that turns the log on.
    public static let defaultsKey = "W7PerfLog"

    public static func shouldLog(duration: TimeInterval, isMainThread: Bool, enabled: Bool) -> Bool {
        enabled && isMainThread && duration > mainThreadBudget
    }
}

/// An async semaphore: at most `limit` holders at a time. Waiters are
/// served first come, first served; a cancelled waiter stops waiting at once.
public actor ConcurrencyLimiter {
    public let limit: Int
    public private(set) var inUse = 0
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []
    private var nextID: UInt64 = 0

    public init(limit: Int) { self.limit = max(1, limit) }

    /// Tasks waiting for a slot.
    public var waiting: Int { waiters.count }

    /// Waits for a slot. True: the caller holds one and must `release()` it. False: the task was
    /// cancelled (before or while waiting) and holds nothing.
    public func acquire() async -> Bool {
        if Task.isCancelled { return false }
        if inUse < limit { inUse += 1; return true }
        let id = nextID
        nextID &+= 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                // Cancelled between the check above and here: the handler's hop may still be queued.
                if Task.isCancelled { c.resume(returning: false) } else { waiters.append((id, c)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }   // already served
        waiters.remove(at: i).continuation.resume(returning: false)
    }

    /// Hands the slot to the next waiter, if any.
    public func release() {
        if waiters.isEmpty {
            inUse = max(0, inUse - 1)
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }
}
