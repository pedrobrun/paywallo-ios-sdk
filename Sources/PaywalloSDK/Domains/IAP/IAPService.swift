import Foundation

#if canImport(StoreKit)
import StoreKit
#endif

// MARK: - IAPService

/// Classification of a validation failure.
///  - `network`: transport/timeout/5xx → keep the StoreKit transaction + enqueue retry.
///  - `server4xx`: permanent server rejection → finish the transaction.
public enum ValidationFailureKind {
    case network
    case server4xx
}

public final class IAPService: @unchecked Sendable {
    private let apiClient: ApiClient
    private var productsCache: [String: Product] = [:]
    private var purchaseInFlight = false
    private var debug: Bool
    private var transactionEmitter: TransactionEmitter?

    // Max retry attempts for loadProducts server enrichment
    private let maxLoadAttempts = 3
    private let loadRetryDelays: [UInt64] = [250_000_000, 500_000_000, 1_000_000_000] // ns

    // Server validation retry: 3 attempts, fixed 3s apart.
    private let validateMaxRetries = 2
    private let validateRetryDelayMs: UInt64 = 3000

    private let validatePath = "/sdk/purchases/validate"

    public init(apiClient: ApiClient, debug: Bool = false) {
        self.apiClient = apiClient
        self.debug = debug
    }

    /// Inject a TransactionEmitter after init (avoids circular deps at construction time).
    ///
    /// Also starts the `Transaction.updates` listener: without an emitter the listener
    /// has nothing to feed, and without the listener `transaction {renewed}` never ships —
    /// which also makes the SKAN `Retained` milestone unreachable and hides refunds and
    /// cancellations from the server.
    public func setTransactionEmitter(_ emitter: TransactionEmitter) {
        self.transactionEmitter = emitter
        startTransactionListener()
    }

    /// A product already loaded by `loadProducts`, if any.
    public func getProduct(_ productId: String) -> Product? {
        productsCache[productId]
    }

