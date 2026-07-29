import Foundation

// MARK: - Plan Types

/// Server sends plans as `SdkPlan` with nested `products` array (snake_case):
/// `{ id, identifier, name, description, metadata, products: [{ id, name, type, apple_product_id, billing_period, trial_days, price_usd, ... }] }`
/// This struct flattens the first iOS product into convenience fields for backward compat.
public struct Plan: Codable, Sendable {
    public let id: String
    /// Stable string identifier used to match the "current" plan (e.g. "pro_monthly").
    public let identifier: String?
    public let name: String
    public let storeProductId: String?
    public let billingPeriod: String?
    public let price: Double?
    public let trialDays: Int?
    public var isDefault: Bool?
    public var metadata: [String: AnyCodable]?
    /// Full list of products from the server (available for advanced use cases).
    public var products: [PlanProduct]?

    public init(
        id: String,
        identifier: String? = nil,
        name: String,
        storeProductId: String? = nil,
        billingPeriod: String? = nil,
        price: Double? = nil,
        trialDays: Int? = nil,
        isDefault: Bool? = nil,
        metadata: [String: AnyCodable]? = nil,
        products: [PlanProduct]? = nil
    ) {
        self.id = id
        self.identifier = identifier
        self.name = name
        self.storeProductId = storeProductId
        self.billingPeriod = billingPeriod
        self.price = price
        self.trialDays = trialDays
        self.isDefault = isDefault
        self.metadata = metadata
        self.products = products
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        name = try container.decode(String.self, forKey: .name)
        metadata = try container.decodeIfPresent([String: AnyCodable].self, forKey: .metadata)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault)

        // Decode nested products array from server (snake_case fields)
        let serverProducts = try container.decodeIfPresent([PlanProduct].self, forKey: .products)
        products = serverProducts

        // Flatten first product's data into convenience fields.
        // Prefer apple_product_id for iOS SDK; fall back to first product.
        let primary = serverProducts?.first(where: { $0.appleProductId != nil }) ?? serverProducts?.first
        storeProductId = try container.decodeIfPresent(String.self, forKey: .storeProductId) ?? primary?.appleProductId
        billingPeriod = try container.decodeIfPresent(String.self, forKey: .billingPeriod) ?? primary?.billingPeriod
        price = try container.decodeIfPresent(Double.self, forKey: .price) ?? primary?.priceUsd
        trialDays = try container.decodeIfPresent(Int.self, forKey: .trialDays) ?? primary?.trialDays
    }

    enum CodingKeys: String, CodingKey {
        case id, identifier, name, metadata, products
        case storeProductId, billingPeriod, price, trialDays
        case isDefault
    }
}

/// A product within a plan/offering, matching the server's SdkProduct shape (snake_case).
public struct PlanProduct: Codable, Sendable {
    public let id: String
    public let name: String
    public let type: String?
    public let appleProductId: String?
    public let googleProductId: String?
    public let billingPeriod: String?
    public let trialDays: Int?
    public let priceUsd: Double?
    public let displayOrder: Int?
    public let isActive: Bool?
    /// Intro offer mode (e.g. "freeTrial", "payAsYouGo", "payUpFront").
    public let introOfferMode: String?
    /// Intro offer price in USD.
    public let introOfferPrice: Double?
    /// Intro offer currency code (e.g. "USD").
    public let introOfferCurrency: String?
    /// Number of intro offer billing cycles.
    public let introOfferCycles: Int?
    /// Total intro offer duration in days.
    public let introOfferDurationDays: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, type
        case appleProductId = "apple_product_id"
        case googleProductId = "google_product_id"
        case billingPeriod = "billing_period"
        case trialDays = "trial_days"
        case priceUsd = "price_usd"
        case displayOrder = "display_order"
        case isActive = "is_active"
        case introOfferMode = "intro_offer_mode"
        case introOfferPrice = "intro_offer_price"
        case introOfferCurrency = "intro_offer_currency"
        case introOfferCycles = "intro_offer_cycles"
        case introOfferDurationDays = "intro_offer_duration_days"
    }

    public init(
        id: String, name: String, type: String? = nil,
        appleProductId: String? = nil, googleProductId: String? = nil,
        billingPeriod: String? = nil, trialDays: Int? = nil,
        priceUsd: Double? = nil, displayOrder: Int? = nil, isActive: Bool? = nil,
        introOfferMode: String? = nil, introOfferPrice: Double? = nil,
        introOfferCurrency: String? = nil, introOfferCycles: Int? = nil,
        introOfferDurationDays: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.appleProductId = appleProductId
        self.googleProductId = googleProductId
        self.billingPeriod = billingPeriod
        self.trialDays = trialDays
        self.priceUsd = priceUsd
        self.displayOrder = displayOrder
        self.isActive = isActive
        self.introOfferMode = introOfferMode
        self.introOfferPrice = introOfferPrice
        self.introOfferCurrency = introOfferCurrency
        self.introOfferCycles = introOfferCycles
        self.introOfferDurationDays = introOfferDurationDays
    }
}

