import XCTest
@testable import PaywalloSDK

final class IAPTests: XCTestCase {

    // MARK: - ProductFormatter: periodToDays

    func testPeriodToDays_oneDay() {
        XCTAssertEqual(ProductFormatter.periodToDays("P1D"), 1)
    }

    func testPeriodToDays_oneWeek() {
        XCTAssertEqual(ProductFormatter.periodToDays("P1W"), 7)
    }

    func testPeriodToDays_oneMonth() {
        XCTAssertEqual(ProductFormatter.periodToDays("P1M"), 30)
    }

    func testPeriodToDays_oneYear() {
        XCTAssertEqual(ProductFormatter.periodToDays("P1Y"), 365)
    }

    func testPeriodToDays_threeMonths() {
        XCTAssertEqual(ProductFormatter.periodToDays("P3M"), 90)
    }

    func testPeriodToDays_twoWeeks() {
        XCTAssertEqual(ProductFormatter.periodToDays("P2W"), 14)
    }

    func testPeriodToDays_sixMonths() {
        XCTAssertEqual(ProductFormatter.periodToDays("P6M"), 180)
    }

    func testPeriodToDays_threedays() {
        XCTAssertEqual(ProductFormatter.periodToDays("P3D"), 3)
    }

    func testPeriodToDays_twoYears() {
        XCTAssertEqual(ProductFormatter.periodToDays("P2Y"), 730)
    }

    func testPeriodToDays_lowercase() {
        // Should handle lowercase input
        XCTAssertEqual(ProductFormatter.periodToDays("p1m"), 30)
    }

    func testPeriodToDays_invalidReturnsNil() {
        XCTAssertNil(ProductFormatter.periodToDays("INVALID"))
        XCTAssertNil(ProductFormatter.periodToDays(""))
        XCTAssertNil(ProductFormatter.periodToDays("P"))
    }

    // MARK: - ProductFormatter: mapProductType

    func testMapProductType_subscription() {
        XCTAssertEqual(ProductFormatter.mapProductType("subscription"), .subscription)
    }

    func testMapProductType_autoRenewable() {
        XCTAssertEqual(ProductFormatter.mapProductType("autoRenewable"), .subscription)
    }

    func testMapProductType_auto_renewable() {
        XCTAssertEqual(ProductFormatter.mapProductType("auto_renewable"), .subscription)
    }

    func testMapProductType_consumable() {
        XCTAssertEqual(ProductFormatter.mapProductType("consumable"), .consumable)
    }

    func testMapProductType_nonConsumable() {
        XCTAssertEqual(ProductFormatter.mapProductType("nonConsumable"), .nonConsumable)
    }

    func testMapProductType_non_consumable() {
        XCTAssertEqual(ProductFormatter.mapProductType("non_consumable"), .nonConsumable)
    }

    func testMapProductType_nonRenewing() {
        XCTAssertEqual(ProductFormatter.mapProductType("nonRenewingSubscription"), .nonConsumable)
    }

    func testMapProductType_unknown_defaultsToSubscription() {
        XCTAssertEqual(ProductFormatter.mapProductType("unknown_type"), .subscription)
    }

    func testMapProductType_caseInsensitive() {
        XCTAssertEqual(ProductFormatter.mapProductType("SUBSCRIPTION"), .subscription)
        XCTAssertEqual(ProductFormatter.mapProductType("Consumable"), .consumable)
    }

    // MARK: - ProductFormatter: formatTrialDays

    func testFormatTrialDays_portuguese() {
        let ptLocale = Locale(identifier: "pt_BR")
        XCTAssertEqual(ProductFormatter.formatTrialDays(7, locale: ptLocale), "7 dias")
    }

    func testFormatTrialDays_portuguese_portugal() {
        let ptPTLocale = Locale(identifier: "pt_PT")
        XCTAssertEqual(ProductFormatter.formatTrialDays(14, locale: ptPTLocale), "14 dias")
    }

