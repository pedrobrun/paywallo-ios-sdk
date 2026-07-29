import Foundation

public struct ServerProductInfo: Codable, Sendable {
    public let storeProductId: String
    public let name: String
    /// Server field: `price_usd`
    public let priceUsd: Double?
    public let billingPeriod: String?
    public let trialDays: Int?
    public let displayOrder: Int?
    public let isActive: Bool?

    /// Convenience alias kept for backwards compat.
    public var price: Double? { priceUsd }

    enum CodingKeys: String, CodingKey {
        case storeProductId
        case name
        case priceUsd = "price"
        case billingPeriod
        case trialDays
        case displayOrder
        case isActive
    }

    public init(
        storeProductId: String,
        name: String,
        priceUsd: Double? = nil,
        billingPeriod: String? = nil,
        trialDays: Int? = nil,
        displayOrder: Int? = nil,
        isActive: Bool? = nil
    ) {
        self.storeProductId = storeProductId
        self.name = name
        self.priceUsd = priceUsd
        self.billingPeriod = billingPeriod
        self.trialDays = trialDays
        self.displayOrder = displayOrder
        self.isActive = isActive
    }
}

public struct CampaignPaywall: Codable, Sendable {
    public let id: String
    public let placement: String
    public let config: [String: AnyCodable]
    public var primaryProductId: String?
    public var secondaryProductId: String?
    public var primaryProduct: ServerProductInfo?
    public var secondaryProduct: ServerProductInfo?

    public init(
        id: String,
        placement: String,
        config: [String: AnyCodable],
        primaryProductId: String? = nil,
        secondaryProductId: String? = nil,
        primaryProduct: ServerProductInfo? = nil,
        secondaryProduct: ServerProductInfo? = nil
    ) {
        self.id = id
        self.placement = placement
        self.config = config
        self.primaryProductId = primaryProductId
        self.secondaryProductId = secondaryProductId
        self.primaryProduct = primaryProduct
        self.secondaryProduct = secondaryProduct
    }
}

public struct CampaignResponse: Codable, Sendable {
    public let campaignId: String
    public let placement: String
    public let variantKey: String
    public var variantId: String?
    public let paywall: CampaignPaywall

    public init(
        campaignId: String,
        placement: String,
        variantKey: String,
        variantId: String? = nil,
        paywall: CampaignPaywall
    ) {
        self.campaignId = campaignId
        self.placement = placement
        self.variantKey = variantKey
        self.variantId = variantId
        self.paywall = paywall
    }
}

public struct CampaignResult: Sendable {
    public let presented: Bool
    public let purchased: Bool
    public var productId: String?
    public var transactionId: String?
    public let cancelled: Bool
    public let restored: Bool
    public var campaignId: String?
    public var variantKey: String?
    public var variantId: String?
    public var error: Error?
    public var skippedReason: String?

    public init(
        presented: Bool,
        purchased: Bool,
        productId: String? = nil,
        transactionId: String? = nil,
        cancelled: Bool,
        restored: Bool,
        campaignId: String? = nil,
        variantKey: String? = nil,
        variantId: String? = nil,
        error: Error? = nil,
        skippedReason: String? = nil
    ) {
        self.presented = presented
        self.purchased = purchased
        self.productId = productId
        self.transactionId = transactionId
        self.cancelled = cancelled
        self.restored = restored
        self.campaignId = campaignId
        self.variantKey = variantKey
        self.variantId = variantId
        self.error = error
        self.skippedReason = skippedReason
    }
}
