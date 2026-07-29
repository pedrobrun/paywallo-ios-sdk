import Foundation

#if canImport(StoreKit)
import StoreKit
#endif

// MARK: - IAPService

public final class IAPService: @unchecked Sendable {
    private let apiClient: ApiClient
    private let offlineQueue: OfflineQueue
    private var productsCache: [String: Product] = [:]
    private var purchaseInFlight = false
    private var debug: Bool
    private var transactionEmitter: TransactionEmitter?

    // Max retry attempts for loadProducts server enrichment
    private let maxLoadAttempts = 3
    private let loadRetryDelays: [UInt64] = [250_000_000, 500_000_000, 1_000_000_000] // ns

    public init(apiClient: ApiClient, offlineQueue: OfflineQueue, debug: Bool = false) {
        self.apiClient = apiClient
        self.offlineQueue = offlineQueue
        self.debug = debug
    }

    /// Inject a TransactionEmitter after init (avoids circular deps at construction time).
    public func setTransactionEmitter(_ emitter: TransactionEmitter) {
        self.transactionEmitter = emitter
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
    /// 4. Validate async with server
    /// 5. Finish or enqueue based on validation result
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

        transactionEmitter?.emitCheckoutStarted(productId: productId, paywallId: placement)

        #if canImport(StoreKit)
        if #available(iOS 15.0, macOS 12.0, *) {
            return await performStoreKitPurchase(productId: productId, distinctId: distinctId, placement: placement, variantKey: variantKey)
        } else {
            let error = PurchaseErrorFactory.create(PurchaseErrorCode.storeNotAvailable)
            transactionEmitter?.emitTransactionFailed(productId: productId, error: error.message ?? "store_not_available", paywallId: placement)
            return PurchaseResult(success: false, error: error)
        }
        #else
        let error = PurchaseErrorFactory.create(PurchaseErrorCode.storeNotAvailable)
        transactionEmitter?.emitTransactionFailed(productId: productId, error: error.message ?? "store_not_available", paywallId: placement)
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

        // Emit transaction completed (fire-and-forget, before server validation)
        let priceValue = NSDecimalNumber(decimal: storeProduct.price).doubleValue
        let currency = storeProduct.priceFormatStyle.currencyCode
        transactionEmitter?.emitTransactionCompleted(
            productId: productId,
            transactionId: String(transaction.id),
            amount: priceValue,
            currency: currency,
            paywallId: placement,
            variantId: variantKey
        )

        // Resolve success BEFORE server validation
        let successResult = PurchaseResult(success: true, purchase: purchase)

        // Async: validate with server, finish or enqueue
        let country = getDeviceCountry()
        Task { [weak self] in
            await self?.validateAndFinish(
                transaction: transaction,
                purchase: purchase,
                priceValue: priceValue,
                currency: currency,
                country: country,
                distinctId: distinctId,
                paywallPlacement: placement,
                variantKey: variantKey
            )
        }

        return successResult
    }

    @available(iOS 15.0, macOS 12.0, *)
    private func validateAndFinish(
        transaction: StoreKit.Transaction,
        purchase: Purchase,
        priceValue: Double,
        currency: String,
        country: String,
        distinctId: String?,
        paywallPlacement: String? = nil,
        variantKey: String? = nil
    ) async {
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

        do {
            let response = try await apiClient.validatePurchase(body)

            if response.success {
                // Validation passed — finish transaction
                await StoreKitManager.shared.finishTransaction(transaction)
                log("Validation succeeded, transaction finished: \(purchase.transactionId)")
            } else {
                // Server returned success=false — treat as 4xx-like, drop
                log("Validation returned success=false, dropping transaction: \(purchase.transactionId)")
                await StoreKitManager.shared.finishTransaction(transaction)
            }
        } catch {
            let httpStatus = extractHttpStatus(from: error)

            if let status = httpStatus, (400..<500).contains(status), status != 408, status != 429 {
                // 4xx — finish and drop (bad receipt, no retry)
                log("Validation failed with 4xx (\(status)), finishing and dropping: \(purchase.transactionId)")
                await StoreKitManager.shared.finishTransaction(transaction)
            } else {
                // Network or 5xx error — enqueue as critical for retry
                log("Validation network error, enqueueing as critical: \(purchase.transactionId)")
                enqueueValidationRetry(
                    purchase: purchase,
                    priceValue: priceValue,
                    currency: currency,
                    country: country,
                    distinctId: distinctId,
                    paywallPlacement: paywallPlacement,
                    variantKey: variantKey
                )
            }
        }
    }

    private func extractHttpStatus(from error: Error) -> Int? {
        if let purchaseError = error as? PurchaseError {
            return purchaseError.httpStatus
        }
        return nil
    }
    #endif

    // MARK: - Offline Queue

    private func enqueueValidationRetry(
        purchase: Purchase,
        priceValue: Double,
        currency: String,
        country: String,
        distinctId: String?,
        paywallPlacement: String? = nil,
        variantKey: String? = nil
    ) {
        let baseUrl = apiClient.httpClient.getBaseUrl()
        let url = baseUrl.hasSuffix("/")
            ? "\(baseUrl)sdk/purchases/validate"
            : "\(baseUrl)/sdk/purchases/validate"

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

        guard let payloadData = try? JSONSerialization.data(withJSONObject: body) else { return }

        let item = QueueItem(
            method: "POST",
            url: url,
            payload: payloadData,
            headers: ["Content-Type": "application/json"],
            priority: .critical,
            appKey: apiClient.appKey,
            isEvent: false
        )

        offlineQueue.enqueue(item)
        log("Enqueued validation retry for \(purchase.transactionId)")
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