    func testFormatTrialDays_english() {
        let enLocale = Locale(identifier: "en_US")
        XCTAssertEqual(ProductFormatter.formatTrialDays(7, locale: enLocale), "7 days")
    }

    func testFormatTrialDays_spanish() {
        let esLocale = Locale(identifier: "es_ES")
        XCTAssertEqual(ProductFormatter.formatTrialDays(30, locale: esLocale), "30 days")
    }

    func testFormatTrialDays_french() {
        let frLocale = Locale(identifier: "fr_FR")
        XCTAssertEqual(ProductFormatter.formatTrialDays(3, locale: frLocale), "3 days")
    }

    func testFormatTrialDays_zeroDays() {
        let enLocale = Locale(identifier: "en_US")
        XCTAssertEqual(ProductFormatter.formatTrialDays(0, locale: enLocale), "0 days")
    }

    func testFormatTrialDays_largeDays() {
        let ptLocale = Locale(identifier: "pt_BR")
        XCTAssertEqual(ProductFormatter.formatTrialDays(365, locale: ptLocale), "365 dias")
    }

    // MARK: - PurchaseError: Factory

    func testPurchaseErrorFactory_userCancelled() {
        let error = PurchaseErrorFactory.create(PurchaseErrorCode.userCancelled)
        XCTAssertEqual(error.code, "USER_CANCELLED")
        XCTAssertTrue(error.userCancelled)
        XCTAssertEqual(error.domain, "purchase")
    }

    func testPurchaseErrorFactory_purchaseFailed() {
        let error = PurchaseErrorFactory.create(PurchaseErrorCode.purchaseFailed)
        XCTAssertEqual(error.code, "PURCHASE_FAILED")
        XCTAssertFalse(error.userCancelled)
        XCTAssertNil(error.httpStatus)
    }

    func testPurchaseErrorFactory_productNotFound() {
        let error = PurchaseErrorFactory.create(PurchaseErrorCode.productNotFound)
        XCTAssertEqual(error.code, "PRODUCT_NOT_FOUND")
        XCTAssertFalse(error.userCancelled)
    }

    func testPurchaseErrorFactory_storeNotAvailable() {
        let error = PurchaseErrorFactory.create(PurchaseErrorCode.storeNotAvailable)
        XCTAssertEqual(error.code, "PURCHASE_STORE_NOT_AVAILABLE")
        XCTAssertFalse(error.userCancelled)
    }

    func testPurchaseErrorFactory_networkError() {
        let error = PurchaseErrorFactory.create(PurchaseErrorCode.networkError)
        XCTAssertEqual(error.code, "PURCHASE_NETWORK_ERROR")
        XCTAssertFalse(error.userCancelled)
    }

    func testPurchaseErrorFactory_validationFailed() {
        let error = PurchaseErrorFactory.create(PurchaseErrorCode.validationFailed)
        XCTAssertEqual(error.code, "VALIDATION_FAILED")
        XCTAssertFalse(error.userCancelled)
    }

    func testPurchaseErrorFactory_customMessage() {
        let error = PurchaseErrorFactory.create(PurchaseErrorCode.purchaseFailed, message: "Custom error message")
        XCTAssertEqual(error.message, "Custom error message")
    }

    func testPurchaseErrorFactory_defaultMessage() {
        let error = PurchaseErrorFactory.create(PurchaseErrorCode.userCancelled)
        XCTAssertEqual(error.message, "Purchase was cancelled.")
    }

    func testPurchaseErrorFactory_unknownCode() {
        let error = PurchaseErrorFactory.create("UNKNOWN_CODE")
        XCTAssertEqual(error.code, "UNKNOWN_CODE")
        XCTAssertFalse(error.userCancelled)
        XCTAssertEqual(error.message, "Unknown purchase error")
    }

