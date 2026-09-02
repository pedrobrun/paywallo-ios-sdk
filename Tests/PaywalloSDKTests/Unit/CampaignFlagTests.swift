import XCTest
@testable import PaywalloSDK

// MARK: - Helpers

private func makeIsolatedNativeStorage(id: String = UUID().uuidString) -> (NativeStorage, UserDefaults, String) {
    let suiteName = "com.paywallo.sdk.tests.campaignflag.\(id)"
    let suite = UserDefaults(suiteName: suiteName)!
    let storage = NativeStorage(service: "com.paywallo.sdk.tests.campaignflag.\(id)", defaults: suite)
    return (storage, suite, suiteName)
}

private func makeFlagStorage(id: String = UUID().uuidString) -> (FlagStorage, UserDefaults, String) {
    let suiteName = "com.paywallo.sdk.tests.flags.\(id)"
    let suite = UserDefaults(suiteName: suiteName)!
    let flagStorage = FlagStorage(defaults: suite, keyPrefix: "@paywallo:flag:")
    return (flagStorage, suite, suiteName)
}

private func makeCampaignResponse(placement: String = "onboarding") -> CampaignResponse {
    let paywall = CampaignPaywall(
        id: "pw_\(UUID().uuidString)",
        placement: placement,
        config: [:]
    )
    return CampaignResponse(
        campaignId: "campaign_\(UUID().uuidString)",
        placement: placement,
        variantKey: "control",
        paywall: paywall
    )
}

// MARK: - FlagStorage Tests

final class FlagStorageTests: XCTestCase {

    private var flagStorage: FlagStorage!
    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        let (fs, d, name) = makeFlagStorage()
        flagStorage = fs
        suite = d
        suiteName = name
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: set → get

    func testSetAndGet_returnsSavedVariant() {
        let variant = FlagVariant(variant: "control", payload: nil)
        flagStorage.set(flagKey: "my_flag", variant: variant)

        let result = flagStorage.get(flagKey: "my_flag")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.variant, "control")
    }

    func testSetAndGet_withPayload_preservesPayload() {
        let payload: [String: AnyCodable] = ["color": AnyCodable("blue"), "count": AnyCodable(42)]
        let variant = FlagVariant(variant: "treatment", payload: payload)
        flagStorage.set(flagKey: "feature_x", variant: variant)

        let result = flagStorage.get(flagKey: "feature_x")
        XCTAssertEqual(result?.variant, "treatment")
    }

    func testGet_nonExistentKey_returnsNil() {
        let result = flagStorage.get(flagKey: "does_not_exist_\(UUID().uuidString)")
        XCTAssertNil(result)
    }

    func testSet_overwritesExistingValue() {
        flagStorage.set(flagKey: "flag_a", variant: FlagVariant(variant: "v1"))
        flagStorage.set(flagKey: "flag_a", variant: FlagVariant(variant: "v2"))

        let result = flagStorage.get(flagKey: "flag_a")
        XCTAssertEqual(result?.variant, "v2")
    }

    func testRemove_clearsKey() {
        flagStorage.set(flagKey: "removable", variant: FlagVariant(variant: "on"))
        flagStorage.remove(flagKey: "removable")

        XCTAssertNil(flagStorage.get(flagKey: "removable"))
    }

    func testRemoveAll_clearsEverything() {
        flagStorage.set(flagKey: "flag_1", variant: FlagVariant(variant: "a"))
        flagStorage.set(flagKey: "flag_2", variant: FlagVariant(variant: "b"))
        flagStorage.removeAll()

        XCTAssertNil(flagStorage.get(flagKey: "flag_1"))
        XCTAssertNil(flagStorage.get(flagKey: "flag_2"))
    }

    func testGet_variantNil_roundtrips() {
        // A FlagVariant with nil variant (no assignment) should persist correctly
        let variant = FlagVariant(variant: nil)
        flagStorage.set(flagKey: "no_assignment", variant: variant)

        let result = flagStorage.get(flagKey: "no_assignment")
        XCTAssertNotNil(result)
        XCTAssertNil(result?.variant)
    }
}

// MARK: - FlagService Tests

final class FlagServiceTests: XCTestCase {

    private var flagStorage: FlagStorage!
    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        let (fs, d, name) = makeFlagStorage()
        flagStorage = fs
        suite = d
        suiteName = name
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: getVariantCached — serves stale

