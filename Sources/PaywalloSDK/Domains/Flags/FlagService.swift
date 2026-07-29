import Foundation

// MARK: - FlagStorage

/// UserDefaults-backed storage for flag variants per key.
public final class FlagStorage: @unchecked Sendable {

    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = PaywalloConstants.flagStoragePrefix) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    private func storageKey(for flagKey: String, distinctId: String) -> String {
        "\(keyPrefix)\(flagKey):\(distinctId)"
    }

    public func get(flagKey: String, distinctId: String = "") -> FlagVariant? {
        guard let json = defaults.string(forKey: storageKey(for: flagKey, distinctId: distinctId)),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FlagVariant.self, from: data)
    }

    public func set(flagKey: String, variant: FlagVariant, distinctId: String = "") {
        guard let data = try? JSONEncoder().encode(variant),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: storageKey(for: flagKey, distinctId: distinctId))
    }

    public func remove(flagKey: String, distinctId: String = "") {
        defaults.removeObject(forKey: storageKey(for: flagKey, distinctId: distinctId))
    }

    public func removeAll(withPrefix prefix: String = "") {
        let fullPrefix = keyPrefix + prefix
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(fullPrefix) }
        keys.forEach { defaults.removeObject(forKey: $0) }
    }
}

// MARK: - FlagCacheEntry

private struct FlagCacheEntry {
    let variant: FlagVariant
    let storedAt: Date
    let ttl: TimeInterval

    var isExpired: Bool {
        Date().timeIntervalSince(storedAt) >= ttl
    }

    var isStale: Bool {
        Date().timeIntervalSince(storedAt) >= ttl * 0.8
    }
}

// MARK: - FlagService

public final class FlagService: @unchecked Sendable {

    // MARK: - Configuration

    private let cacheTTL: TimeInterval

    // MARK: - Dependencies

    private let apiClient: ApiClient
    private let flagStorage: FlagStorage
    private let distinctIdProvider: () -> String

    // MARK: - In-memory cache

    private let lock = NSLock()
    private var memoryCache: [String: FlagCacheEntry] = [:]

    // MARK: - In-flight dedup

    private var activeRequests: [String: Task<FlagVariant?, Never>] = [:]

    // MARK: - Init

    public init(
        apiClient: ApiClient,
        flagStorage: FlagStorage = FlagStorage(),
        cacheTTL: TimeInterval = 5 * 60,
        distinctIdProvider: @escaping () -> String = { "" }
    ) {
        self.apiClient = apiClient
        self.flagStorage = flagStorage
        self.cacheTTL = cacheTTL
        self.distinctIdProvider = distinctIdProvider
    }

    // MARK: - Public API

    /// Fetch variant from server. Returns nil on 404 (flag not found).
    public func getVariant(key: String, distinctId: String?) async -> FlagVariant? {
        do {
            let variant = try await apiClient.getVariant(key: key, distinctId: distinctId)
            // variant.variant == nil means 404/no assignment
            if variant.variant == nil {
                return nil
            }
            cacheInMemory(key: key, variant: variant)
            let storageId = distinctId ?? distinctIdProvider()
            flagStorage.set(flagKey: key, variant: variant, distinctId: storageId)
            return variant
        } catch {
            // Treat network/server errors as nil; 404 from server may throw
            return nil
        }
    }

    /// Serve from local UserDefaults cache immediately; refresh in background.
    /// Returns stale cached value while background refresh runs.
    public func getVariantCached(key: String, distinctId: String?) async -> FlagVariant? {
        // Memory cache hit
        if let entry = getMemoryEntry(key), !entry.isExpired {
            if entry.isStale {
                Task { await self.refreshInBackground(key: key, distinctId: distinctId) }
            }
            return entry.variant
        }

        // Persistent (UserDefaults) fallback — serve stale + refresh
        let storageId = distinctId ?? distinctIdProvider()
        if let stored = flagStorage.get(flagKey: key, distinctId: storageId) {
            Task { await self.refreshInBackground(key: key, distinctId: distinctId) }
            return stored
        }

        // No cache — fetch fresh, blocking
        return await getVariant(key: key, distinctId: distinctId)
    }

    /// Batch evaluate flags. Returns map of key → FlagVariant.
    public func evaluateFlags(keys: [String], distinctId: String?) async throws -> [String: FlagVariant] {
        let result = try await apiClient.evaluateFlags(keys: keys, distinctId: distinctId)

        // Persist results to local cache
        let storageId = distinctId ?? distinctIdProvider()
        for (key, variant) in result {
            cacheInMemory(key: key, variant: variant)
            flagStorage.set(flagKey: key, variant: variant, distinctId: storageId)
        }

        return result
    }

    /// Evaluate a conditional flag with context.
    public func getConditionalFlag(key: String, context: ConditionalFlagContext?) async throws -> ConditionalFlagResult {
        try await apiClient.getConditionalFlag(key: key, context: context)
    }

    /// Invalidate cache for a specific flag key.
    public func invalidateCache(for key: String) {
        lock.lock()
        memoryCache.removeValue(forKey: key)
        lock.unlock()
        let id = distinctIdProvider()
        flagStorage.remove(flagKey: key, distinctId: id)
    }

    /// Invalidate all cached flags.
    public func invalidateAllCache() {
        lock.lock()
        memoryCache.removeAll()
        lock.unlock()
        flagStorage.removeAll()
    }

    // MARK: - Private

    private func refreshInBackground(key: String, distinctId: String?) async {
        // Dedup concurrent refreshes for the same key
        if let existing = getActiveRequest(key) {
            _ = await existing.value
            return
        }

        let task = Task<FlagVariant?, Never> {
            defer { self.removeActiveRequest(key) }
            return await self.getVariant(key: key, distinctId: distinctId)
        }
        setActiveRequest(key, task: task)
        _ = await task.value
    }

    private func cacheInMemory(key: String, variant: FlagVariant) {
        let entry = FlagCacheEntry(variant: variant, storedAt: Date(), ttl: cacheTTL)
        lock.lock()
        memoryCache[key] = entry
        lock.unlock()
    }

    private func getMemoryEntry(_ key: String) -> FlagCacheEntry? {
        lock.lock()
        defer { lock.unlock() }
        return memoryCache[key]
    }

    private func getActiveRequest(_ key: String) -> Task<FlagVariant?, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return activeRequests[key]
    }

    private func setActiveRequest(_ key: String, task: Task<FlagVariant?, Never>) {
        lock.lock()
        defer { lock.unlock() }
        activeRequests[key] = task
    }

    private func removeActiveRequest(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        activeRequests.removeValue(forKey: key)
    }
}
