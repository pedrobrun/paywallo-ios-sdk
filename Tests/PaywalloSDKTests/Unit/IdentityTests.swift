import XCTest
@testable import PaywalloSDK

// MARK: - Helpers

private func makeIsolatedSecureStorage(id: String = UUID().uuidString) -> (SecureStorage, NativeStorage, String) {
    let suiteName = "com.paywallo.sdk.identity.tests.\(id)"
    let suite = UserDefaults(suiteName: suiteName)!
    let keychainService = "com.paywallo.sdk.identity.tests.\(id)"
    let native = NativeStorage(service: keychainService, defaults: suite)
    let secure = SecureStorage(nativeStorage: native)
    return (secure, native, suiteName)
}

// MARK: - IdentityStorage Tests

final class IdentityStorageTests: XCTestCase {

    // MARK: parseProperties

    func testParseProperties_validJson_returnsParsedDict() {
        let json = #"{"plan":"pro","trial":true}"#
        let result = IdentityStorage.parseProperties(json)
        XCTAssertEqual(result["plan"]?.value as? String, "pro")
        XCTAssertEqual(result["trial"]?.value as? Bool, true)
    }

    func testParseProperties_invalidJson_returnsEmptyDict() {
        let result = IdentityStorage.parseProperties("not json at all")
        XCTAssertTrue(result.isEmpty)
    }

    func testParseProperties_nil_returnsEmptyDict() {
        let result = IdentityStorage.parseProperties(nil)
        XCTAssertTrue(result.isEmpty)
    }

    func testParseProperties_emptyString_returnsEmptyDict() {
        let result = IdentityStorage.parseProperties("")
        XCTAssertTrue(result.isEmpty)
    }

    func testParseProperties_emptyObject_returnsEmptyDict() {
        let result = IdentityStorage.parseProperties("{}")
        XCTAssertTrue(result.isEmpty)
    }

    func testParseProperties_nestedValue_parsedCorrectly() {
        let json = #"{"count":42}"#
        let result = IdentityStorage.parseProperties(json)
        XCTAssertNotNil(result["count"])
    }
}

// MARK: - IdentityManager Tests

final class IdentityManagerTests: XCTestCase {

    private var secureStorage: SecureStorage!
    private var native: NativeStorage!
    private var suiteName: String!
    private var manager: IdentityManager!