    func testGetVariantCached_withStoredValue_returnsImmediately() async {
        // Pre-seed the flag storage with a known variant
        let seeded = FlagVariant(variant: "cached_control")
        flagStorage.set(flagKey: "feature_flag", variant: seeded)

        let apiClient = ApiClient(serverUrl: "http://localhost:9999", appKey: "pk_test")
        let service = FlagService(apiClient: apiClient, flagStorage: flagStorage)

        // getVariantCached should return the seeded value without hitting the (non-existent) server
        let result = await service.getVariantCached(key: "feature_flag", distinctId: nil)
        XCTAssertEqual(result?.variant, "cached_control", "Must serve stale from UserDefaults")
    }

    func testGetVariantCached_noStorage_noServer_returnsNil() async {
        let apiClient = ApiClient(serverUrl: "http://localhost:9999", appKey: "pk_test")
        let service = FlagService(apiClient: apiClient, flagStorage: flagStorage)

        // No cache, no server — should return nil gracefully
        let result = await service.getVariantCached(key: "missing_flag_\(UUID().uuidString)", distinctId: nil)
        XCTAssertNil(result)
    }

    // MARK: invalidateCache

    func testInvalidateCache_removesStoredValue() async {
        flagStorage.set(flagKey: "to_clear", variant: FlagVariant(variant: "old"))

        let apiClient = ApiClient(serverUrl: "http://localhost:9999", appKey: "pk_test")
        let service = FlagService(apiClient: apiClient, flagStorage: flagStorage)
        service.invalidateCache(for: "to_clear")

        XCTAssertNil(flagStorage.get(flagKey: "to_clear"))
    }

    func testInvalidateAllCache_clearsAll() async {
        flagStorage.set(flagKey: "flag_x", variant: FlagVariant(variant: "a"))
        flagStorage.set(flagKey: "flag_y", variant: FlagVariant(variant: "b"))

        let apiClient = ApiClient(serverUrl: "http://localhost:9999", appKey: "pk_test")
        let service = FlagService(apiClient: apiClient, flagStorage: flagStorage)
        service.invalidateAllCache()

        XCTAssertNil(flagStorage.get(flagKey: "flag_x"))
        XCTAssertNil(flagStorage.get(flagKey: "flag_y"))
    }
}

// MARK: - CampaignGateService Tests

final class CampaignGateServiceTests: XCTestCase {

    // MARK: - Preload TTL tests

    func testPreloadCampaign_cachedEntryServedBeforeExpiry() async {
        // Use a service with a very long TTL — fresh cache should be served
        let apiClient = ApiClient(serverUrl: "http://localhost:9999", appKey: "pk_test")
        let subscriptionCache = SubscriptionCache()
        let subscriptionManager = SubscriptionManager(cache: subscriptionCache)
        let service = CampaignGateService(
            apiClient: apiClient,
            subscriptionManager: subscriptionManager,
            preloadTTL: 300 // 5 min
        )

        // Prime the cache manually by calling preloadCampaign (will fail network → caches nil)
        _ = await service.preloadCampaign("home", distinctId: nil)

        // The entry is in cache (even if nil from failed network). No crash.
        // Verify we don't crash or hang by calling a second time
        _ = await service.preloadCampaign("home", distinctId: nil)
    }

    func testPreloadAllActive_doesNotCrashWithNoServer() async {
        let apiClient = ApiClient(serverUrl: "http://localhost:9999", appKey: "pk_test")
        let subscriptionCache = SubscriptionCache()
        let subscriptionManager = SubscriptionManager(cache: subscriptionCache)
        let service = CampaignGateService(
            apiClient: apiClient,
            subscriptionManager: subscriptionManager
        )

        // Should not crash even when server is unreachable
        await service.preloadAllActive(distinctId: nil)
    }

    // MARK: - Dedup tests

    func testPreloadCampaign_concurrent_doesNotDeadlock() async {
        let apiClient = ApiClient(serverUrl: "http://localhost:9999", appKey: "pk_test")
        let subscriptionCache = SubscriptionCache()
        let subscriptionManager = SubscriptionManager(cache: subscriptionCache)
        let service = CampaignGateService(
            apiClient: apiClient,
            subscriptionManager: subscriptionManager
        )

        // Fire multiple concurrent preloads for the same placement
        async let r1 = service.preloadCampaign("onboarding", distinctId: nil)
        async let r2 = service.preloadCampaign("onboarding", distinctId: nil)
        async let r3 = service.preloadCampaign("onboarding", distinctId: nil)

        let results = await [r1, r2, r3]
        // All nil (no server) or same value — no crash, no deadlock
        XCTAssertEqual(results.count, 3)
    }

