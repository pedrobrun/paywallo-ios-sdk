import XCTest
@testable import PaywalloSDK

// MARK: - Spy batcher specialized for PaywallTracking tests
// (SpyEventBatcher from TestFactories would work but keeping a local one avoids coupling)

private final class TrackingSpyBatcher: EventBatcherProtocol {
    var enqueuedEvents: [(name: String, properties: [String: AnyCodable], priority: EventPriority)] = []

    func enqueue(name: String, properties: [String: AnyCodable], priority: EventPriority, timestamp: TimeInterval?) {
        enqueuedEvents.append((name: name, properties: properties, priority: priority))
    }

    func flush() async {}
    func dispose() {}
}

// MARK: - Isolated SessionManager helper

private func makeIsolatedSessionManager() -> (SessionManager, SecureStorage, String) {
    let suiteName = "com.paywallo.sdk.tracking.tests.\(UUID().uuidString)"
    let keychainService = suiteName
    let suite = UserDefaults(suiteName: suiteName)!
    let native = NativeStorage(service: keychainService, defaults: suite)
    let secure = SecureStorage(nativeStorage: native)
    let manager = SessionManager(secureStorage: secure, debug: false)
    return (manager, secure, suiteName)
}

// MARK: - PaywallTrackingTests

final class PaywallTrackingTests: XCTestCase {

    private var batcher: TrackingSpyBatcher!
    private var sessionManager: SessionManager!
    private var tracking: PaywallTracking!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        batcher = TrackingSpyBatcher()
        let (sm, _, suite) = makeIsolatedSessionManager()
        sessionManager = sm
        suiteName = suite
        tracking = PaywallTracking(batcher: batcher, sessionManager: sessionManager, debug: false)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - emitPaywallVisible — dual event emission

    func testEmitPaywallVisible_emitsLegacyEvent() {
        tracking.emitPaywallVisible(paywallId: "pw_123", placement: "home")

        let legacyEvent = batcher.enqueuedEvents.first(where: { $0.name == "$paywall_viewed" })
        XCTAssertNotNil(legacyEvent, "Must emit the legacy '$paywall_viewed' event")
    }

    func testEmitPaywallVisible_emitsCanonicalV2Event() {
        tracking.emitPaywallVisible(paywallId: "pw_123", placement: "home")

        let v2Event = batcher.enqueuedEvents.first(where: { $0.name == "paywall" })
        XCTAssertNotNil(v2Event, "Must emit the canonical 'paywall' V2 event")
    }

    func testEmitPaywallVisible_emitsBothEvents() {
        tracking.emitPaywallVisible(paywallId: "pw_123", placement: "home")

        XCTAssertEqual(batcher.enqueuedEvents.count, 2, "Must emit exactly 2 events (legacy + V2)")
    }

    func testEmitPaywallVisible_v2EventTypeIsOpen() {
        tracking.emitPaywallVisible(paywallId: "pw_123", placement: "home")

        let v2Event = batcher.enqueuedEvents.first(where: { $0.name == "paywall" })
        XCTAssertEqual(v2Event?.properties["type"]?.value as? String, "open")
    }

    func testEmitPaywallVisible_v2EventContainsPaywallId() {
        tracking.emitPaywallVisible(paywallId: "pw_abc", placement: "settings")

        let v2Event = batcher.enqueuedEvents.first(where: { $0.name == "paywall" })
        XCTAssertEqual(v2Event?.properties["paywall_id"]?.value as? String, "pw_abc")
    }

    func testEmitPaywallVisible_v2EventContainsPlacement() {
        tracking.emitPaywallVisible(paywallId: "pw_123", placement: "onboarding")

        let v2Event = batcher.enqueuedEvents.first(where: { $0.name == "paywall" })
        XCTAssertEqual(v2Event?.properties["placement"]?.value as? String, "onboarding")
    }

    func testEmitPaywallVisible_v2EventContainsOpenedAt() {
        let before = ISO8601DateFormatter().string(from: Date())
        tracking.emitPaywallVisible(paywallId: "pw_123", placement: "home")
        let after = ISO8601DateFormatter().string(from: Date())

        let v2Event = batcher.enqueuedEvents.first(where: { $0.name == "paywall" })
        let openedAt = v2Event?.properties["opened_at"]?.value as? String
        XCTAssertNotNil(openedAt)
        XCTAssertGreaterThanOrEqual(openedAt!, before)
        XCTAssertLessThanOrEqual(openedAt!, after)
    }

    // MARK: - emitPaywallVisible — variantKey / campaignId propagation

    func testEmitPaywallVisible_variantKey_propagatedToV2Event() {
        tracking.emitPaywallVisible(
            paywallId: "pw_123",
            placement: "home",
            variantKey: "variant_a"
        )

        let v2Event = batcher.enqueuedEvents.first(where: { $0.name == "paywall" })
        XCTAssertEqual(v2Event?.properties["variant_key"]?.value as? String, "variant_a")
    }

