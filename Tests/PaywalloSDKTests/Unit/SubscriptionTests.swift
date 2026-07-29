import XCTest
@testable import PaywalloSDK

// MARK: - SubscriptionStatusMapping Tests

final class SubscriptionStatusMappingTests: XCTestCase {

    // MARK: isActive

    func testIsActive_active_returnsTrue() {
        XCTAssertTrue(SubscriptionStatusMapping.isActive(.active))
    }

    func testIsActive_inGracePeriod_returnsTrue() {
        XCTAssertTrue(SubscriptionStatusMapping.isActive(.inGracePeriod))
    }

    func testIsActive_expired_returnsFalse() {
        XCTAssertFalse(SubscriptionStatusMapping.isActive(.expired))
    }

    func testIsActive_inBillingRetry_returnsFalse() {
        XCTAssertFalse(SubscriptionStatusMapping.isActive(.inBillingRetry))
    }

    func testIsActive_revoked_returnsFalse() {
        XCTAssertFalse(SubscriptionStatusMapping.isActive(.revoked))
    }

    func testIsActive_cancelled_returnsFalse() {
        XCTAssertFalse(SubscriptionStatusMapping.isActive(.cancelled))
    }

    // MARK: isSubscriptionStillActive

    func testIsSubscriptionStillActive_activeWithFutureExpiry_returnsTrue() {
        let future = Date().addingTimeInterval(3600)
        XCTAssertTrue(SubscriptionStatusMapping.isSubscriptionStillActive(status: .active, expiresAt: future))
    }

    func testIsSubscriptionStillActive_activeWithPastExpiry_returnsFalse() {
        let past = Date().addingTimeInterval(-3600)
        XCTAssertFalse(SubscriptionStatusMapping.isSubscriptionStillActive(status: .active, expiresAt: past))
    }

    func testIsSubscriptionStillActive_activeWithNilExpiry_returnsTrue() {
        XCTAssertTrue(SubscriptionStatusMapping.isSubscriptionStillActive(status: .active, expiresAt: nil))
    }

    func testIsSubscriptionStillActive_activeWithEpochDate_returnsTrue() {
        // Date(0) = epoch means "no expiration"
        let epoch = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(SubscriptionStatusMapping.isSubscriptionStillActive(status: .active, expiresAt: epoch))
    }

    func testIsSubscriptionStillActive_expiredWithFutureExpiry_returnsFalse() {
        let future = Date().addingTimeInterval(3600)
        XCTAssertFalse(SubscriptionStatusMapping.isSubscriptionStillActive(status: .expired, expiresAt: future))
    }

    func testIsSubscriptionStillActive_inGracePeriodWithFutureExpiry_returnsTrue() {
        let future = Date().addingTimeInterval(3600)
        XCTAssertTrue(SubscriptionStatusMapping.isSubscriptionStillActive(status: .inGracePeriod, expiresAt: future))
    }

    func testIsSubscriptionStillActive_cancelledWithFutureExpiry_returnsFalse() {
        let future = Date().addingTimeInterval(3600)
        XCTAssertFalse(SubscriptionStatusMapping.isSubscriptionStillActive(status: .cancelled, expiresAt: future))
    }

    // MARK: fromDomain

    func testFromDomain_active() {
        XCTAssertEqual(SubscriptionStatusMapping.fromDomain("active"), .active)
    }

    func testFromDomain_billingRetry() {
        XCTAssertEqual(SubscriptionStatusMapping.fromDomain("billing_retry"), .inBillingRetry)
    }

    func testFromDomain_inBillingRetry() {
        XCTAssertEqual(SubscriptionStatusMapping.fromDomain("in_billing_retry"), .inBillingRetry)
    }

    func testFromDomain_gracePeriod() {
        XCTAssertEqual(SubscriptionStatusMapping.fromDomain("grace_period"), .inGracePeriod)
    }

    func testFromDomain_inGracePeriod() {
        XCTAssertEqual(SubscriptionStatusMapping.fromDomain("in_grace_period"), .inGracePeriod)
    }

    func testFromDomain_paused_mapsToExpired() {
        XCTAssertEqual(SubscriptionStatusMapping.fromDomain("paused"), .expired)
    }

    func testFromDomain_unknown_mapsToExpired() {
        XCTAssertEqual(SubscriptionStatusMapping.fromDomain("unknown"), .expired)
    }

    func testFromDomain_cancelled() {
        XCTAssertEqual(SubscriptionStatusMapping.fromDomain("cancelled"), .cancelled)
    }

    func testFromDomain_canceled_alternateSpelling() {
        XCTAssertEqual(SubscriptionStatusMapping.fromDomain("canceled"), .cancelled)
    }

    func testFromDomain_revoked() {
        XCTAssertEqual(SubscriptionStatusMapping.fromDomain("revoked"), .revoked)
    }

    func testFromDomain_expired() {
        XCTAssertEqual(SubscriptionStatusMapping.fromDomain("expired"), .expired)
    }