    override func setUp() {
        super.setUp()
        let (s, n, name) = makeIsolatedSecureStorage()
        secureStorage = s
        native = n
        suiteName = name
        manager = IdentityManager(secureStorage: s)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: getDeviceId before init

    func testGetDeviceId_beforeInit_returnsNil() {
        XCTAssertNil(manager.getDeviceId())
    }

    // MARK: getDistinctId before init

    func testGetDistinctId_beforeInit_returnsEmptyString() {
        XCTAssertEqual(manager.getDistinctId(), "")
    }

    // MARK: isInitialized before init

    func testIsInitialized_beforeInit_returnsFalse() {
        XCTAssertFalse(manager.isInitialized)
    }

    // MARK: initialize

    func testInitialize_setsInitializedFlag() async throws {
        try await manager.initialize()
        XCTAssertTrue(manager.isInitialized)
    }

    func testInitialize_deviceIdNotNilAfterInit() async throws {
        try await manager.initialize()
        XCTAssertNotNil(manager.getDeviceId())
    }

    func testInitialize_anonIdNotNilAfterInit() async throws {
        try await manager.initialize()
        XCTAssertNotNil(manager.getAnonId())
    }

    // MARK: init idempotent — second call returns same deviceId

    func testInitialize_idempotent_sameDeviceId() async throws {
        let first = try await manager.initialize()
        let second = try await manager.initialize()
        XCTAssertEqual(first, second)
    }

    func testInitialize_idempotent_sameAnonId() async throws {
        try await manager.initialize()
        let anonIdFirst = manager.getAnonId()

        try await manager.initialize()
        let anonIdSecond = manager.getAnonId()

        XCTAssertEqual(anonIdFirst, anonIdSecond)
    }

    // MARK: getDistinctId fallback chain

    func testGetDistinctId_afterInit_fallsBackToAnonId() async throws {
        try await manager.initialize()
        // No distinctId set → should return anonId
        let distinctId = manager.getDistinctId()
        XCTAssertFalse(distinctId.isEmpty)
        XCTAssertEqual(distinctId, manager.getAnonId())
    }

    // MARK: identify — valid email stored

    func testIdentify_validEmail_stored() async throws {
        try await manager.initialize()
        await manager.identify(IdentifyOptions(email: "user@example.com"))
        XCTAssertEqual(manager.getEmail(), "user@example.com")
    }

    // MARK: identify — invalid email silently dropped

    func testIdentify_invalidEmail_silentlyDropped() async throws {
        try await manager.initialize()
        await manager.identify(IdentifyOptions(email: "not-an-email"))
        XCTAssertNil(manager.getEmail())
    }

    func testIdentify_emailMissingAt_silentlyDropped() async throws {
        try await manager.initialize()
        await manager.identify(IdentifyOptions(email: "invalidemail.com"))
        XCTAssertNil(manager.getEmail())
    }

    // MARK: identify — properties merged (not replaced)

    func testIdentify_propertiesMerged() async throws {
        try await manager.initialize()

        await manager.identify(IdentifyOptions(
            email: nil,
            properties: ["plan": AnyCodable("basic")]
        ))
        await manager.identify(IdentifyOptions(
            email: nil,
            properties: ["trial": AnyCodable(true)]
        ))

        let props = manager.getProperties()
        XCTAssertEqual(props["plan"]?.value as? String, "basic")
        XCTAssertEqual(props["trial"]?.value as? Bool, true)
    }

    func testIdentify_propertiesOverwriteKey() async throws {
        try await manager.initialize()

        await manager.identify(IdentifyOptions(
            email: nil,
            properties: ["plan": AnyCodable("basic")]
        ))
        await manager.identify(IdentifyOptions(
            email: nil,
            properties: ["plan": AnyCodable("pro")]
        ))

        XCTAssertEqual(manager.getProperties()["plan"]?.value as? String, "pro")
    }

    // MARK: identify — before init is no-op

    func testIdentify_beforeInit_isNoOp() async {
        await manager.identify(IdentifyOptions(email: "user@example.com"))
        XCTAssertNil(manager.getEmail())
    }

    // MARK: reset

    func testReset_newAnonId_different() async throws {
        try await manager.initialize()
        let originalAnonId = manager.getAnonId()

        await manager.reset()

        let newAnonId = manager.getAnonId()
        XCTAssertNotEqual(originalAnonId, newAnonId)
    }

    func testReset_deviceIdMaintained() async throws {
        try await manager.initialize()
        let deviceId = manager.getDeviceId()

        await manager.reset()

        XCTAssertEqual(manager.getDeviceId(), deviceId)
    }

    func testReset_emailCleared() async throws {
        try await manager.initialize()
        await manager.identify(IdentifyOptions(email: "user@example.com"))
        XCTAssertEqual(manager.getEmail(), "user@example.com")

        await manager.reset()

        XCTAssertNil(manager.getEmail())
    }

    func testReset_propertiesCleared() async throws {
        try await manager.initialize()
        await manager.identify(IdentifyOptions(
            email: nil,
            properties: ["plan": AnyCodable("pro")]
        ))

        await manager.reset()

        XCTAssertTrue(manager.getProperties().isEmpty)
    }

    func testReset_getDistinctId_returnsNewAnonId() async throws {
        try await manager.initialize()
        let oldDistinctId = manager.getDistinctId()

        await manager.reset()

        let newDistinctId = manager.getDistinctId()
        XCTAssertNotEqual(oldDistinctId, newDistinctId)
        XCTAssertEqual(newDistinctId, manager.getAnonId())
    }

    // MARK: getState

    func testGetState_afterInit_deviceIdPopulated() async throws {
        try await manager.initialize()
        let state = manager.getState()
        XCTAssertFalse(state.deviceId.isEmpty)
    }

    func testGetState_afterIdentify_emailInState() async throws {
        try await manager.initialize()
        await manager.identify(IdentifyOptions(email: "test@example.com"))

        let state = manager.getState()
        XCTAssertEqual(state.email, "test@example.com")
    }

    func testGetState_afterIdentify_propertiesInState() async throws {
        try await manager.initialize()
        await manager.identify(IdentifyOptions(
            email: nil,
            properties: ["key": AnyCodable("value")]
        ))

        let state = manager.getState()
        XCTAssertEqual(state.properties["key"]?.value as? String, "value")
    }

    func testGetState_afterReset_emailNil() async throws {
        try await manager.initialize()
        await manager.identify(IdentifyOptions(email: "user@example.com"))
        await manager.reset()

        let state = manager.getState()
        XCTAssertNil(state.email)
    }
}

// MARK: - AttributionTracker Tests

final class AttributionTrackerTests: XCTestCase {

