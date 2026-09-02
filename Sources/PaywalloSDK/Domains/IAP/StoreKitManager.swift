import Foundation

#if canImport(StoreKit)
import StoreKit

// MARK: - Transaction Update Types

public enum TransactionUpdateType: String {
    case renewed
    case refunded
    case canceled
}

public struct TransactionUpdate {
    public let transactionId: String
    public let productId: String
    public let updateType: TransactionUpdateType
    public let transactionDate: Date
}

// MARK: - StoreKitManager

@available(iOS 15.0, macOS 12.0, *)
public final class StoreKitManager: @unchecked Sendable {
    public static let shared = StoreKitManager()

    private var transactionListener: Task<Void, Never>?
    private var finishedTransactions: Set<UInt64> = []
    private var onTransactionUpdate: ((TransactionUpdate) -> Void)?
    private var debug = false

    public init() {}

    // MARK: - Configure

    public func configure(onTransactionUpdate: @escaping (TransactionUpdate) -> Void, debug: Bool = false) {
        self.onTransactionUpdate = onTransactionUpdate
        self.debug = debug
        startTransactionListener()
    }

    // MARK: - Products

    public func getProducts(productIds: [String]) async throws -> [StoreKit.Product] {
        let storeProducts = try await StoreKit.Product.products(for: productIds)
        log("Fetched \(storeProducts.count) products from StoreKit")
        return storeProducts
    }

    // MARK: - Purchase

    public typealias PurchaseOutcome = (transaction: StoreKit.Transaction, jwsRepresentation: String)

    public func purchase(_ product: StoreKit.Product, distinctId: String?) async throws -> PurchaseOutcome? {
        var options: Set<StoreKit.Product.PurchaseOption> = []

        if let distinctId = distinctId {
            let stripped = stripAnonPrefix(distinctId)
            if let uuid = UUID(uuidString: stripped), isValidUUIDv4(uuid) {
                options.insert(.appAccountToken(uuid))
                log("appAccountToken set: \(uuid)")
            } else {
                log("distinctId '\(stripped)' is not a valid UUID v4, skipping appAccountToken")
            }
        }

        let result = try await product.purchase(options: options)

        switch result {
        case .success(let verificationResult):
            let jws = verificationResult.jwsRepresentation
            switch verificationResult {
            case .verified(let transaction):
                log("Purchase verified: txn \(transaction.id)")
                return (transaction, jws)
            case .unverified(let transaction, let error):
                log("Purchase unverified: \(error.localizedDescription)")
                return (transaction, jws)
            }
        case .userCancelled:
            throw PurchaseErrorFactory.create(PurchaseErrorCode.userCancelled)
        case .pending:
            throw PurchaseErrorFactory.create(PurchaseErrorCode.pendingPurchase)
        @unknown default:
            throw PurchaseErrorFactory.create(PurchaseErrorCode.purchaseFailed)
        }
    }

    // MARK: - Finish Transaction

    public func finishTransaction(_ transaction: StoreKit.Transaction) async {
        // Idempotency guard
        guard !finishedTransactions.contains(transaction.id) else {
            log("Transaction \(transaction.id) already finished, skipping")
            return
        }
        finishedTransactions.insert(transaction.id)
        await transaction.finish()
        log("Finished transaction \(transaction.id)")
    }

    // MARK: - Active Transactions

    public func getActiveTransactions() async -> [StoreKit.Transaction] {
        await getActiveEntitlements().map { $0.transaction }
    }

    /// Active entitlements paired with their JWS representation.
    ///
    /// `restore()` needs the signed payload as `receipt_data` and `StoreKit.Transaction`
    /// alone does not carry it — only the enclosing `VerificationResult` does.
    public func getActiveEntitlements() async -> [PurchaseOutcome] {
        var entitlements: [PurchaseOutcome] = []
        for await result in StoreKit.Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                entitlements.append((transaction, result.jwsRepresentation))
            case .unverified:
                break
            }
        }
        return entitlements
    }

    // MARK: - Transaction Listener

    private func startTransactionListener() {
        transactionListener?.cancel()
        transactionListener = Task.detached { [weak self] in
            for await result in StoreKit.Transaction.updates {
                await self?.handleTransactionUpdate(result)
            }
        }
        log("Transaction listener started")
    }

    private func handleTransactionUpdate(_ result: VerificationResult<StoreKit.Transaction>) async {
        switch result {
        case .verified(let transaction):
            if let update = normalizeTransactionUpdate(transaction) {
                log("Transaction update: \(update.updateType.rawValue) for \(update.productId)")
                onTransactionUpdate?(update)
            }
        case .unverified(let transaction, let error):
            log("Unverified transaction update \(transaction.id): \(error.localizedDescription)")
        }
    }

    // MARK: - Normalize Transaction Update

    func normalizeTransactionUpdate(_ transaction: StoreKit.Transaction) -> TransactionUpdate? {
        let updateType: TransactionUpdateType

        if transaction.revocationDate != nil {
            // Transaction was revoked/refunded
            updateType = .refunded
        } else if let expirationDate = transaction.expirationDate, expirationDate < Date() {
            // Subscription expired / canceled
            updateType = .canceled
        } else if transaction.isUpgraded {
            // Upgraded = effectively canceled old sub
            updateType = .canceled
        } else {
            // New purchase or renewal
            updateType = .renewed
        }

        return TransactionUpdate(
            transactionId: String(transaction.id),
            productId: transaction.productID,
            updateType: updateType,
            transactionDate: transaction.purchaseDate
        )
    }

    // MARK: - Helpers

    private func stripAnonPrefix(_ distinctId: String) -> String {
        let prefix = "$paywallo_anon:"
        if distinctId.hasPrefix(prefix) {
            return String(distinctId.dropFirst(prefix.count))
        }
        return distinctId
    }

    private func isValidUUIDv4(_ uuid: UUID) -> Bool {
        // UUID v4: byte 6 has top nibble = 4, byte 8 has top 2 bits = 10
        let bytes = uuid.uuid
        let version = (bytes.6 & 0xF0) >> 4
        let variant = (bytes.8 & 0xC0) >> 6
        return version == 4 && variant == 2
    }

    // MARK: - Dispose

    public func dispose() {
        transactionListener?.cancel()
        transactionListener = nil
        finishedTransactions.removeAll()
        log("Disposed")
    }

    private func log(_ message: String) {
        guard debug else { return }
        print("[Paywallo:StoreKit] \(message)")
    }
}

#endif
