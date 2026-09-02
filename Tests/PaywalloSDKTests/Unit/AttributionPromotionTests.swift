import XCTest
@testable import PaywalloSDK

final class AttributionPromotionTests: XCTestCase {

    private var storage: SecureStorage!
    private var native: NativeStorage!
    private var suiteName: String!
    private var tracker: AttributionTracker!

    override func setUp() {
        super.setUp()
        let suite = "com.paywallo.sdk.promotion.tests.\(UUID().uuidString)"
        suiteName = suite
        native = NativeStorage(service: suite, defaults: UserDefaults(suiteName: suite)!)
        storage = SecureStorage(nativeStorage: native)
        tracker = AttributionTracker(storage: storage, nativeStorage: native)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - Promotion rules

    /// The concrete failure this exists for: an organic store stamp was written first,
    /// and first-write-wins discarded the deferred match carrying the real click.
    func testWeakCurrent_strongIncoming_isPromoted() async {
        await tracker.capture(AttributionInput(utmSource: "google-play", utmMedium: "organic"))

        await tracker.promoteFromServerMatch(
            AttributionInput(fbclid: "fb_real", installReferrerSource: "deferred_match", adNetwork: "meta")
        )

        XCTAssertEqual(tracker.get()?.fbclid, "fb_real")
        XCTAssertEqual(tracker.get()?.adNetwork, "meta")
    }

    func testStrongCurrent_isNeverOverwritten() async {
        await tracker.capture(AttributionInput(fbclid: "fb_deeplink"))

        await tracker.promoteFromServerMatch(AttributionInput(fbclid: "fb_server", adNetwork: "meta"))

        XCTAssertEqual(tracker.get()?.fbclid, "fb_deeplink")
        XCTAssertNil(tracker.get()?.adNetwork)
    }

    func testWeakIncoming_isRejected() async {
        await tracker.capture(AttributionInput(utmSource: "google-play"))

        await tracker.promoteFromServerMatch(AttributionInput(utmSource: "newsletter", utmMedium: "email"))

        XCTAssertEqual(tracker.get()?.utmSource, "google-play")
    }

    /// A malformed payload can carry an empty string; treating that as present would
    /// label a weak capture strong and lock out the real click.
    func testEmptyStringIsAbsence_notStrength() async {
        await tracker.capture(AttributionInput(utmSource: "google-play", fbclid: ""))

        await tracker.promoteFromServerMatch(AttributionInput(fbclid: "fb_real"))

        XCTAssertEqual(tracker.get()?.fbclid, "fb_real")
    }

    func testEmptyStringIncomingIsNotStrongEnoughToPromote() async {
        await tracker.capture(AttributionInput(utmSource: "google-play"))

        await tracker.promoteFromServerMatch(AttributionInput(utmSource: "meta", fbclid: ""))

        XCTAssertEqual(tracker.get()?.utmSource, "google-play")
    }

    /// Any one of the five strong fields is enough to promote over a weak capture.
    func testEveryStrongFieldQualifies() async {
        let cases: [(name: String, input: AttributionInput, read: (AttributionCapture) -> String?)] = [
            ("fbclid", AttributionInput(fbclid: "x"), { $0.fbclid }),
            ("gclid", AttributionInput(gclid: "x"), { $0.gclid }),
            ("ttclid", AttributionInput(ttclid: "x"), { $0.ttclid }),
            ("tiktokCampaignId", AttributionInput(tiktokCampaignId: "x"), { $0.tiktokCampaignId }),
            ("adNetwork", AttributionInput(adNetwork: "x"), { $0.adNetwork }),
        ]

        for testCase in cases {
            let suite = "com.paywallo.sdk.promotion.field.\(UUID().uuidString)"
            let localNative = NativeStorage(service: suite, defaults: UserDefaults(suiteName: suite)!)
            let localTracker = AttributionTracker(
                storage: SecureStorage(nativeStorage: localNative), nativeStorage: localNative
            )
            await localTracker.capture(AttributionInput(utmSource: "google-play"))
            await localTracker.promoteFromServerMatch(testCase.input)

            let capture = localTracker.get()
            XCTAssertEqual(
                capture.flatMap(testCase.read), "x",
                "\(testCase.name) alone must be strong enough to promote"
            )
            // Merge, not replacement: the weak capture's own fields are inherited.
            XCTAssertEqual(capture?.utmSource, "google-play")
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
    }

    func testEmptyCache_promotionFallsBackToCapture() async {
        await tracker.promoteFromServerMatch(AttributionInput(fbclid: "fb_real"))
        XCTAssertEqual(tracker.get()?.fbclid, "fb_real")
    }

    func testEmptyInput_isIgnored() async {
        await tracker.capture(AttributionInput(utmSource: "google-play"))
        await tracker.promoteFromServerMatch(AttributionInput())
        XCTAssertEqual(tracker.get()?.utmSource, "google-play")
    }

    // MARK: - Merge semantics

    /// MERGE, not replacement. Replacing the whole object erased real data: a Meta
    /// deferred link carrying utm_campaign lost the campaign when the server answered
    /// with the network alone.
    func testFieldsTheServerDidNotSendAreInherited() async {
        await tracker.capture(AttributionInput(utmSource: "apps.facebook.com", utmCampaign: "summer_sale"))

        await tracker.promoteFromServerMatch(AttributionInput(adNetwork: "meta"))

        XCTAssertEqual(tracker.get()?.utmCampaign, "summer_sale")
        XCTAssertEqual(tracker.get()?.utmSource, "apps.facebook.com")
        XCTAssertEqual(tracker.get()?.adNetwork, "meta")
    }

    func testServerWinsFieldByField() async {
        await tracker.capture(AttributionInput(utmSource: "old", utmMedium: "old_medium"))

        await tracker.promoteFromServerMatch(AttributionInput(utmSource: "new", fbclid: "fb_real"))

        XCTAssertEqual(tracker.get()?.utmSource, "new")
        XCTAssertEqual(tracker.get()?.utmMedium, "old_medium")
    }

    /// `capturedAt` feeds hasNewCampaignSignal in install classification — moving it
    /// would rewrite new-install/reinstall.
    func testCapturedAtIsPreserved() async {
        await tracker.capture(AttributionInput(utmSource: "google-play"))
        let original = tracker.get()?.capturedAt

        await tracker.promoteFromServerMatch(AttributionInput(fbclid: "fb_real"))

        XCTAssertEqual(tracker.get()?.capturedAt, original)
    }

    /// Local evidence of what the store actually handed over must survive the promotion.
    func testInstallReferrerRawIsPreserved() async {
        await tracker.capture(AttributionInput(
            utmSource: "google-play",
            installReferrerRaw: "https://original/referrer",
            installReferrerSource: "meta_deferred"
        ))

        await tracker.promoteFromServerMatch(AttributionInput(
            fbclid: "fb_real",
            installReferrerRaw: "https://server/referrer",
            installReferrerSource: "deferred_match"
        ))

        XCTAssertEqual(tracker.get()?.installReferrerRaw, "https://original/referrer")
        XCTAssertEqual(tracker.get()?.installReferrerSource, "deferred_match")
    }

    func testPromotionIsPersisted() async {
        await tracker.capture(AttributionInput(utmSource: "google-play"))
        await tracker.promoteFromServerMatch(AttributionInput(fbclid: "fb_real"))

        let reloaded = AttributionTracker(storage: storage, nativeStorage: native)
        await reloaded.loadFromStorage()
        XCTAssertEqual(reloaded.get()?.fbclid, "fb_real")
    }

    /// A forced match can land before init's loadFromStorage() finishes — a strong
    /// capture already on disk must not be mistaken for "empty" and overwritten.
    func testHydratesBeforeDecidingOnAnUnloadedTracker() async {
        await tracker.capture(AttributionInput(fbclid: "fb_on_disk"))

        let fresh = AttributionTracker(storage: storage, nativeStorage: native)
        await fresh.promoteFromServerMatch(AttributionInput(fbclid: "fb_server", adNetwork: "meta"))

        XCTAssertEqual(fresh.get()?.fbclid, "fb_on_disk")
    }

    // MARK: - onCapture

    func testListenerFiresOnFirstCapture() async {
        var received: [AttributionCapture] = []
        tracker.onCapture { received.append($0) }

        await tracker.capture(AttributionInput(fbclid: "fb_1"))

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.fbclid, "fb_1")
    }

    /// First-write-wins: a no-op capture is not a write and must not notify.
    func testListenerDoesNotFireOnNoOpCapture() async {
        var count = 0
        tracker.onCapture { _ in count += 1 }

        await tracker.capture(AttributionInput(fbclid: "fb_1"))
        await tracker.capture(AttributionInput(fbclid: "fb_2"))
        await tracker.capture(AttributionInput())

        XCTAssertEqual(count, 1)
    }

    func testListenerFiresOnPromotion() async {
        await tracker.capture(AttributionInput(utmSource: "google-play"))

        var received: [AttributionCapture] = []
        tracker.onCapture { received.append($0) }
        await tracker.promoteFromServerMatch(AttributionInput(fbclid: "fb_real"))

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.fbclid, "fb_real")
    }

    func testUnsubscribeStopsNotifications() async {
        var count = 0
        let unsubscribe = tracker.onCapture { _ in count += 1 }
        unsubscribe()

        await tracker.capture(AttributionInput(fbclid: "fb_1"))

        XCTAssertEqual(count, 0)
    }

    // MARK: - Hydration

    func testLoadFromStorageIsIdempotent() async {
        await tracker.capture(AttributionInput(fbclid: "fb_1"))

        let fresh = AttributionTracker(storage: storage, nativeStorage: native)
        await fresh.loadFromStorage()
        await fresh.loadFromStorage()

        XCTAssertEqual(fresh.get()?.fbclid, "fb_1")
    }

    func testConcurrentHydrationSharesOneRead() async {
        await tracker.capture(AttributionInput(fbclid: "fb_1"))

        let fresh = AttributionTracker(storage: storage, nativeStorage: native)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { await fresh.loadFromStorage() } }
        }

        XCTAssertEqual(fresh.get()?.fbclid, "fb_1")
    }
}
