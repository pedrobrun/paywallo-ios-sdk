import Foundation

// MARK: - TransactionEmitter

/// Emits transaction events to the analytics pipeline via EventBatcher.
/// Fire-and-forget pattern: tracking failures must never affect the purchase flow.
public final class TransactionEmitter {

    private let batcher: EventBatcherProtocol
    /// Products already loaded by `IAPService` — used to fill in `amount`/`currency`
    /// when the native side does not carry them (StoreKit updates never do).
    private let productProvider: (String) -> Product?
    private let distinctIdProvider: () -> String?
    private let debug: Bool

    public init(
        batcher: EventBatcherProtocol,
        productProvider: @escaping (String) -> Product?,
        distinctIdProvider: @escaping () -> String?,
        debug: Bool = false
    ) {
        self.batcher = batcher
        self.productProvider = productProvider
        self.distinctIdProvider = distinctIdProvider
        self.debug = debug
    }

    // MARK: - Checkout Started

    /// Emits `checkout_started` when the user starts the purchase (taps buy), before
    /// StoreKit opens — so it counts even if the native sheet is cancelled. Becomes
    /// InitiateCheckout on Meta/TikTok, which is why it is `critical` and why `amount`
    /// and `currency` always ship with a default: the ad platforms reject a value event
    /// without them.
    public func emitCheckoutStarted(productId: String) {
        guard let distinctId = distinctId(), !distinctId.isEmpty else {
            log("checkout_started skipped (no distinctId)")
            return
        }

        let product = productProvider(productId)
        // Types are spelled out: inside `AnyCodable`'s `Any` parameter a bare `0` literal
        // would be inferred as `Int` and ship an integer amount on the wire.
        let amount: Double = product?.priceValue ?? 0
        let currency: String = product?.currency ?? "USD"
        let props: [String: AnyCodable] = [
            "product_id": AnyCodable(productId),
            "amount": AnyCodable(amount),
            "currency": AnyCodable(currency),
        ]

        batcher.enqueue(name: "checkout_started", properties: props, priority: .critical, timestamp: nil)
        log("emitted checkout_started: \(productId)")
    }

    // MARK: - Transaction Completed

    /// Emits `transaction {type: "completed"}` after a server-validated purchase.
    /// The transaction key is `tx_id` — the server dedupes on it, `transaction_id` is
    /// silently ignored. `amount` only ships when > 0, so a product with no price does
    /// not inject a bogus `amount: 0` revenue row.
    public func emitTransactionCompleted(
        productId: String,
        transactionId: String,
        amount: Double? = nil,
        currency: String? = nil,
        paywallId: String? = nil,
        variantId: String? = nil
    ) {
        guard let distinctId = distinctId(), !distinctId.isEmpty else {
            log("transaction completed skipped (no distinctId)")
            return
        }

        let product = productProvider(productId)
        var props: [String: AnyCodable] = [
            "type": AnyCodable("completed"),
            "tx_id": AnyCodable(transactionId),
            "product_id": AnyCodable(productId),
        ]
        if let amount = amount ?? product?.priceValue, amount > 0 {
            props["amount"] = AnyCodable(amount)
        }
        if let currency = currency ?? product?.currency {
            props["currency"] = AnyCodable(currency)
        }
        if let paywallId = paywallId {
            props["paywall_id"] = AnyCodable(paywallId)
        }
        if let variantId = variantId {
            props["variant_id"] = AnyCodable(variantId)
        }

        batcher.enqueue(name: "transaction", properties: props, priority: .critical, timestamp: nil)
        log("emitted transaction completed: \(productId) tx=\(transactionId)")
    }

    // MARK: - Transaction Failed

    /// Emits `transaction {type: "failed"}` after a purchase error.
    public func emitTransactionFailed(productId: String, error: String, paywallId: String?) {
        var props: [String: AnyCodable] = [
            "type": AnyCodable("failed"),
            "product_id": AnyCodable(productId),
            "error": AnyCodable(error),
        ]
        if let paywallId = paywallId {
            props["paywall_id"] = AnyCodable(paywallId)
        }

        batcher.enqueue(name: "transaction", properties: props, priority: .critical, timestamp: nil)
        log("emitted transaction failed: \(productId) error=\(error)")
    }

    // MARK: - Transaction Update

    /// Emits `transaction` for renewed/refunded/canceled StoreKit updates.
    /// `Transaction.updates` carries no price, so `amount`/`currency` are enriched from
    /// the product cache. For "canceled" both are skipped (matches the RN SDK).
    public func emitTransactionUpdate(
        type: String,
        productId: String,
        transactionId: String,
        amount: Double? = nil,
        currency: String? = nil
    ) {
        guard let distinctId = distinctId(), !distinctId.isEmpty else {
            log("transaction update dropped (no distinctId): \(type)")
            return
        }

        var props: [String: AnyCodable] = [
            "type": AnyCodable(type),
            "tx_id": AnyCodable(transactionId),
            "product_id": AnyCodable(productId),
        ]

        if type != "canceled" {
            let product = productProvider(productId)
            if let amount = amount ?? product?.priceValue, amount > 0 {
                props["amount"] = AnyCodable(amount)
            }
            if let currency = currency ?? product?.currency {
                props["currency"] = AnyCodable(currency)
            }
        }

        batcher.enqueue(name: "transaction", properties: props, priority: .critical, timestamp: nil)
        log("emitted transaction update: \(type) for \(productId) tx=\(transactionId)")
    }

    // MARK: - Private

    private func distinctId() -> String? {
        distinctIdProvider()
    }

    private func log(_ message: String) {
        guard debug else { return }
        print("[Paywallo:TransactionEmitter] \(message)")
    }
}
