import XCTest
@testable import PaywalloSDK

// MARK: - SpyBatcher for TransactionEmitter tests

private final class SpyBatcher: EventBatcherProtocol {
    struct Call {
        let name: String
        let properties: [String: AnyCodable]
        let priority: EventPriority
    }

    var calls: [Call] = []

    func enqueue(
        name: String,
        properties: [String: AnyCodable],
        priority: EventPriority,
        timestamp: TimeInterval?
    ) {
        calls.append(Call(name: name, properties: properties, priority: priority))
    }

    func flush() async {}
    func dispose() {}

    func lastCall() -> Call? { calls.last }
    func firstCall() -> Call? { calls.first }
}

// MARK: - TransactionEmitterTests

final class TransactionEmitterTests: XCTestCase {

    private var spy: SpyBatcher!
    private var emitter: TransactionEmitter!
    private var products: [String: Product] = [:]
    private var distinctId: String?

    override func setUp() {
        super.setUp()
        spy = SpyBatcher()
        products = [:]
        distinctId = "distinct_1"
        emitter = makeEmitter()
    }

    private func makeEmitter() -> TransactionEmitter {
        TransactionEmitter(
            batcher: spy,
            productProvider: { [weak self] id in self?.products[id] },
            distinctIdProvider: { [weak self] in self?.distinctId },
            debug: false
        )
    }

    // MARK: - emitCheckoutStarted

    func testEmitCheckoutStarted_emitsItsOwnEventName() {
        emitter.emitCheckoutStarted(productId: "com.test.pro")

        XCTAssertEqual(spy.calls.count, 1)
        // `checkout_started` is its own event, not `transaction {type: "started"}` —
        // it maps to InitiateCheckout on Meta/TikTok.
        XCTAssertEqual(spy.calls[0].name, "checkout_started")
    }

    func testEmitCheckoutStarted_usesCriticalPriority() {
        emitter.emitCheckoutStarted(productId: "com.test.pro")

        XCTAssertEqual(spy.calls[0].priority, .critical)
    }

    func testEmitCheckoutStarted_includesProductId() {
        emitter.emitCheckoutStarted(productId: "com.test.pro")

        XCTAssertEqual(spy.calls[0].properties["product_id"]?.value as? String, "com.test.pro")
    }

    func testEmitCheckoutStarted_unknownProduct_shipsAmountAndCurrencyDefaults() {
        emitter.emitCheckoutStarted(productId: "com.test.unknown")

        let props = spy.calls[0].properties
        XCTAssertEqual(props["amount"]?.value as? Double, 0)
        XCTAssertEqual(props["currency"]?.value as? String, "USD")
    }

    func testEmitCheckoutStarted_knownProduct_usesCachedPrice() {
        products["com.test.pro"] = TestFactories.makeProduct(
            productId: "com.test.pro",
            priceValue: 149.9,
            currency: "BRL"
        )

        emitter.emitCheckoutStarted(productId: "com.test.pro")

        let props = spy.calls[0].properties
        XCTAssertEqual(props["amount"]?.value as? Double, 149.9)
        XCTAssertEqual(props["currency"]?.value as? String, "BRL")
    }

    func testEmitCheckoutStarted_noDistinctId_isDropped() {
        distinctId = nil

        emitter.emitCheckoutStarted(productId: "com.test.pro")

        XCTAssertTrue(spy.calls.isEmpty)
    }

    // MARK: - emitTransactionCompleted