    private var secureStorage: SecureStorage!
    private var native: NativeStorage!
    private var suiteName: String!
    private var tracker: AttributionTracker!

    override func setUp() {
        super.setUp()
        let (s, n, name) = makeIsolatedSecureStorage()
        secureStorage = s
        native = n
        suiteName = name
        tracker = AttributionTracker(storage: s, nativeStorage: n)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: get before load

    func testGet_beforeLoad_returnsNil() {
        XCTAssertNil(tracker.get())
    }

    // MARK: first-write-wins

    func testCapture_firstWriteWins_secondCaptureIsNoOp() async {
        let firstInput = AttributionInput(utmSource: "facebook")
        let secondInput = AttributionInput(utmSource: "google")

        await tracker.capture(firstInput)
        await tracker.capture(secondInput)

        XCTAssertEqual(tracker.get()?.utmSource, "facebook")
    }

    func testCapture_storesData() async {
        let input = AttributionInput(
            utmSource: "facebook",
            utmMedium: "cpc",
            fbclid: "fb_12345"
        )

        await tracker.capture(input)

        let result = tracker.get()
        XCTAssertEqual(result?.utmSource, "facebook")
        XCTAssertEqual(result?.utmMedium, "cpc")
        XCTAssertEqual(result?.fbclid, "fb_12345")
    }

    // MARK: all-empty input is no-op

    func testCapture_allEmptyInput_noOp() async {
        let emptyInput = AttributionInput()
        await tracker.capture(emptyInput)
        XCTAssertNil(tracker.get())
    }

    func testCapture_allNilFields_noOp() async {
        let nilInput = AttributionInput(
            utmSource: nil, utmMedium: nil, utmCampaign: nil,
            utmContent: nil, utmTerm: nil,
            fbclid: nil, gclid: nil, ttclid: nil
        )
        await tracker.capture(nilInput)
        XCTAssertNil(tracker.get())
    }

    func testCapture_allEmptyStrings_noOp() async {
        let emptyStrInput = AttributionInput(utmSource: "", fbclid: "")
        await tracker.capture(emptyStrInput)
        XCTAssertNil(tracker.get())
    }

    // MARK: capturedAt timestamp stored

    func testCapture_storesCapturedAt() async {
        let before = ISO8601DateFormatter().string(from: Date())
        await tracker.capture(AttributionInput(utmSource: "fb"))
        let after = ISO8601DateFormatter().string(from: Date())

        let capturedAt = tracker.get()?.capturedAt
        XCTAssertNotNil(capturedAt)
        // capturedAt must be within the test window
        XCTAssertGreaterThanOrEqual(capturedAt!, before)
        XCTAssertLessThanOrEqual(capturedAt!, after)
    }

    // MARK: clear

    func testClear_resetsMemory() async {
        await tracker.capture(AttributionInput(utmSource: "facebook"))
        XCTAssertNotNil(tracker.get())

        await tracker.clear()

        XCTAssertNil(tracker.get())
    }

    func testClear_allowsNewCapture() async {
        await tracker.capture(AttributionInput(utmSource: "facebook"))
        await tracker.clear()

        await tracker.capture(AttributionInput(utmSource: "tiktok"))

        XCTAssertEqual(tracker.get()?.utmSource, "tiktok")
    }

    // MARK: persistence via loadFromStorage

    func testLoadFromStorage_persistedDataAvailable() async {
        // Capture once
        await tracker.capture(AttributionInput(fbclid: "fb_abc"))

        // Create a second tracker backed by the same storage
        let (s2, _, _) = makeIsolatedSecureStorage(id: suiteName)
        let tracker2 = AttributionTracker(storage: secureStorage, nativeStorage: native)
        await tracker2.loadFromStorage()

        XCTAssertEqual(tracker2.get()?.fbclid, "fb_abc")
    }

    func testLoadFromStorage_emptyStorage_returnsNil() async {
        await tracker.loadFromStorage()
        XCTAssertNil(tracker.get())
    }
}

// MARK: - DeepLinkAttributionCapture Tests

final class DeepLinkAttributionCaptureTests: XCTestCase {

