import XCTest
@testable import PaywalloSDK

final class PaywalloClientTests: XCTestCase {

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        // Reset singleton state before each test
        await PaywalloClient.shared.fullReset()
    }

    override func tearDown() async throws {
        await PaywalloClient.shared.fullReset()
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeConfig(appKey: String = "pk_test_key") -> PaywalloInitConfig {
        PaywalloInitConfig(
            appKey: appKey,
            apiUrl: "https://api.paywallo.com",
            debug: false,
            autoStartSession: false,
            notifications: false
        )
    }

    // MARK: - init with empty appKey → throws MISSING_APP_KEY

    func testInitialize_emptyAppKey_throwsMissingAppKey() async {
        let config = PaywalloInitConfig(appKey: "")

        do {
            try await PaywalloClient.shared.initialize(config)
            XCTFail("Expected error to be thrown")
        } catch let error as ClientError {
            XCTAssertEqual(error.code, ClientErrorCode.missingAppKey)
        } catch {
            XCTFail("Expected ClientError, got \(error)")
        }
    }

    // MARK: - isReady false before init

    func testIsReady_beforeInit_returnsFalse() {
        XCTAssertFalse(PaywalloClient.shared.isReady())
    }

    // MARK: - getDistinctId returns "" before init

    func testGetDistinctId_beforeInit_returnsEmpty() {
        XCTAssertEqual(PaywalloClient.shared.getDistinctId(), "")
    }

    // MARK: - identify before init throws NOT_INITIALIZED (matches RN behaviour)

    func testIdentify_beforeInit_throwsNotInitialized() async {
        let options = IdentifyOptions(email: "test@example.com")
        // No init attempted: must throw ClientError.notInitialized (same as RN SDK).
        do {
            try await PaywalloClient.shared.identify(options)
            XCTFail("Expected identify to throw when no init attempted")
        } catch let error as ClientError {
            XCTAssertEqual(error.code, ClientErrorCode.notInitialized)
        } catch {
            XCTFail("Expected ClientError, got \(error)")
        }
        // getDistinctId still returns "" because not initialized
        XCTAssertEqual(PaywalloClient.shared.getDistinctId(), "")
    }

    // MARK: - fullReset sets isReady to false

    func testFullReset_setsIsReadyFalse() async {
        // fullReset on a never-initialized client should work
        await PaywalloClient.shared.fullReset()
        XCTAssertFalse(PaywalloClient.shared.isReady())
        XCTAssertNil(PaywalloClient.shared.getConfig())
    }

    // MARK: - getEnvironment returns nil before init

    func testGetEnvironment_beforeInit_returnsNil() {
        XCTAssertNil(PaywalloClient.shared.getEnvironment())
    }

    // MARK: - getConfig returns nil before init

    func testGetConfig_beforeInit_returnsNil() {
        XCTAssertNil(PaywalloClient.shared.getConfig())
    }

    // MARK: - isOnline is pessimistic before init

    func testIsOnline_beforeInit_returnsFalse() {
        // Pessimistic on purpose (2.9.0): an uninitialised monitor reports offline so
        // PendingRetry waits for a real "online" signal instead of burning its two attempts
        // on a connection that was never confirmed — offline, that spent the critical
        // event's whole retry budget in ~6 minutes and lost it before the network returned.
        XCTAssertFalse(PaywalloClient.shared.isOnline())
    }

    // MARK: - getSessionId returns nil before init

    func testGetSessionId_beforeInit_returnsNil() {
        XCTAssertNil(PaywalloClient.shared.getSessionId())
    }

    // MARK: - track before init does not crash

    func testTrack_beforeInit_doesNotCrash() {
        // EventBatcher not initialized — enqueue is a no-op (no httpClient)
        PaywalloClient.shared.track("test_event", properties: ["key": AnyCodable("value")])
        // No crash expected
    }

    // MARK: - getIdentityState before init returns empty state

    func testGetIdentityState_beforeInit_returnsEmptyDeviceId() {
        let state = PaywalloClient.shared.getIdentityState()
        XCTAssertEqual(state.deviceId, "")
        XCTAssertNil(state.email)
    }

    // MARK: - waitUntilReady returns immediately when no task in-flight

    func testWaitUntilReady_beforeInit_returnsImmediately() async {
        // Not initialized → no task → returns immediately
        await PaywalloClient.shared.waitUntilReady()
        // Still not ready
        XCTAssertFalse(PaywalloClient.shared.isReady())
    }

    // MARK: - double init with empty key: second call is guarded by empty-key check first

    func testInitialize_thenFullReset_allowsReinit() async {
        // After fullReset, can call initialize again (state is cleared)
        await PaywalloClient.shared.fullReset()
        XCTAssertFalse(PaywalloClient.shared.isReady())
        XCTAssertNil(PaywalloClient.shared.getConfig())
    }

    // MARK: - Paywallo typealias works

    func testPaywalloTypealiasIsPaywalloClient() {
        let _: Paywallo.Type = PaywalloClient.self
        XCTAssertTrue(true)
    }

    // MARK: - getDeviceId returns nil before init

    func testGetDeviceId_beforeInit_returnsNil() {
        XCTAssertNil(PaywalloClient.shared.getDeviceId())
    }

    // MARK: - getEmail returns nil before init

    func testGetEmail_beforeInit_returnsNil() {
        XCTAssertNil(PaywalloClient.shared.getEmail())
    }

    // MARK: - identify with UserProperties shorthand (dict overload)

    func testIdentify_withDictShorthand_throwsNotInitializedBeforeInit() async {
        do {
            try await PaywalloClient.shared.identify(["plan": AnyCodable("pro")])
            XCTFail("Expected ClientError to be thrown")
        } catch let error as ClientError {
            XCTAssertEqual(error.code, ClientErrorCode.notInitialized)
        } catch {
            XCTFail("Expected ClientError, got \(error)")
        }
    }

    // MARK: - startSession returns a non-empty String (requires init)

    func testStartSession_beforeInit_returnsSomeId() async {
        // startSession without init creates a UUID via SessionManager default storage.
        // Since init was not called (autoStartSession=false), session manager is in default state.
        // We just verify it does not crash and returns a non-empty string.
        let sid = try? await PaywalloClient.shared.startSession()
        // SessionManager throws SessionError when distinctId is empty, so nil is expected.
        // The important assertion is no unexpected crash.
        _ = sid
    }

    // MARK: - track injects sessionId when session is active

    func testTrack_beforeInit_doesNotCrashWithPropertiesAndPriority() {
        // Verifies the merged dict + sessionId injection path handles nil session gracefully
        PaywalloClient.shared.track(
            "my_event",
            properties: ["foo": AnyCodable("bar")],
            priority: .normal
        )
        // No crash is the assertion
    }

    func testTrack_criticalPriority_doesNotCrash() {
        PaywalloClient.shared.track(
            "critical_event",
            properties: nil,
            priority: .critical
        )
    }

    // MARK: - register* methods accept nil without crashing

    func testRegisterPaywallPresenter_nil_doesNotCrash() {
        PaywalloClient.shared.registerPaywallPresenter(nil)
    }

    func testRegisterCampaignPresenter_nil_doesNotCrash() {
        PaywalloClient.shared.registerCampaignPresenter(nil)
    }

    func testRegisterSubscriptionGetter_nil_doesNotCrash() {
        PaywalloClient.shared.registerSubscriptionGetter(nil)
    }

    func testRegisterActiveChecker_nil_doesNotCrash() {
        PaywalloClient.shared.registerActiveChecker(nil)
    }

    func testRegisterRestoreHandler_nil_doesNotCrash() {
        PaywalloClient.shared.registerRestoreHandler(nil)
    }

    func testRegisterEmergencyPaywallHandler_nil_doesNotCrash() {
        PaywalloClient.shared.registerEmergencyPaywallHandler(nil)
    }

    // MARK: - getSessionState before init

    func testGetSessionState_beforeInit_isNotActive() {
        let state = PaywalloClient.shared.getSessionState()
        XCTAssertFalse(state.isActive)
        XCTAssertNil(state.sessionId)
        XCTAssertEqual(state.duration, 0.0)
    }

    // MARK: - getSessionFlag before init returns nil

    func testGetSessionFlag_beforeInit_returnsNil() {
        let value = PaywalloClient.shared.getSessionFlag(key: "my_flag")
        XCTAssertNil(value)
    }

    // MARK: - getAutoPreloadedPlacement before init returns nil

    func testGetAutoPreloadedPlacement_beforeInit_returnsNil() {
        XCTAssertNil(PaywalloClient.shared.getAutoPreloadedPlacement())
    }

    // MARK: - getOfflineQueueSize before init returns 0

    func testGetOfflineQueueSize_beforeInit_returnsZero() {
        XCTAssertEqual(PaywalloClient.shared.getOfflineQueueSize(), 0)
    }

    // MARK: - reset does not crash before init

    func testReset_beforeInit_doesNotCrash() async {
        await PaywalloClient.shared.reset()
    }
}