    func testPurchaseErrorFactory_onlyUserCancelledSetsFlag() {
        // Only USER_CANCELLED code should set userCancelled = true
        let codes = [
            PurchaseErrorCode.notInitialized,
            PurchaseErrorCode.productNotFound,
            PurchaseErrorCode.purchaseFailed,
            PurchaseErrorCode.restoreFailed,
            PurchaseErrorCode.validationFailed,
            PurchaseErrorCode.networkError,
            PurchaseErrorCode.storeError,
            PurchaseErrorCode.pendingPurchase,
            PurchaseErrorCode.deferredPurchase,
            PurchaseErrorCode.storeNotAvailable,
        ]

        for code in codes {
            let error = PurchaseErrorFactory.create(code)
            XCTAssertFalse(error.userCancelled, "Expected userCancelled=false for code '\(code)'")
        }

        let cancelledError = PurchaseErrorFactory.create(PurchaseErrorCode.userCancelled)
        XCTAssertTrue(cancelledError.userCancelled)
    }

    // MARK: - AppAccountToken: UUID v4 Validation

    func testUUIDv4_validFormat() {
        // Standard UUID v4 format: version nibble = 4, variant bits = 10
        let uuid = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")
        // This is a v4 UUID (nibble at position 6+1 = '4')
        // Let's verify our validation using known v4 UUIDs
        let v4uuid = UUID() // UUID() generates v4 by default on Apple platforms
        let bytes = v4uuid.uuid
        let version = (bytes.6 & 0xF0) >> 4
        let variant = (bytes.8 & 0xC0) >> 6
        XCTAssertEqual(version, 4, "UUID() should generate v4")
        XCTAssertEqual(variant, 2, "UUID() should have variant 10 (= 2 in 2-bit)")
    }

    func testUUIDv4_appleGeneratedIsV4() {
        // Apple's UUID() always generates v4
        let uuid = UUID()
        let bytes = uuid.uuid
        let version = (bytes.6 & 0xF0) >> 4
        XCTAssertEqual(version, 4)
    }

    func testUUIDv4_anonPrefixStripping() {
        // Simulate stripping "$paywallo_anon:" prefix
        let rawId = "$paywallo_anon:550e8400-e29b-41d4-a716-446655440000"
        let prefix = "$paywallo_anon:"
        let stripped = rawId.hasPrefix(prefix) ? String(rawId.dropFirst(prefix.count)) : rawId
        XCTAssertEqual(stripped, "550e8400-e29b-41d4-a716-446655440000")
    }

    func testUUIDv4_noPrefix_unchanged() {
        let rawId = "550e8400-e29b-41d4-a716-446655440000"
        let prefix = "$paywallo_anon:"
        let stripped = rawId.hasPrefix(prefix) ? String(rawId.dropFirst(prefix.count)) : rawId
        XCTAssertEqual(stripped, rawId)
    }

    func testUUIDv4_invalidString_returnsNil() {
        XCTAssertNil(UUID(uuidString: "not-a-uuid"))
        XCTAssertNil(UUID(uuidString: ""))
        XCTAssertNil(UUID(uuidString: "12345"))
    }

    func testUUIDv4_multipleGeneratedAreAllV4() {
        for _ in 0..<10 {
            let uuid = UUID()
            let bytes = uuid.uuid
            let version = (bytes.6 & 0xF0) >> 4
            let variant = (bytes.8 & 0xC0) >> 6
            XCTAssertEqual(version, 4, "Generated UUID should be v4")
            XCTAssertEqual(variant, 2, "Generated UUID should have RFC 4122 variant")
        }
    }

    func testUUIDv4_anonPrefixStripping_withValidUUID() {
        let validUUID = UUID().uuidString
        let withPrefix = "$paywallo_anon:\(validUUID)"
        let prefix = "$paywallo_anon:"
        let stripped = withPrefix.hasPrefix(prefix) ? String(withPrefix.dropFirst(prefix.count)) : withPrefix
        XCTAssertEqual(stripped, validUUID)
        XCTAssertNotNil(UUID(uuidString: stripped))
    }