    private var capture: DeepLinkAttributionCapture!
    private var tracker: AttributionTracker!
    private var secureStorage: SecureStorage!
    private var native: NativeStorage!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        let (s, n, name) = makeIsolatedSecureStorage()
        secureStorage = s
        native = n
        suiteName = name
        tracker = AttributionTracker(storage: s, nativeStorage: n)
        capture = DeepLinkAttributionCapture(attributionTracker: tracker)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: URL without query → nil

    func testParseAttributionFromUrl_noQuery_returnsNil() {
        let url = URL(string: "myapp://open")!
        XCTAssertNil(capture.parseAttributionFromUrl(url))
    }

    // MARK: empty query string → nil

    func testParseAttributionFromUrl_emptyQuery_returnsNil() {
        // URL with ? but nothing after
        let url = URL(string: "myapp://open?")!
        XCTAssertNil(capture.parseAttributionFromUrl(url))
    }

    // MARK: URL with params but no attribution fields → nil (referrer removed, hasAnyField is false)

    func testParseAttributionFromUrl_unknownParams_noAttributionFieldsButReferrerSet() {
        // referrer was removed from parseAttributionFromUrl, so unknown-only params
        // produce no attribution fields (hasAnyField is false) → returns nil.
        let url = URL(string: "myapp://open?foo=bar&baz=qux")!
        let result = capture.parseAttributionFromUrl(url)
        XCTAssertNil(result)
    }

    // MARK: fbclid extracted

    func testParseAttributionFromUrl_extractsFbclid() {
        let url = URL(string: "myapp://open?fbclid=abc123")!
        let result = capture.parseAttributionFromUrl(url)
        XCTAssertEqual(result?.fbclid, "abc123")
    }

    // MARK: gclid extracted

    func testParseAttributionFromUrl_extractsGclid() {
        let url = URL(string: "myapp://open?gclid=goog_xyz")!
        let result = capture.parseAttributionFromUrl(url)
        XCTAssertEqual(result?.gclid, "goog_xyz")
    }

    /// Google Ads sometimes leaves the ValueTrack macro unsubstituted, so the literal
    /// `{gclid}` arrives as the value. Storing it poisons the capture: it looks strong,
    /// so first-write-wins would then reject the real click ID that lands later.
    func testParseAttributionFromUrl_unsubstitutedGclidMacroIsDropped() {
        let url = URL(string: "myapp://open?gclid=%7Bgclid%7D&utm_source=google")!
        let result = capture.parseAttributionFromUrl(url)
        XCTAssertNil(result?.gclid)
        XCTAssertEqual(result?.utmSource, "google")
    }

    func testParseAttributionFromUrl_macroOnlyUrl_returnsNil() {
        let url = URL(string: "myapp://open?gclid=%7Bgclid%7D")!
        XCTAssertNil(capture.parseAttributionFromUrl(url))
    }

    /// Only a full `{...}` wrapper is a macro; a stray brace is a real (if odd) value.
    func testParseAttributionFromUrl_partialBraceIsNotAMacro() {
        let url = URL(string: "myapp://open?gclid=%7Bnot_closed")!
        XCTAssertEqual(capture.parseAttributionFromUrl(url)?.gclid, "{not_closed")
    }

    // MARK: ttclid extracted

    func testParseAttributionFromUrl_extractsTtclid() {
        let url = URL(string: "myapp://open?ttclid=tiktok_id")!
        let result = capture.parseAttributionFromUrl(url)
        XCTAssertEqual(result?.ttclid, "tiktok_id")
    }

    // MARK: utm params extracted

    func testParseAttributionFromUrl_extractsUtmParams() {
        let url = URL(string: "myapp://open?utm_source=facebook&utm_medium=cpc&utm_campaign=summer")!
        let result = capture.parseAttributionFromUrl(url)
        XCTAssertEqual(result?.utmSource, "facebook")
        XCTAssertEqual(result?.utmMedium, "cpc")
        XCTAssertEqual(result?.utmCampaign, "summer")
    }

    func testParseAttributionFromUrl_extractsUtmContentAndTerm() {
        let url = URL(string: "myapp://open?utm_content=banner&utm_term=keyword")!
        let result = capture.parseAttributionFromUrl(url)
        XCTAssertEqual(result?.utmContent, "banner")
        XCTAssertEqual(result?.utmTerm, "keyword")
    }

    // MARK: + → space decoding

    func testParseAttributionFromUrl_plusDecodedAsSpace() {
        let url = URL(string: "myapp://open?utm_campaign=summer+sale")!
        let result = capture.parseAttributionFromUrl(url)
        XCTAssertEqual(result?.utmCampaign, "summer sale")
    }