    private func startTransactionListener() {
        #if canImport(StoreKit)
        if #available(iOS 15.0, macOS 12.0, *) {
            StoreKitManager.shared.configure(
                onTransactionUpdate: { [weak self] update in
                    // amount/currency are absent from StoreKit updates — the emitter
                    // fills them in from the product cache.
                    self?.transactionEmitter?.emitTransactionUpdate(
                        type: update.updateType.rawValue,
                        productId: update.productId,
                        transactionId: update.transactionId
                    )
                },
                debug: debug
            )
        }
        #endif
    }

    // MARK: - Load Products

    /// Loads products by IDs: fetches from StoreKit (when available) and enriches with server data.
    /// Retries server enrichment up to 3 times with 250/500/1000ms backoff.
    public func loadProducts(productIds: [String]) async -> [Product] {
        var products: [Product] = []

        #if canImport(StoreKit)
        if #available(iOS 15.0, macOS 12.0, *) {
            do {
                let storeProducts = try await StoreKitManager.shared.getProducts(productIds: productIds)
                products = storeProducts.map { storeProduct in
                    buildProductFromStoreKit(storeProduct)
                }
                log("Loaded \(products.count) products from StoreKit")
            } catch {
                log("StoreKit product fetch failed: \(error.localizedDescription)")
            }
        }
        #endif

        // Server enrichment with retry
        var attempt = 0
        var serverProducts: [ServerProductInfo] = []

        while attempt < maxLoadAttempts {
            do {
                serverProducts = try await fetchServerProducts(productIds: productIds)
                log("Server enrichment succeeded on attempt \(attempt + 1)")
                break
            } catch {
                log("Server enrichment attempt \(attempt + 1) failed: \(error.localizedDescription)")
                if attempt < maxLoadAttempts - 1 {
                    try? await Task.sleep(nanoseconds: loadRetryDelays[attempt])
                }
                attempt += 1
            }
        }

        // Enrich StoreKit products with server data, or use server fallback
        if !serverProducts.isEmpty {
            if products.isEmpty {
                // No StoreKit products — build from server data as fallback
                products = serverProducts.map { ProductFormatter.buildFromServerProduct($0) }
                log("Using server fallback for \(products.count) products")
            } else {
                // Enrich StoreKit products with server metadata
                products = products.map { product in
                    enrich(product: product, with: serverProducts)
                }
            }
        }

        // Cache results
        for product in products {
            productsCache[product.productId] = product
        }

        return products
    }

    // MARK: - Purchase

    /// Orchestrates a purchase flow:
    /// 1. Guard against concurrent purchases
    /// 2. Invoke StoreKit purchase
    /// 3. Resolve success immediately (before server validation)
    /// 4. Validate async with server (3 attempts, 3s apart)
    /// 5. Finish + emit `transaction {completed}`, or drop / persist for retry
    public func purchase(
        productId: String,
        distinctId: String?,
        placement: String? = nil,
        variantKey: String? = nil
    ) async -> PurchaseResult {
        guard !purchaseInFlight else {
            let error = PurchaseErrorFactory.create(PurchaseErrorCode.purchaseFailed, message: "A purchase is already in progress.")
            return PurchaseResult(success: false, error: error)
        }

        transactionEmitter?.emitCheckoutStarted(productId: productId)

        #if canImport(StoreKit)
        if #available(iOS 15.0, macOS 12.0, *) {
            return await performStoreKitPurchase(productId: productId, distinctId: distinctId, placement: placement, variantKey: variantKey)
        } else {
            let error = PurchaseErrorFactory.create(PurchaseErrorCode.storeNotAvailable)
            transactionEmitter?.emitTransactionFailed(productId: productId, error: error.message, paywallId: placement)
            return PurchaseResult(success: false, error: error)
        }
        #else
        let error = PurchaseErrorFactory.create(PurchaseErrorCode.storeNotAvailable)
        transactionEmitter?.emitTransactionFailed(productId: productId, error: error.message, paywallId: placement)
        return PurchaseResult(success: false, error: error)
        #endif
    }

    // MARK: - Device Country

    /// Returns the user's device region identifier, falling back to "US".
    public func getDeviceCountry() -> String {
        if #available(iOS 16.0, macOS 13.0, *) {
            return Locale.current.region?.identifier ?? "US"
        } else {
            return Locale.current.regionCode ?? "US"
        }
    }

    // MARK: - Private: StoreKit Purchase Flow

    #if canImport(StoreKit)
    @available(iOS 15.0, macOS 12.0, *)
    private func performStoreKitPurchase(
        productId: String,
        distinctId: String?,
        placement: String? = nil,
        variantKey: String? = nil
    ) async -> PurchaseResult {
        purchaseInFlight = true
        defer { purchaseInFlight = false }

        // Find StoreKit product
        let storeProducts: [StoreKit.Product]
        do {
            storeProducts = try await StoreKitManager.shared.getProducts(productIds: [productId])
        } catch {
            let purchaseError = PurchaseErrorFactory.create(PurchaseErrorCode.storeError, message: error.localizedDescription)
            transactionEmitter?.emitTransactionFailed(productId: productId, error: error.localizedDescription, paywallId: placement)
            return PurchaseResult(success: false, error: purchaseError)
        }

        guard let storeProduct = storeProducts.first else {
            let error = PurchaseErrorFactory.create(PurchaseErrorCode.productNotFound)
            transactionEmitter?.emitTransactionFailed(productId: productId, error: "product_not_found", paywallId: placement)
            return PurchaseResult(success: false, error: error)
        }

        // Perform StoreKit purchase
        let transaction: StoreKit.Transaction
        let jwsRepresentation: String
        do {
            guard let outcome = try await StoreKitManager.shared.purchase(storeProduct, distinctId: distinctId) else {
                let error = PurchaseErrorFactory.create(PurchaseErrorCode.purchaseFailed, message: "No transaction returned.")
                transactionEmitter?.emitTransactionFailed(productId: productId, error: "no_transaction_returned", paywallId: placement)
                return PurchaseResult(success: false, error: error)
            }
            transaction = outcome.transaction
            jwsRepresentation = outcome.jwsRepresentation
        } catch let purchaseError as PurchaseError {
            transactionEmitter?.emitTransactionFailed(productId: productId, error: purchaseError.message, paywallId: placement)
            return PurchaseResult(success: false, error: purchaseError)
        } catch {
            let err = PurchaseErrorFactory.create(PurchaseErrorCode.purchaseFailed, message: error.localizedDescription)
            transactionEmitter?.emitTransactionFailed(productId: productId, error: error.localizedDescription, paywallId: placement)
            return PurchaseResult(success: false, error: err)
        }

        // Build purchase object — use JWS representation as receipt for server verification
        let purchase = Purchase(
            productId: productId,
            transactionId: String(transaction.id),
            transactionDate: transaction.purchaseDate.timeIntervalSince1970 * 1000,
            receipt: jwsRepresentation,
            platform: .ios
        )

        // Resolve success BEFORE server validation
        let successResult = PurchaseResult(success: true, purchase: purchase)

        let priceValue = NSDecimalNumber(decimal: storeProduct.price).doubleValue
        let currency = storeProduct.priceFormatStyle.currencyCode
        let body = buildValidationBody(
            purchase: purchase,
            priceValue: priceValue,
            currency: currency,
            country: getDeviceCountry(),
            distinctId: distinctId,
            paywallPlacement: placement,
            variantKey: variantKey
        )

        // Async: validate with server, then finish + emit (or drop / persist for retry).
        Task { [weak self] in
            guard let self = self else { return }
            await self.validateAndSettle(
                body: body,
                productId: productId,
                transactionId: purchase.transactionId,
                paywallId: placement,
                variantId: variantKey,
                finish: { await StoreKitManager.shared.finishTransaction(transaction) }
            )
        }

        return successResult
    }
    #endif

    // MARK: - Server Validation

    /// Validate → finish → emit.
    ///
    /// The `transaction {completed}` event is emitted only AFTER the server accepts the
    /// receipt and the transaction is finished. Emitting before validation produced a
    /// bogus revenue row for every purchase the server rejected with a 4xx.
    ///
    /// Split out of `performStoreKitPurchase` (and parameterised on `finish`) so the
    /// ordering is testable without a real StoreKit transaction.
    func validateAndSettle(
        body: [String: Any],
        productId: String,
        transactionId: String,
        paywallId: String?,
        variantId: String?,
        finish: @escaping () async -> Void
    ) async {
        do {
            let response = try await validateWithRetry { try await self.apiClient.validatePurchase(body) }

            guard response.success else {
                // Server answered `valid: false` — the receipt will never validate, drop it.
                log("Validation returned success=false, dropping transaction: \(transactionId)")
                await finish()
                return
            }

            await finish()
            log("Validation succeeded, transaction finished: \(transactionId)")
            transactionEmitter?.emitTransactionCompleted(
                productId: productId,
                transactionId: transactionId,
                paywallId: paywallId,
                variantId: variantId
            )
        } catch {
            if classifyValidationError(error) == .server4xx {
                // Permanent rejection (bad receipt): retrying cannot change the outcome.
                log("Validation rejected (4xx), finishing and dropping: \(transactionId)")
                await finish()
                return
            }
            log("Validation failed (network) — queued for retry: \(transactionId)")
            await enqueueValidationRetry(body: body, transactionId: transactionId)
        }
    }

    /// 3 attempts, 3s apart, rethrowing the last error. A purchase is a money flow, so a
    /// transient blip must not be mistaken for a rejection.
    private func validateWithRetry(
        _ attempt: () async throws -> ValidatePurchaseResponse
    ) async throws -> ValidatePurchaseResponse {
        var lastError: Error?
        for i in 0...validateMaxRetries {
            do {
                return try await attempt()
            } catch {
                lastError = error
                if i < validateMaxRetries {
                    try? await Task.sleep(nanoseconds: validateRetryDelayMs * 1_000_000)
                }
            }
        }
        throw lastError ?? PurchaseErrorFactory.create(PurchaseErrorCode.validationFailed)
    }

    /// Buckets a validation failure into `server4xx` (permanent) vs `network` (transient).
    /// Anything that is not a `PurchaseError` carrying a 4xx status is transient — a decode
    /// failure or a dropped connection says nothing about the receipt.
    func classifyValidationError(_ error: Error) -> ValidationFailureKind {
        if let purchaseError = error as? PurchaseError,
           let status = purchaseError.httpStatus,
           (400..<500).contains(status) {
            return .server4xx
        }
        return .network
    }

    /// Posts the validation payload directly, one more time. On a retryable failure the
    /// request is handed to `PendingRetry` — the same minimal persisted retry the critical
    /// event pipeline uses — because a purchase is a money flow and must not be dropped
    /// silently. A 4xx (invalid receipt) is not retried. StoreKit also redelivers the
    /// un-finished transaction on the next launch as a safety net.
    func enqueueValidationRetry(body: [String: Any], transactionId: String) async {
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            log("Validation retry dropped (payload not serializable): \(transactionId)")
            return
        }
        // Persist the request EXACTLY as built (X-App-Key included; PendingRetry re-posts
        // the body byte-for-byte and never re-wraps it — incident 03/08/2026).
        let headers = ["X-App-Key": apiClient.appKey]

        do {
            let response = try await apiClient.httpClient.requestRaw(
                path: validatePath,
                options: RequestOptions(method: "POST", body: payload)
            )
            if response.ok {
                log("Validation retry posted: \(transactionId)")
                return
            }

            // NOTE: HttpClient RETURNS (does not throw) on 5xx/429 once its internal
            // retries are exhausted — those land here, not in the catch. A missing status
            // means a malformed response, which is NOT a definitive 4xx → retry (2.7.1).
            let hasNumericStatus = response.status > 0
            let isPermanent4xx = hasNumericStatus
                && (400..<500).contains(response.status)
                && response.status != 429
            guard isPermanent4xx else {
                await PendingRetry.shared.save(url: validatePath, body: payload, headers: headers)
                log("Validation → pendingRetry: \(transactionId) (status \(response.status))")
                return
            }
            log("Validation dropped (4xx): \(transactionId) (status \(response.status))")
        } catch {
            await PendingRetry.shared.save(url: validatePath, body: payload, headers: headers)
            log("Validation → pendingRetry (network): \(transactionId)")
        }
    }

    private func buildValidationBody(
        purchase: Purchase,
        priceValue: Double,
        currency: String,
        country: String,
        distinctId: String?,
        paywallPlacement: String?,
        variantKey: String?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "platform": "ios",
            "receipt_data": purchase.receipt,
            "product_id": purchase.productId,
            "transaction_id": purchase.transactionId,
            "price_local": priceValue,
            "currency": currency,
            "country": country,
        ]
        if let distinctId = distinctId {
            body["distinct_id"] = distinctId
        }
        if let placement = paywallPlacement {
            body["paywall_placement"] = placement
        }
        if let variantKey = variantKey {
            body["variant_key"] = variantKey
        }
        return body
    }

    // MARK: - Restore

    /// Revalidates every active entitlement with the server.
    ///
    /// Success finishes the transaction and returns it; a permanent 4xx (or `valid: false`)
    /// finishes and drops it — the receipt will never validate; a network failure keeps the
    /// transaction un-finished and persists the request, so StoreKit redelivers it anyway.
    public func restore(distinctId: String?) async -> [Purchase] {
        #if canImport(StoreKit)
        guard #available(iOS 15.0, macOS 12.0, *) else { return [] }

        let entitlements = await StoreKitManager.shared.getActiveEntitlements()
        let country = getDeviceCountry()
        var validated: [Purchase] = []

        for entitlement in entitlements {
            let transaction = entitlement.transaction
            let product = productsCache[transaction.productID]
            let purchase = Purchase(
                productId: transaction.productID,
                transactionId: String(transaction.id),
                transactionDate: transaction.purchaseDate.timeIntervalSince1970 * 1000,
                receipt: entitlement.jwsRepresentation,
                platform: .ios
            )
            let body = buildValidationBody(
                purchase: purchase,
                priceValue: product?.priceValue ?? 0,
                currency: product?.currency ?? "USD",
                country: country,
                distinctId: distinctId,
                paywallPlacement: nil,
                variantKey: nil
            )

            do {
                let response = try await apiClient.validatePurchase(body)
                if response.success {
                    await StoreKitManager.shared.finishTransaction(transaction)
                    validated.append(purchase)
                } else {
                    log("Restore: server returned success=false — dropping \(purchase.transactionId)")
                    await StoreKitManager.shared.finishTransaction(transaction)
                }
            } catch {
                if classifyValidationError(error) == .server4xx {
                    log("Restore: validation rejected (4xx) — dropping \(purchase.transactionId)")
                    await StoreKitManager.shared.finishTransaction(transaction)
                } else {
                    log("Restore: validation failed (network) — queued for retry \(purchase.transactionId)")
                    await enqueueValidationRetry(body: body, transactionId: purchase.transactionId)
                }
            }
        }

        return validated
        #else
        return []
        #endif
    }

    // MARK: - Server Product Fetching

    private func fetchServerProducts(productIds: [String]) async throws -> [ServerProductInfo] {
        let data = try await apiClient.getOfferings(ids: productIds)
        let decoder = JSONDecoder()

        // Primary: { data: { offerings: [{ products: [...] }] } }
        struct OfferingItem: Decodable {
            let products: [ServerProductInfo]?
        }
        struct OfferingsInner: Decodable {
            let offerings: [OfferingItem]
        }
        struct OfferingsEnvelope: Decodable {
            let data: OfferingsInner
        }
        if let envelope = try? decoder.decode(OfferingsEnvelope.self, from: data) {
            return envelope.data.offerings.flatMap { $0.products ?? [] }
        }

        // Fallback: { data: [...] } flat product array
        struct FlatEnvelope: Decodable {
            let data: [ServerProductInfo]
        }
        if let flat = try? decoder.decode(FlatEnvelope.self, from: data) {
            return flat.data
        }

        // Legacy: { products: [...] } or { data: [...] } at top level
        struct LegacyWrapper: Decodable {
            let products: [ServerProductInfo]?
            let data: [ServerProductInfo]?
        }
        if let legacy = try? decoder.decode(LegacyWrapper.self, from: data) {
            return legacy.products ?? legacy.data ?? []
        }

        // Last resort: direct array
        if let products = try? decoder.decode([ServerProductInfo].self, from: data) {
            return products
        }

        return []
    }

    // MARK: - Product Building

    #if canImport(StoreKit)
    @available(iOS 15.0, macOS 12.0, *)
    private func buildProductFromStoreKit(_ storeProduct: StoreKit.Product) -> Product {
        let priceValue = NSDecimalNumber(decimal: storeProduct.price).doubleValue
        let currency = storeProduct.priceFormatStyle.currencyCode
        let localizedPrice = storeProduct.displayPrice

        var subscriptionPeriod: String?
        var trialDays: Int?
        var freeTrialPeriod: String?
        var pricePerMonth: String?
        var pricePerWeek: String?
        var pricePerDay: String?

        if let sub = storeProduct.subscription {
            subscriptionPeriod = isoFromSubscriptionPeriod(sub.subscriptionPeriod)

            if let intro = sub.introductoryOffer, intro.paymentMode == .freeTrial {
                let days = daysFromSubscriptionPeriod(intro.period)
                trialDays = days
                freeTrialPeriod = ProductFormatter.formatTrialDays(days)
            }

            if let period = subscriptionPeriod {
                let prices = ProductFormatter.calculatePerPeriodPrices(
                    priceValue: priceValue,
                    period: period,
                    currency: currency
                )
                pricePerMonth = prices.pricePerMonth
                pricePerWeek = prices.pricePerWeek
                pricePerDay = prices.pricePerDay
            }
        }

        let productType = ProductFormatter.mapProductType(storeProduct.type.rawValue)

        return Product(
            productId: storeProduct.id,
            title: storeProduct.displayName,
            description: storeProduct.description,
            price: String(format: "%.2f", priceValue),
            priceValue: priceValue,
            currency: currency,
            localizedPrice: localizedPrice,
            type: productType,
            subscriptionPeriod: subscriptionPeriod,
            freeTrialPeriod: freeTrialPeriod,
            trialDays: trialDays,
            pricePerMonth: pricePerMonth,
            pricePerWeek: pricePerWeek,
            pricePerDay: pricePerDay
        )
    }

    @available(iOS 15.0, macOS 12.0, *)
    private func isoFromSubscriptionPeriod(_ period: StoreKit.Product.SubscriptionPeriod) -> String {
        switch period.unit {
        case .day: return "P\(period.value)D"
        case .week: return "P\(period.value)W"
        case .month: return "P\(period.value)M"
        case .year: return "P\(period.value)Y"
        @unknown default: return "P1M"
        }
    }

    @available(iOS 15.0, macOS 12.0, *)
    private func daysFromSubscriptionPeriod(_ period: StoreKit.Product.SubscriptionPeriod) -> Int {
        let iso = isoFromSubscriptionPeriod(period)
        return ProductFormatter.periodToDays(iso) ?? 0
    }
    #endif

    private func enrich(product: Product, with serverProducts: [ServerProductInfo]) -> Product {
        guard let serverProduct = serverProducts.first(where: { $0.storeProductId == product.productId }) else {
            return product
        }

        var enriched = product

        // Use server trial days if not already set
        if enriched.trialDays == nil, let trialDays = serverProduct.trialDays {
            enriched.trialDays = trialDays
            enriched.freeTrialPeriod = ProductFormatter.formatTrialDays(trialDays)
        }

        // Use server billing period if subscription period is missing
        if enriched.subscriptionPeriod == nil, let billingPeriod = serverProduct.billingPeriod {
            enriched.subscriptionPeriod = billingPeriod
        }

        return enriched
    }

    private func log(_ message: String) {
        guard debug else { return }
        print("[Paywallo:IAP] \(message)")
    }
}
