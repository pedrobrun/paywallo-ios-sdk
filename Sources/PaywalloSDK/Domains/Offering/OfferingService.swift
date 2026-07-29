import Foundation

// MARK: - Offering Types

/// Matches the server's SdkOfferingProduct shape (snake_case):
/// `{ id, name, description, type, apple_product_id, google_product_id, billing_period, trial_days, price_usd, regional_prices, display_order, is_active }`
public struct OfferingProduct: Codable, Sendable {
    /// Server product UUID.
    public let id: String?
    public let name: String
    /// Apple App Store product identifier.
    public let appleProductId: String?
    /// Google Play product identifier.
    public let googleProductId: String?
    public let billingPeriod: String?
    public let trialDays: Int?
    public let priceUsd: Double?
    public let displayOrder: Int?
    public let isActive: Bool?
    public let type: String?

    /// Convenience alias — returns `appleProductId` (iOS SDK).
    public var storeProductId: String? { appleProductId }
    /// Convenience alias — returns `priceUsd`.
    public var price: Double? { priceUsd }
    /// Convenience alias — returns `displayOrder`.
    public var position: Int? { displayOrder }

    enum CodingKeys: String, CodingKey {
        case id, name, type
        case appleProductId = "apple_product_id"
        case googleProductId = "google_product_id"
        case billingPeriod = "billing_period"
        case trialDays = "trial_days"
        case priceUsd = "price_usd"
        case displayOrder = "display_order"
        case isActive = "is_active"
    }

    public init(
        id: String? = nil,
        name: String,
        appleProductId: String? = nil,
        googleProductId: String? = nil,
        billingPeriod: String? = nil,
        trialDays: Int? = nil,
        priceUsd: Double? = nil,
        displayOrder: Int? = nil,
        isActive: Bool? = nil,
        type: String? = nil
    ) {
        self.id = id
        self.name = name
        self.appleProductId = appleProductId
        self.googleProductId = googleProductId
        self.billingPeriod = billingPeriod
        self.trialDays = trialDays
        self.priceUsd = priceUsd
        self.displayOrder = displayOrder
        self.isActive = isActive
        self.type = type
    }
}

public struct Offering: Codable, Sendable {
    public let id: String
    public let identifier: String
    public let name: String
    public let description: String?
    public let products: [OfferingProduct]
    public var metadata: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case id, identifier, name, description, products, metadata
    }

    public init(
        id: String,
        identifier: String,
        name: String,
        description: String? = nil,
        products: [OfferingProduct],
        metadata: [String: AnyCodable]? = nil
    ) {
        self.id = id
        self.identifier = identifier
        self.name = name
        self.description = description
        self.products = products
        self.metadata = metadata
    }
}

// MARK: - Cached Offering Entry

private struct CachedOfferingEntry: Codable {
    let offerings: [Offering]
    let cachedAt: TimeInterval
}

// MARK: - OfferingService

public final class OfferingService: @unchecked Sendable {

    // MARK: - Configuration

    private let cacheTTL: TimeInterval
    private let staleThreshold: TimeInterval
    private let cacheKey = PaywalloConstants.offeringsCacheKey

    // MARK: - Dependencies

    private let apiClient: ApiClient
    private let storage: SecureStorage

    // MARK: - In-memory cache

    private let lock = NSLock()
    private var memoryCache: (offerings: [Offering], storedAt: Date)?

    // MARK: - Init

    public init(
        apiClient: ApiClient,
        storage: SecureStorage = .shared,
        cacheTTL: TimeInterval = 5 * 60
    ) {
        self.apiClient = apiClient
        self.storage = storage
        self.cacheTTL = cacheTTL
        self.staleThreshold = cacheTTL * 0.8
    }

    // MARK: - Public API

    /// Fetch offerings, optionally filtered by IDs. Stale-while-revalidate from SecureStorage.
    public func getOfferings(ids: [String]? = nil) async throws -> [Offering] {
        // Memory cache hit (still fresh)
        if let mem = getMemoryCache(), !isExpired(mem.storedAt) {
            if isStale(mem.storedAt) {
                Task { try? await self.fetchAndPersist(ids: ids) }
            }
            return mem.offerings
        }

        // Persistent cache fallback
        if let persisted = await loadFromStorage() {
            let storedAt = Date(timeIntervalSince1970: persisted.cachedAt)
            if !isExpired(storedAt) {
                setMemoryCache(persisted.offerings, storedAt: storedAt)
                if isStale(storedAt) {
                    Task { try? await self.fetchAndPersist(ids: ids) }
                }
                return persisted.offerings
            }
        }

        // Fetch fresh
        return try await fetchAndPersist(ids: ids)
    }

    /// Invalidate in-memory and persistent cache.
    public func invalidateCache() async {
        lock.lock()
        memoryCache = nil
        lock.unlock()
        await storage.remove(cacheKey)
    }

    // MARK: - Private

    @discardableResult
    private func fetchAndPersist(ids: [String]?) async throws -> [Offering] {
        let rawData = try await apiClient.getOfferings(ids: ids)
        let offerings = try decode(rawData)

        let now = Date()
        setMemoryCache(offerings, storedAt: now)
        await persistToStorage(offerings, storedAt: now)
        return offerings
    }

    private func decode(_ data: Data) throws -> [Offering] {
        let decoder = JSONDecoder()

        // Try direct array first
        if let offerings = try? decoder.decode([Offering].self, from: data) {
            return offerings
        }

        // Try wrapped { data: [...] }
        struct Wrapper: Decodable {
            let data: [Offering]
        }
        if let wrapped = try? decoder.decode(Wrapper.self, from: data) {
            return wrapped.data
        }

        // Try server shape { data: { offerings: [...] } }
        struct OfferingsWrapper: Decodable {
            struct Inner: Decodable { let offerings: [Offering] }
            let data: Inner
        }
        if let wrapped = try? decoder.decode(OfferingsWrapper.self, from: data) {
            return wrapped.data.offerings
        }

        // Try double-wrapped { data: { data: [...] } }
        struct DoubleWrapper: Decodable {
            struct Inner: Decodable { let data: [Offering] }
            let data: Inner
        }
        let doubleWrapped = try decoder.decode(DoubleWrapper.self, from: data)
        return doubleWrapped.data.data
    }

    private func persistToStorage(_ offerings: [Offering], storedAt: Date) async {
        let entry = CachedOfferingEntry(offerings: offerings, cachedAt: storedAt.timeIntervalSince1970)
        guard let jsonData = try? JSONEncoder().encode(entry),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        await storage.set(cacheKey, value: json)
    }

    private func loadFromStorage() async -> CachedOfferingEntry? {
        guard let raw = await storage.get(cacheKey),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CachedOfferingEntry.self, from: data)
    }

    // MARK: - Memory cache helpers (lock-protected)

    private func getMemoryCache() -> (offerings: [Offering], storedAt: Date)? {
        lock.lock()
        defer { lock.unlock() }
        return memoryCache
    }

    private func setMemoryCache(_ offerings: [Offering], storedAt: Date) {
        lock.lock()
        defer { lock.unlock() }
        memoryCache = (offerings, storedAt)
    }

    // MARK: - TTL helpers

    private func isExpired(_ storedAt: Date) -> Bool {
        Date().timeIntervalSince(storedAt) >= cacheTTL
    }

    private func isStale(_ storedAt: Date) -> Bool {
        Date().timeIntervalSince(storedAt) >= staleThreshold
    }
}