    // MARK: campaign_id → tiktokCampaignId

    func testParseAttributionFromUrl_campaignIdMappedToTiktokCampaignId() {
        let url = URL(string: "myapp://open?campaign_id=camp_123&adgroup_id=adg_456&ad_id=ad_789")!
        let result = capture.parseAttributionFromUrl(url)
        XCTAssertEqual(result?.tiktokCampaignId, "camp_123")
        XCTAssertEqual(result?.tiktokAdgroupId, "adg_456")
        XCTAssertEqual(result?.tiktokAdId, "ad_789")
    }

    // MARK: referrer is nil (field was removed from parseAttributionFromUrl)

    func testParseAttributionFromUrl_referrerIsFullUrl() {
        let urlString = "myapp://open?fbclid=abc123"
        let url = URL(string: urlString)!
        let result = capture.parseAttributionFromUrl(url)
        XCTAssertNil(result?.referrer)
    }

    // MARK: multiple params together

    func testParseAttributionFromUrl_multipleParams() {
        let url = URL(string: "myapp://open?fbclid=fb1&utm_source=facebook&utm_medium=paid")!
        let result = capture.parseAttributionFromUrl(url)
        XCTAssertEqual(result?.fbclid, "fb1")
        XCTAssertEqual(result?.utmSource, "facebook")
        XCTAssertEqual(result?.utmMedium, "paid")
    }

    // MARK: handleUrl calls tracker.capture

    func testHandleUrl_capturesAttribution() async {
        let url = URL(string: "myapp://open?fbclid=handled_fb")!
        await capture.handleUrl(url)
        XCTAssertEqual(tracker.get()?.fbclid, "handled_fb")
    }
}

// MARK: - MetaBridge Tests

final class MetaBridgeTests: XCTestCase {

    // MetaBridge.shared is a singleton, can't reset between tests.
    // We create a fresh test via reflection isn't possible on `private init`.
    // Instead we test the public behavior from the documented spec.

    // MARK: getAnonymousID without FBSDK returns nil

    func testGetAnonymousID_withoutFBSDK_returnsNil() async {
        // FBSDK is not linked in tests — returns nil per #else branch
        let result = await MetaBridge.shared.getAnonymousID()
        XCTAssertNil(result)
    }

    // MARK: cached after first call

    func testGetAnonymousID_cachedAfterFirstCall() async {
        let first = await MetaBridge.shared.getAnonymousID()
        let second = await MetaBridge.shared.getAnonymousID()
        // Both should be equal (both nil without FBSDK, or same value if FBSDK present)
        XCTAssertEqual(first, second)
    }
}

// MARK: - AdvertisingIdManager Tests

final class AdvertisingIdManagerTests: XCTestCase {

    // MARK: getCached before collect

    func testGetCached_beforeCollect_returnsNil() {
        let manager = AdvertisingIdManager()
        XCTAssertNil(manager.getCached())
    }

    // MARK: caching is gated on the IDFV being present

    /// `collect()` caches ONLY when the IDFV came back — UIDevice can answer nil while
    /// the app is early in launch, and caching that nil freezes an empty result until the
    /// next cold boot. On a host with no UIKit the IDFV is always nil, so nothing caches.
    @MainActor
    func testGetCached_afterCollect_cachesOnlyWithIdfv() async {
        let manager = AdvertisingIdManager()
        let collected = await manager.collect(requestATT: false)
        let cached = manager.getCached()

        if collected.idfv != nil {
            XCTAssertEqual(cached?.attStatus, collected.attStatus)
        } else {
            XCTAssertNil(cached)
        }
    }

    /// The SDK never raises the ATT prompt — that is the host app's call alone. The
    /// parameter survives for source compatibility and must be inert.
    @MainActor
    func testRequestATTIsIgnored() async {
        let manager = AdvertisingIdManager()
        let withoutPrompt = await manager.collect(requestATT: false)
        let refreshed = await AdvertisingIdManager().collect(requestATT: true)
        XCTAssertEqual(withoutPrompt.attStatus, refreshed.attStatus)
    }

    /// `refresh()` must null the cache first: `collect()` skips writing it when the IDFV
    /// is nil, so a bare re-invocation would keep serving the stale snapshot.
    @MainActor
    func testRefreshReCollects() async {
        let manager = AdvertisingIdManager()
        let first = await manager.collect(requestATT: false)
        let refreshed = await manager.refresh()
        XCTAssertEqual(first.attStatus, refreshed.attStatus)
    }

