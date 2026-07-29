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

    override func setUp() {
        super.setUp()
        spy = SpyBatcher()
        emitter = TransactionEmitter(batcher: spy, debug: false)
    }

    // MARK: - emitCheckoutStarted

    func testEmitCheckoutStarted_emitsTransactionEvent() {
        emitter.emitCheckoutStarted(productId: "com.test.pro", paywallId: "pw_abc")

        XCTAssertEqual(spy.calls.count, 1)
        let call = spy.calls[0]
        XCTAssertEqual(call.name, "transaction")
    }

    func testEmitCheckoutStarted_includesProductId() {
        emitter.emitCheckoutStarted(productId: "com.test.pro", paywallId: nil)

        let props = spy.calls[0].properties
        XCTAssertEqual(props["product_id"]?.value as? String, "com.test.pro")
    }

    func testEmitCheckoutStarted_includesTypeStarted() {
        emitter.emitCheckoutStarted(productId: "com.test.pro", paywallId: nil)

        let props = spy.calls[0].properties
        XCTAssertEqual(props["type"]?.value as? String, "started")
    }

    func testEmitCheckoutStarted_withPaywallId_includesPaywallId() {
        emitter.emitCheckoutStarted(productId: "com.test.pro", paywallId: "pw_xyz")

        let props = spy.calls[0].properties
        XCTAssertEqual(props["paywall_id"]?.value as? String, "pw_xyz")
    }

    func testEmitCheckoutStarted_nilPaywallId_doesNotIncludePaywallId() {
        emitter.emitCheckoutStarted(productId: "com.test.pro", paywallId: nil)

        let props = spy.calls[0].properties
        XCTAssertNil(props["paywall_id"])
    }

    func testEmitCheckoutStarted_usesNormalPriority() {
        emitter.emitCheckoutStarted(productId: "com.test.pro", paywallId: nil)

        XCTAssertEqual(spy.calls[0].priority, .normal)
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

    func testEmitTransactionCompleted_includesTransactionId() {
        emitter.emitTransactionCompleted(
            productId: "com.test.pro",
            transactionId: "txn_001",
            amount: nil,
            currency: nil,
            paywallId: nil,
            variantId: nil
        )

        let props = spy.calls[0].properties
        XCTAssertEqual(props["transaction_id"]?.value as? String, "txn_001")
    }

    func testEmitTransactionCompleted_includesPaywallId() {
        emitter.emitTransactionCompleted(
            productId: "com.test.pro",
            transactionId: "txn_001",
            amount: nil,
            currency: nil,
            paywallId: "pw_abc",
            variantId: nil
        )

        let props = spy.calls[0].properties
        XCTAssertEqual(props["paywall_id"]?.value as? String, "pw_abc")
    }

    func testEmitTransactionCompleted_includesVariantId() {
        emitter.emitTransactionCompleted(
            productId: "com.test.pro",
            transactionId: "txn_001",
            amount: nil,
            currency: nil,
            paywallId: nil,
            variantId: "var_42"
        )

        let props = spy.calls[0].properties
        XCTAssertEqual(props["variant_id"]?.value as? String, "var_42")
    }

    func testEmitTransactionCompleted_positiveAmount_included() {
        emitter.emitTransactionCompleted(
            productId: "com.test.pro",
            transactionId: "txn_001",
            amount: 9.99,
            currency: "USD",
            paywallId: nil,
            variantId: nil
        )

        let props = spy.calls[0].properties
        XCTAssertEqual(props["amount"]?.value as? Double, 9.99)
        XCTAssertEqual(props["currency"]?.value as? String, "USD")
    }

    func testEmitTransactionCompleted_zeroAmount_isIncluded() {
        // amount=0 means free trial — must be included
        emitter.emitTransactionCompleted(
            productId: "com.test.pro",
            transactionId: "txn_free",
            amount: 0.0,
            currency: "USD",
            paywallId: nil,
            variantId: nil
        )

        let props = spy.calls[0].properties
        XCTAssertEqual(props["amount"]?.value as? Double, 0.0)
    }

    func testEmitTransactionCompleted_nilCurrency_notIncluded() {
        emitter.emitTransactionCompleted(
            productId: "com.test.pro",
            transactionId: "txn_001",
            amount: 9.99,
            currency: nil,
            paywallId: nil,
            variantId: nil
        )

        let props = spy.calls[0].properties
        XCTAssertNil(props["currency"])
    }

    func testEmitTransactionCompleted_nilAmount_notIncluded() {
        emitter.emitTransactionCompleted(
            productId: "com.test.pro",
            transactionId: "txn_001",
            amount: nil,
            currency: nil,
            paywallId: nil,
            variantId: nil
        )

        let props = spy.calls[0].properties
        XCTAssertNil(props["amount"])
    }

    func testEmitTransactionCompleted_negativeAmount_notIncluded() {
        emitter.emitTransactionCompleted(
            productId: "com.test.pro",
            transactionId: "txn_001",
            amount: -1.0,
            currency: "USD",
            paywallId: nil,
            variantId: nil
        )

        let props = spy.calls[0].properties
        XCTAssertNil(props["amount"])
    }

    func testEmitTransactionCompleted_usesCriticalPriority() {
        emitter.emitTransactionCompleted(
            productId: "com.test.pro",
            transactionId: "txn_001",
            amount: nil,
            currency: nil,
            paywallId: nil,
            variantId: nil
        )

        XCTAssertEqual(spy.calls[0].priority, .critical)
    }

    func testEmitTransactionCompleted_typeIsCompleted() {
        emitter.emitTransactionCompleted(
            productId: "com.test.pro",
            transactionId: "txn_001",
            amount: nil,
            currency: nil,
            paywallId: nil,
            variantId: nil
        )

        let props = spy.calls[0].properties
        XCTAssertEqual(props["type"]?.value as? String, "completed")
    }

    // MARK: - emitTransactionFailed

    func testEmitTransactionFailed_emitsTransactionEvent() {
        emitter.emitTransactionFailed(productId: "com.test.pro", error: "Payment declined", paywallId: nil)

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls[0].name, "transaction")
    }

    func testEmitTransactionFailed_includesErrorString() {
        emitter.emitTransactionFailed(productId: "com.test.pro", error: "Payment declined", paywallId: nil)

        let props = spy.calls[0].properties
        XCTAssertEqual(props["error"]?.value as? String, "Payment declined")
    }

    func testEmitTransactionFailed_includesPaywallId() {
        emitter.emitTransactionFailed(productId: "com.test.pro", error: "err", paywallId: "pw_fail")

        let props = spy.calls[0].properties
        XCTAssertEqual(props["paywall_id"]?.value as? String, "pw_fail")
    }

    func testEmitTransactionFailed_nilPaywallId_notIncluded() {
        emitter.emitTransactionFailed(productId: "com.test.pro", error: "err", paywallId: nil)

        let props = spy.calls[0].properties
        XCTAssertNil(props["paywall_id"])
    }

    func testEmitTransactionFailed_typeIsFailed() {
        emitter.emitTransactionFailed(productId: "com.test.pro", error: "err", paywallId: nil)

        let props = spy.calls[0].properties
        XCTAssertEqual(props["type"]?.value as? String, "failed")
    }

    func testEmitTransactionFailed_usesCriticalPriority() {
        emitter.emitTransactionFailed(productId: "com.test.pro", error: "err", paywallId: nil)

        XCTAssertEqual(spy.calls[0].priority, .critical)
    }

    // MARK: - emitTransactionUpdate

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

    func testEmitTransactionUpdate_canceled_skipsAmountAndCurrency() {
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
        emitter.emitTransactionUpdate(
            type: "canceled",
            productId: "com.test.pro",
            transactionId: "txn_003",
            amount: nil,
            currency: nil
        )

        let props = spy.calls[0].properties
        XCTAssertEqual(props["type"]?.value as? String, "canceled")
        XCTAssertEqual(props["product_id"]?.value as? String, "com.test.pro")
        XCTAssertEqual(props["transaction_id"]?.value as? String, "txn_003")
    }

    func testEmitTransactionUpdate_refunded_zeroAmount_isIncluded() {
        emitter.emitTransactionUpdate(
            type: "refunded",
            productId: "com.test.pro",
            transactionId: "txn_004",
            amount: 0.0,
            currency: "BRL"
        )

        let props = spy.calls[0].properties
        XCTAssertEqual(props["amount"]?.value as? Double, 0.0)
    }

    func testEmitTransactionUpdate_nonCanceled_negativeAmount_notIncluded() {
        emitter.emitTransactionUpdate(
            type: "renewed",
            productId: "com.test.pro",
            transactionId: "txn_005",
            amount: -5.0,
            currency: "USD"
        )

        let props = spy.calls[0].properties
        XCTAssertNil(props["amount"])
    }

    func testEmitTransactionUpdate_usesCriticalPriority() {
        emitter.emitTransactionUpdate(
            type: "renewed",
            productId: "com.test.pro",
            transactionId: "txn_002",
            amount: nil,
            currency: nil
        )

        XCTAssertEqual(spy.calls[0].priority, .critical)
    }

    func testEmitTransactionUpdate_emitsTransactionEventName() {
        emitter.emitTransactionUpdate(
            type: "renewed",
            productId: "com.test.pro",
            transactionId: "txn_002"
        )

        XCTAssertEqual(spy.calls[0].name, "transaction")
    }
}