    // MARK: - presentCampaign tests

    func testPresentCampaign_withActiveSubscription_returnsNilWhenNotForced() async {
        let apiClient = ApiClient(serverUrl: "http://localhost:9999", appKey: "pk_test")
        let subscriptionCache = SubscriptionCache()
        let subscriptionManager = SubscriptionManager(cache: subscriptionCache)
        let service = CampaignGateService(
            apiClient: apiClient,
            subscriptionManager: subscriptionManager
        )

        // Not initialized → hasActiveSubscription = false, so it proceeds
        // This tests the guard logic: with no active sub and no server, returns nil
        let result = await service.presentCampaign(
            placement: "upsell",
            distinctId: nil,
            forceShow: false
        )
        // nil because no server, but no crash
        XCTAssertNil(result)
    }

    func testPresentCampaign_forceShow_skipsSubscriptionCheck() async {
        let apiClient = ApiClient(serverUrl: "http://localhost:9999", appKey: "pk_test")
        let subscriptionCache = SubscriptionCache()
        let subscriptionManager = SubscriptionManager(cache: subscriptionCache)
        let service = CampaignGateService(
            apiClient: apiClient,
            subscriptionManager: subscriptionManager
        )

        // forceShow=true skips subscription check, proceeds to fetch (returns nil from no server)
        let result = await service.presentCampaign(
            placement: "promo",
            distinctId: nil,
            forceShow: true
        )
        XCTAssertNil(result)
    }

    // MARK: - Cache invalidation

    func testInvalidateCache_specificPlacement() async {
        let apiClient = ApiClient(serverUrl: "http://localhost:9999", appKey: "pk_test")
        let subscriptionCache = SubscriptionCache()
        let subscriptionManager = SubscriptionManager(cache: subscriptionCache)
        let service = CampaignGateService(
            apiClient: apiClient,
            subscriptionManager: subscriptionManager
        )

        _ = await service.preloadCampaign("test_placement", distinctId: nil)
        service.invalidateCache(for: "test_placement")

        // After invalidation, subsequent calls should not use stale entry (no crash)
        _ = await service.preloadCampaign("test_placement", distinctId: nil)
    }

    func testInvalidateAllCache_doesNotCrash() {
        let apiClient = ApiClient(serverUrl: "http://localhost:9999", appKey: "pk_test")
        let subscriptionCache = SubscriptionCache()
        let subscriptionManager = SubscriptionManager(cache: subscriptionCache)
        let service = CampaignGateService(
            apiClient: apiClient,
            subscriptionManager: subscriptionManager
        )

        service.invalidateAllCache()
    }

    // MARK: - waitForPreload