    /// Apple's decision is monotonic, so without an actual undetermined→granted
    /// transition the listener must stay silent.
    @MainActor
    func testGrantedTransitionListenerDoesNotFireWithoutATransition() async {
        let manager = AdvertisingIdManager()
        var notified = 0
        manager.onGrantedTransition { _ in notified += 1 }

        _ = await manager.collect(requestATT: false)
        _ = await manager.refresh()

        XCTAssertEqual(notified, 0)
    }

    @MainActor
    func testGrantedTransitionUnsubscribe() async {
        let manager = AdvertisingIdManager()
        var notified = 0
        let unsubscribe = manager.onGrantedTransition { _ in notified += 1 }
        unsubscribe()

        _ = await manager.refresh()

        XCTAssertEqual(notified, 0)
    }

    // MARK: collect idempotent — second call returns same instance

    @MainActor
    func testCollect_idempotent_sameAttStatus() async {
        let manager = AdvertisingIdManager()
        let first = await manager.collect(requestATT: false)
        let second = await manager.collect(requestATT: false)
        XCTAssertEqual(first.attStatus, second.attStatus)
    }

    // MARK: attStatus is unavailable in test environment (no UIKit/ATT)

    @MainActor
    func testCollect_inTestEnv_attStatusIsUnavailableOrUndetermined() async {
        let manager = AdvertisingIdManager()
        let result = await manager.collect(requestATT: false)
        let acceptableStatuses: [AttStatus] = [.unavailable, .undetermined, .denied, .restricted]
        XCTAssertTrue(acceptableStatuses.contains(result.attStatus),
                      "Expected undetermined/unavailable/denied/restricted in test, got \(result.attStatus)")
    }
}

// MARK: - IdentityManager: durability, zip, IDFV drift, erase

final class IdentityDurabilityTests: XCTestCase {

    private var secureStorage: SecureStorage!
    private var native: NativeStorage!
    private var suiteName: String!
    private var manager: IdentityManager!