    func testEmitTransactionCompleted_emitsTransactionEvent() {
        emitter.emitTransactionCompleted(
            productId: "com.test.pro",
            transactionId: "txn_001",
            amount: 9.99,
            currency: "USD",
            paywallId: "pw_abc",
            variantId: "var_1"
        )

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls[0].name, "transaction")
    }

    func testEmitTransactionCompleted_usesTxIdKey() {
        emitter.emitTransactionCompleted(productId: "com.test.pro", transactionId: "txn_001")

        let props = spy.calls[0].properties
        // The server dedupes on `tx_id`; `transaction_id` is silently ignored.
        XCTAssertEqual(props["tx_id"]?.value as? String, "txn_001")
        XCTAssertNil(props["transaction_id"])
    }

    func testEmitTransactionCompleted_includesPaywallId() {
        emitter.emitTransactionCompleted(productId: "com.test.pro", transactionId: "txn_001", paywallId: "pw_abc")

        XCTAssertEqual(spy.calls[0].properties["paywall_id"]?.value as? String, "pw_abc")
    }

    func testEmitTransactionCompleted_includesVariantId() {
        emitter.emitTransactionCompleted(productId: "com.test.pro", transactionId: "txn_001", variantId: "var_42")

        XCTAssertEqual(spy.calls[0].properties["variant_id"]?.value as? String, "var_42")
    }

    func testEmitTransactionCompleted_positiveAmount_included() {
        emitter.emitTransactionCompleted(
            productId: "com.test.pro",
            transactionId: "txn_001",
            amount: 9.99,
            currency: "USD"
        )

        let props = spy.calls[0].properties
        XCTAssertEqual(props["amount"]?.value as? Double, 9.99)
        XCTAssertEqual(props["currency"]?.value as? String, "USD")
    }

    func testEmitTransactionCompleted_zeroAmount_notIncluded() {
        // A product with no price must not inject a bogus `amount: 0` revenue row.
        emitter.emitTransactionCompleted(
            productId: "com.test.free",
            transactionId: "txn_free",
            amount: 0.0,
            currency: "USD"
        )

        XCTAssertNil(spy.calls[0].properties["amount"])
    }

    func testEmitTransactionCompleted_negativeAmount_notIncluded() {
        emitter.emitTransactionCompleted(
            productId: "com.test.pro",
            transactionId: "txn_001",
            amount: -1.0,
            currency: "USD"
        )

        XCTAssertNil(spy.calls[0].properties["amount"])
    }

    func testEmitTransactionCompleted_missingAmount_enrichedFromProductCache() {
        products["com.test.pro"] = TestFactories.makeProduct(
            productId: "com.test.pro",
            priceValue: 19.9,
            currency: "BRL"
        )

        emitter.emitTransactionCompleted(productId: "com.test.pro", transactionId: "txn_001")

        let props = spy.calls[0].properties
        XCTAssertEqual(props["amount"]?.value as? Double, 19.9)
        XCTAssertEqual(props["currency"]?.value as? String, "BRL")
    }

    func testEmitTransactionCompleted_unknownProductAndNoAmount_shipsNeither() {
        emitter.emitTransactionCompleted(productId: "com.test.pro", transactionId: "txn_001")

        let props = spy.calls[0].properties
        XCTAssertNil(props["amount"])
        XCTAssertNil(props["currency"])
    }

    func testEmitTransactionCompleted_usesCriticalPriority() {
        emitter.emitTransactionCompleted(productId: "com.test.pro", transactionId: "txn_001")

        XCTAssertEqual(spy.calls[0].priority, .critical)
    }

    func testEmitTransactionCompleted_typeIsCompleted() {
        emitter.emitTransactionCompleted(productId: "com.test.pro", transactionId: "txn_001")

        XCTAssertEqual(spy.calls[0].properties["type"]?.value as? String, "completed")
    }

    func testEmitTransactionCompleted_noDistinctId_isDropped() {
        distinctId = nil

        emitter.emitTransactionCompleted(productId: "com.test.pro", transactionId: "txn_001")

        XCTAssertTrue(spy.calls.isEmpty)
    }

    // MARK: - emitTransactionFailed

    func testEmitTransactionFailed_emitsTransactionEvent() {
        emitter.emitTransactionFailed(productId: "com.test.pro", error: "Payment declined", paywallId: nil)

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls[0].name, "transaction")
    }

    func testEmitTransactionFailed_includesErrorString() {
        emitter.emitTransactionFailed(productId: "com.test.pro", error: "Payment declined", paywallId: nil)

        XCTAssertEqual(spy.calls[0].properties["error"]?.value as? String, "Payment declined")
    }

    func testEmitTransactionFailed_includesPaywallId() {
        emitter.emitTransactionFailed(productId: "com.test.pro", error: "err", paywallId: "pw_fail")

        XCTAssertEqual(spy.calls[0].properties["paywall_id"]?.value as? String, "pw_fail")
    }

    func testEmitTransactionFailed_nilPaywallId_notIncluded() {
        emitter.emitTransactionFailed(productId: "com.test.pro", error: "err", paywallId: nil)

        XCTAssertNil(spy.calls[0].properties["paywall_id"])
    }

    func testEmitTransactionFailed_typeIsFailed() {
        emitter.emitTransactionFailed(productId: "com.test.pro", error: "err", paywallId: nil)

        XCTAssertEqual(spy.calls[0].properties["type"]?.value as? String, "failed")
    }

    func testEmitTransactionFailed_usesCriticalPriority() {
        emitter.emitTransactionFailed(productId: "com.test.pro", error: "err", paywallId: nil)

        XCTAssertEqual(spy.calls[0].priority, .critical)
    }

    // MARK: - emitTransactionUpdate

    func testEmitTransactionUpdate_usesTxIdKey() {
        emitter.emitTransactionUpdate(type: "renewed", productId: "com.test.pro", transactionId: "txn_002")

        let props = spy.calls[0].properties
        XCTAssertEqual(props["tx_id"]?.value as? String, "txn_002")
        XCTAssertNil(props["transaction_id"])
    }

    func testEmitTransactionUpdate_renewed_includesAmount() {
        emitter.emitTransactionUpdate(
            type: "renewed",
            productId: "com.test.pro",
            transactionId: "txn_002",
            amount: 9.99,
            currency: "USD"
        )

        let props = spy.calls[0].properties
        XCTAssertEqual(props["amount"]?.value as? Double, 9.99)
        XCTAssertEqual(props["currency"]?.value as? String, "USD")
    }

    func testEmitTransactionUpdate_renewed_enrichesFromProductCache() {
        // StoreKit's Transaction.updates carries no price — the cache is the only source.
        products["com.test.pro"] = TestFactories.makeProduct(
            productId: "com.test.pro",
            priceValue: 29.9,
            currency: "BRL"
        )

        emitter.emitTransactionUpdate(type: "renewed", productId: "com.test.pro", transactionId: "txn_002")

        let props = spy.calls[0].properties
        XCTAssertEqual(props["amount"]?.value as? Double, 29.9)
        XCTAssertEqual(props["currency"]?.value as? String, "BRL")
    }

    func testEmitTransactionUpdate_canceled_skipsAmountAndCurrency() {
        products["com.test.pro"] = TestFactories.makeProduct(productId: "com.test.pro")

        emitter.emitTransactionUpdate(
            type: "canceled",
            productId: "com.test.pro",
            transactionId: "txn_003",
            amount: 9.99,
            currency: "USD"
        )

        let props = spy.calls[0].properties
        XCTAssertNil(props["amount"])
        XCTAssertNil(props["currency"])
    }

    func testEmitTransactionUpdate_canceled_stillIncludesTypeAndIds() {
        emitter.emitTransactionUpdate(type: "canceled", productId: "com.test.pro", transactionId: "txn_003")

        let props = spy.calls[0].properties
        XCTAssertEqual(props["type"]?.value as? String, "canceled")
        XCTAssertEqual(props["product_id"]?.value as? String, "com.test.pro")
        XCTAssertEqual(props["tx_id"]?.value as? String, "txn_003")
    }

    func testEmitTransactionUpdate_nonCanceled_zeroAmount_notIncluded() {
        emitter.emitTransactionUpdate(
            type: "refunded",
            productId: "com.test.pro",
            transactionId: "txn_004",
            amount: 0.0,
            currency: "BRL"
        )

        XCTAssertNil(spy.calls[0].properties["amount"])
    }

    func testEmitTransactionUpdate_usesCriticalPriority() {
        emitter.emitTransactionUpdate(type: "renewed", productId: "com.test.pro", transactionId: "txn_002")

        XCTAssertEqual(spy.calls[0].priority, .critical)
    }

    func testEmitTransactionUpdate_emitsTransactionEventName() {
        emitter.emitTransactionUpdate(type: "renewed", productId: "com.test.pro", transactionId: "txn_002")

        XCTAssertEqual(spy.calls[0].name, "transaction")
    }

    func testEmitTransactionUpdate_noDistinctId_isDropped() {
        distinctId = nil

        emitter.emitTransactionUpdate(type: "renewed", productId: "com.test.pro", transactionId: "txn_002")

        XCTAssertTrue(spy.calls.isEmpty)
    }
}
