import Foundation

/// In-memory preload entry for a campaign placement.
private struct PreloadEntry {
    let response: CampaignResponse?
    let storedAt: Date
    let ttl: TimeInterval

    var isExpired: Bool {
        Date().timeIntervalSince(storedAt) >= ttl
    }

    /// Returns true when 80% of TTL has elapsed (stale-while-revalidate threshold).
    var isStale: Bool {
        Date().timeIntervalSince(storedAt) >= ttl * 0.8
    }
}

public final class CampaignGateService: @unchecked Sendable {
    // MARK: - Configuration

    private let preloadTTL: TimeInterval
    private let staleThreshold: TimeInterval    // 80% of TTL = 4 min by default
    private let waitPollInterval: TimeInterval  // 100ms
    private let waitMaxDuration: TimeInterval   // 2000ms
    private let activePreloadDelay: TimeInterval // 500ms between placements

    // MARK: - Dependencies

    private let apiClient: ApiClient
    private let subscriptionManager: SubscriptionManager

    // MARK: - State

    private let lock = NSLock()
    private var preloadCache: [String: PreloadEntry] = [:]
    private var activePreloadPromises: [String: Task<CampaignResponse?, Never>] = [:]

    // MARK: - Init

    public init(
        apiClient: ApiClient,
        subscriptionManager: SubscriptionManager,
        preloadTTL: TimeInterval = 5 * 60,
        waitPollInterval: TimeInterval = 0.1,
        waitMaxDuration: TimeInterval = 2.0,
        activePreloadDelay: TimeInterval = 0.5
    ) {
        self.apiClient = apiClient
        self.subscriptionManager = subscriptionManager
        self.preloadTTL = preloadTTL
        self.staleThreshold = preloadTTL * 0.8
        self.waitPollInterval = waitPollInterval
        self.waitMaxDuration = waitMaxDuration
        self.activePreloadDelay = activePreloadDelay
    }

    // MARK: - Preload

    /// Preload a campaign placement into memory cache. Deduplicates concurrent calls.
    @discardableResult
    public func preloadCampaign(
        _ placement: String,
        distinctId: String?,
        context: [String: AnyCodable]? = nil
    ) async -> CampaignResponse? {
        // Return cached if still fresh
        if let cached = getCached(placement), !cached.isExpired {
            // Background revalidate if stale
            if cached.isStale {
                Task { await self.fetchAndCache(placement, distinctId: distinctId, context: context) }
            }
            return cached.response
        }

        // Dedup: reuse existing in-flight task
        if let existing = getActivePromise(placement) {
            return await existing.value
        }

        let task = Task<CampaignResponse?, Never> {
            defer { self.removeActivePromise(placement) }
            return await self.fetchAndCache(placement, distinctId: distinctId, context: context)
        }

        setActivePromise(placement, task: task)
        return await task.value
    }

    /// Preload all active campaign placements one at a time with 500ms delay between them.
    public func preloadAllActive(distinctId: String?) async {
        do {
            let placements = try await apiClient.getCampaignPlacements()
            for (index, placement) in placements.enumerated() {
                if index > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(activePreloadDelay * 1_000_000_000))
                }
                await preloadCampaign(placement, distinctId: distinctId, context: nil)
            }
        } catch {
            // Non-critical — best effort
        }
    }

    // MARK: - Wait for preload

    /// Polls until preload completes or timeout (2s). Falls back to nil.
    public func waitForPreload(_ placement: String) async -> CampaignResponse? {
        let deadline = Date().addingTimeInterval(waitMaxDuration)

        while Date() < deadline {
            if let cached = getCached(placement) {
                return cached.response
            }

            // Check if there's an active preload in flight
            if let promise = getActivePromise(placement) {
                return await promise.value
            }

            try? await Task.sleep(nanoseconds: UInt64(waitPollInterval * 1_000_000_000))
        }

        // Return whatever is cached (even stale) after timeout
        return getCached(placement)?.response
    }

    // MARK: - Present campaign

    /// Returns campaign for presentation.
    /// - forceShow: skip subscription check, present regardless of active status.
    /// - Returns nil when paywall is null or subscription gate blocks presentation.
    public func presentCampaign(
        placement: String,
        distinctId: String?,
        context: [String: AnyCodable]? = nil,
        forceShow: Bool = false
    ) async -> CampaignResponse? {
        if !forceShow {
            let hasActive = await subscriptionManager.hasActiveSubscription()
            if hasActive { return nil }
        }

        // Try preload cache first
        if let cached = getCached(placement), !cached.isExpired {
            if cached.isStale {
                Task { await self.fetchAndCache(placement, distinctId: distinctId, context: context) }
            }
            return cached.response
        }

        // Wait for in-flight preload, then fetch fresh if nothing cached
        let fromPreload = await waitForPreload(placement)
        if let result = fromPreload {
            return result
        }

        return await fetchAndCache(placement, distinctId: distinctId, context: context)
    }

    // MARK: - Cache invalidation

    public func invalidateCache(for placement: String) {
        lock.lock()
        defer { lock.unlock() }
        preloadCache.removeValue(forKey: placement)
    }

    public func invalidateAllCache() {
        lock.lock()
        defer { lock.unlock() }
        preloadCache.removeAll()
    }

    // MARK: - Private helpers

    @discardableResult
    private func fetchAndCache(
        _ placement: String,
        distinctId: String?,
        context: [String: AnyCodable]? = nil
    ) async -> CampaignResponse? {
        do {
            let response = try await apiClient.getCampaign(placement, distinctId: distinctId, context: context)
            let entry = PreloadEntry(response: response, storedAt: Date(), ttl: preloadTTL)
            setCache(placement, entry: entry)
            return response
        } catch {
            // Cache a nil tombstone so repeated fails don't hammer the server
            let entry = PreloadEntry(response: nil, storedAt: Date(), ttl: preloadTTL)
            setCache(placement, entry: entry)
            return nil
        }
    }

    private func getCached(_ placement: String) -> PreloadEntry? {
        lock.lock()
        defer { lock.unlock() }
        return preloadCache[placement]
    }

    private func setCache(_ placement: String, entry: PreloadEntry) {
        lock.lock()
        defer { lock.unlock() }
        preloadCache[placement] = entry
    }

    private func getActivePromise(_ placement: String) -> Task<CampaignResponse?, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return activePreloadPromises[placement]
    }

    private func setActivePromise(_ placement: String, task: Task<CampaignResponse?, Never>) {
        lock.lock()
        defer { lock.unlock() }
        activePreloadPromises[placement] = task
    }

    private func removeActivePromise(_ placement: String) {
        lock.lock()
        defer { lock.unlock() }
        activePreloadPromises.removeValue(forKey: placement)
    }
}
