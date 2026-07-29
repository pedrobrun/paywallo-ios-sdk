import Foundation
import Security

public enum PaywalloConstants {
    public static let sdkVersion = "2.6.0"
    public static let sdkPlatform = "ios"

    // MARK: - API
    public static let defaultApiUrl = "https://panel.lucasqueiroga.shop"
    public static let defaultWebUrl = "https://paywallo.com.br"
    public static let defaultTimeout: TimeInterval = 30
    public static let httpClientTimeout: TimeInterval = 10

    // MARK: - Keychain
    public static let keychainServiceName = "com.paywallo.sdk"
    public static let keychainAccessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    // MARK: - Storage Key Prefix
    public static let storagePrefix = "@paywallo:"
    public static let legacyStoragePrefix = "@panel:"

    // MARK: - Identity Storage Keys
    public static let deviceIdKey = "@paywallo:device_id"
    public static let deviceIdFallbackKey = "device_id_fallback"
    public static let anonIdKey = "@paywallo:anon_id"
    public static let distinctIdKey = "@paywallo:user_distinct_id"
    public static let userEmailKey = "@paywallo:user_email"
    public static let userFirstNameKey = "@paywallo:user_first_name"
    public static let userLastNameKey = "@paywallo:user_last_name"
    public static let userPhoneKey = "@paywallo:user_phone"
    public static let userDobKey = "@paywallo:user_dob"
    public static let userGenderKey = "@paywallo:user_gender"
    public static let userPropertiesKey = "@paywallo:user_properties"
    public static let userNameKey = "@paywallo:user_name"
    public static let userCountryKey = "@paywallo:user_country"
    public static let userLocaleKey = "@paywallo:user_locale"

    // MARK: - Legacy Identity Keys (SDK ≤2.x used @panel: prefix)
    public static let legacyUserPhoneKey = "@panel:user_phone"
    public static let legacyUserFirstNameKey = "@panel:user_first_name"
    public static let legacyUserLastNameKey = "@panel:user_last_name"
    public static let legacyUserDobKey = "@panel:user_dob"
    public static let legacyUserGenderKey = "@panel:user_gender"

    // MARK: - Legacy Identity Keys (SDK ≤1.5.x)
    public static let legacyDeviceIdKey = "device_id"
    public static let legacyAnonIdKey = "anon_id"
    public static let legacyEmailKey = "user_email"
    public static let legacyPropertiesKey = "user_properties"
    public static let legacyDistinctIdKey = "user_distinct_id"
    public static let legacyNameKey = "user_name"
    public static let legacyCountryKey = "user_country"
    public static let legacyLocaleKey = "user_locale"

    // MARK: - Install Tracking Keys
    public static let installTrackedKey = "@paywallo:install_tracked"
    public static let appInstalledSentKey = "@paywallo:app_installed_sent"
    public static let installEventIdKey = "@paywallo:install_event_id"
    public static let deferredMatchDoneKey = "@paywallo:deferred_match_done"

    // MARK: - Session Storage Keys
    public static let currentSessionIdKey = "@paywallo:current_session_id"
    public static let sessionStartKey = "@paywallo:session_start"
    public static let emergencyPaywallShownKey = "@paywallo:emergency_paywall_shown"

    // MARK: - Attribution Keys
    public static let attributionV2Key = "@paywallo:attribution_v2"
    public static let legacyAttributionV2Key = "@panel:attribution_v2"

    // MARK: - Paywall Keys
    public static let paywallHeartbeatKey = "@paywallo:paywall_heartbeat"
    public static let legacyPaywallHeartbeatKey = "@panel:paywall_heartbeat"

    // MARK: - Subscription Cache Keys
    public static let subscriptionCachePrefix = "subscription_cache:"
    public static let subscriptionCacheIndexKey = "subscription_cache:__index__"
    public static let legacySubscriptionCacheKey = "@panel:subscription_cache"

    // MARK: - Offline Queue Keys
    public static let offlineQueueKey = "@paywallo:offline_queue"
    public static let offlineQueueJournalKey = "@paywallo:offline_queue:journal"
    public static let queueDlqKey = "@paywallo:offline_queue:dlq"

    // MARK: - Migration Keys
    public static let migrationV152DoneKey = "@paywallo:_migration_v152_done"

    // MARK: - Notification Keys
    public static let seenMessagesKey = "seen_messages"
    public static let pushTokenKey = "@paywallo:push_token"
    public static let flagStoragePrefix = "@paywallo:flag:"

    // MARK: - Legacy Notification Keys
    public static let legacyPushTokenKey = "@panel:push_token"
    public static let legacyEmergencyPaywallShownKey = "@panel:emergency_paywall_shown"

    // MARK: - Offering Cache Keys
    public static let offeringsCacheKey = "@paywallo:offerings_cache"

    // MARK: - Auto Events Keys
    public static let firstSeenKey = "@paywallo:firstSeen"

    // MARK: - Session
    public static let sessionTimeoutMs: Int = 30 * 60 * 1000  // 30 minutes

    // MARK: - Event Batching
    public static let batchMaxSize = 25
    public static let batchFlushMs = 10_000  // 10 seconds

    // MARK: - Paywall
    public static let paywallTimeoutMs: Int = 30 * 60 * 1000  // 30 minutes
    public static let heartbeatIntervalMs = 5000  // 5 seconds
}