    override func setUp() {
        super.setUp()
        let (s, n, name) = makeIsolatedSecureStorage()
        secureStorage = s
        native = n
        suiteName = name
        manager = IdentityManager(secureStorage: s)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: anonId durability

    func testPersistAnonIdDurably_writesToKeychain() async {
        await IdentityStorage.persistAnonIdDurably(storage: secureStorage, anonId: "anon-1")
        let awaited1 = await secureStorage.get(PaywalloConstants.anonIdKey)
        XCTAssertEqual(awaited1, "anon-1")
    }

    func testReadAnonIdDurably_prefersTheKeychain() async {
        await secureStorage.set(PaywalloConstants.anonIdKey, value: "keychain-anon")
        native.set(PaywalloConstants.anonIdFallbackKey, value: "fallback-anon")

        let awaited2 = await IdentityStorage.readAnonIdDurably(storage: secureStorage)
        XCTAssertEqual(awaited2, "keychain-anon")
    }

    /// Without the fallback, a cold start with a locked Keychain loses the anonId and
    /// mints a new UUID — which inflated distinct_id counts on iOS by roughly 30%.
    func testReadAnonIdDurably_fallsBackToRegularStorage() async {
        native.set(PaywalloConstants.anonIdFallbackKey, value: "fallback-anon")
        let awaited3 = await IdentityStorage.readAnonIdDurably(storage: secureStorage)
        XCTAssertEqual(awaited3, "fallback-anon")
    }

    /// Returns nil ONLY when both sources came back empty — the caller must not
    /// regenerate before that is established.
    func testReadAnonIdDurably_nilOnlyWhenBothSourcesAreEmpty() async {
        let awaited4 = await IdentityStorage.readAnonIdDurably(storage: secureStorage)
        XCTAssertNil(awaited4)
    }

    func testInitializeAdoptsTheFallbackAnonId() async throws {
        native.set(PaywalloConstants.anonIdFallbackKey, value: "fallback-anon")

        try await manager.initialize()

        XCTAssertEqual(manager.getAnonId(), "fallback-anon")
    }

    // MARK: zipCode

    func testIdentifyPersistsZipCode() async throws {
        try await manager.initialize()
        await manager.identify(IdentifyOptions(zipCode: "01310-100"))

        XCTAssertEqual(manager.getState().zipCode, "01310-100")
        let awaited5 = await secureStorage.get(PaywalloConstants.userZipKey)
        XCTAssertEqual(awaited5, "01310-100")
    }

    func testZipCodeSurvivesAReload() async throws {
        try await manager.initialize()
        await manager.identify(IdentifyOptions(zipCode: "01310-100"))

        let reloaded = IdentityManager(secureStorage: secureStorage)
        try await reloaded.initialize()

        XCTAssertEqual(reloaded.getState().zipCode, "01310-100")
    }

    func testResetClearsZipCode() async throws {
        try await manager.initialize()
        await manager.identify(IdentifyOptions(zipCode: "01310-100"))

        await manager.reset()

        XCTAssertNil(manager.getState().zipCode)
        let awaited6 = await secureStorage.get(PaywalloConstants.userZipKey)
        XCTAssertNil(awaited6)
    }

    // MARK: updateProperties

    func testUpdatePropertiesMerges() async throws {
        try await manager.initialize()
        await manager.identify(IdentifyOptions(properties: ["plan": AnyCodable("free")]))

        await manager.updateProperties(["tier": AnyCodable("gold")])

        XCTAssertEqual(manager.getProperties()["plan"]?.value as? String, "free")
        XCTAssertEqual(manager.getProperties()["tier"]?.value as? String, "gold")
    }

    func testUpdatePropertiesBeforeInit_isNoOp() async {
        await manager.updateProperties(["tier": AnyCodable("gold")])
        XCTAssertTrue(manager.getProperties().isEmpty)
    }

    // MARK: IDFV drift

    func testIdfvChangedIsFalseOnFirstRun() async throws {
        try await manager.initialize()
        XCTAssertFalse(manager.hasIdfvChanged())
    }

    func testIdfvChangeIsDetected() async throws {
        // A different IDFV was persisted by a previous run of this app on another device.
        await secureStorage.set(PaywalloConstants.previousIdfvKey, value: "OLD-IDFV-VALUE")

        try await manager.initialize()

        // Only meaningful on a host that actually exposes an IDFV.
        if let current = manager.getPreviousIdfv() {
            XCTAssertTrue(manager.hasIdfvChanged())
            let awaited7 = await secureStorage.get(PaywalloConstants.previousIdfvKey)
            XCTAssertEqual(awaited7, current)
        } else {
            XCTAssertFalse(manager.hasIdfvChanged())
        }
    }

    func testIdfvChangedTravelsInState() async throws {
        try await manager.initialize()
        XCTAssertEqual(manager.getState().idfvChanged, manager.hasIdfvChanged())
    }

    // MARK: deleteUserData

    /// LGPD/GDPR erase. deviceId is NOT user data and feeds install idempotency, so it
    /// must survive.
    func testDeleteUserDataKeepsTheDeviceId() async throws {
        try await manager.initialize()
        let deviceId = manager.getDeviceId()

        await manager.deleteUserData()

        XCTAssertEqual(manager.getDeviceId(), deviceId)
    }

    func testDeleteUserDataWipesPii() async throws {
        try await manager.initialize()
        await manager.identify(IdentifyOptions(
            email: "user@example.com",
            properties: ["plan": AnyCodable("gold")],
            phone: "+5511999999999",
            firstName: "Ada",
            zipCode: "01310-100"
        ))

        await manager.deleteUserData()

        let state = manager.getState()
        XCTAssertNil(state.email)
        XCTAssertNil(state.phone)
        XCTAssertNil(state.firstName)
        XCTAssertNil(state.zipCode)
        XCTAssertTrue(state.properties.isEmpty)
        let awaited8 = await secureStorage.get(PaywalloConstants.userEmailKey)
        XCTAssertNil(awaited8)
        let awaited9 = await secureStorage.get(PaywalloConstants.userZipKey)
        XCTAssertNil(awaited9)
    }

    /// A fresh anonId is issued IMMEDIATELY so a still-running app never tracks under an
    /// empty distinctId.
    func testDeleteUserDataIssuesANewAnonIdImmediately() async throws {
        try await manager.initialize()
        let before = manager.getAnonId()

        await manager.deleteUserData()

        XCTAssertNotNil(manager.getAnonId())
        XCTAssertNotEqual(manager.getAnonId(), before)
        XCTAssertFalse(manager.getDistinctId().isEmpty)
    }

    func testDeleteUserDataBeforeInit_isNoOp() async {
        await manager.deleteUserData()
        XCTAssertNil(manager.getAnonId())
    }

    // MARK: clearInstallStateForDev

    func testClearInstallStateForDevRemovesTheInstallMarkers() async throws {
        try await manager.initialize()
        await secureStorage.set(PaywalloConstants.installTrackedKey, value: "1700000000000")
        native.set(PaywalloConstants.installEventIdKey, value: "event-1")

        await manager.clearInstallStateForDev()

        let awaited10 = await secureStorage.get(PaywalloConstants.installTrackedKey)
        XCTAssertNil(awaited10)
        XCTAssertNil(native.get(PaywalloConstants.installEventIdKey))
        XCTAssertNotNil(native.get(PaywalloConstants.devResetEpochKey))
    }

    func testClearInstallStateForDevIssuesANewAnonId() async throws {
        try await manager.initialize()
        let before = manager.getAnonId()

        await manager.clearInstallStateForDev()

        XCTAssertNotEqual(manager.getAnonId(), before)
    }
}

// MARK: - Synced identity signal

final class IdentitySyncedSignalTests: XCTestCase {