    // MARK: - ProductFormatter: buildFromServerProduct

    func testBuildFromServerProduct_basic() {
        let serverProduct = ServerProductInfo(
            storeProductId: "com.app.monthly",
            name: "Monthly Plan",
            priceUsd: 9.99,
            billingPeriod: "P1M",
            trialDays: 7
        )
        let product = ProductFormatter.buildFromServerProduct(serverProduct, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(product.productId, "com.app.monthly")
        XCTAssertEqual(product.title, "Monthly Plan")
        XCTAssertEqual(product.priceValue, 9.99)
        XCTAssertEqual(product.currency, "BRL")
        XCTAssertEqual(product.type, .subscription)
        XCTAssertEqual(product.subscriptionPeriod, "P1M")
        XCTAssertEqual(product.trialDays, 7)
        XCTAssertEqual(product.freeTrialPeriod, "7 days")
    }

    func testBuildFromServerProduct_portugueseLocale() {
        let serverProduct = ServerProductInfo(
            storeProductId: "com.app.yearly",
            name: "Anual",
            priceUsd: 99.99,
            billingPeriod: "P1Y",
            trialDays: 30
        )
        let product = ProductFormatter.buildFromServerProduct(serverProduct, locale: Locale(identifier: "pt_BR"))
        XCTAssertEqual(product.trialDays, 30)
        XCTAssertEqual(product.freeTrialPeriod, "30 dias")
    }

    func testBuildFromServerProduct_noTrialDays() {
        let serverProduct = ServerProductInfo(
            storeProductId: "com.app.weekly",
            name: "Weekly",
            priceUsd: 2.99,
            billingPeriod: "P1W",
            trialDays: nil
        )
        let product = ProductFormatter.buildFromServerProduct(serverProduct)
        XCTAssertNil(product.trialDays)
        XCTAssertNil(product.freeTrialPeriod)
    }

    func testBuildFromServerProduct_nilPrice_defaultsToZero() {
        let serverProduct = ServerProductInfo(
            storeProductId: "com.app.free",
            name: "Free",
            priceUsd: nil,
            billingPeriod: nil,
            trialDays: nil
        )
        let product = ProductFormatter.buildFromServerProduct(serverProduct)
        XCTAssertEqual(product.priceValue, 0.0)
    }

    // MARK: - ProductFormatter: calculatePerPeriodPrices

    func testCalculatePerPeriodPrices_monthly() {
        let (monthly, weekly, daily) = ProductFormatter.calculatePerPeriodPrices(
            priceValue: 9.99,
            period: "P1M",
            currency: "USD"
        )
        // Monthly = price itself (P1M)
        XCTAssertNotNil(monthly)
        XCTAssertNotNil(weekly)
        XCTAssertNotNil(daily)
    }

    func testCalculatePerPeriodPrices_yearly() {
        let (monthly, weekly, daily) = ProductFormatter.calculatePerPeriodPrices(
            priceValue: 99.99,
            period: "P1Y",
            currency: "USD"
        )
        XCTAssertNotNil(monthly)
        XCTAssertNotNil(weekly)
        XCTAssertNotNil(daily)
    }

    func testCalculatePerPeriodPrices_weekly() {
        let (monthly, weekly, daily) = ProductFormatter.calculatePerPeriodPrices(
            priceValue: 4.99,
            period: "P1W",
            currency: "BRL"
        )
        XCTAssertNotNil(monthly)
        // Weekly = price itself (P1W)
        XCTAssertNotNil(weekly)
        XCTAssertNotNil(daily)
    }

    func testCalculatePerPeriodPrices_invalidPeriod() {
        let (monthly, weekly, daily) = ProductFormatter.calculatePerPeriodPrices(
            priceValue: 9.99,
            period: "INVALID",
            currency: "USD"
        )
        XCTAssertNil(monthly)
        XCTAssertNil(weekly)
        XCTAssertNil(daily)
    }
}
