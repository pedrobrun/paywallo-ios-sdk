import Foundation
import Security

public enum PaywalloConstants {
    public static let sdkVersion = "2.9.0"
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
    /// Durability fallback when the Keychain write fails — not PII, durability > secrecy.
    public static let anonIdFallbackKey = "@paywallo:anon_id_fallback"
    public static let distinctIdKey = "@paywallo:user_distinct_id"
    public static let userEmailKey = "@paywallo:user_email"
    public static let userFirstNameKey = "@paywallo:user_first_name"
    public static let userLastNameKey = "@paywallo:user_last_name"
    public static let userPhoneKey = "@paywallo:user_phone"
    public static let userDobKey = "@paywallo:user_dob"
    public static let userGenderKey = "@paywallo:user_gender"
    public static let userZipKey = "@paywallo:user_zip"
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
    /// Persisted app version — distinguishes `app_update` from `relaunch` on residue.
    public static let installAppVersionKey = "@paywallo:app_version"
    /// Write-ahead payload + backoff bookkeeping for the deferred-match retry (24h ceiling).
    public static let deferredMatchStateKey = "@paywallo:deferred_match_state"
    /// Stamped by devResetInstallState so the deterministic installEventId changes on reset.
    public static let devResetEpochKey = "@paywallo:dev_reset_epoch"
    /// SDK first-run marker, ms since epoch — feeds the install clock-freshness gate.
    public static let sdkFirstRunAtKey = "@paywallo:sdk_first_run_at"
    /// Last seen IDFV — `idfvChanged` signal.
    public static let previousIdfvKey = "@paywallo:previous_idfv"
    /// Deferred deep link from the match response (screen personalisation only, never an event).
    public static let deferredDeepLinkKey = "@paywallo:deferred_deep_link"

    // MARK: - Legacy Install Keys (read + cleared on dev reset)
    public static let legacyInstallTrackedKey = "@panel:install_tracked"
    public static let legacyInstallEventIdKey = "@panel:install_event_id"
    public static let legacyDeferredMatchDoneKey = "@panel:deferred_match_done"
    public static let legacyAnonIdCurrentKey = "@panel:anon_id"

    // MARK: - Synced Identity (iCloud Keychain)
    public static let syncedIdentityKey = "identity_sync_id"
    public static let syncedIdentityLocalKey = "identity_sync_id:local"

    // MARK: - SKAdNetwork Keys
    public static let skanHighestFineKey = "@paywallo:skan_highest_fine"
    public static let skanLockedKey = "@paywallo:skan_locked"

    // MARK: - Durable Retry
    /// PendingRetry queue — regular storage (UserDefaults), never Keychain.
    public static let pendingRetryKey = "@paywallo:pending_retry"

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

    // MARK: - PendingRetry (durable retry for critical events)
    public static let pendingRetryMaxItems = 50
    /// Exactly two re-attempts: 1min, then 5min. Exhausted → dropped from disk.
    public static let pendingRetryDelaysMs: [Int] = [60_000, 300_000]
    public static let pendingRetryProcessIntervalMs = 30_000

    // MARK: - Request Retry Policy (postWithQueue layer)
    public static let retryMaxAttempts = 2
    public static let retryBaseDelayMs = 1_000
    public static let retryMaxDelayMs = 30_000
    /// Symmetric jitter: ±25%, clamped to [0, retryMaxDelayMs].
    public static let retryJitterRatio = 0.25
    public static let circuitBreakerThreshold = 5
    public static let circuitBreakerOpenMs = 5 * 60 * 1000  // 5 minutes, then half-open

    // MARK: - Deferred Match Retry
    /// Last step repeats until the 24h ceiling.
    public static let deferredMatchBackoffMs: [Int] = [30_000, 120_000, 600_000]
    public static let deferredMatchMaxAgeMs = 86_400_000  // 24h from firstAttemptAt
    public static let forcedMatchMinIntervalMs = 30_000
    public static let deferredMatchTimeout: TimeInterval = 5

    // MARK: - Attribution
    /// Server ceiling for `install_referrer_raw`. Meta's encrypted blob exceeds 2048.
    public static let installReferrerMaxLength = 4096
    /// Meta deferred app link raw cap — distinct from the install referrer cap above.
    public static let deferredAppLinkMaxLength = 2048
    public static let clickSignalWindowMs = 86_400_000  // 24h

    // MARK: - Identity Durability
    public static let anonIdSetRetries = 2
    public static let anonIdRetryDelayMs = 50
    public static let idfvCollectMaxAttempts = 3
    public static let idfvCollectRetryDelayMs = 80

    // MARK: - Superwall Attribute Sync
    public static let defaultSyncTimeoutMs = 1_500
    public static let minPushBudgetMs = 300
    public static let configPollIntervalMs = 250
    public static let configPollMaxAttempts = 40  // ~10s
    public static let configRetryDelaysMs: [Int] = [30_000, 60_000, 120_000]
}
