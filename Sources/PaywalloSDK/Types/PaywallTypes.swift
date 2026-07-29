import Foundation

public struct PaywallConfig: Codable, Sendable {
    public let id: String
    public let placement: String
    public let config: [String: AnyCodable]
    public var content: AnyCodable?
    public var primaryProductId: String?
    public var secondaryProductId: String?

    public init(
        id: String,
        placement: String,
        config: [String: AnyCodable],
        content: AnyCodable? = nil,
        primaryProductId: String? = nil,
        secondaryProductId: String? = nil
    ) {
        self.id = id
        self.placement = placement
        self.config = config
        self.content = content
        self.primaryProductId = primaryProductId
        self.secondaryProductId = secondaryProductId
    }
}

public struct PaywallResult: Sendable {
    public let presented: Bool
    public let purchased: Bool
    public var productId: String?
    public var transactionId: String?
    public let cancelled: Bool
    public let restored: Bool
    public var error: Error?

    public init(
        presented: Bool,
        purchased: Bool,
        productId: String? = nil,
        transactionId: String? = nil,
        cancelled: Bool,
        restored: Bool,
        error: Error? = nil
    ) {
        self.presented = presented
        self.purchased = purchased
        self.productId = productId
        self.transactionId = transactionId
        self.cancelled = cancelled
        self.restored = restored
        self.error = error
    }
}

/// Matches server response: `{ enabled: Bool, paywallId: String | null, isActive: Bool }`.
/// Note: the server does NOT return a full `paywall` config inline — the SDK must
/// fetch the paywall separately via `/sdk/paywalls/:placement` if needed.
public struct EmergencyPaywallResponse: Codable, Sendable {
    public let enabled: Bool
    public var paywallId: String?
    /// Whether the emergency paywall is within its active time window.
    /// Server always returns `isActive == enabled` (both true or both false).
    public var isActive: Bool?

    public init(enabled: Bool, paywallId: String? = nil, isActive: Bool? = nil) {
        self.enabled = enabled
        self.paywallId = paywallId
        self.isActive = isActive
    }
}
