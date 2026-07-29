import Foundation

// MARK: - Push Permission Status (mirrors RN PushPermissionStatus)

/// Mirrors RN SDK `PushPermissionStatus`:
/// `"granted" | "denied" | "provisional" | "notDetermined"`
public enum PushPermissionStatus: String, Sendable {
    case granted
    case denied
    case provisional
    case notDetermined
}

// MARK: - Session State (mirrors RN SessionState)

/// Mirrors RN SDK `SessionState`:
/// `{ sessionId: string | null; startedAt: Date | null; isActive: boolean; duration: number }`
public struct SessionState: Sendable {
    public let sessionId: String?
    public let startedAt: Date?
    public let isActive: Bool
    /// Duration of the current session in milliseconds (0 if no active session).
    public let duration: TimeInterval

    public init(sessionId: String?, startedAt: Date?, isActive: Bool, duration: TimeInterval) {
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.isActive = isActive
        self.duration = duration
    }
}

// MARK: - Offline Queue Result (mirrors RN processOfflineQueue result)

/// Mirrors RN SDK `{ processed: number; failed: number }` returned by `processOfflineQueue()`.
public struct OfflineQueueResult: Sendable {
    public let processed: Int
    public let failed: Int

    public init(processed: Int, failed: Int) {
        self.processed = processed
        self.failed = failed
    }
}

public enum SubscriptionStatus: String, Codable, Sendable {
    case active
    case expired
    case inBillingRetry = "in_billing_retry"
    case inGracePeriod = "in_grace_period"
    case revoked
    case cancelled
    case paused
}

public enum SubscriptionPlatform: String, Codable, Sendable {
    case ios
    case android
}

/// Matches server V2 response shape (snake_case):
/// `{ product_id, status, expires_at, platform, auto_renew_enabled, in_grace_period }`
public struct Subscription: Codable, Sendable {
    public let productId: String
    public let status: SubscriptionStatus
    public let expiresAt: String?
    public let platform: SubscriptionPlatform
    public let autoRenewEnabled: Bool
    public let inGracePeriod: Bool

    enum CodingKeys: String, CodingKey {
        case productId = "product_id"
        case status
        case expiresAt = "expires_at"
        case platform
        case autoRenewEnabled = "auto_renew_enabled"
        case inGracePeriod = "in_grace_period"
    }

    public init(
        productId: String,
        status: SubscriptionStatus,
        expiresAt: String?,
        platform: SubscriptionPlatform,
        autoRenewEnabled: Bool,
        inGracePeriod: Bool
    ) {
        self.productId = productId
        self.status = status
        self.expiresAt = expiresAt
        self.platform = platform
        self.autoRenewEnabled = autoRenewEnabled
        self.inGracePeriod = inGracePeriod
    }
}

/// Matches server V2 response shape (snake_case):
/// `{ has_active_subscription, subscription: Subscription | null }`
public struct SubscriptionStatusResponse: Codable, Sendable {
    public let hasActiveSubscription: Bool
    public let subscription: Subscription?

    enum CodingKeys: String, CodingKey {
        case hasActiveSubscription = "has_active_subscription"
        case subscription
    }

    public init(hasActiveSubscription: Bool, subscription: Subscription?) {
        self.hasActiveSubscription = hasActiveSubscription
        self.subscription = subscription
    }
}

public struct RestoreResult: Sendable {
    public let success: Bool
    public let restoredProducts: [String]
    public var error: Error?

    public init(success: Bool, restoredProducts: [String], error: Error? = nil) {
        self.success = success
        self.restoredProducts = restoredProducts
        self.error = error
    }
}
