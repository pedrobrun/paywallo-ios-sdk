import XCTest
@testable import PaywalloSDK

final class TypesTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - AnyCodable

    func testAnyCodableString() throws {
        let original = AnyCodable("hello")
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? String, "hello")
    }

    func testAnyCodableInt() throws {
        let original = AnyCodable(42)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? Int, 42)
    }

    func testAnyCodableDouble() throws {
        let original = AnyCodable(3.14)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? Double, 3.14)
    }

    func testAnyCodableBool() throws {
        let original = AnyCodable(true)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? Bool, true)
    }

    func testAnyCodableNull() throws {
        let original = AnyCodable(NSNull())
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AnyCodable.self, from: data)
        XCTAssertTrue(decoded.value is NSNull)
    }

    func testAnyCodableEquality() {
        XCTAssertEqual(AnyCodable("a"), AnyCodable("a"))
        XCTAssertNotEqual(AnyCodable("a"), AnyCodable("b"))
        XCTAssertEqual(AnyCodable(1), AnyCodable(1))
        XCTAssertEqual(AnyCodable(true), AnyCodable(true))
        XCTAssertEqual(AnyCodable(NSNull()), AnyCodable(NSNull()))
    }

    // MARK: - Environment

    func testEnvironmentRoundTrip() throws {
        for env in [Environment.production, Environment.sandbox] {
            let data = try encoder.encode(env)
            let decoded = try decoder.decode(Environment.self, from: data)
            XCTAssertEqual(decoded, env)
        }
    }

    func testEnvironmentRawValues() {
        XCTAssertEqual(Environment.production.rawValue, "Production")
        XCTAssertEqual(Environment.sandbox.rawValue, "Sandbox")
    }

    // MARK: - PaywalloConfig

    func testPaywalloConfigRoundTrip() throws {
        let config = PaywalloConfig(appKey: "pk_test", apiUrl: "https://api.test.com", debug: true, environment: .sandbox)
        let data = try encoder.encode(config)
        let decoded = try decoder.decode(PaywalloConfig.self, from: data)
        XCTAssertEqual(decoded.appKey, "pk_test")
        XCTAssertEqual(decoded.apiUrl, "https://api.test.com")
        XCTAssertEqual(decoded.debug, true)
        XCTAssertEqual(decoded.environment, .sandbox)
    }

    func testPaywalloConfigOptionalFields() throws {
        let config = PaywalloConfig(appKey: "pk_test")
        let data = try encoder.encode(config)
        let decoded = try decoder.decode(PaywalloConfig.self, from: data)
        XCTAssertEqual(decoded.appKey, "pk_test")
        XCTAssertNil(decoded.apiUrl)
        XCTAssertNil(decoded.debug)
        XCTAssertNil(decoded.environment)
    }

    // MARK: - PaywallErrorStrings

    func testPaywallErrorStringsRoundTrip() throws {
        let strings = PaywallErrorStrings(title: "Error", retry: "Retry", close: "Close")
        let data = try encoder.encode(strings)
        let decoded = try decoder.decode(PaywallErrorStrings.self, from: data)
        XCTAssertEqual(decoded.title, "Error")
        XCTAssertEqual(decoded.retry, "Retry")
        XCTAssertEqual(decoded.close, "Close")
    }

    // MARK: - SessionFlagConfig

    func testSessionFlagConfigRoundTrip() throws {
        let config = SessionFlagConfig(keys: ["flag1", "flag2"], timeout: 5.0)
        let data = try encoder.encode(config)
        let decoded = try decoder.decode(SessionFlagConfig.self, from: data)
        XCTAssertEqual(decoded.keys, ["flag1", "flag2"])
        XCTAssertEqual(decoded.timeout, 5.0)
    }

    func testSessionFlagConfigNilTimeout() throws {
        let config = SessionFlagConfig(keys: ["flag_a"])
        let data = try encoder.encode(config)
        let decoded = try decoder.decode(SessionFlagConfig.self, from: data)
        XCTAssertEqual(decoded.keys, ["flag_a"])
        XCTAssertNil(decoded.timeout)
    }

    // MARK: - Gender

    func testGenderRawValues() {
        XCTAssertEqual(Gender.male.rawValue, "m")
        XCTAssertEqual(Gender.female.rawValue, "f")
    }

    func testGenderRoundTrip() throws {
        for gender in [Gender.male, Gender.female] {
            let data = try encoder.encode(gender)
            let decoded = try decoder.decode(Gender.self, from: data)
            XCTAssertEqual(decoded, gender)
        }
    }

    // MARK: - IdentifyOptions

    func testIdentifyOptionsRoundTrip() throws {
        let options = IdentifyOptions(
            email: "test@test.com",
            phone: "+5511999999999",
            firstName: "John",
            lastName: "Doe",
            dateOfBirth: "1990-01-01",
            gender: .male
        )
        let data = try encoder.encode(options)
        let decoded = try decoder.decode(IdentifyOptions.self, from: data)
        XCTAssertEqual(decoded.email, "test@test.com")
        XCTAssertEqual(decoded.phone, "+5511999999999")
        XCTAssertEqual(decoded.firstName, "John")
        XCTAssertEqual(decoded.lastName, "Doe")
        XCTAssertEqual(decoded.dateOfBirth, "1990-01-01")
        XCTAssertEqual(decoded.gender, .male)
    }

    func testIdentifyOptionsAllNil() throws {
        let options = IdentifyOptions()
        let data = try encoder.encode(options)
        let decoded = try decoder.decode(IdentifyOptions.self, from: data)
        XCTAssertNil(decoded.email)
        XCTAssertNil(decoded.phone)
        XCTAssertNil(decoded.firstName)
        XCTAssertNil(decoded.gender)
    }

    // MARK: - EventPriority

    func testEventPriorityRawValues() {
        XCTAssertEqual(EventPriority.critical.rawValue, "critical")
        XCTAssertEqual(EventPriority.normal.rawValue, "normal")
    }

    func testEventPriorityRoundTrip() throws {
        for priority in [EventPriority.critical, EventPriority.normal] {
            let data = try encoder.encode(priority)
            let decoded = try decoder.decode(EventPriority.self, from: data)
            XCTAssertEqual(decoded, priority)
        }
    }

    // MARK: - FlagVariant

    func testFlagVariantRoundTrip() throws {
        let flag = FlagVariant(variant: "control", payload: ["key": AnyCodable("value")])
        let data = try encoder.encode(flag)
        let decoded = try decoder.decode(FlagVariant.self, from: data)
        XCTAssertEqual(decoded.variant, "control")
        XCTAssertEqual(decoded.payload?["key"]?.value as? String, "value")
    }

    func testFlagVariantNullVariant() throws {
        let flag = FlagVariant(variant: nil)
        let data = try encoder.encode(flag)
        let decoded = try decoder.decode(FlagVariant.self, from: data)
        XCTAssertNil(decoded.variant)
    }

    // MARK: - ConditionalFlagResult

    func testConditionalFlagResultRoundTrip() throws {
        let result = ConditionalFlagResult(value: true, flagKey: "show_banner")
        let data = try encoder.encode(result)
        let decoded = try decoder.decode(ConditionalFlagResult.self, from: data)
        XCTAssertTrue(decoded.value)
        XCTAssertEqual(decoded.flagKey, "show_banner")
    }

    // MARK: - ConditionalFlagContext

    func testConditionalFlagContextRoundTrip() throws {
        let ctx = ConditionalFlagContext(platform: "ios", appVersion: "1.0.0", country: "BR", distinctId: "user_123")
        let data = try encoder.encode(ctx)
        let decoded = try decoder.decode(ConditionalFlagContext.self, from: data)
        XCTAssertEqual(decoded.platform, "ios")
        XCTAssertEqual(decoded.appVersion, "1.0.0")
        XCTAssertEqual(decoded.country, "BR")
        XCTAssertEqual(decoded.distinctId, "user_123")
    }

    // MARK: - ProductType

    func testProductTypeRawValues() {
        XCTAssertEqual(ProductType.subscription.rawValue, "subscription")
        XCTAssertEqual(ProductType.consumable.rawValue, "consumable")
        XCTAssertEqual(ProductType.nonConsumable.rawValue, "non_consumable")
    }

    func testProductTypeRoundTrip() throws {
        for type_ in [ProductType.subscription, .consumable, .nonConsumable] {
            let data = try encoder.encode(type_)
            let decoded = try decoder.decode(ProductType.self, from: data)
            XCTAssertEqual(decoded, type_)
        }
    }

    // MARK: - Product

    func testProductRoundTrip() throws {
        let product = Product(
            productId: "com.app.monthly",
            title: "Monthly",
            description: "Monthly subscription",
            price: "9.99",
            priceValue: 9.99,
            currency: "USD",
            localizedPrice: "$9.99",
            type: .subscription,
            subscriptionPeriod: "P1M",
            trialDays: 7
        )
        let data = try encoder.encode(product)
        let decoded = try decoder.decode(Product.self, from: data)
        XCTAssertEqual(decoded.productId, "com.app.monthly")
        XCTAssertEqual(decoded.title, "Monthly")
        XCTAssertEqual(decoded.priceValue, 9.99)
        XCTAssertEqual(decoded.type, .subscription)
        XCTAssertEqual(decoded.subscriptionPeriod, "P1M")
        XCTAssertEqual(decoded.trialDays, 7)
    }

    // MARK: - PurchasePlatform

    func testPurchasePlatformRawValues() {
        XCTAssertEqual(PurchasePlatform.ios.rawValue, "ios")
        XCTAssertEqual(PurchasePlatform.android.rawValue, "android")
    }

    func testPurchasePlatformRoundTrip() throws {
        for platform in [PurchasePlatform.ios, .android] {
            let data = try encoder.encode(platform)
            let decoded = try decoder.decode(PurchasePlatform.self, from: data)
            XCTAssertEqual(decoded, platform)
        }
    }

    // MARK: - Purchase

    func testPurchaseRoundTrip() throws {
        let purchase = Purchase(
            productId: "com.app.monthly",
            transactionId: "txn_123",
            transactionDate: 1700000000000,
            receipt: "receipt_data",
            platform: .ios
        )
        let data = try encoder.encode(purchase)
        let decoded = try decoder.decode(Purchase.self, from: data)
        XCTAssertEqual(decoded.productId, "com.app.monthly")
        XCTAssertEqual(decoded.transactionId, "txn_123")
        XCTAssertEqual(decoded.transactionDate, 1700000000000)
        XCTAssertEqual(decoded.platform, .ios)
    }

    // MARK: - ValidatePurchaseResponse

    func testValidatePurchaseResponseRoundTrip() throws {
        let response = ValidatePurchaseResponse(valid: true, subscriptionId: "sub_123", expiresAt: "2025-12-31")
        let data = try encoder.encode(response)
        let decoded = try decoder.decode(ValidatePurchaseResponse.self, from: data)
        XCTAssertTrue(decoded.valid)
        XCTAssertTrue(decoded.success)  // computed alias
        XCTAssertEqual(decoded.subscriptionId, "sub_123")
        XCTAssertEqual(decoded.expiresAt, "2025-12-31")
    }

    func testValidatePurchaseResponseNoSubscription() throws {
        let response = ValidatePurchaseResponse(valid: false, error: "invalid_receipt")
        let data = try encoder.encode(response)
        let decoded = try decoder.decode(ValidatePurchaseResponse.self, from: data)
        XCTAssertFalse(decoded.valid)
        XCTAssertFalse(decoded.success)
        XCTAssertNil(decoded.subscriptionId)
        XCTAssertEqual(decoded.error, "invalid_receipt")
    }

    // MARK: - SubscriptionStatus

    func testSubscriptionStatusRawValues() {
        XCTAssertEqual(SubscriptionStatus.active.rawValue, "active")
        XCTAssertEqual(SubscriptionStatus.expired.rawValue, "expired")
        XCTAssertEqual(SubscriptionStatus.inBillingRetry.rawValue, "in_billing_retry")
        XCTAssertEqual(SubscriptionStatus.inGracePeriod.rawValue, "in_grace_period")
        XCTAssertEqual(SubscriptionStatus.revoked.rawValue, "revoked")
        XCTAssertEqual(SubscriptionStatus.cancelled.rawValue, "cancelled")
    }

    func testSubscriptionStatusRoundTrip() throws {
        for status in [SubscriptionStatus.active, .expired, .inBillingRetry, .inGracePeriod, .revoked, .cancelled] {
            let data = try encoder.encode(status)
            let decoded = try decoder.decode(SubscriptionStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
    }

    // MARK: - SubscriptionPlatform

    func testSubscriptionPlatformRawValues() {
        XCTAssertEqual(SubscriptionPlatform.ios.rawValue, "ios")
        XCTAssertEqual(SubscriptionPlatform.android.rawValue, "android")
    }

    func testSubscriptionPlatformRoundTrip() throws {
        for platform in [SubscriptionPlatform.ios, .android] {
            let data = try encoder.encode(platform)
            let decoded = try decoder.decode(SubscriptionPlatform.self, from: data)
            XCTAssertEqual(decoded, platform)
        }
    }

    // MARK: - Subscription

    func testSubscriptionRoundTrip() throws {
        let sub = Subscription(
            productId: "com.app.yearly",
            status: .active,
            expiresAt: "2023-11-14T22:13:20Z",
            platform: .ios,
            autoRenewEnabled: true,
            inGracePeriod: false
        )
        let data = try encoder.encode(sub)
        let decoded = try decoder.decode(Subscription.self, from: data)
        XCTAssertEqual(decoded.productId, "com.app.yearly")
        XCTAssertEqual(decoded.status, .active)
        XCTAssertNotNil(decoded.expiresAt)
        XCTAssertEqual(decoded.platform, .ios)
        XCTAssertTrue(decoded.autoRenewEnabled)
        XCTAssertFalse(decoded.inGracePeriod)
    }

    func testSubscriptionNilExpiresAt() throws {
        let sub = Subscription(
            productId: "com.app.lifetime",
            status: .active,
            expiresAt: nil,
            platform: .android,
            autoRenewEnabled: false,
            inGracePeriod: false
        )
        let data = try encoder.encode(sub)
        let decoded = try decoder.decode(Subscription.self, from: data)
        XCTAssertNil(decoded.expiresAt)
        XCTAssertEqual(decoded.platform, .android)
    }

    // MARK: - SubscriptionStatusResponse

    func testSubscriptionStatusResponseRoundTrip() throws {
        let response = SubscriptionStatusResponse(
            hasActiveSubscription: true,
            subscription: nil
        )
        let data = try encoder.encode(response)
        let decoded = try decoder.decode(SubscriptionStatusResponse.self, from: data)
        XCTAssertTrue(decoded.hasActiveSubscription)
        XCTAssertNil(decoded.subscription)
    }

    // MARK: - EmergencyPaywallResponse

    func testEmergencyPaywallResponseRoundTrip() throws {
        let response = EmergencyPaywallResponse(enabled: true, paywallId: "pw_123")
        let data = try encoder.encode(response)
        let decoded = try decoder.decode(EmergencyPaywallResponse.self, from: data)
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.paywallId, "pw_123")
    }

    func testEmergencyPaywallResponseDisabled() throws {
        let response = EmergencyPaywallResponse(enabled: false)
        let data = try encoder.encode(response)
        let decoded = try decoder.decode(EmergencyPaywallResponse.self, from: data)
        XCTAssertFalse(decoded.enabled)
        XCTAssertNil(decoded.paywallId)
        XCTAssertNil(decoded.isActive)
    }

    // MARK: - ServerProductInfo

    func testServerProductInfoRoundTrip() throws {
        let info = ServerProductInfo(storeProductId: "com.app.monthly", name: "Monthly", priceUsd: 9.99, billingPeriod: "P1M", trialDays: 7)
        let data = try encoder.encode(info)
        let decoded = try decoder.decode(ServerProductInfo.self, from: data)
        XCTAssertEqual(decoded.storeProductId, "com.app.monthly")
        XCTAssertEqual(decoded.name, "Monthly")
        XCTAssertEqual(decoded.price, 9.99)
        XCTAssertEqual(decoded.billingPeriod, "P1M")
        XCTAssertEqual(decoded.trialDays, 7)
    }

    func testServerProductInfoNilFields() throws {
        let info = ServerProductInfo(storeProductId: "prod_1", name: "Basic", priceUsd: nil, billingPeriod: nil, trialDays: nil)
        let data = try encoder.encode(info)
        let decoded = try decoder.decode(ServerProductInfo.self, from: data)
        XCTAssertEqual(decoded.storeProductId, "prod_1")
        XCTAssertNil(decoded.price)
        XCTAssertNil(decoded.billingPeriod)
        XCTAssertNil(decoded.trialDays)
    }

    // MARK: - CampaignPaywall

    func testCampaignPaywallRoundTrip() throws {
        let paywall = CampaignPaywall(
            id: "pw_1",
            placement: "main",
            config: ["color": AnyCodable("blue")],
            primaryProductId: "prod_1",
            secondaryProductId: "prod_2"
        )
        let data = try encoder.encode(paywall)
        let decoded = try decoder.decode(CampaignPaywall.self, from: data)
        XCTAssertEqual(decoded.id, "pw_1")
        XCTAssertEqual(decoded.placement, "main")
        XCTAssertEqual(decoded.config["color"]?.value as? String, "blue")
        XCTAssertEqual(decoded.primaryProductId, "prod_1")
        XCTAssertEqual(decoded.secondaryProductId, "prod_2")
    }

    // MARK: - CampaignResponse

    func testCampaignResponseRoundTrip() throws {
        let paywall = CampaignPaywall(
            id: "pw_1",
            placement: "main",
            config: ["key": AnyCodable("value")],
            primaryProductId: "prod_1"
        )
        let campaign = CampaignResponse(
            campaignId: "camp_1",
            placement: "main",
            variantKey: "control",
            variantId: "var_uuid",
            paywall: paywall
        )
        let data = try encoder.encode(campaign)
        let decoded = try decoder.decode(CampaignResponse.self, from: data)
        XCTAssertEqual(decoded.campaignId, "camp_1")
        XCTAssertEqual(decoded.placement, "main")
        XCTAssertEqual(decoded.variantKey, "control")
        XCTAssertEqual(decoded.variantId, "var_uuid")
        XCTAssertEqual(decoded.paywall.id, "pw_1")
        XCTAssertEqual(decoded.paywall.primaryProductId, "prod_1")
    }

    func testCampaignResponseNilVariantId() throws {
        let paywall = CampaignPaywall(id: "pw_2", placement: "onboarding", config: [:])
        let campaign = CampaignResponse(
            campaignId: "camp_2",
            placement: "onboarding",
            variantKey: "treatment",
            variantId: nil,
            paywall: paywall
        )
        let data = try encoder.encode(campaign)
        let decoded = try decoder.decode(CampaignResponse.self, from: data)
        XCTAssertNil(decoded.variantId)
        XCTAssertEqual(decoded.variantKey, "treatment")
    }
}
