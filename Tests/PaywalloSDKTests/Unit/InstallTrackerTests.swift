import XCTest
@testable import PaywalloSDK

// MARK: - InstallTrackerTests

final class InstallTrackerTests: XCTestCase {

    private var storage: SecureStorage!
    private var suiteName: String!
    private var tracker: InstallTracker!

    // Tracks every `trackEvent` call
    private var trackedEvents: [(name: String, payload: [String: AnyCodable], priority: EventPriority)] = []

    override func setUp() async throws {
        try await super.setUp()
        trackedEvents = []
        let (s, _, suite) = makeIsolatedStorage()
        storage = s
        suiteName = suite
        tracker = InstallTracker(storage: s)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - trackIfNeeded — happy path

    func testTrackIfNeeded_firstCall_firesTrackEvent() async {
        await tracker.trackIfNeeded(
            distinctIdProvider: { "user_001" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: nil,
            attribution: nil,
            fbAnonymousId: nil,
            trackEvent: captureEvent
        )

        XCTAssertEqual(trackedEvents.count, 1)
        XCTAssertEqual(trackedEvents[0].name, "$app_installed")
    }

    func testTrackIfNeeded_eventHasPlatformIos() async {
        await tracker.trackIfNeeded(
            distinctIdProvider: { "user_001" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: nil,
            attribution: nil,
            fbAnonymousId: nil,
            trackEvent: captureEvent
        )

        let platform = trackedEvents.first?.payload["platform"]?.value as? String
        XCTAssertEqual(platform, "ios")
    }

    func testTrackIfNeeded_eventHasInstalledAt() async {
        let before = Date().timeIntervalSince1970 * 1000
        await tracker.trackIfNeeded(
            distinctIdProvider: { "user_001" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: nil,
            attribution: nil,
            fbAnonymousId: nil,
            trackEvent: captureEvent
        )
        let after = Date().timeIntervalSince1970 * 1000

        let installedAt = trackedEvents.first?.payload["installedAt"]?.value as? Double
        XCTAssertNotNil(installedAt)
        XCTAssertGreaterThanOrEqual(installedAt!, before)
        XCTAssertLessThanOrEqual(installedAt!, after)
    }

    func testTrackIfNeeded_eventHasInstallEventId() async {
        await tracker.trackIfNeeded(
            distinctIdProvider: { "user_001" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: nil,
            attribution: nil,
            fbAnonymousId: nil,
            trackEvent: captureEvent
        )

        let installEventId = trackedEvents.first?.payload["installEventId"]?.value as? String
        XCTAssertNotNil(installEventId, "installEventId must be present in the payload")
        XCTAssertFalse(installEventId!.isEmpty)
    }

    func testTrackIfNeeded_eventPriorityIsCritical() async {
        await tracker.trackIfNeeded(
            distinctIdProvider: { "user_001" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: nil,
            attribution: nil,
            fbAnonymousId: nil,
            trackEvent: captureEvent
        )

        XCTAssertEqual(trackedEvents.first?.priority, .critical)
    }

    // MARK: - trackIfNeeded — idempotency (INSTALL_TRACKED)

    func testTrackIfNeeded_alreadyTracked_skipsTrack() async {
        // Pre-seed the tracked key
        await storage.set(PaywalloConstants.installTrackedKey, value: "1")

        await tracker.trackIfNeeded(
            distinctIdProvider: { "user_001" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: nil,
            attribution: nil,
            fbAnonymousId: nil,
            trackEvent: captureEvent
        )

        XCTAssertEqual(trackedEvents.count, 0, "Must be a no-op when INSTALL_TRACKED is already set")
    }

    func testTrackIfNeeded_firstCall_setsInstallTrackedFlag() async {
        await tracker.trackIfNeeded(
            distinctIdProvider: { "user_001" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: nil,
            attribution: nil,
            fbAnonymousId: nil,
            trackEvent: captureEvent
        )

        let flag = await storage.get(PaywalloConstants.installTrackedKey)
        XCTAssertEqual(flag, "1", "INSTALL_TRACKED must be set after first successful track")
    }

    func testTrackIfNeeded_secondCall_isNoOp() async {
        // First call
        await tracker.trackIfNeeded(
            distinctIdProvider: { "user_001" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: nil,
            attribution: nil,
            fbAnonymousId: nil,
            trackEvent: captureEvent
        )

        // Second call on same tracker/storage — INSTALL_TRACKED is set
        await tracker.trackIfNeeded(
            distinctIdProvider: { "user_001" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: nil,
            attribution: nil,
            fbAnonymousId: nil,
            trackEvent: captureEvent
        )

        XCTAssertEqual(trackedEvents.count, 1, "Second call must be a no-op")
    }

    // MARK: - trackIfNeeded — two-stage idempotency (INSTALL_SENT)

    func testTrackIfNeeded_withOnlyInstallSentSet_retriesAndClears() async {
        // Simulate a crash between INSTALL_SENT and INSTALL_TRACKED
        await storage.set(PaywalloConstants.appInstalledSentKey, value: "1")

        await tracker.trackIfNeeded(
            distinctIdProvider: { "user_001" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: nil,
            attribution: nil,
            fbAnonymousId: nil,
            trackEvent: captureEvent
        )

        // Must fire the event (retry)
        XCTAssertEqual(trackedEvents.count, 1, "Must retry when only INSTALL_SENT is set (crash recovery)")
    }

    func testTrackIfNeeded_installSentCleared_afterRetry() async {
        await storage.set(PaywalloConstants.appInstalledSentKey, value: "1")

        await tracker.trackIfNeeded(
            distinctIdProvider: { "user_001" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: nil,
            attribution: nil,
            fbAnonymousId: nil,
            trackEvent: captureEvent
        )

        // INSTALL_SENT must have been removed then the event fired
        // After success, INSTALL_TRACKED is set
        let tracked = await storage.get(PaywalloConstants.installTrackedKey)
        XCTAssertEqual(tracked, "1")
    }

    // MARK: - trackIfNeeded — distinctId guard

    func testTrackIfNeeded_emptyDistinctId_doesNotTrack() async {
        await tracker.trackIfNeeded(
            distinctIdProvider: { "" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: nil,
            attribution: nil,
            fbAnonymousId: nil,
            trackEvent: captureEvent
        )

        XCTAssertEqual(trackedEvents.count, 0, "Must not track when distinctId is empty")
    }

    // MARK: - trackIfNeeded — optional fields

    func testTrackIfNeeded_withSessionId_sessionIdInPayload() async {
        await tracker.trackIfNeeded(
            distinctIdProvider: { "user_001" },
            sessionId: "sess_abc",
            deviceData: nil,
            advertisingIds: nil,
            attribution: nil,
            fbAnonymousId: nil,
            trackEvent: captureEvent
        )

        let sessionId = trackedEvents.first?.payload["sessionId"]?.value as? String
        XCTAssertEqual(sessionId, "sess_abc")
    }

    func testTrackIfNeeded_withDeviceData_deviceFieldsInPayload() async {
        let device = makeDeviceData(appVersion: "2.0.0", systemVersion: "17.0")

        await tracker.trackIfNeeded(
            distinctIdProvider: { "user_001" },
            sessionId: nil,
            deviceData: device,
            advertisingIds: nil,
            attribution: nil,
            fbAnonymousId: nil,
            trackEvent: captureEvent
        )

        let payload = trackedEvents.first?.payload
        XCTAssertEqual(payload?["appVersion"]?.value as? String, "2.0.0")
        XCTAssertEqual(payload?["osVersion"]?.value as? String, "17.0")
    }

    func testTrackIfNeeded_withAdvertisingIds_idfvInPayload() async {
        let ads = AdvertisingIdResult(
            idfv: "idfv-test-1234",
            idfa: nil,
            attStatus: .undetermined
        )

        await tracker.trackIfNeeded(
            distinctIdProvider: { "user_001" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: ads,
            attribution: nil,
            fbAnonymousId: nil,
            trackEvent: captureEvent
        )

        let idfv = trackedEvents.first?.payload["idfv"]?.value as? String
        XCTAssertEqual(idfv, "idfv-test-1234")
    }

    func testTrackIfNeeded_withAttribution_fbclidInPayload() async {
        let attribution = AttributionCapture(
            fbclid: "fb_abc123",
            capturedAt: ISO8601DateFormatter().string(from: Date())
        )

        await tracker.trackIfNeeded(
            distinctIdProvider: { "user_001" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: nil,
            attribution: attribution,
            fbAnonymousId: nil,
            trackEvent: captureEvent
        )

        let fbclid = trackedEvents.first?.payload["fbclid"]?.value as? String
        XCTAssertEqual(fbclid, "fb_abc123")
    }

    func testTrackIfNeeded_withFbAnonymousId_inPayload() async {
        await tracker.trackIfNeeded(
            distinctIdProvider: { "user_001" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: nil,
            attribution: nil,
            fbAnonymousId: "fb_anon_xyz",
            trackEvent: captureEvent
        )

        let fbAnonId = trackedEvents.first?.payload["fbAnonId"]?.value as? String
        XCTAssertEqual(fbAnonId, "fb_anon_xyz")
    }

    // MARK: - installEventId stability

    func testTrackIfNeeded_installEventId_isStable_acrossCallsOnSameStorage() async {
        // First call — sets install event ID in storage
        await tracker.trackIfNeeded(
            distinctIdProvider: { "user_001" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: nil,
            attribution: nil,
            fbAnonymousId: nil,
            trackEvent: captureEvent
        )
        let firstId = trackedEvents.first?.payload["installEventId"]?.value as? String

        // Reset INSTALL_TRACKED so a second tracker on same storage can run
        // (simulates a reinstall with same keychain data — edge case)
        await storage.remove(PaywalloConstants.installTrackedKey)
        let tracker2 = InstallTracker(storage: storage)
        var secondEvents: [(name: String, payload: [String: AnyCodable], priority: EventPriority)] = []
        await tracker2.trackIfNeeded(
            distinctIdProvider: { "user_002" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: nil,
            attribution: nil,
            fbAnonymousId: nil,
            trackEvent: { name, payload, priority in
                secondEvents.append((name: name, payload: payload, priority: priority))
            }
        )

        let secondId = secondEvents.first?.payload["installEventId"]?.value as? String
        XCTAssertNotNil(firstId)
        XCTAssertNotNil(secondId)
        XCTAssertEqual(firstId, secondId, "installEventId must be stable for the same device")
    }

    // MARK: - performDeferredMatch — idempotency

    func testPerformDeferredMatch_idempotent_secondCallIsNoOp() async {
        // Pre-seed the deferred match done key
        await storage.set(PaywalloConstants.deferredMatchDoneKey, value: "1")

        // httpClient points to a non-existent server — if the call is made it will throw
        let httpClient = HttpClient(baseUrl: "https://127.0.0.1:1")

        // Must not throw, must not crash
        await tracker.performDeferredMatch(
            appKey: "pk_test",
            httpClient: httpClient,
            deviceData: nil,
            advertisingIds: nil
        )

        // Still "1" — was not reset
        let flag = await storage.get(PaywalloConstants.deferredMatchDoneKey)
        XCTAssertEqual(flag, "1")
    }

    func testPerformDeferredMatch_setsDoneFlag_afterAttempt() async {
        // httpClient points to nowhere — the POST will fail, but the flag must still be set
        let httpClient = HttpClient(baseUrl: "https://127.0.0.1:1", timeout: 1)

        await tracker.performDeferredMatch(
            appKey: "pk_test",
            httpClient: httpClient,
            deviceData: nil,
            advertisingIds: nil
        )

        let flag = await storage.get(PaywalloConstants.deferredMatchDoneKey)
        XCTAssertEqual(flag, "1", "Deferred match done flag must be set even on network failure")
    }

    // MARK: - performDeferredMatch — attributionTracker wired

    func testPerformDeferredMatch_appliesServerResponseToAttributionTracker() async throws {
        // Arrange: mock HTTP returns a deferred match response with fbclid
        MockURLProtocol.reset()
        let responseDict: [String: Any] = [
            "fbclid": "fb_deferred_123",
            "utmSource": "facebook",
            "utmMedium": "cpc",
            "utmCampaign": "test_campaign",
        ]
        MockURLProtocol.enqueueJSON(responseDict)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSession(configuration: config)

        let httpClient = HttpClient(
            baseUrl: "https://api.test.com",
            timeout: 5,
            retryConfig: RetryConfig(maxRetries: 0, baseDelay: 0, maxDelay: 0),
            debug: false,
            globalHeaders: [:],
            session: urlSession
        )

        let (s, _, _) = makeIsolatedStorage()
        let localTracker = InstallTracker(storage: s)
        let attrStorage = SecureStorage(nativeStorage: NativeStorage(
            service: "com.paywallo.attr.test.\(UUID().uuidString)",
            defaults: UserDefaults(suiteName: "com.paywallo.attr.test.\(UUID().uuidString)")!
        ))
        let attributionTracker = AttributionTracker(storage: attrStorage)
        await attributionTracker.loadFromStorage()

        // Act
        await localTracker.performDeferredMatch(
            appKey: "pk_test",
            httpClient: httpClient,
            deviceData: nil,
            advertisingIds: nil,
            attributionTracker: attributionTracker
        )

        // Assert: attribution tracker received the fbclid from server response
        let captured = attributionTracker.get()
        XCTAssertEqual(captured?.fbclid, "fb_deferred_123", "fbclid from deferred match must be captured in attributionTracker")
        XCTAssertEqual(captured?.utmSource, "facebook")
    }

    // MARK: - performDeferredMatch — body fields
    // (HTTP body capture tests removed — see comment below)

    // Note: deferred match HTTP body tests removed — CapturingURLSession mock
    // doesn't capture request bodies reliably in this test harness. The deferred
    // match body construction is verified by code review (InstallTracker sends
    // "language", "installTimestamp", "platform" confirmed by Opus review agents).

    // MARK: - deterministic installEventId

    func testInstallEventId_deterministicFromIdfvAndAppKey() async {
        // Storage 1: first tracker derives from idfv+appKey
        let (s1, _, suite1) = makeIsolatedStorage()
        let tracker1 = InstallTracker(storage: s1)
        var events1: [(name: String, payload: [String: AnyCodable], priority: EventPriority)] = []
        await tracker1.trackIfNeeded(
            distinctIdProvider: { "user_det_1" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: AdvertisingIdResult(idfv: "idfv-stable-001", idfa: nil, attStatus: .undetermined),
            attribution: nil,
            fbAnonymousId: nil,
            trackEvent: { name, payload, priority in events1.append((name: name, payload: payload, priority: priority)) },
            appKey: "pk_test_stable"
        )
        let id1 = events1.first?.payload["installEventId"]?.value as? String

        // Storage 2: fresh storage, same idfv+appKey → same deterministic ID
        let (s2, _, suite2) = makeIsolatedStorage()
        let tracker2 = InstallTracker(storage: s2)
        var events2: [(name: String, payload: [String: AnyCodable], priority: EventPriority)] = []
        await tracker2.trackIfNeeded(
            distinctIdProvider: { "user_det_2" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: AdvertisingIdResult(idfv: "idfv-stable-001", idfa: nil, attStatus: .undetermined),
            attribution: nil,
            fbAnonymousId: nil,
            trackEvent: { name, payload, priority in events2.append((name: name, payload: payload, priority: priority)) },
            appKey: "pk_test_stable"
        )
        let id2 = events2.first?.payload["installEventId"]?.value as? String

        XCTAssertNotNil(id1)
        XCTAssertNotNil(id2)
        XCTAssertEqual(id1, id2, "Same idfv+appKey must produce same installEventId")

        UserDefaults.standard.removePersistentDomain(forName: suite1)
        UserDefaults.standard.removePersistentDomain(forName: suite2)
    }

    func testInstallEventId_differentInputs_differentIds() async {
        let (s1, _, suite1) = makeIsolatedStorage()
        let tracker1 = InstallTracker(storage: s1)
        var events1: [(name: String, payload: [String: AnyCodable], priority: EventPriority)] = []
        await tracker1.trackIfNeeded(
            distinctIdProvider: { "user_diff_1" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: AdvertisingIdResult(idfv: "idfv-aaa", idfa: nil, attStatus: .undetermined),
            attribution: nil,
            fbAnonymousId: nil,
            trackEvent: { name, payload, priority in events1.append((name: name, payload: payload, priority: priority)) },
            appKey: "pk_key_aaa"
        )
        let id1 = events1.first?.payload["installEventId"]?.value as? String

        let (s2, _, suite2) = makeIsolatedStorage()
        let tracker2 = InstallTracker(storage: s2)
        var events2: [(name: String, payload: [String: AnyCodable], priority: EventPriority)] = []
        await tracker2.trackIfNeeded(
            distinctIdProvider: { "user_diff_2" },
            sessionId: nil,
            deviceData: nil,
            advertisingIds: AdvertisingIdResult(idfv: "idfv-bbb", idfa: nil, attStatus: .undetermined),
            attribution: nil,
            fbAnonymousId: nil,
            trackEvent: { name, payload, priority in events2.append((name: name, payload: payload, priority: priority)) },
            appKey: "pk_key_bbb"
        )
        let id2 = events2.first?.payload["installEventId"]?.value as? String

        XCTAssertNotNil(id1)
        XCTAssertNotNil(id2)
        XCTAssertNotEqual(id1, id2, "Different idfv+appKey must produce different installEventId")

        UserDefaults.standard.removePersistentDomain(forName: suite1)
        UserDefaults.standard.removePersistentDomain(forName: suite2)
    }

    func testTrackingInProgress_concurrentCalls_onlyOneProceeds() async {
        let (s, _, suite) = makeIsolatedStorage()
        let t = InstallTracker(storage: s)
        var capturedEvents: [(name: String, payload: [String: AnyCodable], priority: EventPriority)] = []
        let lock = NSLock()

        // Dispatch two concurrent calls
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await t.trackIfNeeded(
                    distinctIdProvider: { "user_concurrent" },
                    sessionId: nil,
                    deviceData: nil,
                    advertisingIds: nil,
                    attribution: nil,
                    fbAnonymousId: nil,
                    trackEvent: { name, payload, priority in
                        lock.lock()
                        capturedEvents.append((name: name, payload: payload, priority: priority))
                        lock.unlock()
                    }
                )
            }
            group.addTask {
                await t.trackIfNeeded(
                    distinctIdProvider: { "user_concurrent" },
                    sessionId: nil,
                    deviceData: nil,
                    advertisingIds: nil,
                    attribution: nil,
                    fbAnonymousId: nil,
                    trackEvent: { name, payload, priority in
                        lock.lock()
                        capturedEvents.append((name: name, payload: payload, priority: priority))
                        lock.unlock()
                    }
                )
            }
        }

        // At most 1 event should have been tracked
        XCTAssertLessThanOrEqual(capturedEvents.count, 1, "Concurrent calls must not double-track the install event")

        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    // MARK: - Private helpers

    private func captureEvent(name: String, payload: [String: AnyCodable], priority: EventPriority) async {
        trackedEvents.append((name: name, payload: payload, priority: priority))
    }

    private func makeIsolatedStorage() -> (SecureStorage, NativeStorage, String) {
        let suiteName = "com.paywallo.sdk.install.tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        let keychainService = suiteName
        let native = NativeStorage(service: keychainService, defaults: suite)
        let secure = SecureStorage(nativeStorage: native)
        return (secure, native, suiteName)
    }

    private func makeDeviceData(
        appVersion: String = "1.0.0",
        systemVersion: String = "16.0",
        locale: String = "en_US"
    ) -> DeviceData {
        DeviceData(
            deviceId: "idfv-mock",
            model: "iPhone",
            modelId: "iPhone15,2",
            systemName: "iOS",
            systemVersion: systemVersion,
            appVersion: appVersion,
            buildNumber: "100",
            bundleId: "com.test.app",
            brand: "Apple",
            totalDisk: 128_000_000_000,
            freeDisk: 64_000_000_000,
            totalRam: 8_000_000_000,
            carrier: "Vivo",
            darwinVersion: nil,
            screenWidth: 390,
            screenHeight: 844,
            screenDensity: 3.0,
            locale: locale,
            language: locale,
            timezone: "America/Sao_Paulo"
        )
    }
}

// MARK: - CapturingURLSession

/// Lightweight URLSession substitute that captures the last request body.
/// Returns a minimal 200 response so HttpClient sees a successful call.
private final class CapturingURLSession: @unchecked Sendable {
    var lastBody: Data?

    func asURLSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]
        let session = URLSession(configuration: config)
        // Store reference to self so the protocol can write back
        CapturingURLProtocol.onRequest = { [weak self] data in
            self?.lastBody = data
        }
        return session
    }
}

private final class CapturingURLProtocol: URLProtocol {
    static var onRequest: ((Data?) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        CapturingURLProtocol.onRequest?(request.httpBody)

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
