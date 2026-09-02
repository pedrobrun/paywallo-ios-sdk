import XCTest
@testable import PaywalloSDK

// MARK: - Stub transport

/// Serves one canned response per test and counts the requests that reached it.
private final class DeferredMatchStubProtocol: URLProtocol {
    static var status = 200
    static var body = Data()
    static var responseHeaders: [String: String] = [:]
    static var requestCount = 0
    static var failWithNetworkError = false

    static func reset() {
        status = 200
        body = Data()
        responseHeaders = [:]
        requestCount = 0
        failWithNetworkError = false
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1

        if Self.failWithNetworkError {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: "HTTP/1.1",
            headerFields: Self.responseHeaders
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Sealing rules

final class InstallRetrySchedulerSealingTests: XCTestCase {

    private var storage: SecureStorage!
    private var suiteName: String!
    private var tracker: AttributionTracker!
    private var deepLinkStore: DeferredDeepLinkStore!
    private var scheduler: InstallRetryScheduler!
    private var apiClient: ApiClient!

    override func setUp() {
        super.setUp()
        DeferredMatchStubProtocol.reset()

        let suite = "com.paywallo.sdk.deferredmatch.tests.\(UUID().uuidString)"
        suiteName = suite
        let native = NativeStorage(service: suite, defaults: UserDefaults(suiteName: suite)!)
        storage = SecureStorage(nativeStorage: native)
        tracker = AttributionTracker(storage: storage, nativeStorage: native)
        deepLinkStore = DeferredDeepLinkStore(storage: storage)
        scheduler = InstallRetryScheduler(
            storage: storage,
            attributionTracker: tracker,
            deepLinkStore: deepLinkStore
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeferredMatchStubProtocol.self]
        let http = HttpClient(baseUrl: "https://stub.test", session: URLSession(configuration: config))
        apiClient = ApiClient(httpClient: http, appKey: "test_app_key")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: helpers

    private func seedPendingState(
        firstAttemptAt: Double = Date().timeIntervalSince1970 * 1000,
        attempts: Int = 0,
        nextAttemptAt: Double = 0,
        retryAfterUntil: Double? = nil,
        lastForcedAttemptAt: Double? = nil
    ) async {
        let state = DeferredMatchState(
            payload: Data(#"{"distinctId":"user_1"}"#.utf8),
            firstAttemptAt: firstAttemptAt,
            attempts: attempts,
            nextAttemptAt: nextAttemptAt,
            retryAfterUntil: retryAfterUntil,
            lastForcedAttemptAt: lastForcedAttemptAt
        )
        let json = String(data: try! JSONEncoder().encode(state), encoding: .utf8)!
        await storage.set(PaywalloConstants.deferredMatchStateKey, value: json)
    }

    private func currentState() async -> DeferredMatchState? {
        guard let raw = await storage.get(PaywalloConstants.deferredMatchStateKey),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DeferredMatchState.self, from: data)
    }

    private func respond(_ json: String, status: Int = 200, headers: [String: String] = [:]) {
        DeferredMatchStubProtocol.status = status
        DeferredMatchStubProtocol.body = Data(json.utf8)
        DeferredMatchStubProtocol.responseHeaders = headers
    }

    // MARK: - THE regression: matched:true with no payload must NOT seal

    /// The server's organic fallback ALWAYS answers `matched:true`. Treating that alone
    /// as a match sealed the device on the very first attempt, and the real click that
    /// resolved minutes later was never asked for again. This is the 2.9.0 bug:
    /// "install with no match stopped sealing the device" — it must keep retrying.
    func testMatchedTrueWithoutAttributionOrDeepLink_doesNotSeal() async {
        await seedPendingState()
        respond(#"{"data":{"matched":true}}"#)

        await scheduler.retryIfDue(apiClient: apiClient)

        let done = await storage.get(PaywalloConstants.deferredMatchDoneKey)
        XCTAssertNil(done, "matched:true with no payload means 'waterfall exhausted', not 'found'")
        let state = await currentState()
        XCTAssertNotNil(state, "the pending state must survive so a later cold start retries")
        XCTAssertEqual(state?.attempts, 1)
    }

    func testMatchedTrueWithEmptyAttributionObject_doesNotSeal() async {
        await seedPendingState()
        respond(#"{"data":{"matched":true,"attribution":{}}}"#)

        await scheduler.retryIfDue(apiClient: apiClient)

        let done = await storage.get(PaywalloConstants.deferredMatchDoneKey)
        XCTAssertNil(done)
    }

    /// Only empty strings came back — a partial/malformed payload must not count as a match.
    func testMatchedTrueWithBlankAttributionValues_doesNotSeal() async {
        await seedPendingState()
        respond(#"{"data":{"matched":true,"attribution":{"fbclid":"","utmSource":""}}}"#)

        await scheduler.retryIfDue(apiClient: apiClient)

        let done = await storage.get(PaywalloConstants.deferredMatchDoneKey)
        XCTAssertNil(done)
    }

    // MARK: - Real payload seals

    func testMatchedTrueWithAttribution_sealsAndPromotes() async {
        await seedPendingState()
        respond(#"{"data":{"matched":true,"matchType":"deterministic_referrer","attribution":{"fbclid":"fb_real","adNetwork":"meta","utmCampaign":"summer"}}}"#)

        await scheduler.retryIfDue(apiClient: apiClient)

        let done = await storage.get(PaywalloConstants.deferredMatchDoneKey)
        XCTAssertEqual(done, "1")
        let state = await currentState()
        XCTAssertNil(state, "a confirmed match clears the pending state")

        let capture = tracker.get()
        XCTAssertEqual(capture?.fbclid, "fb_real")
        XCTAssertEqual(capture?.adNetwork, "meta")
        XCTAssertEqual(capture?.utmCampaign, "summer")
        XCTAssertEqual(capture?.installReferrerSource, "deferred_match")
        XCTAssertEqual(capture?.matchType, "deterministic_referrer", "matchType lives outside `attribution`")
    }

    func testMatchedTrueWithDeepLinkOnly_seals() async {
        await seedPendingState()
        respond("""
        {"data":{"matched":true,"deepLink":{"deeplinkId":"dl_1","installId":"in_1","redirectionUrl":"https://example.com/offer","expiresAt":"2026-12-31T00:00:00Z"}}}
        """)

        await scheduler.retryIfDue(apiClient: apiClient)

        let done = await storage.get(PaywalloConstants.deferredMatchDoneKey)
        XCTAssertEqual(done, "1")
        XCTAssertEqual(deepLinkStore.get()?.deeplinkId, "dl_1")
    }

    /// Retrocompat with a hypothetical un-enveloped body.
    func testUnwrappedTopLevelBody_isAccepted() async {
        await seedPendingState()
        respond(#"{"matched":true,"attribution":{"gclid":"g_real"}}"#)

        await scheduler.retryIfDue(apiClient: apiClient)

        let awaited1 = await storage.get(PaywalloConstants.deferredMatchDoneKey)
        XCTAssertEqual(awaited1, "1")
        XCTAssertEqual(tracker.get()?.gclid, "g_real")
    }

    // MARK: - Non-answers never seal

    func testMatchedFalse_doesNotSeal() async {
        await seedPendingState()
        respond(#"{"data":{"matched":false}}"#)

        await scheduler.retryIfDue(apiClient: apiClient)

        let awaited2 = await storage.get(PaywalloConstants.deferredMatchDoneKey)
        XCTAssertNil(awaited2)
        let awaited3 = await currentState()
        XCTAssertNotNil(awaited3)
    }

    /// A 5xx carrying a matched-looking body must not seal: the answer is not confirmed.
    func testServerErrorWithMatchedBody_doesNotSeal() async {
        await seedPendingState()
        respond(#"{"data":{"matched":true,"attribution":{"fbclid":"fb_real"}}}"#, status: 500)

        await scheduler.retryIfDue(apiClient: apiClient)

        let awaited4 = await storage.get(PaywalloConstants.deferredMatchDoneKey)
        XCTAssertNil(awaited4)
        let awaited5 = await currentState()?.attempts
        XCTAssertEqual(awaited5, 1)
    }

    func testNetworkError_schedulesRetry() async {
        await seedPendingState()
        DeferredMatchStubProtocol.failWithNetworkError = true

        await scheduler.retryIfDue(apiClient: apiClient)

        let awaited6 = await storage.get(PaywalloConstants.deferredMatchDoneKey)
        XCTAssertNil(awaited6)
        let awaited7 = await currentState()?.attempts
        XCTAssertEqual(awaited7, 1)
    }

    func testMalformedBody_doesNotSeal() async {
        await seedPendingState()
        respond("not json at all")

        await scheduler.retryIfDue(apiClient: apiClient)

        let awaited8 = await storage.get(PaywalloConstants.deferredMatchDoneKey)
        XCTAssertNil(awaited8)
    }

    // MARK: - Scheduling

    func testAlreadySealed_doesNotHitTheNetwork() async {
        await storage.set(PaywalloConstants.deferredMatchDoneKey, value: "1")
        await seedPendingState()

        await scheduler.retryIfDue(apiClient: apiClient)

        XCTAssertEqual(DeferredMatchStubProtocol.requestCount, 0)
    }

    func testNoPendingState_doesNothing() async {
        await scheduler.retryIfDue(apiClient: apiClient)
        XCTAssertEqual(DeferredMatchStubProtocol.requestCount, 0)
    }

    func testCorruptState_isDiscarded() async {
        await storage.set(PaywalloConstants.deferredMatchStateKey, value: "{ not json")

        await scheduler.retryIfDue(apiClient: apiClient)

        XCTAssertEqual(DeferredMatchStubProtocol.requestCount, 0)
        let awaited9 = await storage.get(PaywalloConstants.deferredMatchStateKey)
        XCTAssertNil(awaited9)
    }

    func testBeforeNextAttemptAt_doesNotHitTheNetwork() async {
        await seedPendingState(nextAttemptAt: Date().timeIntervalSince1970 * 1000 + 60_000)

        await scheduler.retryIfDue(apiClient: apiClient)

        XCTAssertEqual(DeferredMatchStubProtocol.requestCount, 0)
    }

    /// `force` exists precisely to skip the LOCAL backoff.
    func testForceSkipsLocalBackoff() async {
        await seedPendingState(nextAttemptAt: Date().timeIntervalSince1970 * 1000 + 60_000)
        respond(#"{"data":{"matched":false}}"#)

        await scheduler.retryIfDue(apiClient: apiClient, force: true)

        XCTAssertEqual(DeferredMatchStubProtocol.requestCount, 1)
    }

    /// Backpressure the server asked for explicitly binds even through `force`.
    func testRetryAfterUntilBindsEvenWithForce() async {
        await seedPendingState(retryAfterUntil: Date().timeIntervalSince1970 * 1000 + 60_000)

        await scheduler.retryIfDue(apiClient: apiClient, force: true)

        XCTAssertEqual(DeferredMatchStubProtocol.requestCount, 0)
    }

    func testForcedAttemptsRespectTheMinimumInterval() async {
        await seedPendingState(lastForcedAttemptAt: Date().timeIntervalSince1970 * 1000 - 1000)

        await scheduler.retryIfDue(apiClient: apiClient, force: true)

        XCTAssertEqual(DeferredMatchStubProtocol.requestCount, 0)
    }

    func testFirstForcedAttemptIsNeverGated() async {
        await seedPendingState(nextAttemptAt: Date().timeIntervalSince1970 * 1000 + 60_000)
        respond(#"{"data":{"matched":false}}"#)

        await scheduler.retryIfDue(apiClient: apiClient, force: true)

        XCTAssertEqual(DeferredMatchStubProtocol.requestCount, 1)
    }

    func testResponseRetryAfterHeaderSetsTheFloor() async {
        await seedPendingState()
        respond(#"{"data":{"matched":false}}"#, status: 429, headers: ["Retry-After": "120"])

        let before = Date().timeIntervalSince1970 * 1000
        await scheduler.retryIfDue(apiClient: apiClient)

        let state = await currentState()
        XCTAssertNotNil(state?.retryAfterUntil)
        XCTAssertGreaterThanOrEqual(state!.retryAfterUntil!, before + 119_000)
    }

    /// Recomputed from THIS response only: no Retry-After clears an earlier floor instead
    /// of carrying it forward forever.
    func testAbsentRetryAfterClearsThePreviousFloor() async {
        await seedPendingState(retryAfterUntil: Date().timeIntervalSince1970 * 1000 - 1000)
        respond(#"{"data":{"matched":false}}"#, status: 503)

        await scheduler.retryIfDue(apiClient: apiClient)

        let awaited10 = await currentState()?.retryAfterUntil
        XCTAssertNil(awaited10)
    }

    /// Past the 24h ceiling the answer stops being worth asking for.
    func testExpiredState_isDroppedWithoutARequest() async {
        let old = Date().timeIntervalSince1970 * 1000 - Double(PaywalloConstants.deferredMatchMaxAgeMs) - 1000
        await seedPendingState(firstAttemptAt: old)

        await scheduler.retryIfDue(apiClient: apiClient)

        XCTAssertEqual(DeferredMatchStubProtocol.requestCount, 0)
        let awaited11 = await storage.get(PaywalloConstants.deferredMatchStateKey)
        XCTAssertNil(awaited11)
    }

    /// Backoff steps: the last one repeats until the ceiling.
    func testBackoffUsesTheLastStepOnceExhausted() async {
        await seedPendingState(attempts: 7)
        respond(#"{"data":{"matched":false}}"#)

        let before = Date().timeIntervalSince1970 * 1000
        await scheduler.retryIfDue(apiClient: apiClient)

        let state = await currentState()
        XCTAssertEqual(state?.attempts, 8)
        let lastStep = Double(PaywalloConstants.deferredMatchBackoffMs.last!)
        // Equal jitter: never below half the intended backoff, never above it.
        XCTAssertGreaterThanOrEqual(state!.nextAttemptAt, before + lastStep / 2)
        XCTAssertLessThanOrEqual(state!.nextAttemptAt, before + lastStep + 1000)
    }

    /// The persisted body is re-posted verbatim — never rebuilt or re-wrapped.
    func testStartWritesTheStateAheadOfTheFirstAttempt() async {
        respond(#"{"data":{"matched":false}}"#)

        await scheduler.start(
            apiClient: apiClient,
            distinctId: "user_1",
            deviceData: nil,
            country: "BR",
            idfv: "idfv-1",
            anonId: "anon-1",
            installedAt: 1_700_000_000_000,
            rawReferrer: nil
        )

        let state = await currentState()
        XCTAssertNotNil(state)
        let decoded = try? JSONSerialization.jsonObject(with: state!.payload) as? [String: Any]
        XCTAssertEqual(decoded?["distinctId"] as? String, "user_1")
        XCTAssertEqual(decoded?["idfv"] as? String, "idfv-1")
    }

    func testStartIsSkippedWhenAlreadySealed() async {
        await storage.set(PaywalloConstants.deferredMatchDoneKey, value: "1")

        await scheduler.start(
            apiClient: apiClient,
            distinctId: "user_1",
            deviceData: nil,
            country: nil,
            idfv: nil,
            anonId: nil,
            installedAt: 1_700_000_000_000,
            rawReferrer: nil
        )

        XCTAssertEqual(DeferredMatchStubProtocol.requestCount, 0)
        let awaited12 = await storage.get(PaywalloConstants.deferredMatchStateKey)
        XCTAssertNil(awaited12)
    }
}

// MARK: - Pure helpers

final class InstallRetrySchedulerPayloadTests: XCTestCase {

    private func makeDeviceData() -> DeviceData {
        DeviceData(
            deviceId: "idfv-mock", model: "iPhone", modelId: "iPhone15,2",
            systemName: "iOS", systemVersion: "17.2", appVersion: "1.0.0", buildNumber: "100",
            bundleId: "com.test.app", brand: "Apple",
            totalDisk: 128_000_000_000, freeDisk: 64_000_000_000, totalRam: 8_000_000_000,
            carrier: "Vivo", darwinVersion: nil,
            screenWidth: 390, screenHeight: 844, screenDensity: 3.0,
            locale: "pt_BR", language: "pt-BR", timezone: "America/Sao_Paulo"
        )
    }

    private func decode(_ data: Data?) -> [String: Any] {
        guard let data = data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    func testPayloadCarriesTheJoinKeys() {
        let body = decode(buildDeferredMatchPayload(
            distinctId: "user_1", deviceData: makeDeviceData(), country: "BR",
            idfv: "idfv-1", anonId: "anon-1", installedAt: 1_700_000_000_000, rawReferrer: "https://ref"
        ))

        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["distinctId"] as? String, "user_1")
        XCTAssertEqual(body["idfv"] as? String, "idfv-1")
        XCTAssertEqual(body["installReferrer"] as? String, "https://ref")
        XCTAssertEqual(body["deviceModel"] as? String, "iPhone15,2")
        XCTAssertEqual(body["osVersion"] as? String, "17.2")
        XCTAssertEqual(body["screenWidth"] as? Int, 390)
        XCTAssertEqual(body["screenHeight"] as? Int, 844)
        XCTAssertEqual(body["timezone"] as? String, "America/Sao_Paulo")
        XCTAssertEqual(body["language"] as? String, "pt_BR")
        XCTAssertEqual(body["country"] as? String, "BR")
        XCTAssertEqual(body["fbAnonId"] as? String, "anon-1")
        XCTAssertNotNil(body["installTimestamp"] as? String)
    }

    /// Sent even when nil: "no Meta anon id on this device" and "the SDK did not look"
    /// are different answers to the server.
    func testFbAnonIdIsSentEvenWhenNil() {
        let body = decode(buildDeferredMatchPayload(
            distinctId: "user_1", deviceData: nil, country: nil,
            idfv: nil, anonId: nil, installedAt: 1_700_000_000_000, rawReferrer: nil
        ))
        XCTAssertTrue(body.keys.contains("fbAnonId"))
        XCTAssertTrue(body["fbAnonId"] is NSNull)
    }

    func testAbsentOptionalsAreOmitted() {
        let body = decode(buildDeferredMatchPayload(
            distinctId: "user_1", deviceData: nil, country: nil,
            idfv: nil, anonId: nil, installedAt: 1_700_000_000_000, rawReferrer: ""
        ))
        XCTAssertFalse(body.keys.contains("idfv"))
        XCTAssertFalse(body.keys.contains("installReferrer"))
        XCTAssertFalse(body.keys.contains("country"))
    }

    // MARK: extractDeferredAttribution

    func testOnlyWhitelistedNonEmptyStringsSurvive() {
        let input = extractDeferredAttribution([
            "adNetwork": "meta",
            "fbclid": "fb_1",
            "gclid": "",
            "ttclid": 42,
            "utmSource": "facebook",
            "unknownField": "ignored",
        ])
        XCTAssertEqual(input?.adNetwork, "meta")
        XCTAssertEqual(input?.fbclid, "fb_1")
        XCTAssertNil(input?.gclid)
        XCTAssertNil(input?.ttclid)
        XCTAssertEqual(input?.utmSource, "facebook")
    }

    func testAllTiktokFieldsAreWhitelisted() {
        let input = extractDeferredAttribution([
            "tiktokCampaignId": "c1", "tiktokAdgroupId": "g1", "tiktokAdId": "a1",
        ])
        XCTAssertEqual(input?.tiktokCampaignId, "c1")
        XCTAssertEqual(input?.tiktokAdgroupId, "g1")
        XCTAssertEqual(input?.tiktokAdId, "a1")
    }

    func testNonObjectReturnsNil() {
        XCTAssertNil(extractDeferredAttribution(nil))
        XCTAssertNil(extractDeferredAttribution("string"))
        XCTAssertNil(extractDeferredAttribution([String: Any]()))
    }

    // MARK: Retry-After

    func testRetryAfterSeconds() {
        XCTAssertEqual(parseRetryAfterMs("120", now: 0), 120_000)
    }

    func testRetryAfterNegativeSecondsClampsToZero() {
        XCTAssertEqual(parseRetryAfterMs("-5", now: 0), 0)
    }

    func testRetryAfterHttpDate() {
        let now: Double = 0
        let value = parseRetryAfterMs("Wed, 21 Oct 2015 07:28:00 GMT", now: now)
        XCTAssertNotNil(value)
        XCTAssertEqual(value!, 1_445_412_480_000, accuracy: 1000)
    }

    func testRetryAfterPastDateClampsToZero() {
        let future = Date().timeIntervalSince1970 * 1000 + 10_000_000_000
        XCTAssertEqual(parseRetryAfterMs("Wed, 21 Oct 2015 07:28:00 GMT", now: future), 0)
    }

    func testRetryAfterGarbageIsNil() {
        XCTAssertNil(parseRetryAfterMs("soon please", now: 0))
        XCTAssertNil(parseRetryAfterMs(nil, now: 0))
        XCTAssertNil(parseRetryAfterMs("", now: 0))
    }

    // MARK: jitter

    func testJitterStaysInTheEqualJitterBand() {
        for _ in 0..<200 {
            let value = jitter(30_000)
            XCTAssertGreaterThanOrEqual(value, 15_000)
            XCTAssertLessThanOrEqual(value, 30_000)
        }
    }
}
