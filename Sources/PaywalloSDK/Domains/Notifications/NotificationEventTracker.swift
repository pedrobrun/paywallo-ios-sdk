import Foundation

// MARK: - Notification Event Names
//
// Canonical event types — MUST match server `PushEventType` enum 1:1
// (and the RN SDK `NotificationEventType` in types.ts).
// Server Zod (`pushNotificationEventSchema`) rejects anything outside this set.
// Events are emitted as `eventName: "notification"` with `type` in properties.
public enum NotificationEventName {
    public static let received   = "notification_delivered"
    public static let displayed  = "notification_displayed"
    public static let opened     = "notification_clicked"
    public static let dismissed  = "notification_dismissed"
    public static let failed     = "notification_failed"
    public static let converted  = "notification_converted"
}

// MARK: - Seen Entry (for LRU + TTL)

private struct SeenEntry: Codable {
    let timestamp: TimeInterval   // seconds since epoch
}

// MARK: - NotificationEventTracker

public final class NotificationEventTracker {

    // MARK: - Configuration

    private static let maxEntries     = 1000
    private static let ttlSeconds: TimeInterval = 3600   // 1 hour
    private static let storageKey     = PaywalloConstants.seenMessagesKey

    // MARK: - Dependencies

    private let eventBatcher: EventBatcherProtocol
    private let secureStorage: SecureStorage
    private let deviceIdProvider: () -> String

    // MARK: - State

    /// key: "\(messageId):\(eventType)"  value: entry with timestamp
    private var seenMessages: [String: SeenEntry] = [:]
    /// Insertion-order tracker for LRU eviction
    private var insertionOrder: [String] = []

    private var debug = false

    // MARK: - Init

    public init(
        eventBatcher: EventBatcherProtocol,
        secureStorage: SecureStorage = .shared,
        deviceIdProvider: @escaping () -> String,
        debug: Bool = false
    ) {
        self.eventBatcher = eventBatcher
        self.secureStorage = secureStorage
        self.deviceIdProvider = deviceIdProvider
        self.debug = debug
    }

    // MARK: - Restore / Persist

