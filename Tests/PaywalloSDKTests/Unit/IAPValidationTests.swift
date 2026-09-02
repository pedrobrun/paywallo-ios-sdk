import XCTest
@testable import PaywalloSDK

// MARK: - Spy

private final class IAPSpyBatcher: EventBatcherProtocol {
    var calls: [(name: String, properties: [String: AnyCodable], priority: EventPriority)] = []
    /// Shared ordering log so a test can assert emit-after-finish.
    var timeline: [String] = []

    func enqueue(name: String, properties: [String: AnyCodable], priority: EventPriority, timestamp: TimeInterval?) {
        calls.append((name: name, properties: properties, priority: priority))
        timeline.append("emit:\(name)")
    }

    func flush() async {}
    func dispose() {}
}

// MARK: - Tests

final class IAPValidationTests: XCTestCase {

    private var session: URLSession!
    private var apiClient: ApiClient!
    private var service: IAPService!
    private var spy: IAPSpyBatcher!

    private let body: [String: Any] = [
        "platform": "ios",
        "receipt_data": "jws_blob",
        "product_id": "com.test.pro",
        "transaction_id": "txn_001",
        "price_local": 9.99,
        "currency": "USD",
        "country": "US",
    ]

    override func setUp() async throws {
        try await super.setUp()
        MockURLProtocol.reset()
        await PendingRetry.shared.clear()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)

        let httpClient = HttpClient(
            baseUrl: "https://api.test.com",
            timeout: 10,
            retryConfig: RetryConfig(maxRetries: 2, baseDelay: 0.0, maxDelay: 0.0),
            debug: false,
            globalHeaders: [:],
            session: session
        )
        apiClient = ApiClient(httpClient: httpClient, appKey: "pk_test_key", debug: false)

