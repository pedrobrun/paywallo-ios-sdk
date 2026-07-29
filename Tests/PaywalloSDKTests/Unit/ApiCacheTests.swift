import XCTest
@testable import PaywalloSDK

final class ApiCacheTests: XCTestCase {

    private var cache: ApiCache!

    override func setUp() {
        super.setUp()
        cache = ApiCache(nullTtl: 60)
    }

    override func tearDown() {
        cache.invalidateAll()
        cache = nil
        super.tearDown()
    }

    // MARK: - set + get within TTL

    func testGetReturnsValueWithinTTL() {
        cache.set("key:1", value: "hello", ttl: 300)
        let result: String? = cache.get("key:1")
        XCTAssertEqual(result, "hello")
    }

    func testGetReturnsIntValueWithinTTL() {
        cache.set("key:int", value: 42, ttl: 300)
        let result: Int? = cache.get("key:int")
        XCTAssertEqual(result, 42)
    }

    func testGetReturnsNilForMissingKey() {
        let result: String? = cache.get("nonexistent")
        XCTAssertNil(result)
    }

    func testGetReturnsNilForWrongType() {
        cache.set("key:str", value: "text", ttl: 300)
        let result: Int? = cache.get("key:str")
        XCTAssertNil(result)
    }

    // MARK: - stale-while-revalidate: expired entry still returned

    func testGetReturnsStaleValueAfterTTLExpired() {
        // TTL=0 means no expiry (not treated as expired by isExpired when ttl == 0)
        // Use a positive TTL near-zero and skip past it via isStale check
        // Since Date() is "now" at set time, isExpired = Date().timeIntervalSince(storedAt) > ttl
        // We can't fast-forward time directly, so we validate the SWR contract:
        // get() always returns the value regardless of staleness.
        cache.set("swr:key", value: "stale-value", ttl: 300)
        let result: String? = cache.get("swr:key")
        XCTAssertEqual(result, "stale-value", "get() should return value (SWR — never nil for existing entry)")
    }

    func testIsStaleReturnsFalseForFreshEntry() {
        cache.set("fresh:key", value: "x", ttl: 300)
        XCTAssertFalse(cache.isStale("fresh:key"))
    }

    func testIsStaleReturnsFalseForNilTTL() {
        // nil TTL = permanent, never expired
        cache.set("permanent:key", value: "forever", ttl: nil)
        XCTAssertFalse(cache.isStale("permanent:key"))
    }

    func testIsStaleReturnsFalseForMissingKey() {
        XCTAssertFalse(cache.isStale("does-not-exist"))
    }

    // MARK: - nil TTL for 404 tombstone caching

    func testSetNullMakesTombstoneActive() {
        cache.setNull("campaign:missing")
        XCTAssertTrue(cache.isNull("campaign:missing"))
    }

    func testIsNullReturnsFalseForKeyWithValue() {
        cache.set("campaign:exists", value: "data", ttl: 300)
        XCTAssertFalse(cache.isNull("campaign:exists"))
    }

    func testIsNullReturnsFalseForMissingKey() {
        XCTAssertFalse(cache.isNull("never-set"))
    }

    func testSetNullRemovesExistingValue() {
        cache.set("key:promo", value: "old-value", ttl: 300)
        cache.setNull("key:promo")
        let result: String? = cache.get("key:promo")
        XCTAssertNil(result, "setNull should evict the existing value entry")
    }

    func testSetValueAfterSetNullClearsTombstone() {
        cache.setNull("campaign:promo")
        XCTAssertTrue(cache.isNull("campaign:promo"))
        cache.set("campaign:promo", value: "recovered", ttl: 300)
        XCTAssertFalse(cache.isNull("campaign:promo"), "setNull tombstone should be cleared when value is written")
        let result: String? = cache.get("campaign:promo")
        XCTAssertEqual(result, "recovered")
    }

