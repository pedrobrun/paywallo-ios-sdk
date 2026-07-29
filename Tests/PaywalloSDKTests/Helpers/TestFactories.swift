import Foundation
@testable import PaywalloSDK

// MARK: - SpyEventBatcher
// Shared spy used by NotificationEventTrackerTests and any other test that needs
// to observe EventBatcher.enqueue() calls without making real network requests.
public final class SpyEventBatcher: EventBatcher {
    public var enqueuedEvents: [(name: String, properties: [String: AnyCodable])] = []

    public override func enqueue(
        name: String,
        properties: [String: AnyCodable],
        priority: EventPriority = .normal,
        timestamp: TimeInterval? = nil
    ) {
        enqueuedEvents.append((name: name, properties: properties))
        // Intentionally do NOT call super — avoids queue/timer/network logic
    }
}

public enum TestFactories {

    public static func makeConfig(
        appKey: String = "pk_test_key_123",
        apiUrl: String = "https://api.paywallo.com",
        debug: Bool = true,
        environment: Environment = .sandbox
    ) -> PaywalloConfig {
        PaywalloConfig(
            appKey: appKey,
            apiUrl: apiUrl,
            debug: debug,
            environment: environment
        )
    }

    public static func makeProduct(
        productId: String = "com.test.monthly",
        title: String = "Monthly Plan",
        description: String = "Monthly subscription",
        price: String = "9.99",
        priceValue: Double = 9.99,
        currency: String = "USD",
        localizedPrice: String = "$9.99",
        type: ProductType = .subscription
    ) -> Product {
        Product(
            productId: productId,
            title: title,
            description: description,
            price: price,
            priceValue: priceValue,
            currency: currency,
            localizedPrice: localizedPrice,
            type: type
        )
    }

    public static func makeSubscription(
        productId: String = "com.test.monthly",
        status: SubscriptionStatus = .active,
        expiresAt: String? = ISO8601DateFormatter().string(from: Date().addingTimeInterval(30 * 24 * 3600)),
        platform: SubscriptionPlatform = .ios,
        autoRenewEnabled: Bool = true,
        inGracePeriod: Bool = false
    ) -> Subscription {
        Subscription(
            productId: productId,
            status: status,
            expiresAt: expiresAt,
            platform: platform,
            autoRenewEnabled: autoRenewEnabled,
            inGracePeriod: inGracePeriod
        )
    }

    public static func makePurchase(
        productId: String = "com.test.monthly",
        transactionId: String = "txn_123456",
        transactionDate: TimeInterval = Date().timeIntervalSince1970 * 1000,
        receipt: String = "mock_receipt_data",
        platform: PurchasePlatform = .ios
    ) -> Purchase {
        Purchase(
            productId: productId,
            transactionId: transactionId,
            transactionDate: transactionDate,
            receipt: receipt,
            platform: platform
        )
    }

    public static func makeIdentifyOptions(
        email: String? = "test@example.com",
        properties: [String: AnyCodable]? = nil,
        phone: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        dateOfBirth: String? = nil,
        gender: Gender? = nil
    ) -> IdentifyOptions {
        IdentifyOptions(
            email: email,
            properties: properties,
            phone: phone,
            firstName: firstName,
            lastName: lastName,
            dateOfBirth: dateOfBirth,
            gender: gender
        )
    }
}