    func testEmitPaywallVisible_campaignId_propagatedToV2Event() {
        tracking.emitPaywallVisible(
            paywallId: "pw_123",
            placement: "home",
            campaignId: "camp_xyz"
        )

        let v2Event = batcher.enqueuedEvents.first(where: { $0.name == "paywall" })
        XCTAssertEqual(v2Event?.properties["campaign_id"]?.value as? String, "camp_xyz")
    }

    func testEmitPaywallVisible_variantKeyNil_notPresentInV2Props() {
        tracking.emitPaywallVisible(paywallId: "pw_123", placement: "home", variantKey: nil)

        let v2Event = batcher.enqueuedEvents.first(where: { $0.name == "paywall" })
        XCTAssertNil(v2Event?.properties["variant_key"])
    }

    // MARK: - emitPaywallVisible — once-per-cycle guard (viewedEmitted)

    func testEmitPaywallVisible_secondCallIsNoOp() {
        tracking.emitPaywallVisible(paywallId: "pw_123", placement: "home")
        tracking.emitPaywallVisible(paywallId: "pw_123", placement: "home")

        XCTAssertEqual(batcher.enqueuedEvents.count, 2, "Second call must be ignored by the guard")
    }

    func testEmitPaywallVisible_afterResetCycle_emitsAgain() {
        tracking.emitPaywallVisible(paywallId: "pw_123", placement: "home")
        tracking.resetCycle()
        tracking.emitPaywallVisible(paywallId: "pw_456", placement: "settings")

        XCTAssertEqual(batcher.enqueuedEvents.count, 4, "After resetCycle, a second emit must fire both events again")
    }

    func testResetCycle_allowsNewCycleWithDifferentPaywall() {
        tracking.emitPaywallVisible(paywallId: "pw_first", placement: "home")
        tracking.resetCycle()
        tracking.emitPaywallVisible(paywallId: "pw_second", placement: "settings")

        let v2Events = batcher.enqueuedEvents.filter { $0.name == "paywall" }
        let paywall1 = v2Events.first?.properties["paywall_id"]?.value as? String
        let paywall2 = v2Events.last?.properties["paywall_id"]?.value as? String
        XCTAssertEqual(paywall1, "pw_first")
        XCTAssertEqual(paywall2, "pw_second")
    }

    // MARK: - emitPaywallClosed

    func testEmitPaywallClosed_emitsPaywallEvent() {
        tracking.emitPaywallClosed(
            paywallId: "pw_123",
            placement: "home",
            durationS: 5.0,
            closeReason: "dismiss"
        )

        XCTAssertEqual(batcher.enqueuedEvents.count, 1)
        XCTAssertEqual(batcher.enqueuedEvents[0].name, "paywall")
    }

    func testEmitPaywallClosed_eventTypeIsClosed() {
        tracking.emitPaywallClosed(
            paywallId: "pw_123",
            placement: "home",
            durationS: 5.0,
            closeReason: "dismiss"
        )

        let event = batcher.enqueuedEvents.first
        XCTAssertEqual(event?.properties["type"]?.value as? String, "closed")
    }

    func testEmitPaywallClosed_containsClosedAt() {
        let before = ISO8601DateFormatter().string(from: Date())
        tracking.emitPaywallClosed(
            paywallId: "pw_123",
            placement: "home",
            durationS: 5.0,
            closeReason: "dismiss"
        )
        let after = ISO8601DateFormatter().string(from: Date())

        let closedAt = batcher.enqueuedEvents.first?.properties["closed_at"]?.value as? String
        XCTAssertNotNil(closedAt)
        XCTAssertGreaterThanOrEqual(closedAt!, before)
        XCTAssertLessThanOrEqual(closedAt!, after)
    }

    func testEmitPaywallClosed_durationS_isCorrect() {
        tracking.emitPaywallClosed(
            paywallId: "pw_123",
            placement: "home",
            durationS: 12.5,
            closeReason: "purchase"
        )

        let duration = batcher.enqueuedEvents.first?.properties["duration_s"]?.value as? Double
        XCTAssertEqual(duration, 12.5)
    }

    func testEmitPaywallClosed_closeReason_isPresent() {
        tracking.emitPaywallClosed(
            paywallId: "pw_123",
            placement: "home",
            durationS: 3.0,
            closeReason: "cta"
        )

        let reason = batcher.enqueuedEvents.first?.properties["close_reason"]?.value as? String
        XCTAssertEqual(reason, "cta")
    }

    func testEmitPaywallClosed_variantKey_presentWhenProvided() {
        tracking.emitPaywallClosed(
            paywallId: "pw_123",
            placement: "home",
            durationS: 3.0,
            closeReason: "dismiss",
            variantKey: "control"
        )

        let variantKey = batcher.enqueuedEvents.first?.properties["variant_key"]?.value as? String
        XCTAssertEqual(variantKey, "control")
    }

    func testEmitPaywallClosed_campaignId_presentWhenProvided() {
        tracking.emitPaywallClosed(
            paywallId: "pw_123",
            placement: "home",
            durationS: 3.0,
            closeReason: "dismiss",
            campaignId: "camp_42"
        )

        let campaignId = batcher.enqueuedEvents.first?.properties["campaign_id"]?.value as? String
        XCTAssertEqual(campaignId, "camp_42")
    }

