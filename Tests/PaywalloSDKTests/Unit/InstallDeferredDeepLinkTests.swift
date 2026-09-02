import XCTest
@testable import PaywalloSDK

// MARK: - parseDeferredDeepLink

final class InstallDeferredDeepLinkParseTests: XCTestCase {

    private let validRaw: [String: Any] = [
        "deeplinkId": "dl_1",
        "installId": "in_1",
        "redirectionUrl": "https://example.com/offer",
        "expiresAt": "2026-12-31T00:00:00Z",
    ]

    func testValidPayload_isParsed() {
        let link = parseDeferredDeepLink(validRaw)
        XCTAssertEqual(link?.deeplinkId, "dl_1")
        XCTAssertEqual(link?.installId, "in_1")
        XCTAssertEqual(link?.redirectionUrl, "https://example.com/offer")
        XCTAssertEqual(link?.expiresAt, "2026-12-31T00:00:00Z")
    }

    func testNonObject_returnsNil() {
        XCTAssertNil(parseDeferredDeepLink(nil))
        XCTAssertNil(parseDeferredDeepLink("string"))
        XCTAssertNil(parseDeferredDeepLink(42))
    }

    /// All four strings are required — a partial payload is dropped, not propagated.
    func testEachRequiredFieldIsMandatory() {
        for missing in ["deeplinkId", "installId", "redirectionUrl", "expiresAt"] {
            var raw = validRaw
            raw.removeValue(forKey: missing)
            XCTAssertNil(parseDeferredDeepLink(raw), "\(missing) must be required")
        }
    }

    func testBlankRequiredField_returnsNil() {
        for blanked in ["deeplinkId", "installId", "redirectionUrl", "expiresAt"] {
            var raw = validRaw
            raw[blanked] = "   "
            XCTAssertNil(parseDeferredDeepLink(raw), "blank \(blanked) must be rejected")
        }
    }

    func testWrongTypeRequiredField_returnsNil() {
        var raw = validRaw
        raw["deeplinkId"] = 42
        XCTAssertNil(parseDeferredDeepLink(raw))
    }

    /// Same rule as the server's DestinationUrlValidator — anything not https is dropped
    /// rather than handed to the app to open.
    func testNonHttpsRedirection_returnsNil() {
        for scheme in ["http://example.com", "myapp://open", "javascript:alert(1)", "//example.com"] {
            var raw = validRaw
            raw["redirectionUrl"] = scheme
            XCTAssertNil(parseDeferredDeepLink(raw), "\(scheme) must be rejected")
        }
    }

    func testQueryParams_onlyNonEmptyStringsSurvive() {
        var raw = validRaw
        raw["queryParams"] = ["offer": "black_friday", "blank": "", "numeric": 7]

        let link = parseDeferredDeepLink(raw)
        XCTAssertEqual(link?.queryParams, ["offer": "black_friday"])
    }

    func testQueryParams_allDropped_becomesNil() {
        var raw = validRaw
        raw["queryParams"] = ["blank": ""]
        XCTAssertNil(parseDeferredDeepLink(raw)?.queryParams)
    }

    func testCampaignFields() {
        var raw = validRaw
        raw["campaign"] = ["name": "Summer", "adsetName": "", "adName": "Creative A"]

        let campaign = parseDeferredDeepLink(raw)?.campaign
        XCTAssertEqual(campaign?.name, "Summer")
        XCTAssertNil(campaign?.adsetName)
        XCTAssertEqual(campaign?.adName, "Creative A")
    }

    func testCampaign_allEmpty_becomesNil() {
        var raw = validRaw
        raw["campaign"] = ["name": "", "adsetName": ""]
        XCTAssertNil(parseDeferredDeepLink(raw)?.campaign)
    }

    /// Additive field: an older server never sends it, and the rest must keep parsing.
    func testMissingOptionalBlocks_stillParses() {
        let link = parseDeferredDeepLink(validRaw)
        XCTAssertNotNil(link)
        XCTAssertNil(link?.queryParams)
        XCTAssertNil(link?.campaign)
    }
}

// MARK: - DeferredDeepLinkStore

final class InstallDeferredDeepLinkStoreTests: XCTestCase {

    private var storage: SecureStorage!
    private var suiteName: String!
    private var store: DeferredDeepLinkStore!

    private let link = DeferredDeepLink(
        deeplinkId: "dl_1",
        installId: "in_1",
        redirectionUrl: "https://example.com/offer",
        expiresAt: "2026-12-31T00:00:00Z",
        queryParams: ["offer": "bf"],
        campaign: DeferredDeepLink.Campaign(name: "Summer")
    )

    override func setUp() {
        super.setUp()
        let suite = "com.paywallo.sdk.deeplinkstore.tests.\(UUID().uuidString)"
        suiteName = suite
        let native = NativeStorage(service: suite, defaults: UserDefaults(suiteName: suite)!)
        storage = SecureStorage(nativeStorage: native)
        store = DeferredDeepLinkStore(storage: storage)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func testGetBeforeCapture_isNil() {
        XCTAssertNil(store.get())
    }

    func testCaptureThenGet() async {
        await store.capture(link)
        XCTAssertEqual(store.get(), link)
    }

    func testCaptureIsPersisted() async {
        await store.capture(link)

        let reloaded = DeferredDeepLinkStore(storage: storage)
        await reloaded.loadFromStorage()
        XCTAssertEqual(reloaded.get(), link)
    }

    /// Unlike attribution, a newer personalisation target replaces the previous one.
    func testCaptureOverwrites() async {
        await store.capture(link)
        let newer = DeferredDeepLink(
            deeplinkId: "dl_2", installId: "in_2",
            redirectionUrl: "https://example.com/other", expiresAt: "2027-01-01T00:00:00Z"
        )
        await store.capture(newer)
        XCTAssertEqual(store.get()?.deeplinkId, "dl_2")
    }

    /// The deferred-match answer lands in background AFTER the UI is built — listeners
    /// exist so that screen can react.
    func testListenerIsNotified() async {
        var received: [DeferredDeepLink] = []
        store.onCapture { received.append($0) }

        await store.capture(link)

        XCTAssertEqual(received, [link])
    }

    func testUnsubscribeStopsNotifications() async {
        var count = 0
        let unsubscribe = store.onCapture { _ in count += 1 }
        unsubscribe()

        await store.capture(link)

        XCTAssertEqual(count, 0)
    }

    func testClear() async {
        await store.capture(link)
        await store.clear()

        XCTAssertNil(store.get())
        let reloaded = DeferredDeepLinkStore(storage: storage)
        await reloaded.loadFromStorage()
        XCTAssertNil(reloaded.get())
    }

    func testMalformedPersistedValue_isTreatedAsEmpty() async {
        await storage.set(PaywalloConstants.deferredDeepLinkKey, value: "{ not json")

        await store.loadFromStorage()

        XCTAssertNil(store.get())
    }

    /// This store must never reach the event envelope or the CAPI pipeline; it lives on
    /// its own key, apart from attribution.
    func testUsesItsOwnStorageKey() async {
        await store.capture(link)
        let awaited1 = await storage.get(PaywalloConstants.deferredDeepLinkKey)
        XCTAssertNotNil(awaited1)
        let awaited2 = await storage.get(PaywalloConstants.attributionV2Key)
        XCTAssertNil(awaited2)
    }
}