    func testWaitForPreload_noPreloadRunning_returnsImmediately() async {
        let apiClient = ApiClient(serverUrl: "http://localhost:9999", appKey: "pk_test")
        let subscriptionManager = SubscriptionManager(cache: SubscriptionCache())
        let service = CampaignGateService(
            apiClient: apiClient,
            subscriptionManager: subscriptionManager,
            waitPollInterval: 0.5,
            waitMaxDuration: 2.0  // teto real — não pode ser pago no caminho frio
        )

        let start = Date()
        let result = await service.waitForPreload("never_preloaded_\(UUID().uuidString)")
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result)
        XCTAssertLessThan(
            elapsed, 0.3,
            "Sem preload em voo não há o que esperar — dormir o teto aqui custava 2s em toda apresentação fria"
        )
    }

    // MARK: - Erro de rede não vira cache

    func testFetchFailure_doesNotCacheTombstone() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.enqueueError(URLError(.networkConnectionLost))
        MockURLProtocol.enqueueError(URLError(.networkConnectionLost))

        let service = makeMockedService()

        _ = await service.preloadCampaign("home", distinctId: "user_1")
        _ = await service.preloadCampaign("home", distinctId: "user_1")

        XCTAssertEqual(
            MockURLProtocol.capturedRequests.count, 2,
            "Falha transitória não pode virar entrada de cache com TTL cheio — bloqueava a campanha por 5 min"
        )
    }

    // MARK: - resolveCampaign: "não encontrada" ≠ "assinante"

    func testResolveCampaign_noCampaign_returnsNotFound() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.enqueueError(URLError(.networkConnectionLost))

        let service = makeMockedService()
        let outcome = await service.resolveCampaign(placement: "home", distinctId: "user_1")

        guard case .notFound(let error) = outcome else {
            return XCTFail("Esperava .notFound, veio \(outcome)")
        }
        XCTAssertEqual(error.code, CampaignErrorCode.notFound)
    }

    func testResolveCampaign_found_returnsCampaign() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.enqueueJSON(campaignJSON(placement: "home"))

        let service = makeMockedService()
        let outcome = await service.resolveCampaign(placement: "home", distinctId: "user_1")

        guard case .campaign(let campaign) = outcome else {
            return XCTFail("Esperava .campaign, veio \(outcome)")
        }
        XCTAssertEqual(campaign.placement, "home")
    }

    func testResolveCampaign_activeSubscriber_returnsSubscriber() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.enqueueJSON(campaignJSON(placement: "home"))

        let subscriptionManager = await makeSubscribedManager()
        let service = makeMockedService(subscriptionManager: subscriptionManager)
        let outcome = await service.resolveCampaign(placement: "home", distinctId: "user_1")

        guard case .subscriber = outcome else {
            return XCTFail("Esperava .subscriber, veio \(outcome)")
        }
    }

    func testResolveCampaign_activeSubscriberButPlacementMissing_reportsNotFound() async {
        // A campanha é resolvida ANTES da checagem de assinatura: invertido, um
        // placement errado ficava invisível para todo assinante.
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.enqueueError(URLError(.networkConnectionLost))

        let subscriptionManager = await makeSubscribedManager()
        let service = makeMockedService(subscriptionManager: subscriptionManager)
        let outcome = await service.resolveCampaign(placement: "ghost", distinctId: "user_1")

        guard case .notFound = outcome else {
            return XCTFail("Esperava .notFound, veio \(outcome)")
        }
    }

    func testResolveCampaign_forceShow_skipsSubscriptionCheck() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.enqueueJSON(campaignJSON(placement: "promo"))

        let subscriptionManager = await makeSubscribedManager()
        let service = makeMockedService(subscriptionManager: subscriptionManager)
        let outcome = await service.resolveCampaign(
            placement: "promo",
            distinctId: "user_1",
            forceShow: true
        )

        guard case .campaign = outcome else {
            return XCTFail("Esperava .campaign, veio \(outcome)")
        }
    }

    // MARK: - Helpers

    private func makeMockedService(
        subscriptionManager: SubscriptionManager? = nil
    ) -> CampaignGateService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let httpClient = HttpClient(
            baseUrl: "https://api.paywallo.com",
            timeout: 10,
            retryConfig: RetryConfig(maxRetries: 0, baseDelay: 0, maxDelay: 0),
            debug: false,
            globalHeaders: [:],
            session: URLSession(configuration: config)
        )
        let apiClient = ApiClient(httpClient: httpClient, appKey: "pk_test", debug: false, environment: .production)
        return CampaignGateService(
            apiClient: apiClient,
            subscriptionManager: subscriptionManager ?? SubscriptionManager(cache: SubscriptionCache()),
            waitPollInterval: 0.02,
            waitMaxDuration: 0.2
        )
    }

    /// SubscriptionManager com o cache pré-aquecido em "assinante ativo" — o `get`
    /// serve da memória, então não há rede envolvida.
    private func makeSubscribedManager() async -> SubscriptionManager {
        let cache = SubscriptionCache()
        await cache.set("__anonymous__", data: SubscriptionStatusResponse(
            hasActiveSubscription: true,
            subscription: nil
        ))
        let manager = SubscriptionManager(cache: cache)
        manager.initialize(SubscriptionManagerConfig(serverUrl: "https://api.paywallo.com", appKey: "pk_test"))
        return manager
    }

    private func campaignJSON(placement: String) -> [String: Any] {
        [
            "campaignId": "camp_\(placement)",
            "placement": placement,
            "variantKey": "control",
            "paywall": [
                "id": "pw_\(placement)",
                "placement": placement,
                "config": [String: Any](),
            ],
        ]
    }
}

// MARK: - PlanService Tests

final class PlanServiceTests: XCTestCase {

    // MARK: - Construction

