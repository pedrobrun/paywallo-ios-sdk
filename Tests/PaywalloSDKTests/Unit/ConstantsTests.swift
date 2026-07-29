import XCTest
@testable import PaywalloSDK

final class ConstantsTests: XCTestCase {

    func testSdkVersionNotEmpty() {
        XCTAssertFalse(PaywalloConstants.sdkVersion.isEmpty)
    }

    func testSdkPlatform() {
        XCTAssertEqual(PaywalloConstants.sdkPlatform, "ios")
    }

    func testDefaultApiUrl() {
        XCTAssertEqual(PaywalloConstants.defaultApiUrl, "https://panel.lucasqueiroga.shop")
        XCTAssertTrue(PaywalloConstants.defaultApiUrl.hasPrefix("https://"))
    }

    func testTimeouts() {
        XCTAssertEqual(PaywalloConstants.defaultTimeout, 30)
        XCTAssertEqual(PaywalloConstants.httpClientTimeout, 10)
        XCTAssertTrue(PaywalloConstants.defaultTimeout > 0)
        XCTAssertTrue(PaywalloConstants.httpClientTimeout > 0)
    }

    func testKeychainServiceName() {
        XCTAssertEqual(PaywalloConstants.keychainServiceName, "com.paywallo.sdk")
    }

    func testStoragePrefixes() {
        XCTAssertEqual(PaywalloConstants.storagePrefix, "@paywallo:")
        XCTAssertEqual(PaywalloConstants.legacyStoragePrefix, "@panel:")
    }

    func testAllPaywalloKeysHavePrefix() {
        // All @paywallo: keys should start with the prefix
        let paywalloKeys = [
            PaywalloConstants.deviceIdKey,
            PaywalloConstants.anonIdKey,
            PaywalloConstants.distinctIdKey,
            PaywalloConstants.userEmailKey,
            PaywalloConstants.userFirstNameKey,
            PaywalloConstants.userLastNameKey,
            PaywalloConstants.userPhoneKey,
            PaywalloConstants.userDobKey,
            PaywalloConstants.userGenderKey,
            PaywalloConstants.userPropertiesKey,
            PaywalloConstants.userNameKey,
            PaywalloConstants.userCountryKey,
            PaywalloConstants.userLocaleKey,
            PaywalloConstants.installTrackedKey,
            PaywalloConstants.appInstalledSentKey,
            PaywalloConstants.installEventIdKey,
            PaywalloConstants.deferredMatchDoneKey,
            PaywalloConstants.currentSessionIdKey,
            PaywalloConstants.sessionStartKey,
            PaywalloConstants.emergencyPaywallShownKey,
            PaywalloConstants.attributionV2Key,
            PaywalloConstants.paywallHeartbeatKey,
            PaywalloConstants.offlineQueueKey,
            PaywalloConstants.offlineQueueJournalKey,
            PaywalloConstants.queueDlqKey,
            PaywalloConstants.migrationV152DoneKey,
            PaywalloConstants.firstSeenKey,
        ]

        for key in paywalloKeys {
            XCTAssertTrue(key.hasPrefix("@paywallo:"), "Key '\(key)' should start with @paywallo:")
        }
    }

    func testAllLegacyKeysHavePrefix() {
        let legacyKeys = [
            PaywalloConstants.legacyUserPhoneKey,
            PaywalloConstants.legacyUserFirstNameKey,
            PaywalloConstants.legacyUserLastNameKey,
            PaywalloConstants.legacyUserDobKey,
            PaywalloConstants.legacyUserGenderKey,
            PaywalloConstants.legacyAttributionV2Key,
            PaywalloConstants.legacyPaywallHeartbeatKey,
            PaywalloConstants.legacySubscriptionCacheKey,
        ]

        for key in legacyKeys {
            XCTAssertTrue(key.hasPrefix("@panel:"), "Legacy key '\(key)' should start with @panel:")
        }
    }

    func testNoStorageKeyDuplicates() {
        let allKeys = [
            PaywalloConstants.deviceIdKey,
            PaywalloConstants.anonIdKey,
            PaywalloConstants.distinctIdKey,
            PaywalloConstants.userEmailKey,
            PaywalloConstants.userFirstNameKey,
            PaywalloConstants.userLastNameKey,
            PaywalloConstants.userPhoneKey,
            PaywalloConstants.userDobKey,
            PaywalloConstants.userGenderKey,
            PaywalloConstants.userPropertiesKey,
            PaywalloConstants.userNameKey,
            PaywalloConstants.userCountryKey,
            PaywalloConstants.userLocaleKey,
            PaywalloConstants.installTrackedKey,
            PaywalloConstants.appInstalledSentKey,
            PaywalloConstants.installEventIdKey,
            PaywalloConstants.deferredMatchDoneKey,
            PaywalloConstants.currentSessionIdKey,
            PaywalloConstants.sessionStartKey,
            PaywalloConstants.emergencyPaywallShownKey,
            PaywalloConstants.attributionV2Key,
            PaywalloConstants.paywallHeartbeatKey,
            PaywalloConstants.offlineQueueKey,
            PaywalloConstants.offlineQueueJournalKey,
            PaywalloConstants.queueDlqKey,
            PaywalloConstants.migrationV152DoneKey,
            PaywalloConstants.seenMessagesKey,
            PaywalloConstants.firstSeenKey,
        ]

        let uniqueKeys = Set(allKeys)
        XCTAssertEqual(allKeys.count, uniqueKeys.count, "Found duplicate storage keys")
    }

    func testSessionTimeout() {
        XCTAssertEqual(PaywalloConstants.sessionTimeoutMs, 30 * 60 * 1000)
    }

    func testBatchConstants() {
        XCTAssertEqual(PaywalloConstants.batchMaxSize, 25)
        XCTAssertEqual(PaywalloConstants.batchFlushMs, 10_000)
    }

    func testPaywallTimeout() {
        XCTAssertEqual(PaywalloConstants.paywallTimeoutMs, 30 * 60 * 1000)
    }

    func testHeartbeatInterval() {
        XCTAssertEqual(PaywalloConstants.heartbeatIntervalMs, 5000)
    }
}