    public func restoreFromStorage() async {
        guard let json = await secureStorage.get(Self.storageKey),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: SeenEntry].self, from: data)
        else { return }

        seenMessages = decoded
        insertionOrder = Array(decoded.keys)
        evictExpired()
        log("Restored \(seenMessages.count) seen-message entries")
    }

    private func persistToStorage() async {
        guard let data = try? JSONEncoder().encode(seenMessages),
              let json = String(data: data, encoding: .utf8)
        else { return }
        await secureStorage.set(Self.storageKey, value: json)
    }

    // MARK: - Track

    /// Tracks a notification event. Returns false if the event was deduped (skipped).
    @discardableResult
    public func track(
        eventName: String,
        notificationId: String?,
        campaignId: String?,
        variantKey: String? = nil,
        messageId: String?,
        appUserId: String? = nil,
        failureReason: String? = nil,
        extraProperties: [String: AnyCodable] = [:]
    ) async -> Bool {
        let dedupeKey = makeDedupeKey(messageId: messageId, eventType: eventName)

        if isDuplicate(key: dedupeKey) {
            log("Deduped event '\(eventName)' for key '\(dedupeKey)'")
            return false
        }

        recordSeen(key: dedupeKey)
        await persistToStorage()

        let deviceId = deviceIdProvider()
        var properties: [String: AnyCodable] = [
            "family":        AnyCodable("notification"),
            "type":          AnyCodable(eventName),
            "push_platform": AnyCodable("ios"),
            "timezone":      AnyCodable(TimeZone.current.identifier),
            "device_id":     AnyCodable(deviceId),
        ]

        if let notificationId = notificationId {
            properties["notification_id"] = AnyCodable(notificationId)
        }
        if let campaignId = campaignId {
            properties["campaign_id"] = AnyCodable(campaignId)
        }
        if let variantKey = variantKey {
            properties["variant_key"] = AnyCodable(variantKey)
        }
        if let messageId = messageId {
            properties["message_id"] = AnyCodable(messageId)
        }
        if let appUserId = appUserId {
            properties["app_user_id"] = AnyCodable(appUserId)
        }
        if let failureReason = failureReason {
            properties["failure_reason"] = AnyCodable(failureReason)
        }

        for (k, v) in extraProperties {
            properties[k] = v
        }

        // Route through the "notification" event — matching RN SDK's batcher.trackEvent("notification", ...)
        eventBatcher.enqueue(name: "notification", properties: properties, priority: .normal, timestamp: nil)
        log("Tracked '\(eventName)' for messageId=\(messageId ?? "nil")")
        return true
    }

    // MARK: - Convenience Methods

    @discardableResult
    public func trackReceived(
        notificationId: String? = nil,
        campaignId: String? = nil,
        variantKey: String? = nil,
        messageId: String? = nil,
        appUserId: String? = nil,
        extra: [String: AnyCodable] = [:]
    ) async -> Bool {
        await track(
            eventName: NotificationEventName.received,
            notificationId: notificationId,
            campaignId: campaignId,
            variantKey: variantKey,
            messageId: messageId,
            appUserId: appUserId,
            failureReason: nil,
            extraProperties: extra
        )
    }

    @discardableResult
    public func trackDisplayed(
        notificationId: String? = nil,
        campaignId: String? = nil,
        variantKey: String? = nil,
        messageId: String? = nil,
        appUserId: String? = nil,
        extra: [String: AnyCodable] = [:]
    ) async -> Bool {
        await track(
            eventName: NotificationEventName.displayed,
            notificationId: notificationId,
            campaignId: campaignId,
            variantKey: variantKey,
            messageId: messageId,
            appUserId: appUserId,
            failureReason: nil,
            extraProperties: extra
        )
    }

    @discardableResult
    public func trackOpened(
        notificationId: String? = nil,
        campaignId: String? = nil,
        variantKey: String? = nil,
        messageId: String? = nil,
        appUserId: String? = nil,
        extra: [String: AnyCodable] = [:]
    ) async -> Bool {
        await track(
            eventName: NotificationEventName.opened,
            notificationId: notificationId,
            campaignId: campaignId,
            variantKey: variantKey,
            messageId: messageId,
            appUserId: appUserId,
            failureReason: nil,
            extraProperties: extra
        )
    }

    @discardableResult
    public func trackDismissed(
        notificationId: String? = nil,
        campaignId: String? = nil,
        variantKey: String? = nil,
        messageId: String? = nil,
        appUserId: String? = nil,
        extra: [String: AnyCodable] = [:]
    ) async -> Bool {
        await track(
            eventName: NotificationEventName.dismissed,
            notificationId: notificationId,
            campaignId: campaignId,
            variantKey: variantKey,
            messageId: messageId,
            appUserId: appUserId,
            failureReason: nil,
            extraProperties: extra
        )
    }

    @discardableResult
    public func trackFailed(
        notificationId: String? = nil,
        campaignId: String? = nil,
        variantKey: String? = nil,
        messageId: String? = nil,
        appUserId: String? = nil,
        failureReason: String? = nil,
        extra: [String: AnyCodable] = [:]
    ) async -> Bool {
        await track(
            eventName: NotificationEventName.failed,
            notificationId: notificationId,
            campaignId: campaignId,
            variantKey: variantKey,
            messageId: messageId,
            appUserId: appUserId,
            failureReason: failureReason,
            extraProperties: extra
        )
    }

    @discardableResult
    public func trackConverted(
        notificationId: String? = nil,
        campaignId: String? = nil,
        variantKey: String? = nil,
        messageId: String? = nil,
        appUserId: String? = nil,
        extra: [String: AnyCodable] = [:]
    ) async -> Bool {
        await track(
            eventName: NotificationEventName.converted,
            notificationId: notificationId,
            campaignId: campaignId,
            variantKey: variantKey,
            messageId: messageId,
            appUserId: appUserId,
            failureReason: nil,
            extraProperties: extra
        )
    }

    // MARK: - Dedup Logic

    private func makeDedupeKey(messageId: String?, eventType: String) -> String {
        "\(messageId ?? "_no_id"):\(eventType)"
    }

    private func isDuplicate(key: String) -> Bool {
        guard let entry = seenMessages[key] else { return false }
        let age = Date().timeIntervalSince1970 - entry.timestamp
        if age > Self.ttlSeconds {
            // Expired entry — remove it so we re-track
            removeSeen(key: key)
            return false
        }
        return true
    }

    private func recordSeen(key: String) {
        let entry = SeenEntry(timestamp: Date().timeIntervalSince1970)

        if seenMessages[key] == nil {
            // New entry — check LRU cap
            if insertionOrder.count >= Self.maxEntries {
                evictLRU()
            }
            insertionOrder.append(key)
        }

        seenMessages[key] = entry
    }

    private func removeSeen(key: String) {
        seenMessages.removeValue(forKey: key)
        insertionOrder.removeAll { $0 == key }
    }

    private func evictLRU() {
        guard !insertionOrder.isEmpty else { return }
        let oldest = insertionOrder.removeFirst()
        seenMessages.removeValue(forKey: oldest)
        log("LRU evicted key: \(oldest)")
    }

    private func evictExpired() {
        let now = Date().timeIntervalSince1970
        let expired = seenMessages.filter { now - $0.value.timestamp > Self.ttlSeconds }.map { $0.key }
        for key in expired {
            removeSeen(key: key)
        }
        if !expired.isEmpty {
            log("Evicted \(expired.count) expired entries")
        }
    }

    // MARK: - Testing Helpers

    /// Number of currently tracked (non-expired) message keys.
    public var seenCount: Int { seenMessages.count }

    /// Manually inject a seen entry at a specific timestamp (for testing TTL).
    public func injectSeen(key: String, timestamp: TimeInterval) {
        seenMessages[key] = SeenEntry(timestamp: timestamp)
        if !insertionOrder.contains(key) {
            insertionOrder.append(key)
        }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        guard debug else { return }
        print("[Paywallo:NotifTracker] \(message)")
    }
}
