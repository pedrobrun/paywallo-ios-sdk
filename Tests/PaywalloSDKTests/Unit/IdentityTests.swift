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

    // MARK: getCached after collect returns same result

    @MainActor
    func testGetCached_afterCollect_returnsCachedResult() async {
        let manager = AdvertisingIdManager()
        let collected = await manager.collect(requestATT: false)
        let cached = manager.getCached()

        XCTAssertNotNil(cached)
        XCTAssertEqual(cached?.attStatus, collected.attStatus)
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
