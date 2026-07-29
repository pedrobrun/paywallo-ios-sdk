import Foundation

public struct CachedSubscription: Sendable {
    public let data: SubscriptionStatusResponse
    public let cachedAt: Date
    public var isStale: Bool

    public init(data: SubscriptionStatusResponse, cachedAt: Date = Date(), isStale: Bool = false) {
        self.data = data
        self.cachedAt = cachedAt
        self.isStale = isStale
    }
}

// Internal Codable wrapper for persistence
struct CachedSubscriptionStorage: Codable {
    let data: SubscriptionStatusResponse
    let cachedAt: TimeInterval  // Date as timeIntervalSince1970
}

public actor SubscriptionCache {
    private var ttl: TimeInterval
    private var memoryCache: [String: CachedSubscription] = [:]
    private let storage: SecureStorage
    private var legacyCleanupDone = false

    private let cacheKeyPrefix = PaywalloConstants.subscriptionCachePrefix
    private let cacheIndexKey = PaywalloConstants.subscriptionCacheIndexKey
    private let legacyCacheKey = PaywalloConstants.legacySubscriptionCacheKey

    public init(ttl: TimeInterval = 24 * 60 * 60, storage: SecureStorage = .shared) {
        self.ttl = ttl
        self.storage = storage
    }

    private func keyFor(_ distinctId: String) -> String {
        "\(cacheKeyPrefix)\(distinctId)"
    }

    private func cleanupLegacyCache() async {
        guard !legacyCleanupDone else { return }
        legacyCleanupDone = true
        // legacyCacheKey is "@panel:subscription_cache" — a plain UserDefaults key
        UserDefaults.standard.removeObject(forKey: legacyCacheKey)
    }

    public func get(_ distinctId: String) async -> CachedSubscription? {
        await cleanupLegacyCache()
        guard !distinctId.isEmpty else { return nil }

        // Check memory first
        if let memEntry = memoryCache[distinctId], !isExpired(memEntry) {
            return memEntry
        }

        // Read from storage
        guard let raw = await storage.get(keyFor(distinctId)),
              let data = raw.data(using: .utf8) else {
            return nil
        }

        do {
            let stored = try JSONDecoder().decode(CachedSubscriptionStorage.self, from: data)
            let cachedAt = Date(timeIntervalSince1970: stored.cachedAt)
            var cached = CachedSubscription(data: stored.data, cachedAt: cachedAt)
            cached.isStale = isExpired(cached)

            if !cached.isStale {
                memoryCache[distinctId] = cached
            }

            return cached
        } catch {
            await storage.remove(keyFor(distinctId))
            return nil
        }
    }

    public func set(_ distinctId: String, data: SubscriptionStatusResponse) async {
        guard !distinctId.isEmpty else { return }

        let cached = CachedSubscription(data: data)
        memoryCache[distinctId] = cached

        let storable = CachedSubscriptionStorage(
            data: data,
            cachedAt: Date().timeIntervalSince1970
        )

        if let jsonData = try? JSONEncoder().encode(storable),
           let json = String(data: jsonData, encoding: .utf8) {
            await storage.set(keyFor(distinctId), value: json)
            await addToIndex(distinctId)
        }
    }

    private func addToIndex(_ distinctId: String) async {
        var ids = await readIndex()
        if !ids.contains(distinctId) {
            ids.append(distinctId)
            if let data = try? JSONEncoder().encode(ids),
               let json = String(data: data, encoding: .utf8) {
                await storage.set(cacheIndexKey, value: json)
            }
        }
    }

    private func readIndex() async -> [String] {
        guard let raw = await storage.get(cacheIndexKey),
              let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    public func invalidate(_ distinctId: String) async {
        guard !distinctId.isEmpty else { return }
        memoryCache.removeValue(forKey: distinctId)
        await storage.remove(keyFor(distinctId))
    }

    public func invalidateAll() async {
        let memKeys = Array(memoryCache.keys)
        let indexKeys = await readIndex()
        let allKeys = Set(memKeys + indexKeys)

        memoryCache.removeAll()

        // Remove all cached entries
        for key in allKeys {
            await storage.remove(keyFor(key))
        }

        // Remove legacy and index
        UserDefaults.standard.removeObject(forKey: legacyCacheKey)
        await storage.remove(cacheIndexKey)
    }

    public func setTTL(_ ttl: TimeInterval) {
        self.ttl = ttl
    }

    private func isExpired(_ cached: CachedSubscription) -> Bool {
        Date().timeIntervalSince(cached.cachedAt) > ttl
    }
}
