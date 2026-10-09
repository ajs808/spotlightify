import Foundation

/// A small in-memory LRU cache with per-entry expiry, used to avoid re-requesting
/// Spotify responses the user saw moments ago (retyped queries, reopened albums).
struct ResponseCache<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        let storedAt: Date
    }

    private let capacity: Int
    private let timeToLive: TimeInterval
    private let now: () -> Date
    private var entries: [Key: Entry] = [:]
    /// Least recently used first.
    private var order: [Key] = []

    init(capacity: Int, timeToLive: TimeInterval, now: @escaping () -> Date = Date.init) {
        self.capacity = max(1, capacity)
        self.timeToLive = timeToLive
        self.now = now
    }

    mutating func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        guard now().timeIntervalSince(entry.storedAt) < timeToLive else {
            removeValue(for: key)
            return nil
        }
        touch(key)
        return entry.value
    }

    mutating func insert(_ value: Value, for key: Key) {
        entries[key] = Entry(value: value, storedAt: now())
        touch(key)
        while order.count > capacity {
            let evicted = order.removeFirst()
            entries[evicted] = nil
        }
    }

    mutating func removeValue(for key: Key) {
        entries[key] = nil
        order.removeAll { $0 == key }
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    private mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