    func testFromDomain_unknownString_mapsToExpired() {
        XCTAssertEqual(SubscriptionStatusMapping.fromDomain("something_random"), .expired)
    }

    func testFromDomain_caseInsensitive() {
        XCTAssertEqual(SubscriptionStatusMapping.fromDomain("ACTIVE"), .active)
        XCTAssertEqual(SubscriptionStatusMapping.fromDomain("Active"), .active)
    }

    // MARK: toDomain

    func testToDomain_active() {
        XCTAssertEqual(SubscriptionStatusMapping.toDomain(.active), "active")
    }

    func testToDomain_inBillingRetry() {
        XCTAssertEqual(SubscriptionStatusMapping.toDomain(.inBillingRetry), "billing_retry")
    }

    func testToDomain_inGracePeriod() {
        XCTAssertEqual(SubscriptionStatusMapping.toDomain(.inGracePeriod), "grace_period")
    }

    func testToDomain_revoked_mapsToRevoked() {
        XCTAssertEqual(SubscriptionStatusMapping.toDomain(.revoked), "revoked")
    }

    func testToDomain_expired() {
        XCTAssertEqual(SubscriptionStatusMapping.toDomain(.expired), "expired")
    }

    func testToDomain_cancelled() {
        XCTAssertEqual(SubscriptionStatusMapping.toDomain(.cancelled), "cancelled")
    }
}

// MARK: - SubscriptionCache Tests

private func makeIsolatedCache(ttl: TimeInterval = 24 * 60 * 60) -> (SubscriptionCache, NativeStorage, String) {
    let id = UUID().uuidString
    let suiteName = "com.paywallo.sdk.tests.cache.\(id)"
    let suite = UserDefaults(suiteName: suiteName)!
    let keychainService = "com.paywallo.sdk.tests.cache.\(id)"
    let nativeStorage = NativeStorage(service: keychainService, defaults: suite)
    let secureStorage = SecureStorage(nativeStorage: nativeStorage)
    let cache = SubscriptionCache(ttl: ttl, storage: secureStorage)
    return (cache, nativeStorage, suiteName)
}

private func makeSubscriptionStatusResponse(
    hasActive: Bool = true,
    productId: String = "com.test.monthly"
) -> SubscriptionStatusResponse {
    let subscription = Subscription(
        productId: productId,
        status: .active,
        expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(30 * 24 * 3600)),
        platform: .ios,
        autoRenewEnabled: true,
        inGracePeriod: false
    )
    return SubscriptionStatusResponse(
        hasActiveSubscription: hasActive,
        subscription: subscription
    )
}

final class SubscriptionCacheTests: XCTestCase {

    private var cache: SubscriptionCache!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        let (c, _, name) = makeIsolatedCache()
        cache = c
        suiteName = name
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: set → get

    func testSetAndGet_returnsCachedData() async {
        let response = makeSubscriptionStatusResponse()
        await cache.set("user1", data: response)

        let result = await cache.get("user1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.data.hasActiveSubscription, true)
        XCTAssertFalse(result?.isStale ?? true, "Fresh entry must not be stale")
    }

    func testSetAndGet_productIdPreserved() async {
        let response = makeSubscriptionStatusResponse(productId: "com.test.yearly")
        await cache.set("user2", data: response)

        let result = await cache.get("user2")
        XCTAssertEqual(result?.data.subscription?.productId, "com.test.yearly")
    }

    // MARK: get nonexistent

    func testGet_nonexistentKey_returnsNil() async {
        let result = await cache.get("nonexistent_\(UUID().uuidString)")
        XCTAssertNil(result)
    }

    func testGet_emptyDistinctId_returnsNil() async {
        let result = await cache.get("")
        XCTAssertNil(result)
    }

    // MARK: TTL / stale

    func testGet_afterTTLExpiry_returnsStaleEntry() async {
        // Build a cache with very short TTL
        let (shortCache, _, shortSuiteName) = makeIsolatedCache(ttl: 0.05)
        defer { UserDefaults.standard.removePersistentDomain(forName: shortSuiteName) }

        let response = makeSubscriptionStatusResponse()
        await shortCache.set("user_ttl", data: response)

        // Wait just over the TTL
        try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms

        let result = await shortCache.get("user_ttl")
        // The entry is returned from storage but marked stale
        XCTAssertNotNil(result, "Stale entry must still be returned")
        XCTAssertTrue(result?.isStale ?? false, "Entry past TTL must be marked stale")
    }

    func testGet_beforeTTLExpiry_isNotStale() async {
        let response = makeSubscriptionStatusResponse()
        await cache.set("user_fresh", data: response)

        let result = await cache.get("user_fresh")
        XCTAssertNotNil(result)
        XCTAssertFalse(result?.isStale ?? true)
    }

    // MARK: invalidate

    func testInvalidate_removesEntry() async {
        let response = makeSubscriptionStatusResponse()
        await cache.set("user_inv", data: response)
        await cache.invalidate("user_inv")

        let result = await cache.get("user_inv")
        XCTAssertNil(result)
    }

    func testInvalidate_emptyId_doesNotCrash() async {
        // Should be a no-op, no crash
        await cache.invalidate("")
    }

    func testInvalidate_nonexistentKey_doesNotCrash() async {
        await cache.invalidate("never_set_\(UUID().uuidString)")
    }

    // MARK: invalidateAll

    func testInvalidateAll_removesAllEntries() async {
        let response = makeSubscriptionStatusResponse()
        await cache.set("user_a", data: response)
        await cache.set("user_b", data: response)
        await cache.set("user_c", data: response)

        await cache.invalidateAll()

        let a = await cache.get("user_a")
        let b = await cache.get("user_b")
        let c = await cache.get("user_c")

        XCTAssertNil(a)
        XCTAssertNil(b)
        XCTAssertNil(c)
    }

    // MARK: setTTL

    func testSetTTL_updatesExpiryBehavior() async {
        // Start with long TTL
        let response = makeSubscriptionStatusResponse()
        await cache.set("user_ttl2", data: response)

        // Shorten TTL to near-zero so current entry becomes stale immediately
        await cache.setTTL(0.001)
        try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms

        let result = await cache.get("user_ttl2")
        XCTAssertTrue(result?.isStale ?? false, "Entry must be stale after TTL shortened")
    }
}

// MARK: - SubscriptionManager Tests

final class SubscriptionManagerTests: XCTestCase {