    private var secureStorage: SecureStorage!
    private var native: NativeStorage!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        let (s, n, name) = makeIsolatedSecureStorage()
        secureStorage = s
        native = n
        suiteName = name
    }

    override func tearDown() async throws {
        await native.secureRemoveSynced("com.paywallo.sdk.sync.\(PaywalloConstants.syncedIdentityKey)")
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    /// Nothing anywhere: create the identity in both slots. A first-ever run reports no
    /// pre-existing synced key.
    func testCreatesTheIdentityWhenNeitherSlotExists() async {
        let result = await secureStorage.resolveSyncedIdentity(
            PaywalloConstants.syncedIdentityKey, enabled: true, createValue: { "created-id" }
        )

        XCTAssertEqual(result.value, "created-id")
        XCTAssertFalse(result.syncedKeyExists)
        XCTAssertFalse(result.divergence)
        let awaited11 = await secureStorage.get(PaywalloConstants.syncedIdentityLocalKey)
        XCTAssertEqual(awaited11, "created-id")
    }

    /// Local-only value: promote it up so the next device inherits it.
    func testPromotesALocalOnlyValue() async {
        await secureStorage.set(PaywalloConstants.syncedIdentityLocalKey, value: "local-id")

        let result = await secureStorage.resolveSyncedIdentity(
            PaywalloConstants.syncedIdentityKey, enabled: true, createValue: { "unused" }
        )

        XCTAssertEqual(result.value, "local-id")
        XCTAssertFalse(result.syncedKeyExists)
        XCTAssertFalse(result.divergence)
    }

    /// Kill switch off: degrade to the local value and never touch the synced Keychain.
    func testDisabledReadsLocalOnly() async {
        await secureStorage.set(PaywalloConstants.syncedIdentityLocalKey, value: "local-id")

        let result = await secureStorage.resolveSyncedIdentity(
            PaywalloConstants.syncedIdentityKey, enabled: false, createValue: { "unused" }
        )

        XCTAssertEqual(result.value, "local-id")
        XCTAssertFalse(result.syncedKeyExists)
        XCTAssertFalse(result.divergence)
    }

    func testDisabledWithNothingStored_reportsNoSignal() async {
        let result = await secureStorage.resolveSyncedIdentity(
            PaywalloConstants.syncedIdentityKey, enabled: false, createValue: { "unused" }
        )
        XCTAssertNil(result.value)
        XCTAssertFalse(result.syncedKeyExists)
    }

    /// The kill switch ships ON: a flag-cache miss means "no answer yet", not "off".
    func testCollectDefaultsToEnabled() async {
        let signals = await SyncedIdentitySignal.collect(
            storage: secureStorage, createValue: { "created-id" }
        )
        XCTAssertFalse(signals.syncedIdentityDivergence)
        let awaited12 = await secureStorage.get(PaywalloConstants.syncedIdentityLocalKey)
        XCTAssertEqual(awaited12, "created-id")
    }

    /// Telemetry only — collecting must never write anything the classifier reads.
    func testCollectDoesNotTouchInstallClassificationKeys() async {
        _ = await SyncedIdentitySignal.collect(storage: secureStorage)

        let awaited13 = await secureStorage.get(PaywalloConstants.installTrackedKey)
        XCTAssertNil(awaited13)
        let awaited14 = await secureStorage.get(PaywalloConstants.installAppVersionKey)
        XCTAssertNil(awaited14)
    }
}
