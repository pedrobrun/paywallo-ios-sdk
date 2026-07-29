import Foundation

public enum ProductType: String, Codable, Sendable {
    case subscription
    case consumable
    case nonConsumable = "non_consumable"
}

public enum PurchasePlatform: String, Codable, Sendable {
    case ios
    case android
}

public struct Product: Codable, Sendable {
    public let productId: String
    public let title: String
    public let description: String
    public let price: String
    public let priceValue: Double
    public let currency: String
    public let localizedPrice: String
    public let type: ProductType
    public var subscriptionPeriod: String?
    public var introductoryPrice: String?
    public var introductoryPriceValue: Double?
    public var freeTrialPeriod: String?
    public var trialDays: Int?
    public var pricePerMonth: String?
    public var pricePerWeek: String?
    public var pricePerDay: String?
    public var savings: String?
    public var savingsPercent: String?

    public init(
        productId: String,
        title: String,
        description: String,
        price: String,
        priceValue: Double,
        currency: String,
        localizedPrice: String,
        type: ProductType,
        subscriptionPeriod: String? = nil,
        introductoryPrice: String? = nil,
        introductoryPriceValue: Double? = nil,
        freeTrialPeriod: String? = nil,
        trialDays: Int? = nil,
        pricePerMonth: String? = nil,
        pricePerWeek: String? = nil,
        pricePerDay: String? = nil,
        savings: String? = nil,
        savingsPercent: String? = nil
    ) {
        self.productId = productId
        self.title = title
        self.description = description
        self.price = price
        self.priceValue = priceValue
        self.currency = currency
        self.localizedPrice = localizedPrice
        self.type = type
        self.subscriptionPeriod = subscriptionPeriod
        self.introductoryPrice = introductoryPrice
        self.introductoryPriceValue = introductoryPriceValue
        self.freeTrialPeriod = freeTrialPeriod
        self.trialDays = trialDays
        self.pricePerMonth = pricePerMonth
        self.pricePerWeek = pricePerWeek
        self.pricePerDay = pricePerDay
        self.savings = savings
        self.savingsPercent = savingsPercent
    }
}

public struct Purchase: Codable, Sendable {
    public let productId: String
    public let transactionId: String
    public let transactionDate: TimeInterval
    public let receipt: String
    public let platform: PurchasePlatform

    public init(productId: String, transactionId: String, transactionDate: TimeInterval, receipt: String, platform: PurchasePlatform) {
        self.productId = productId
        self.transactionId = transactionId
        self.transactionDate = transactionDate
        self.receipt = receipt
        self.platform = platform
    }
}

public struct PurchaseResult: Sendable {
    public let success: Bool
    public var purchase: Purchase?
    public var error: PurchaseError?

    public init(success: Bool, purchase: Purchase? = nil, error: PurchaseError? = nil) {
        self.success = success
        self.purchase = purchase
        self.error = error
    }
}

/// Matches the server V2 response shape:
/// `{ data: { valid, subscription_id, expires_at, error? }, meta: { ... } }`
/// The v2 envelope is unwrapped by ApiClient; this struct decodes the inner `data`.
public struct ValidatePurchaseResponse: Codable, Sendable {
    /// Server field: `valid` (NOT `success`)
    public let valid: Bool
    public var subscriptionId: String?
    public var expiresAt: String?
    public var error: String?

    /// Convenience alias so callers can keep using `.success`
    public var success: Bool { valid }

    enum CodingKeys: String, CodingKey {
        case valid
        case subscriptionId = "subscription_id"
        case expiresAt = "expires_at"
        case error
    }

    public init(valid: Bool, subscriptionId: String? = nil, expiresAt: String? = nil, error: String? = nil) {
        self.valid = valid
        self.subscriptionId = subscriptionId
        self.expiresAt = expiresAt
        self.error = error
    }
}

/// Legacy struct kept for downstream compatibility — not returned by the V2 endpoint.
public struct ValidatedSubscription: Codable, Sendable {
    public let productId: String
    public let status: String
    public let expiresAt: String?

    public init(productId: String, status: String, expiresAt: String?) {
        self.productId = productId
        self.status = status
        self.expiresAt = expiresAt
    }
}