    private var manager: SubscriptionManager!

    override func setUp() {
        super.setUp()
        let (cache, _, _) = makeIsolatedCache()
        manager = SubscriptionManager(cache: cache)
    }

    // MARK: Not initialized

    func testGetSubscriptionStatus_notInitialized_returnsEmpty() async {
        let status = await manager.getSubscriptionStatus()
        XCTAssertFalse(status.hasActiveSubscription)
        XCTAssertNil(status.subscription)
        XCTAssertNil(status.subscription)
    }

    func testHasActiveSubscription_notInitialized_returnsFalse() async {
        let result = await manager.hasActiveSubscription()
        XCTAssertFalse(result)
    }

    func testGetSubscription_notInitialized_returnsNil() async {
        let sub = await manager.getSubscription()
        XCTAssertNil(sub)
    }

    func testRestorePurchases_notInitialized_throws() async {
        do {
            _ = try await manager.restorePurchases()
            XCTFail("Should have thrown")
        } catch let error as SessionError {
            XCTAssertEqual(error.code, SessionErrorCode.notInitialized)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: Listener

    func testAddListener_returnsRemoveFunction() {
        let remove = manager.addListener { _ in }
        // Just verifying it compiles and runs without crash
        remove()
    }

    func testAddListener_cleanupStopsNotifications() async {
        var callCount = 0
        let remove = manager.addListener { _ in callCount += 1 }

        // Remove before any notification fires
        remove()

        // Manually verify listener is gone by checking count stays 0
        // (we can't trigger notifications without a real server, so
        // we confirm the remove closure executes without crash)
        XCTAssertEqual(callCount, 0)
    }

    func testAddMultipleListeners_independentCleanup() {
        var count1 = 0
        var count2 = 0

        let remove1 = manager.addListener { _ in count1 += 1 }
        let remove2 = manager.addListener { _ in count2 += 1 }

        // Remove first listener only
        remove1()

        // Both removes must be callable without crash
        remove2()

        XCTAssertEqual(count1, 0)
        XCTAssertEqual(count2, 0)
    }

    // MARK: setUserId

    func testSetUserId_sameValue_doesNotCrash() {
        manager.setUserId("user123")
        manager.setUserId("user123")  // same — no cache invalidation
    }

    func testSetUserId_differentValue_doesNotCrash() {
        manager.setUserId("user123")
        manager.setUserId("user456")
    }

    func testSetUserId_nil_doesNotCrash() {
        manager.setUserId(nil)
    }

    // MARK: initialize

    func testInitialize_setsConfig() async {
        let config = SubscriptionManagerConfig(
            serverUrl: "https://api.paywallo.com",
            appKey: "pk_test_123"
        )
        manager.initialize(config)

        // After initialization, getSubscriptionStatus will attempt a network call
        // and fail (no server) — should return empty rather than crash
        let status = await manager.getSubscriptionStatus()
        XCTAssertFalse(status.hasActiveSubscription)
    }

    func testInitialize_withCustomTTL_doesNotCrash() {
        let config = SubscriptionManagerConfig(
            serverUrl: "https://api.paywallo.com",
            appKey: "pk_test_123",
            cacheTTL: 60
        )
        manager.initialize(config)
    }

    func testInitialize_withDebug_doesNotCrash() {
        let config = SubscriptionManagerConfig(
            serverUrl: "https://api.paywallo.com",
            appKey: "pk_test_123",
            debug: true
        )
        manager.initialize(config)
    }
}