        spy = IAPSpyBatcher()
        service = IAPService(apiClient: apiClient, debug: false)
        service.setTransactionEmitter(
            TransactionEmitter(
                batcher: spy,
                productProvider: { _ in nil },
                distinctIdProvider: { "distinct_1" },
                debug: false
            )
        )
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        await PendingRetry.shared.clear()
        try await super.tearDown()
    }

    // MARK: - classifyValidationError

    func testClassify_purchaseErrorWith4xx_isServer4xx() {
        for status in [400, 401, 404, 408, 422, 429, 499] {
            let error = PurchaseError(code: PurchaseErrorCode.validationFailed, message: "rejected", httpStatus: status)
            XCTAssertEqual(service.classifyValidationError(error), .server4xx, "status \(status)")
        }
    }

    func testClassify_purchaseErrorWith5xx_isNetwork() {
        let error = PurchaseError(code: PurchaseErrorCode.validationFailed, message: "boom", httpStatus: 503)
        XCTAssertEqual(service.classifyValidationError(error), .network)
    }

    func testClassify_purchaseErrorWithoutStatus_isNetwork() {
        let error = PurchaseErrorFactory.create(PurchaseErrorCode.validationFailed)
        XCTAssertEqual(service.classifyValidationError(error), .network)
    }

    func testClassify_nonPurchaseError_isNetwork() {
        XCTAssertEqual(service.classifyValidationError(URLError(.notConnectedToInternet)), .network)
    }

    // MARK: - Emission order

    func testValidateAndSettle_emitsCompletedOnlyAfterServerAcceptsAndTransactionFinishes() async {
        MockURLProtocol.enqueueJSON(["data": ["valid": true]], statusCode: 200)

        await service.validateAndSettle(
            body: body,
            productId: "com.test.pro",
            transactionId: "txn_001",
            paywallId: "pw_1",
            variantId: "var_1",
            finish: { [spy] in spy?.timeline.append("finish") }
        )

        XCTAssertEqual(spy.timeline, ["finish", "emit:transaction"])
        XCTAssertEqual(spy.calls.first?.properties["tx_id"]?.value as? String, "txn_001")
    }

    func testValidateAndSettle_serverSaysInvalid_finishesWithoutEmitting() async {
        MockURLProtocol.enqueueJSON(["data": ["valid": false]], statusCode: 200)

        await service.validateAndSettle(
            body: body,
            productId: "com.test.pro",
            transactionId: "txn_001",
            paywallId: nil,
            variantId: nil,
            finish: { [spy] in spy?.timeline.append("finish") }
        )

        XCTAssertEqual(spy.timeline, ["finish"])
        XCTAssertTrue(spy.calls.isEmpty)
    }

    /// A rejected purchase: 3 validation attempts (3s apart), then the receipt is dropped —
    /// 3 requests in total, no persisted retry, and no `transaction {completed}` anywhere.
    ///
    /// A 4th request would mean the 4xx was misread as transient. That is what happened while
    /// `validatePurchase` let a 4xx surface as an untyped decode failure: the status was lost,
    /// `classifyValidationError` fell through to `.network`, and a receipt that can never
    /// validate was posted again.
    func testValidateAndSettle_rejectedPurchase_retriesThreeTimesThenDrops() async {
        for _ in 0..<8 { MockURLProtocol.enqueueResponse(statusCode: 400, data: Data("{}".utf8)) }

        await service.validateAndSettle(
            body: body,
            productId: "com.test.pro",
            transactionId: "txn_001",
            paywallId: nil,
            variantId: nil,
            finish: { [spy] in spy?.timeline.append("finish") }
        )

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 3,
                       "4xx é permanente: 3 tentativas e para — sem o post extra do enqueue")
        XCTAssertEqual(spy.timeline, ["finish"],
                       "a transação precisa ser finalizada, senão a StoreKit reentrega para sempre")
        XCTAssertTrue(spy.calls.isEmpty, "a purchase the server rejected must not produce a revenue row")
    }

    // MARK: - enqueueValidationRetry

    func testEnqueueValidationRetry_success_persistsNothing() async {
        MockURLProtocol.enqueueResponse(statusCode: 200)

        await service.enqueueValidationRetry(body: body, transactionId: "txn_001")

        let pending = await PendingRetry.shared.snapshot()
        XCTAssertTrue(pending.isEmpty)
    }

    func testEnqueueValidationRetry_permanent4xx_dropsTheReceipt() async {
        MockURLProtocol.enqueueResponse(statusCode: 400)

        await service.enqueueValidationRetry(body: body, transactionId: "txn_001")

        let pending = await PendingRetry.shared.snapshot()
        XCTAssertTrue(pending.isEmpty, "an invalid receipt cannot be fixed by retrying")
    }

    func testEnqueueValidationRetry_429_isPersisted() async {
        // HttpClient exhausts its own retries and RETURNS the 429 — it does not throw.
        for _ in 0..<3 { MockURLProtocol.enqueueResponse(statusCode: 429) }

        await service.enqueueValidationRetry(body: body, transactionId: "txn_001")

        let pending = await PendingRetry.shared.snapshot()
        XCTAssertEqual(pending.count, 1)
    }

    func testEnqueueValidationRetry_5xx_isPersisted() async {
        for _ in 0..<3 { MockURLProtocol.enqueueResponse(statusCode: 503) }

        await service.enqueueValidationRetry(body: body, transactionId: "txn_001")

        let pending = await PendingRetry.shared.snapshot()
        XCTAssertEqual(pending.count, 1)
    }

    func testEnqueueValidationRetry_networkFailure_isPersisted() async {
        for _ in 0..<3 { MockURLProtocol.enqueueError(URLError(.notConnectedToInternet)) }

        await service.enqueueValidationRetry(body: body, transactionId: "txn_001")

        let pending = await PendingRetry.shared.snapshot()
        XCTAssertEqual(pending.count, 1)
    }

    func testEnqueueValidationRetry_persistsPathHeadersAndUnwrappedBody() async {
        for _ in 0..<3 { MockURLProtocol.enqueueResponse(statusCode: 503) }

        await service.enqueueValidationRetry(body: body, transactionId: "txn_001")

        let pending = await PendingRetry.shared.snapshot()
        guard let item = pending.first else { return XCTFail("nothing persisted") }

        XCTAssertEqual(item.url, "/sdk/purchases/validate")
        XCTAssertEqual(item.headers, ["X-App-Key": "pk_test_key"])

        // The body is re-posted byte-for-byte: a complete validation request, never
        // re-wrapped into an envelope (incident 03/08/2026).
        let decoded = try? JSONSerialization.jsonObject(with: item.body) as? [String: Any]
        XCTAssertEqual(decoded?["transaction_id"] as? String, "txn_001")
        XCTAssertEqual(decoded?["receipt_data"] as? String, "jws_blob")
        XCTAssertEqual(decoded?["product_id"] as? String, "com.test.pro")
        XCTAssertNil(decoded?["events"])
    }
}
