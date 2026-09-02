import Foundation

/// Entry stored in the cache.
private struct CacheEntry<T> {
    let value: T
    let storedAt: Date
    let ttl: TimeInterval?  // set() always fills it with defaultTTL when the caller omits one
    let isNull: Bool        // true for 404/null tombstones

    var isExpired: Bool {
        guard let ttl = ttl, ttl > 0 else { return false }
        return Date().timeIntervalSince(storedAt) > ttl
    }
}

/// In-memory TTL cache with stale-while-revalidate support.
///
/// - Keys are arbitrary strings (e.g. "paywall:onboarding", "campaign:home").
/// - TTL=0 is treated as "null tombstone" (404 cached briefly to avoid hammering).
/// - Stale-while-revalidate: expired entries are returned immediately while
///   the caller refreshes in the background.
public final class ApiCache {
    /// Applied when `set` is called without an explicit TTL.
    public static let defaultTTL: TimeInterval = 300
    /// 404 tombstone lifetime. 30s, not 60s: a paywall published mid-session used to stay
    /// invisible for a full minute after going live.
    public static let defaultNullTTL: TimeInterval = 30
    /// Past its TTL an entry is still served while it revalidates — but only inside this
    /// window (86_400_000 ms). Older than a day it is not "stale", it is wrong.
    public static let staleWindow: TimeInterval = 86_400
    /// Entry ceiling. On overflow only the already-expired entries are evicted: a live entry
    /// is never thrown away to make room.
    public static let maxSize = 200

    private var store: [String: Any] = [:]
    private var nullTombstones: [String: Date] = [:]
    private let nullTtl: TimeInterval
    private let lock = NSLock()

    public init(nullTtl: TimeInterval = ApiCache.defaultNullTTL) {
        self.nullTtl = nullTtl
    }

    // MARK: - Generic set/get

    /// Store a value under key with a given TTL (seconds). Omit `ttl` for `defaultTTL`.
    public func set<T>(_ key: String, value: T, ttl: TimeInterval? = nil) {
        lock.lock()
        defer { lock.unlock() }
        nullTombstones.removeValue(forKey: key)
        store[key] = CacheEntry(value: value, storedAt: Date(), ttl: ttl ?? Self.defaultTTL, isNull: false)
        evictExpiredEntriesUnlocked()
    }

    /// Retrieve a cached value. Returns the value even when past its TTL
    /// (stale-while-revalidate) as long as it is inside `staleWindow`; use `isStale(key:)` to
    /// decide whether to revalidate in the background.
    public func get<T>(_ key: String) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = store[key] as? CacheEntry<T> else { return nil }
        guard Date().timeIntervalSince(entry.storedAt) < Self.staleWindow else {
            store.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    /// Returns true if the entry exists but is past its TTL.
    public func isStale(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // Check any generic entry — we use a helper that reads the isExpired flag
        return isExpiredUnlocked(key)
    }

    // MARK: - Null tombstones (404 caching)

    /// Record a null/404 for this key so repeated misses don't hammer the server.
    public func setNull(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        store.removeValue(forKey: key)
        nullTombstones[key] = Date()
    }

    /// Returns true if the key has a live null tombstone (404 cached within nullTtl).
    public func isNull(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let storedAt = nullTombstones[key] else { return false }
        if Date().timeIntervalSince(storedAt) > nullTtl {
            nullTombstones.removeValue(forKey: key)
            return false
        }
        return true
    }

    // MARK: - Invalidation

    /// Remove a single key (both value and tombstone).
    public func invalidate(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        store.removeValue(forKey: key)
        nullTombstones.removeValue(forKey: key)
    }

    /// Remove all entries whose key has the given prefix.
    public func invalidatePrefix(_ prefix: String) {
        lock.lock()
        defer { lock.unlock() }
        store = store.filter { !$0.key.hasPrefix(prefix) }
        nullTombstones = nullTombstones.filter { !$0.key.hasPrefix(prefix) }
    }

    /// Clear the entire cache.
    public func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        store.removeAll()
        nullTombstones.removeAll()
    }

    // MARK: - Paywall helpers

    public func getPaywall(_ placement: String) -> PaywallConfig? {
        get("paywall:\(placement)")
    }

    public func setPaywall(_ placement: String, value: PaywallConfig, ttl: TimeInterval) {
        set("paywall:\(placement)", value: value, ttl: ttl)
    }

    // MARK: - Campaign helpers

    public func getCampaign(_ placement: String) -> CampaignResponse? {
        get("campaign:\(placement)")
    }

    public func setCampaign(_ placement: String, value: CampaignResponse, ttl: TimeInterval) {
        set("campaign:\(placement)", value: value, ttl: ttl)
    }

    // MARK: - Private helpers

    private func isExpiredUnlocked(_ key: String) -> Bool {
        // We can't erase the generic type here without type erasure;
        // instead we use a protocol-based approach via a box.
        guard let entry = store[key] as? ExpiryCheckable else { return false }
        return entry.isExpired
    }

    /// Only runs past `maxSize`, and only drops entries that are already past their TTL —
    /// evicting a live entry would turn a memory cap into a cache miss on the hot path.
    private func evictExpiredEntriesUnlocked() {
        guard store.count > Self.maxSize else { return }
        store = store.filter { _, value in
            guard let entry = value as? ExpiryCheckable else { return true }
            return !entry.isExpired
        }
    }
}

// MARK: - ExpiryCheckable protocol for type-erased expiry check

private protocol ExpiryCheckable {
    var isExpired: Bool { get }
}

extension CacheEntry: ExpiryCheckable {}
