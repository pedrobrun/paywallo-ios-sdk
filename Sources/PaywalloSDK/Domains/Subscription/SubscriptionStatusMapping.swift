import Foundation

public enum SubscriptionStatusMapping {

    public static let activeStatuses: Set<SubscriptionStatus> = [.active, .inGracePeriod]

    /// Check if a subscription status is considered active
    public static func isActive(_ status: SubscriptionStatus) -> Bool {
        activeStatuses.contains(status)
    }

    /// Check if subscription is still active based on status and expiration
    /// - Returns: false if expiresAt is non-nil, non-epoch, and in the past
    /// - Date(0) (epoch) means "no expiration" → returns true if status is active
    public static func isSubscriptionStillActive(status: SubscriptionStatus, expiresAt: Date?) -> Bool {
        guard isActive(status) else { return false }

        guard let expiresAt = expiresAt else { return true }

        // Epoch (timeIntervalSince1970 == 0) means "no expiration"
        if expiresAt.timeIntervalSince1970 == 0 {
            return true
        }

        return expiresAt > Date()
    }

    // MARK: - Domain → Public mapping

    /// Map server/domain status string to public SubscriptionStatus
    public static func fromDomain(_ domainStatus: String) -> SubscriptionStatus {
        switch domainStatus.lowercased() {
        case "active":
            return .active
        case "expired":
            return .expired
        case "billing_retry", "in_billing_retry":
            return .inBillingRetry
        case "grace_period", "in_grace_period":
            return .inGracePeriod
        case "revoked":
            return .revoked
        case "cancelled", "canceled":
            return .cancelled
        case "paused":
            return .expired  // paused maps to expired
        case "unknown":
            return .expired  // unknown maps to expired
        default:
            return .expired
        }
    }

    // MARK: - Public → Domain mapping

    /// Map public SubscriptionStatus to domain/server status string
    public static func toDomain(_ status: SubscriptionStatus) -> String {
        switch status {
        case .active:
            return "active"
        case .expired:
            return "expired"
        case .inBillingRetry:
            return "billing_retry"
        case .inGracePeriod:
            return "grace_period"
        case .revoked:
            return "revoked"
        case .cancelled:
            return "cancelled"
        case .paused:
            return "paused"
        }
    }
}