    func testEmitPaywallClosed_scrollDepth_presentWhenProvided() {
        tracking.emitPaywallClosed(
            paywallId: "pw_123",
            placement: "home",
            durationS: 3.0,
            closeReason: "dismiss",
            scrollDepth: 0.75
        )

        let depth = batcher.enqueuedEvents.first?.properties["scroll_depth"]?.value as? Double
        XCTAssertEqual(depth, 0.75)
    }

    func testEmitPaywallClosed_scrollDepthNil_notInProps() {
        tracking.emitPaywallClosed(
            paywallId: "pw_123",
            placement: "home",
            durationS: 3.0,
            closeReason: "dismiss",
            scrollDepth: nil
        )

        XCTAssertNil(batcher.enqueuedEvents.first?.properties["scroll_depth"])
    }

    func testEmitPaywallClosed_priorityIsCritical() {
        tracking.emitPaywallClosed(
            paywallId: "pw_123",
            placement: "home",
            durationS: 3.0,
            closeReason: "dismiss"
        )

        XCTAssertEqual(batcher.enqueuedEvents.first?.priority, .critical)
    }

    // MARK: - emitPaywallClosed — sessionId (camelCase, igual ao RN)

    func testEmitPaywallClosed_noActiveSession_sessionIdAbsent() {
        // sessionManager has no active session — sessionId must not be injected
        tracking.emitPaywallClosed(
            paywallId: "pw_123",
            placement: "home",
            durationS: 2.0,
            closeReason: "dismiss"
        )

        XCTAssertNil(batcher.enqueuedEvents.first?.properties["sessionId"],
                     "sessionId must be absent when no session is active")
    }

    func testEmitPaywallClosed_withActiveSession_sessionIdPresent() async throws {
        try await sessionManager.startSession(distinctIdProvider: { "user_abc" })

        tracking.emitPaywallClosed(
            paywallId: "pw_123",
            placement: "home",
            durationS: 4.0,
            closeReason: "purchase"
        )

        let sessionId = batcher.enqueuedEvents.first?.properties["sessionId"]?.value as? String
        XCTAssertNotNil(sessionId, "sessionId must be present when a session is active")
        XCTAssertFalse(sessionId!.isEmpty)
    }

    func testEmitPaywallClosed_doesNotEmitSnakeCaseSessionKey() async throws {
        // O recovery de heartbeat já emitia `sessionId`; o `closed` normal emitia
        // `session_id` e metade dos rows ficava sem sessão do lado do servidor.
        try await sessionManager.startSession(distinctIdProvider: { "user_abc" })

        tracking.emitPaywallClosed(
            paywallId: "pw_123",
            placement: "home",
            durationS: 4.0,
            closeReason: "dismiss"
        )

        XCTAssertNil(batcher.enqueuedEvents.first?.properties["session_id"])
    }

    // MARK: - emitPaywallVisible — sessionId injected in V2 event
    //
    // camelCase `sessionId`, matching the RN SDK on every paywall event (viewed AND closed)
    // and the heartbeat recovery path. Emitting snake_case here left `viewed` without a
    // session server-side while `closed` had one.

    func testEmitPaywallVisible_withActiveSession_v2HasSessionId() async throws {
        try await sessionManager.startSession(distinctIdProvider: { "user_abc" })

        tracking.emitPaywallVisible(paywallId: "pw_123", placement: "home")

        let v2Event = batcher.enqueuedEvents.first(where: { $0.name == "paywall" })
        let sessionId = try XCTUnwrap(v2Event?.properties["sessionId"]?.value as? String)
        XCTAssertFalse(sessionId.isEmpty)
        XCTAssertNil(v2Event?.properties["session_id"],
                     "DESVIO: paywall events usam sessionId (camelCase), nunca session_id")
    }

    func testEmitPaywallVisible_noSession_v2LacksSessionId() {
        tracking.emitPaywallVisible(paywallId: "pw_123", placement: "home")

        let v2Event = batcher.enqueuedEvents.first(where: { $0.name == "paywall" })
        XCTAssertNil(v2Event?.properties["sessionId"])
    }

    // MARK: - emitPaywallClosed — duration_s calculation (via caller)

    func testEmitPaywallClosed_zeroDuration_isAllowed() {
        tracking.emitPaywallClosed(
            paywallId: "pw_123",
            placement: "home",
            durationS: 0.0,
            closeReason: "dismiss"
        )

        let duration = batcher.enqueuedEvents.first?.properties["duration_s"]?.value as? Double
        XCTAssertEqual(duration, 0.0)
    }

    func testEmitPaywallClosed_largeDuration_passedThrough() {
        tracking.emitPaywallClosed(
            paywallId: "pw_123",
            placement: "home",
            durationS: 1800.0,
            closeReason: "dismiss"
        )

        let duration = batcher.enqueuedEvents.first?.properties["duration_s"]?.value as? Double
        XCTAssertEqual(duration, 1800.0)
    }
}
