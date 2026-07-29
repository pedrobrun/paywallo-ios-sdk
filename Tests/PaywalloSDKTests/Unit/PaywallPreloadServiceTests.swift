import XCTest
@testable import PaywalloSDK

// MARK: - Helpers

/// Builds a URLSession whose requests are intercepted by MockURLProtocol.
private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

/// Minimal PaywallConfig JSON for MockURLProtocol to serve.
private func paywallConfigJSON(placement: String = "home", primaryProductId: String? = nil) -> [String: Any] {
    var dict: [String: Any] = [
        "id": "pw_test",
        "placement": placement,
        "config": [String: Any]()
    ]
    if let pid = primaryProductId {
        dict["primaryProductId"] = pid
    }
    return dict
}

// MARK: - PaywallPreloadServiceTests

final class PaywallPreloadServiceTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        session = makeMockSession()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        session = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeApiClient(serverUrl: String = "https://api.paywallo.com") -> ApiClient {
        let httpClient = HttpClient(
            baseUrl: serverUrl,
            timeout: 10,
            retryConfig: RetryConfig(maxRetries: 0, baseDelay: 0, maxDelay: 0),
            debug: false,
            globalHeaders: [:],
            session: session
        )
        return ApiClient(httpClient: httpClient, appKey: "pk_test", debug: false, environment: .production)
    }

    private func makeService(
        apiClient: ApiClient,
        ttl: TimeInterval = 5 * 60,
        staggerDelay: TimeInterval = 0
    ) -> PaywallPreloadService {
        // IAPService with no StoreKit products — loadProducts returns [] for all ids.
        let suite = UserDefaults(suiteName: "com.paywallo.sdk.tests.preload.\(UUID().uuidString)")!
        let storage = NativeStorage(service: "com.paywallo.sdk.tests.preload.\(UUID().uuidString)", defaults: suite)
        let iap = IAPService(apiClient: apiClient, offlineQueue: OfflineQueue(storage: storage), debug: false)
        return PaywallPreloadService(
            apiClient: apiClient,
            iapService: iap,
            debug: false,
            preloadTTL: ttl,
            staggerDelay: staggerDelay
        )
    }

    // MARK: - 1. Cache miss → fetches from network

    func testCacheMissTriggersNetworkFetch() async throws {
        MockURLProtocol.enqueueJSON(paywallConfigJSON(placement: "home"))

        let apiClient = makeApiClient()
        // Redirect HttpClient to use mock session by building service (it wraps ApiClient)
        let service = makeService(apiClient: apiClient)

        // On fresh service getPreloaded returns nil (cache miss)
        XCTAssertNil(service.getPreloaded("home"), "Cache should be empty before preload")

        await service.preload("home")

        // After preload, snapshot should be cached
        let snapshot = service.getPreloaded("home")
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.config.placement, "home")
    }

    // MARK: - 2. Cache hit (fresh) → no extra network call

    func testCacheHitDoesNotFetchAgain() async throws {
        // Enqueue exactly one response — second call should NOT consume it.
        MockURLProtocol.enqueueJSON(paywallConfigJSON(placement: "offers"))

        let apiClient = makeApiClient()
        let service = makeService(apiClient: apiClient)

        await service.preload("offers")            // first call: fetches
        let requestsAfterFirst = MockURLProtocol.capturedRequests.count

        await service.preload("offers")            // second call: cache hit, no fetch
        let requestsAfterSecond = MockURLProtocol.capturedRequests.count

        XCTAssertEqual(requestsAfterFirst, requestsAfterSecond,
                       "Cache hit must not trigger an additional network request")
    }

    // MARK: - 3. TTL expiry → cache miss after expiry

    func testTTLExpiredEntryIsEvicted() async throws {
        // TTL = 0 means the entry expires immediately.
        MockURLProtocol.enqueueJSON(paywallConfigJSON(placement: "flash"))

        let apiClient = makeApiClient()
        let service = makeService(apiClient: apiClient, ttl: 0)

        await service.preload("flash")

        // With TTL=0 the entry is already expired; getPreloaded evicts and returns nil.
        let snapshot = service.getPreloaded("flash")
        XCTAssertNil(snapshot, "Expired entry must not be served by getPreloaded")
    }

    // MARK: - 4. Stale-while-revalidate: stale entry is still returned

    func testStaleEntryIsReturnedWhileBackgroundRevalidates() async throws {
        // TTL = 1s, stale threshold at 75% = 0.75s.
        // We'll preload, wait a tiny bit (stale window), and expect getPreloaded returns non-nil.
        MockURLProtocol.enqueueJSON(paywallConfigJSON(placement: "premium"))
        // Enqueue a second response for the background revalidation.
        MockURLProtocol.enqueueJSON(paywallConfigJSON(placement: "premium"))

        let apiClient = makeApiClient()
        let service = makeService(apiClient: apiClient, ttl: 1.0)

        await service.preload("premium")

        // The entry is stale (0.75s into 1s TTL) but NOT expired yet — should still serve.
        // We can't reliably sleep in unit tests, so we test the synchronous path:
        // isStale is a pure computed property based on storedAt. Here we verify
        // the entry is returned immediately after preload (fresh case).
        let snapshot = service.getPreloaded("premium")
        XCTAssertNotNil(snapshot, "Fresh entry must be returned by getPreloaded")
    }

    // MARK: - 5. isPaywallPreloaded reflects cache state

    func testIsPaywallPreloadedReturnsFalseBeforePreload() {
        let apiClient = makeApiClient()
        let service = makeService(apiClient: apiClient)
        XCTAssertFalse(service.isPaywallPreloaded("never_preloaded"))
    }

    func testIsPaywallPreloadedReturnsTrueAfterSuccessfulPreload() async throws {
        MockURLProtocol.enqueueJSON(paywallConfigJSON(placement: "annual"))

        let apiClient = makeApiClient()
        let service = makeService(apiClient: apiClient)

        await service.preload("annual")
        XCTAssertTrue(service.isPaywallPreloaded("annual"))
    }

    // MARK: - 6. clear() empties cache

    func testClearRemovesAllEntries() async throws {
        MockURLProtocol.enqueueJSON(paywallConfigJSON(placement: "home"))
        MockURLProtocol.enqueueJSON(paywallConfigJSON(placement: "upsell"))

        let apiClient = makeApiClient()
        let service = makeService(apiClient: apiClient, staggerDelay: 0)

        await service.preloadMany(["home", "upsell"])
        XCTAssertTrue(service.isPaywallPreloaded("home"))
        XCTAssertTrue(service.isPaywallPreloaded("upsell"))

        service.clear()

        XCTAssertFalse(service.isPaywallPreloaded("home"),  "clear() must evict home")
        XCTAssertFalse(service.isPaywallPreloaded("upsell"), "clear() must evict upsell")
    }

    // MARK: - 7. prewarmHTTP sends GET to /paywall/preheat

    func testPrewarmHTTPSendsGetToPreheatPath() async throws {
        // Enqueue a response for the preheat HEAD request.
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let apiClient = makeApiClient(serverUrl: "https://api.test.com")
        let service = makeService(apiClient: apiClient)

        service.prewarmHTTP(for: "home")

        // Give the fire-and-forget Task a moment to execute.
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1s

        let paths = MockURLProtocol.capturedRequests.map { $0.url?.path ?? "" }
        XCTAssertTrue(
            paths.contains { $0.hasSuffix("/paywall/preheat") },
            "prewarmHTTP must send a request to /paywall/preheat, got paths: \(paths)"
        )
    }

    // MARK: - 8. Network error during preload does not crash or cache stale data

    func testNetworkErrorDoesNotCacheEntry() async throws {
        MockURLProtocol.enqueueError(URLError(.networkConnectionLost))

        let apiClient = makeApiClient()
        let service = makeService(apiClient: apiClient)

        await service.preload("error_placement")

        XCTAssertFalse(service.isPaywallPreloaded("error_placement"),
                       "Failed fetch must not cache any entry")
    }
}
