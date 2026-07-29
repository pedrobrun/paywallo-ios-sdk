import Foundation

// MARK: - TransactionEmitter

/// Emits transaction events to the analytics pipeline via EventBatcher.
/// Fire-and-forget pattern: tracking failures must never affect the purchase flow.
public final class TransactionEmitter {

    private let batcher: EventBatcherProtocol
    private let debug: Bool

    public init(batcher: EventBatcherProtocol, debug: Bool = false) {
        self.batcher = batcher
        self.debug = debug
    }

    // MARK: - Checkout Started

    /// Emits `transaction {type: "started"}` before a purchase begins.
    public func emitCheckoutStarted(productId: String, paywallId: String?) {
        var props: [String: AnyCodable] = [
            "type": AnyCodable("started"),
            "product_id": AnyCodable(productId),
        ]
        if let paywallId = paywallId {
            props["paywall_id"] = AnyCodable(paywallId)
        }

        batcher.enqueue(name: "transaction", properties: props, priority: .normal, timestamp: nil)
        log("emitted transaction started: \(productId)")
    }

    // MARK: - Transaction Completed

    /// Emits `transaction {type: "completed"}` after a successful purchase.
    /// Amount is only included if > 0. Currency is only included if non-nil.
    public func emitTransactionCompleted(
        productId: String,
        transactionId: String,
        amount: Double?,
        currency: String?,
        paywallId: String?,
        variantId: String?
    ) {
        var props: [String: AnyCodable] = [
            "type": AnyCodable("completed"),
            "product_id": AnyCodable(productId),
            "transaction_id": AnyCodable(transactionId),
        ]
        if let amount = amount, amount >= 0 {
            props["amount"] = AnyCodable(amount)
        }
        if let currency = currency {
            props["currency"] = AnyCodable(currency)
        }
        if let paywallId = paywallId {
            props["paywall_id"] = AnyCodable(paywallId)
        }
        if let variantId = variantId {
            props["variant_id"] = AnyCodable(variantId)
        }

        batcher.enqueue(name: "transaction", properties: props, priority: .critical, timestamp: nil)
        log("emitted transaction completed: \(productId) txn=\(transactionId)")
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
    /// For "canceled" type, amount and currency are skipped (matches RN SDK behavior).
    public func emitTransactionUpdate(
        type: String,
        productId: String,
        transactionId: String,
        amount: Double? = nil,
        currency: String? = nil
    ) {
        var props: [String: AnyCodable] = [
            "type": AnyCodable(type),
            "product_id": AnyCodable(productId),
            "transaction_id": AnyCodable(transactionId),
        ]

        if type != "canceled" {
            if let amount = amount, amount >= 0 {
                props["amount"] = AnyCodable(amount)
            }
            if let currency = currency {
                props["currency"] = AnyCodable(currency)
            }
        }

        batcher.enqueue(name: "transaction", properties: props, priority: .critical, timestamp: nil)
        log("emitted transaction update: \(type) for \(productId) txn=\(transactionId)")
    }

    // MARK: - Private

    private func log(_ message: String) {
        guard debug else { return }
        print("[Paywallo:TransactionEmitter] \(message)")
    }
}
