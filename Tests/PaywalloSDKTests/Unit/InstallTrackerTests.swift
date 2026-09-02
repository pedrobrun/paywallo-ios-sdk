import XCTest
@testable import PaywalloSDK

/// Answers every deferred-match POST with a plain 200 so the fire-and-forget scheduler
/// started by `trackIfNeeded` never touches the network.
private final class InstallStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":{"matched":false}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class InstallTrackerTests: XCTestCase {

    private var storage: SecureStorage!
    private var native: NativeStorage!
    private var suiteName: String!
    private var tracker: InstallTracker!
    private var attributionTracker: AttributionTracker!
    private var apiClient: ApiClient!

    private var trackedEvents: [(name: String, payload: [String: AnyCodable], priority: EventPriority)] = []

    override func setUp() {
        super.setUp()
        trackedEvents = []
        // The install guard is process-wide by design; every case starts from a cold launch.
        InstallIdempotency.resetInstallGuardForTests()

        let suite = "com.paywallo.sdk.install.tests.\(UUID().uuidString)"
        suiteName = suite
        native = NativeStorage(service: suite, defaults: UserDefaults(suiteName: suite)!)
        storage = SecureStorage(nativeStorage: native)
        attributionTracker = AttributionTracker(storage: storage, nativeStorage: native)
        tracker = InstallTracker(
            storage: storage,
            attributionTracker: attributionTracker,
            deepLinkStore: DeferredDeepLinkStore(storage: storage)
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InstallStubProtocol.self]
        let http = HttpClient(baseUrl: "https://stub.test", session: URLSession(configuration: config))
        apiClient = ApiClient(httpClient: http, appKey: "test_app_key")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func track(
        distinctId: String = "user_001",
        sessionId: String? = nil,
        deviceData: DeviceData? = nil,
        advertisingIds: AdvertisingIdResult? = nil,
        fbAnonymousId: String? = nil,
        referrer: MetaDeferredLinkParams? = nil,
        idfvChanged: Bool = false
    ) async -> Bool {
        await tracker.trackIfNeeded(
            apiClient: apiClient,
            distinctIdProvider: { distinctId },
            sessionId: sessionId,
            deviceData: deviceData,
            advertisingIds: advertisingIds,
            fbAnonymousId: fbAnonymousId,
            referrer: referrer,
            idfvChanged: idfvChanged,
            trackEvent: { name, payload, priority in
                self.trackedEvents.append((name: name, payload: payload, priority: priority))
            }
        )
    }

    private func makeDeviceData(appVersion: String = "1.0.0") -> DeviceData {
        DeviceData(
            deviceId: "idfv-mock", model: "iPhone", modelId: "iPhone15,2",
            systemName: "iOS", systemVersion: "17.2", appVersion: appVersion, buildNumber: "100",
            bundleId: "com.test.app", brand: "Apple",
            totalDisk: 128_000_000_000, freeDisk: 64_000_000_000, totalRam: 8_000_000_000,
            carrier: "Vivo", darwinVersion: nil,
            screenWidth: 390, screenHeight: 844, screenDensity: 3.0,
            locale: "pt_BR", language: "pt-BR", timezone: "America/Sao_Paulo"
        )
    }

    private var firstPayload: [String: AnyCodable] { trackedEvents.first?.payload ?? [:] }

    // MARK: - Dispatch

    func testFirstCall_firesTheEvent_andReturnsTrue() async {
        let fired = await track()

        XCTAssertTrue(fired)
        XCTAssertEqual(trackedEvents.count, 1)
        XCTAssertEqual(trackedEvents[0].name, "$app_installed")
        XCTAssertEqual(trackedEvents[0].priority, .critical)
    }

    func testFirstCall_setsInstallTrackedFlag() async {
        await track()
        let awaited1 = await storage.get(PaywalloConstants.installTrackedKey)
        XCTAssertNotNil(awaited1)
    }

    /// The return value must mean "dispatched", not "resolved" — the old signature made
    /// every early exit look like a successful send.
    func testAlreadyTracked_returnsFalse_andDoesNotFire() async {
        await storage.set(PaywalloConstants.installTrackedKey, value: "1700000000000")
        await storage.set(PaywalloConstants.installAppVersionKey, value: "1.0.0")

        let fired = await track(deviceData: makeDeviceData())

        XCTAssertFalse(fired)
        XCTAssertEqual(trackedEvents.count, 0)
    }

    /// Residue says nothing about the deferred match having a confirmed answer — that
    /// retry must still run, without re-lighting the install event.
    func testNotFiring_stillRetriesTheDeferredMatch() async {
        await storage.set(PaywalloConstants.installTrackedKey, value: "1700000000000")
        await storage.set(PaywalloConstants.installAppVersionKey, value: "1.0.0")
        let state = DeferredMatchState(
            payload: Data(#"{"distinctId":"user_001"}"#.utf8),
            firstAttemptAt: Date().timeIntervalSince1970 * 1000,
            attempts: 0, nextAttemptAt: 0, retryAfterUntil: nil, lastForcedAttemptAt: nil
        )
        let json = String(data: try! JSONEncoder().encode(state), encoding: .utf8)!
        await storage.set(PaywalloConstants.deferredMatchStateKey, value: json)

        _ = await track(deviceData: makeDeviceData())

        // The stub answers matched:false, so the attempt bumps the counter and re-persists.
        let raw = await storage.get(PaywalloConstants.deferredMatchStateKey)
        let updated = try? JSONDecoder().decode(DeferredMatchState.self, from: Data(raw!.utf8))
        XCTAssertEqual(updated?.attempts, 1)
    }

    func testSecondCallInSameLaunch_isNoOp() async {
        await track()
        let second = await track()

        XCTAssertFalse(second)
        XCTAssertEqual(trackedEvents.count, 1)
    }

    func testEmptyDistinctId_doesNotFire_andDoesNotMarkTracked() async {
        let fired = await tracker.trackIfNeeded(
            apiClient: apiClient,
            distinctIdProvider: { "" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: nil,
            fbAnonymousId: nil,
            trackEvent: { name, payload, priority in
                self.trackedEvents.append((name: name, payload: payload, priority: priority))
            }
        )

        XCTAssertFalse(fired)
        XCTAssertEqual(trackedEvents.count, 0)
        let awaited2 = await storage.get(PaywalloConstants.installTrackedKey)
        XCTAssertNil(awaited2, "next boot must retry")
    }

    // MARK: - Payload

    func testCoreFields() async {
        await track(sessionId: "sess_1", deviceData: makeDeviceData())

        XCTAssertEqual(firstPayload["platform"]?.value as? String, "ios")
        XCTAssertEqual(firstPayload["sessionId"]?.value as? String, "sess_1")
        XCTAssertNotNil(firstPayload["installedAt"]?.value as? Double)
        XCTAssertNotNil(firstPayload["installEventId"]?.value as? String)
    }

    func testInstallClassificationIsTheEnumString() async {
        await track(deviceData: makeDeviceData())
        XCTAssertEqual(firstPayload["installClassification"]?.value as? String, "new_install")
    }

    /// ONE nested object, not a flattened spread — the server's key budget is 50.
    func testInstallSignalsIsASingleNestedObject() async {
        await track(deviceData: makeDeviceData(), idfvChanged: true)

        let signals = firstPayload["installSignals"]?.value as? [String: Any]
        XCTAssertNotNil(signals)
        XCTAssertEqual(signals?["idfvChanged"] as? Bool, true)
        XCTAssertEqual(signals?["hasInstallTrackedKey"] as? Bool, false)
        XCTAssertEqual(signals?["hasAppVersionKey"] as? Bool, false)
        XCTAssertNil(firstPayload["idfvChanged"], "signals must not be flattened onto the payload")
    }

    /// The classifier's APP_VERSION side effect runs before the payload is built, so the
    /// PREVIOUS value has to be read first or the snapshot loses it.
    func testPreviousAppVersionIsCapturedBeforeTheRewrite() async {
        await storage.set(PaywalloConstants.installAppVersionKey, value: "0.9.0")

        await track(deviceData: makeDeviceData(appVersion: "1.0.0"))

        let signals = firstPayload["installSignals"]?.value as? [String: Any]
        XCTAssertEqual(signals?["previousAppVersion"] as? String, "0.9.0")
        let awaited3 = await storage.get(PaywalloConstants.installAppVersionKey)
        XCTAssertEqual(awaited3, "1.0.0")
    }

    func testSyncedIdentitySignalsArePresent() async {
        await track(deviceData: makeDeviceData())

        XCTAssertNotNil(firstPayload["syncedIdentityKeyExists"]?.value as? Bool)
        XCTAssertNotNil(firstPayload["syncedIdentityDivergence"]?.value as? Bool)
    }

    func testDeviceFields() async {
        await track(deviceData: makeDeviceData())

        XCTAssertEqual(firstPayload["deviceModel"]?.value as? String, "iPhone15,2")
        XCTAssertEqual(firstPayload["osVersion"]?.value as? String, "17.2")
        XCTAssertEqual(firstPayload["appVersion"]?.value as? String, "1.0.0")
        XCTAssertEqual(firstPayload["buildNumber"]?.value as? String, "100")
        XCTAssertEqual(firstPayload["locale"]?.value as? String, "pt_BR")
        XCTAssertEqual(firstPayload["timezone"]?.value as? String, "America/Sao_Paulo")
        XCTAssertEqual(firstPayload["carrier"]?.value as? String, "Vivo")
        XCTAssertEqual(firstPayload["brand"]?.value as? String, "Apple")
        XCTAssertEqual(firstPayload["totalDisk"]?.value as? Int, 128_000_000_000)
        XCTAssertEqual(firstPayload["freeDisk"]?.value as? Int, 64_000_000_000)
        XCTAssertEqual(firstPayload["totalRam"]?.value as? Int, 8_000_000_000)
    }

    /// "The app never asked" and "the user said no" are different answers; only the
    /// status distinguishes them, so it always travels.
    func testAttStatusIsAlwaysPresent() async {
        await track()
        XCTAssertEqual(firstPayload["attStatus"]?.value as? String, "unavailable")

        InstallIdempotency.resetInstallGuardForTests()
        trackedEvents = []
        await storage.remove(PaywalloConstants.installTrackedKey)
        native.remove(PaywalloConstants.legacyInstallTrackedKey)
        await track(advertisingIds: AdvertisingIdResult(idfv: "idfv-1", idfa: nil, attStatus: .denied))
        XCTAssertEqual(firstPayload["attStatus"]?.value as? String, "denied")
    }

    func testAdvertisingIds() async {
        await track(advertisingIds: AdvertisingIdResult(idfv: "idfv-1", idfa: "idfa-1", attStatus: .granted))

        XCTAssertEqual(firstPayload["idfv"]?.value as? String, "idfv-1")
        XCTAssertEqual(firstPayload["idfa"]?.value as? String, "idfa-1")
    }

    /// The RN SDK does NOT emit these at the payload root from the attribution capture —
    /// they travel in the event envelope's `context.attribution` instead.
    func testAttributionClickIdsAreNotEmittedAtTheRoot() async {
        await attributionTracker.capture(AttributionInput(fbclid: "fb_1", gclid: "g_1", ttclid: "tt_1"))

        await track(deviceData: makeDeviceData())

        XCTAssertNil(firstPayload["fbclid"])
        XCTAssertNil(firstPayload["gclid"])
        XCTAssertNil(firstPayload["ttclid"])
    }

    // MARK: - Referrer (Meta deferred app link)

    func testReferrerFields() async {
        let referrer = MetaDeferredLinkParams(
            fbclid: "fb_ref", utmSource: "facebook", utmMedium: "cpc", utmCampaign: "summer",
            ttclid: "tt_ref", trackingId: "trk_1",
            targetUrl: "https://advertiser.example/offer",
            raw: "https://l.facebook.com/?target_url=..."
        )

        await track(deviceData: makeDeviceData(), referrer: referrer)

        XCTAssertEqual(firstPayload["installReferrer"]?.value as? String, "https://advertiser.example/offer")
        XCTAssertEqual(firstPayload["install_referrer_raw"]?.value as? String, "https://l.facebook.com/?target_url=...")
        XCTAssertEqual(firstPayload["install_referrer_source"]?.value as? String, "meta_deferred")
        XCTAssertEqual(firstPayload["referrerTrackingId"]?.value as? String, "trk_1")
        XCTAssertEqual(firstPayload["referrerFbclid"]?.value as? String, "fb_ref")
        XCTAssertEqual(firstPayload["referrerUtmSource"]?.value as? String, "facebook")
        XCTAssertEqual(firstPayload["referrerUtmMedium"]?.value as? String, "cpc")
        XCTAssertEqual(firstPayload["referrerUtmCampaign"]?.value as? String, "summer")
        XCTAssertEqual(firstPayload["ttclid"]?.value as? String, "tt_ref")
    }

    func testNoReferrer_omitsTheReferrerFields() async {
        await track(deviceData: makeDeviceData())

        XCTAssertNil(firstPayload["installReferrer"])
        XCTAssertNil(firstPayload["install_referrer_source"])
    }

    // MARK: - fb_anon_id

    func testUsesTheMetaAnonymousIdWhenAvailable() async {
        await track(fbAnonymousId: "XZ_meta_anon")
        XCTAssertEqual(firstPayload["fbAnonId"]?.value as? String, "XZ_meta_anon")
    }

    func testFallsBackToThePersistedAnonId() async {
        await storage.set(PaywalloConstants.anonIdKey, value: "stored-anon")

        await track(fbAnonymousId: nil)

        XCTAssertEqual(firstPayload["fbAnonId"]?.value as? String, "stored-anon")
    }

    /// PW_ is not a real _fbp — Meta does not recognise it — but a stable per-device id
    /// still lets the server stitch the install to later events.
    func testGeneratesAndPersistsAPwFallback() async {
        await track(fbAnonymousId: nil)

        let anonId = firstPayload["fbAnonId"]?.value as? String
        XCTAssertTrue(anonId?.hasPrefix("PW_") == true)
        let awaited4 = await storage.get(PaywalloConstants.anonIdKey)
        XCTAssertEqual(awaited4, anonId)
    }

    // MARK: - Install event id

    func testInstallEventIdIsDeterministicFromIdfvAndAppKey() async {
        await track(advertisingIds: AdvertisingIdResult(idfv: "idfv-1", idfa: nil, attStatus: .denied))

        XCTAssertEqual(
            firstPayload["installEventId"]?.value as? String,
            deterministicUUID("test_app_key:idfv-1")
        )
    }

    func testInstallEventIdFallsBackToARandomUuidWithoutIdfv() async {
        await track(advertisingIds: nil)

        let id = firstPayload["installEventId"]?.value as? String
        XCTAssertNotNil(id)
        XCTAssertEqual(native.get(PaywalloConstants.installEventIdKey), id)
    }

    // MARK: - Concurrency

    func testConcurrentCalls_onlyOneDispatches() async {
        let lock = NSLock()
        var captured: [String] = []

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    _ = await self.tracker.trackIfNeeded(
                        apiClient: self.apiClient,
                        distinctIdProvider: { "user_concurrent" },
                        sessionId: nil,
                        deviceData: nil,
                        advertisingIds: nil,
                        fbAnonymousId: nil,
                        trackEvent: { name, _, _ in
                            lock.lock()
                            captured.append(name)
                            lock.unlock()
                        }
                    )
                }
            }
        }

        XCTAssertLessThanOrEqual(captured.count, 1, "concurrent calls must not double-track the install")
    }
}
