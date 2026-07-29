import XCTest
@testable import PaywalloSDK

final class EventBatcherRetryTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        session = nil
        super.tearDown()
    }

    func testBatch_429_enqueuedForRetry_notDropped() async {
        MockURLProtocol.enqueueResponse(statusCode: 429)

        let httpClient = HttpClient(
            baseUrl: "https://api.test.com",
            timeout: 5,
            retryConfig: RetryConfig(maxRetries: 0, baseDelay: 0, maxDelay: 0),
            debug: false,
            globalHeaders: [:],
            session: session
        )

        let suiteName = "com.paywallo.batcher.tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        let nativeStorage = NativeStorage(service: suiteName, defaults: suite)
        let offlineQueue = OfflineQueue(
            storage: nativeStorage,
            maxCapacity: 100,
            maxAttempts: 3,
            maxAge: 3600,
            baseRetryDelay: 0.001,
            maxRetryDelay: 0.001
        )

        let batcher = EventBatcher()
        batcher.initialize(
            httpClient: httpClient,
            contextProvider: { IngestContext() },
            offlineQueue: offlineQueue,
            appKey: "pk_test",
            debug: false
        )

        batcher.enqueue(name: "lifecycle", properties: ["type": AnyCodable("cold_start")], priority: .normal)
        await batcher.flush()

        // 429 deve enfileirar no offlineQueue, não dropar
        XCTAssertEqual(offlineQueue.count, 1, "429 deve enqueue para retry, não ser dropado")
        offlineQueue.dispose()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    func testCritical_429_enqueuedForRetry_notDropped() async {
        MockURLProtocol.enqueueResponse(statusCode: 429)

        let httpClient = HttpClient(
            baseUrl: "https://api.test.com",
            timeout: 5,
            retryConfig: RetryConfig(maxRetries: 0, baseDelay: 0, maxDelay: 0),
            debug: false,
            globalHeaders: [:],
            session: session
        )

        let suiteName = "com.paywallo.batcher.critical.tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        let nativeStorage = NativeStorage(service: suiteName, defaults: suite)
        let offlineQueue = OfflineQueue(
            storage: nativeStorage,
            maxCapacity: 100,
            maxAttempts: 3,
            maxAge: 3600,
            baseRetryDelay: 0.001,
            maxRetryDelay: 0.001
        )

        let batcher = EventBatcher()
        batcher.initialize(
            httpClient: httpClient,
            contextProvider: { IngestContext() },
            offlineQueue: offlineQueue,
            appKey: "pk_test",
            debug: false
        )

        batcher.enqueue(name: "lifecycle", properties: ["type": AnyCodable("install")], priority: .critical)

        // Aguarda o flush assíncrono do critical (scheduleCriticalFlush → drainCritical)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // 429 no critical também deve enfileirar para retry
        XCTAssertEqual(offlineQueue.count, 1, "429 no critical deve enqueue para retry, não ser dropado")
        offlineQueue.dispose()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    func testBatch_400_dropsEvent_notEnqueued() async {
        MockURLProtocol.enqueueResponse(statusCode: 400)

        let httpClient = HttpClient(
            baseUrl: "https://api.test.com",
            timeout: 5,
            retryConfig: RetryConfig(maxRetries: 0, baseDelay: 0, maxDelay: 0),
            debug: false,
            globalHeaders: [:],
            session: session
        )

        let suiteName = "com.paywallo.batcher.400.tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        let nativeStorage = NativeStorage(service: suiteName, defaults: suite)
        let offlineQueue = OfflineQueue(
            storage: nativeStorage,
            maxCapacity: 100,
            maxAttempts: 3,
            maxAge: 3600,
            baseRetryDelay: 0.001,
            maxRetryDelay: 0.001
        )

        let batcher = EventBatcher()
        batcher.initialize(
            httpClient: httpClient,
            contextProvider: { IngestContext() },
            offlineQueue: offlineQueue,
            appKey: "pk_test",
            debug: false
        )

        batcher.enqueue(name: "lifecycle", properties: ["type": AnyCodable("cold_start")], priority: .normal)
        await batcher.flush()

        // 400 deve dropar o evento (payload inválido)
        XCTAssertEqual(offlineQueue.count, 0, "400 deve dropar o evento, não enfileirar")
        offlineQueue.dispose()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}