/// Response from `/sdk/plans/all` — mirrors RN `AllPlansResponse`.
public struct AllPlansResponse: Codable, Sendable {
    public let plans: [Plan]
    public let currentIdentifier: String?

    public init(plans: [Plan], currentIdentifier: String?) {
        self.plans = plans
        self.currentIdentifier = currentIdentifier
    }
}

// MARK: - Cached Plan Entry

private struct CachedPlanEntry: Codable {
    let plans: [Plan]
    let cachedAt: TimeInterval
}

private struct CachedAllPlansEntry: Codable {
    let plans: [Plan]
    let currentIdentifier: String?
    let cachedAt: TimeInterval
}

// MARK: - PlanService

public final class PlanService: @unchecked Sendable {

    // MARK: - Configuration

    private let cacheTTL: TimeInterval
    private let staleThreshold: TimeInterval
    private let plansCacheKey = "plan_cache:active"
    private let allPlansCacheKey = "plan_cache:all"

    // MARK: - Dependencies

    private let apiClient: ApiClient
    private let storage: SecureStorage

    // MARK: - In-memory cache

    private let lock = NSLock()
    private var plansMemCache: (plans: [Plan], storedAt: Date)?
    private var allPlansMemCache: (plans: [Plan], storedAt: Date)?
    private var allPlansCurrentIdentifier: String?

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

    /// Fetch active plans (/sdk/plans). Stale-while-revalidate from SecureStorage.
    public func getPlans() async throws -> [Plan] {
        return try await fetchPlans(all: false)
    }

    /// Fetch all plans (/sdk/plans/all). Stale-while-revalidate from SecureStorage.
    public func getAllPlans() async throws -> [Plan] {
        return try await fetchPlans(all: true)
    }

    /// Fetch all plans and return the full response including `currentIdentifier`.
    /// Mirrors RN `planService.getAllPlans() → AllPlansResponse`.
    public func getAllPlansResponse() async throws -> AllPlansResponse {
        let plans = try await fetchPlans(all: true)
        let currentId = allPlansCurrentIdentifier
        return AllPlansResponse(plans: plans, currentIdentifier: currentId)
    }

    /// Returns the plan marked as "current" by the server, or nil if not set.
    /// Matches RN `planService.getCurrentPlan()`.
    public func getCurrentPlan() async throws -> Plan? {
        let plans = try await fetchPlans(all: true)
        // Read currentIdentifier without NSLock (safe: single async context reads after fetchPlans settles)
        let currentId = allPlansCurrentIdentifier
        guard let id = currentId else { return nil }
        return plans.first { $0.identifier == id }
    }

    /// Invalidate cache for a specific scope or all.
    public func invalidateCache(all: Bool = false) async {
        lock.lock()
        if all {
            allPlansMemCache = nil
        } else {
            plansMemCache = nil
        }
        lock.unlock()

        let key = all ? allPlansCacheKey : plansCacheKey
        await storage.remove(key)
    }

    /// Invalidate both caches.
    public func invalidateAllCaches() async {
        lock.lock()
        plansMemCache = nil
        allPlansMemCache = nil
        lock.unlock()
        await storage.remove(plansCacheKey)
        await storage.remove(allPlansCacheKey)
    }

    // MARK: - Private

    private func fetchPlans(all: Bool) async throws -> [Plan] {
        let cacheKey = all ? allPlansCacheKey : plansCacheKey

        // Memory cache
        if let mem = getMemoryCache(all: all), !isExpired(mem.storedAt) {
            if isStale(mem.storedAt) {
                Task { try? await self.fetchAndPersist(all: all) }
            }
            return mem.plans
        }

        // Persistent cache
        if let persisted = await loadFromStorage(key: cacheKey) {
            let storedAt = Date(timeIntervalSince1970: persisted.cachedAt)
            if !isExpired(storedAt) {
                setMemoryCache(persisted.plans, storedAt: storedAt, all: all)
                // Restore currentIdentifier from storage on cold boot.
                if all {
                    allPlansCurrentIdentifier = await storage.get(cacheKey + ":current_identifier")
                }
                if isStale(storedAt) {
                    Task { try? await self.fetchAndPersist(all: all) }
                }
                return persisted.plans
            }
        }

        return try await fetchAndPersist(all: all)
    }