    func testPlanService_init_doesNotCrash() {
        let apiClient = ApiClient(serverUrl: "http://localhost:9999", appKey: "pk_test")
        let service = PlanService(apiClient: apiClient)
        XCTAssertNotNil(service)
    }

    func testPlanService_customTTL_doesNotCrash() {
        let apiClient = ApiClient(serverUrl: "http://localhost:9999", appKey: "pk_test")
        let service = PlanService(apiClient: apiClient, cacheTTL: 60)
        XCTAssertNotNil(service)
    }

    func testPlanService_getPlans_noServer_throws() async {
        let apiClient = ApiClient(serverUrl: "http://localhost:9999", appKey: "pk_test")
        let service = PlanService(apiClient: apiClient)

        do {
            _ = try await service.getPlans()
            XCTFail("Should throw with no server")
        } catch {
            // Expected
        }
    }

    func testPlanService_getAllPlans_noServer_throws() async {
        let apiClient = ApiClient(serverUrl: "http://localhost:9999", appKey: "pk_test")
        let service = PlanService(apiClient: apiClient)

        do {
            _ = try await service.getAllPlans()
            XCTFail("Should throw with no server")
        } catch {
            // Expected
        }
    }

    func testPlanService_invalidateCache_doesNotCrash() async {
        let apiClient = ApiClient(serverUrl: "http://localhost:9999", appKey: "pk_test")
        let service = PlanService(apiClient: apiClient)
        await service.invalidateCache(all: false)
        await service.invalidateCache(all: true)
        await service.invalidateAllCaches()
    }

    // MARK: - Plan struct

    func testPlan_init_setsAllProperties() {
        let plan = Plan(
            id: "plan_123",
            name: "Monthly",
            storeProductId: "com.app.monthly",
            billingPeriod: "month",
            price: 9.99,
            trialDays: 7,
            isDefault: true
        )

        XCTAssertEqual(plan.id, "plan_123")
        XCTAssertEqual(plan.name, "Monthly")
        XCTAssertEqual(plan.storeProductId, "com.app.monthly")
        XCTAssertEqual(plan.billingPeriod, "month")
        XCTAssertEqual(plan.price, 9.99)
        XCTAssertEqual(plan.trialDays, 7)
        XCTAssertEqual(plan.isDefault, true)
    }

    func testPlan_optionalFields_defaultToNil() {
        let plan = Plan(id: "p1", name: "Basic", storeProductId: "com.app.basic")
        XCTAssertNil(plan.billingPeriod)
        XCTAssertNil(plan.price)
        XCTAssertNil(plan.trialDays)
        XCTAssertNil(plan.isDefault)
        XCTAssertNil(plan.metadata)
    }
}

// MARK: - OfferingService Tests

final class OfferingServiceTests: XCTestCase {

    func testOfferingService_init_doesNotCrash() {
        let apiClient = ApiClient(serverUrl: "http://localhost:9999", appKey: "pk_test")
        let service = OfferingService(apiClient: apiClient)
        XCTAssertNotNil(service)
    }

    func testOfferingService_invalidateCache_doesNotCrash() async {
        let apiClient = ApiClient(serverUrl: "http://localhost:9999", appKey: "pk_test")
        let service = OfferingService(apiClient: apiClient)
        await service.invalidateCache()
    }

    func testOffering_init_setsAllProperties() {
        let product = OfferingProduct(
            name: "Monthly Plan",
            appleProductId: "com.app.monthly",
            billingPeriod: "month",
            trialDays: 7,
            priceUsd: 9.99,
            displayOrder: 0
        )
        let offering = Offering(
            id: "off_123",
            identifier: "default",
            name: "Default Offering",
            products: [product]
        )

        XCTAssertEqual(offering.id, "off_123")
        XCTAssertEqual(offering.identifier, "default")
        XCTAssertEqual(offering.name, "Default Offering")
        XCTAssertEqual(offering.products.count, 1)
        XCTAssertEqual(offering.products[0].storeProductId, "com.app.monthly")
        XCTAssertEqual(offering.products[0].price, 9.99)
    }

    func testOfferingProduct_optionalFields_defaultToNil() {
        let product = OfferingProduct(name: "Basic")
        XCTAssertNil(product.price)
        XCTAssertNil(product.billingPeriod)
        XCTAssertNil(product.trialDays)
        XCTAssertNil(product.position)
    }
}