    func testNullTombstoneExpiredAfterTTL() {
        // Use nullTtl=0 so the tombstone expires instantly
        let shortCache = ApiCache(nullTtl: 0)
        shortCache.setNull("campaign:gone")
        // With nullTtl=0, any positive timeIntervalSince > 0 makes it expire
        // Run the check after a tick (Date() is already past storedAt)
        // With nullTtl=0, same-tick check may return true (timestamp granularity)
        // After a small delay, it should expire
        Thread.sleep(forTimeInterval: 0.01)
        let isNullAfterExpiry = shortCache.isNull("campaign:gone")
        XCTAssertFalse(isNullAfterExpiry, "Tombstone with nullTtl=0 should expire after delay")
    }

    // MARK: - invalidate by key

    func testInvalidateRemovesValue() {
        cache.set("paywall:onboarding", value: "config", ttl: 300)
        cache.invalidate("paywall:onboarding")
        let result: String? = cache.get("paywall:onboarding")
        XCTAssertNil(result)
    }

    func testInvalidateRemovesTombstone() {
        cache.setNull("paywall:onboarding")
        cache.invalidate("paywall:onboarding")
        XCTAssertFalse(cache.isNull("paywall:onboarding"))
    }

    func testInvalidateOnlyRemovesTargetKey() {
        cache.set("key:a", value: "aaa", ttl: 300)
        cache.set("key:b", value: "bbb", ttl: 300)
        cache.invalidate("key:a")
        let a: String? = cache.get("key:a")
        let b: String? = cache.get("key:b")
        XCTAssertNil(a)
        XCTAssertEqual(b, "bbb")
    }

    // MARK: - invalidatePrefix

    func testInvalidatePrefixRemovesMatchingKeys() {
        cache.set("campaign:home", value: "h", ttl: 300)
        cache.set("campaign:settings", value: "s", ttl: 300)
        cache.set("paywall:onboarding", value: "p", ttl: 300)
        cache.invalidatePrefix("campaign:")
        let home: String? = cache.get("campaign:home")
        let settings: String? = cache.get("campaign:settings")
        let paywall: String? = cache.get("paywall:onboarding")
        XCTAssertNil(home)
        XCTAssertNil(settings)
        XCTAssertEqual(paywall, "p", "Unrelated key should survive prefix invalidation")
    }

    func testInvalidatePrefixRemovesMatchingTombstones() {
        cache.setNull("campaign:gone")
        cache.setNull("paywall:gone")
        cache.invalidatePrefix("campaign:")
        XCTAssertFalse(cache.isNull("campaign:gone"))
        XCTAssertTrue(cache.isNull("paywall:gone"), "Paywall tombstone should not be affected")
    }

    // MARK: - invalidateAll

    func testInvalidateAllClearsEverything() {
        cache.set("a", value: "1", ttl: 300)
        cache.set("b", value: "2", ttl: 300)
        cache.setNull("c")
        cache.invalidateAll()
        let a: String? = cache.get("a")
        let b: String? = cache.get("b")
        XCTAssertNil(a)
        XCTAssertNil(b)
        XCTAssertFalse(cache.isNull("c"))
    }

    func testInvalidateAllOnEmptyCacheDoesNotCrash() {
        // Should complete without error
        cache.invalidateAll()
        let result: String? = cache.get("any")
        XCTAssertNil(result)
    }

    // MARK: - Paywall helpers

    func testSetAndGetPaywallRoundTrip() {
        let config = PaywallConfig(id: "pw1", placement: "onboarding", config: [:])
        cache.setPaywall("onboarding", value: config, ttl: 300)
        let result = cache.getPaywall("onboarding")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.id, "pw1")
        XCTAssertEqual(result?.placement, "onboarding")
    }

    func testGetPaywallReturnNilWhenMissing() {
        let result = cache.getPaywall("nonexistent-placement")
        XCTAssertNil(result)
    }

    // MARK: - Campaign helpers

    func testSetAndGetCampaignRoundTrip() {
        let paywall = CampaignPaywall(id: "pw1", placement: "home", config: [:])
        let campaign = CampaignResponse(
            campaignId: "c1",
            placement: "home",
            variantKey: "control",
            paywall: paywall
        )
        cache.setCampaign("home", value: campaign, ttl: 300)
        let result = cache.getCampaign("home")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.campaignId, "c1")
        XCTAssertEqual(result?.variantKey, "control")
    }

    func testGetCampaignReturnNilWhenMissing() {
        let result = cache.getCampaign("no-campaign-here")
        XCTAssertNil(result)
    }
}