    @discardableResult
    private func fetchAndPersist(all: Bool) async throws -> [Plan] {
        let rawData = all ? try await apiClient.getAllPlans() : try await apiClient.getPlans()
        let (plans, currentIdentifier) = try decodePlans(rawData, isAll: all)

        let now = Date()
        if all {
            allPlansCurrentIdentifier = currentIdentifier
        }
        setMemoryCache(plans, storedAt: now, all: all)
        let key = all ? allPlansCacheKey : plansCacheKey
        await persistToStorage(plans, storedAt: now, key: key, currentIdentifier: all ? currentIdentifier : nil)
        return plans
    }

    private func decodePlans(_ data: Data, isAll: Bool) throws -> (plans: [Plan], currentIdentifier: String?) {
        let decoder = JSONDecoder()

        // 1. Direct array
        if let plans = try? decoder.decode([Plan].self, from: data) {
            return (plans, nil)
        }

        // 2. V2 envelope with multiple plans: { data: { plans: [...], current_identifier: "..." }, meta: {...} }
        struct InnerAll: Decodable {
            let plans: [Plan]
            let current_identifier: String?
        }
        struct OuterAll: Decodable {
            let data: InnerAll
        }
        if isAll, let outer = try? decoder.decode(OuterAll.self, from: data) {
            return (outer.data.plans, outer.data.current_identifier)
        }

        // 3. V2 envelope with single plan: { data: { plan: Plan? }, meta: {...} }
        //    Server sends this for GET /sdk/plans (getCurrentPlan)
        struct InnerSingle: Decodable {
            let plan: Plan?
        }
        struct OuterSingle: Decodable {
            let data: InnerSingle
        }
        if !isAll, let outer = try? decoder.decode(OuterSingle.self, from: data) {
            if let plan = outer.data.plan {
                return ([plan], nil)
            }
            return ([], nil)
        }

        // 4. Simple wrapper { data: [...] }
        struct Wrapper: Decodable {
            let data: [Plan]
        }
        if let wrapped = try? decoder.decode(Wrapper.self, from: data) {
            return (wrapped.data, nil)
        }

        // 5. Double-wrapped { data: { data: [...] } }
        struct DoubleWrapper: Decodable {
            struct Inner: Decodable { let data: [Plan] }
            let data: Inner
        }
        let doubleWrapped = try decoder.decode(DoubleWrapper.self, from: data)
        return (doubleWrapped.data.data, nil)
    }

    private func persistToStorage(_ plans: [Plan], storedAt: Date, key: String, currentIdentifier: String? = nil) async {
        let entry = CachedPlanEntry(plans: plans, cachedAt: storedAt.timeIntervalSince1970)
        guard let jsonData = try? JSONEncoder().encode(entry),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        await storage.set(key, value: json)
        // Also persist the currentIdentifier alongside the all-plans cache key.
        if let id = currentIdentifier {
            await storage.set(key + ":current_identifier", value: id)
        }
    }

    private func loadFromStorage(key: String) async -> CachedPlanEntry? {
        guard let raw = await storage.get(key),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CachedPlanEntry.self, from: data)
    }

    // MARK: - Memory cache helpers

    private func getMemoryCache(all: Bool) -> (plans: [Plan], storedAt: Date)? {
        lock.lock()
        defer { lock.unlock() }
        return all ? allPlansMemCache : plansMemCache
    }

    private func setMemoryCache(_ plans: [Plan], storedAt: Date, all: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if all {
            allPlansMemCache = (plans, storedAt)
        } else {
            plansMemCache = (plans, storedAt)
        }
    }

    // MARK: - TTL helpers

    private func isExpired(_ storedAt: Date) -> Bool {
        Date().timeIntervalSince(storedAt) >= cacheTTL
    }

    private func isStale(_ storedAt: Date) -> Bool {
        Date().timeIntervalSince(storedAt) >= staleThreshold
    }
}
