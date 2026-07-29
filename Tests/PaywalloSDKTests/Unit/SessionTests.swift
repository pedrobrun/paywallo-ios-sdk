import XCTest
@testable import PaywalloSDK

// MARK: - Helpers

private func makeIsolatedSessionStorage(id: String = UUID().uuidString) -> (SecureStorage, NativeStorage, String) {
    let suiteName = "com.paywallo.sdk.session.tests.\(id)"
    let suite = UserDefaults(suiteName: suiteName)!
    let keychainService = "com.paywallo.sdk.session.tests.\(id)"
    let native = NativeStorage(service: keychainService, defaults: suite)
    let secure = SecureStorage(nativeStorage: native)
    return (secure, native, suiteName)
}

// MARK: - SessionManager Tests

final class SessionManagerTests: XCTestCase {

    private var secureStorage: SecureStorage!
    private var native: NativeStorage!
    private var suiteName: String!
    private var manager: SessionManager!

    // A provider that always returns a valid distinctId
    private let validProvider: () -> String = { "user_abc123" }
    // A provider that always returns empty (unavailable)
    private let emptyProvider: () -> String = { "" }

    override func setUp() {
        super.setUp()
        let (s, n, name) = makeIsolatedSessionStorage()
        secureStorage = s
        native = n
        suiteName = name
        manager = SessionManager(secureStorage: s, debug: false)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - getSessionId before any session

    func testGetSessionId_beforeStart_returnsNil() {
        XCTAssertNil(manager.getSessionId())
    }

    // MARK: - isSessionActive before any session

    func testIsSessionActive_beforeStart_returnsFalse() {
        XCTAssertFalse(manager.isSessionActive())
    }

    // MARK: - startSession creates new UUID session

    func testStartSession_createsNonNilSessionId() async throws {
        try await manager.startSession(distinctIdProvider: validProvider)
        XCTAssertNotNil(manager.getSessionId())
    }

    func testStartSession_sessionIdIsValidUUID() async throws {
        try await manager.startSession(distinctIdProvider: validProvider)
        let sid = manager.getSessionId()!
        XCTAssertNotNil(UUID(uuidString: sid), "Session ID should be a valid UUID")
    }

    func testStartSession_isSessionActiveAfterStart() async throws {
        try await manager.startSession(distinctIdProvider: validProvider)
        XCTAssertTrue(manager.isSessionActive())
    }

    // MARK: - startSession persists to storage

    func testStartSession_persistsSessionId() async throws {
        try await manager.startSession(distinctIdProvider: validProvider)
        let sid = manager.getSessionId()!

        let stored = await secureStorage.get(PaywalloConstants.currentSessionIdKey)
        XCTAssertEqual(stored, sid)
    }

    func testStartSession_persistsSessionStart() async throws {
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        try await manager.startSession(distinctIdProvider: validProvider)
        let after = Int64(Date().timeIntervalSince1970 * 1000)

        let storedStr = await secureStorage.get(PaywalloConstants.sessionStartKey)
        XCTAssertNotNil(storedStr)
        let storedMs = Int64(storedStr!)!
        XCTAssertGreaterThanOrEqual(storedMs, before)
        XCTAssertLessThanOrEqual(storedMs, after)
    }

    // MARK: - startSession generates new ID each time

    func testStartSession_eachCallGeneratesNewSessionId() async throws {
        try await manager.startSession(distinctIdProvider: validProvider)
        let first = manager.getSessionId()!

        // Second call ends first session, starts new one
        try await manager.startSession(distinctIdProvider: validProvider)
        let second = manager.getSessionId()!

        XCTAssertNotEqual(first, second)
    }

    // MARK: - startSession fails when no distinctId

    func testStartSession_noDistinctId_throws() async {
        do {
            try await manager.startSession(distinctIdProvider: emptyProvider)
            XCTFail("Expected SessionError to be thrown")
        } catch let err as SessionError {
            XCTAssertEqual(err.code, SessionErrorCode.startFailed)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - endSession clears storage

    func testEndSession_clearsSessionId() async throws {
        try await manager.startSession(distinctIdProvider: validProvider)
        await manager.endSession()
        XCTAssertNil(manager.getSessionId())
    }

    func testEndSession_isSessionActiveReturnsFalse() async throws {
        try await manager.startSession(distinctIdProvider: validProvider)
        await manager.endSession()
        XCTAssertFalse(manager.isSessionActive())
    }

    func testEndSession_removesStoredSessionId() async throws {
        try await manager.startSession(distinctIdProvider: validProvider)
        await manager.endSession()

        let stored = await secureStorage.get(PaywalloConstants.currentSessionIdKey)
        XCTAssertNil(stored)
    }

    func testEndSession_removesStoredSessionStart() async throws {
        try await manager.startSession(distinctIdProvider: validProvider)
        await manager.endSession()

        let stored = await secureStorage.get(PaywalloConstants.sessionStartKey)
        XCTAssertNil(stored)
    }

    // MARK: - endSession calculates duration

    func testEndSession_returnsDurationGreaterThanOrEqualZero() async throws {
        try await manager.startSession(distinctIdProvider: validProvider)
        let duration = await manager.endSession()
        XCTAssertGreaterThanOrEqual(duration, 0.0)
    }

    func testEndSession_beforeStart_returnsZero() async {
        let duration = await manager.endSession()
        XCTAssertEqual(duration, 0.0)
    }

    // MARK: - Session restore: elapsed < timeout → restores

    func testRestoreIfValid_freshSession_restores() async throws {
        // Write a session that started 1 minute ago
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let startMs = nowMs - 60_000  // 1 minute ago (within 30-min timeout)
        let testId = "test-session-uuid"

        await secureStorage.set(PaywalloConstants.currentSessionIdKey, value: testId)
        await secureStorage.set(PaywalloConstants.sessionStartKey, value: String(startMs))

        await manager.restoreIfValid()

        XCTAssertEqual(manager.getSessionId(), testId)
        XCTAssertTrue(manager.isSessionActive())
    }

    // MARK: - Session restore: elapsed > timeout → clears

    func testRestoreIfValid_expiredSession_clears() async throws {
        // Write a session that started 31 minutes ago (past 30-min timeout)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let startMs = nowMs - 31 * 60 * 1000  // 31 minutes ago
        let testId = "expired-session-uuid"

        await secureStorage.set(PaywalloConstants.currentSessionIdKey, value: testId)
        await secureStorage.set(PaywalloConstants.sessionStartKey, value: String(startMs))

        await manager.restoreIfValid()

        XCTAssertNil(manager.getSessionId())
        XCTAssertFalse(manager.isSessionActive())
    }

    func testRestoreIfValid_expiredSession_removesFromStorage() async throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let startMs = nowMs - 35 * 60 * 1000  // 35 min ago

        await secureStorage.set(PaywalloConstants.currentSessionIdKey, value: "old-id")
        await secureStorage.set(PaywalloConstants.sessionStartKey, value: String(startMs))

        await manager.restoreIfValid()

        let stored = await secureStorage.get(PaywalloConstants.currentSessionIdKey)
        XCTAssertNil(stored)
    }

    func testRestoreIfValid_missingStorage_noSession() async {
        // Nothing stored — should result in no active session
        await manager.restoreIfValid()
        XCTAssertNil(manager.getSessionId())
    }

    // MARK: - Emergency paywall shown flag

    func testEmergencyPaywallShown_defaultFalse() async throws {
        try await manager.startSession(distinctIdProvider: validProvider)
        let shown = await manager.hasEmergencyPaywallBeenShown()
        XCTAssertFalse(shown)
    }

    func testEmergencyPaywallShown_afterMark_returnsTrue() async throws {
        try await manager.startSession(distinctIdProvider: validProvider)
        await manager.markEmergencyPaywallShown()
        let shown = await manager.hasEmergencyPaywallBeenShown()
        XCTAssertTrue(shown)
    }

    func testEmergencyPaywallShown_noSession_returnsFalse() async {
        // No active session — should always be false
        await manager.markEmergencyPaywallShown()
        let shown = await manager.hasEmergencyPaywallBeenShown()
        XCTAssertFalse(shown)
    }

    func testEmergencyPaywallFlag_clearedOnSessionEnd() async throws {
        try await manager.startSession(distinctIdProvider: validProvider)
        await manager.markEmergencyPaywallShown()

        await manager.endSession()

        // After session ends, start fresh and flag should be gone
        try await manager.startSession(distinctIdProvider: validProvider)
        let shown = await manager.hasEmergencyPaywallBeenShown()
        XCTAssertFalse(shown)
    }

    // MARK: - getSessionStartMs

    func testGetSessionStartMs_beforeStart_returnsNil() {
        XCTAssertNil(manager.getSessionStartMs())
    }

    func testGetSessionStartMs_afterStart_returnsValue() async throws {
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        try await manager.startSession(distinctIdProvider: validProvider)
        let after = Int64(Date().timeIntervalSince1970 * 1000)

        let startMs = manager.getSessionStartMs()
        XCTAssertNotNil(startMs)
        XCTAssertGreaterThanOrEqual(startMs!, before)
        XCTAssertLessThanOrEqual(startMs!, after)
    }

    func testGetSessionStartMs_afterEnd_returnsNil() async throws {
        try await manager.startSession(distinctIdProvider: validProvider)
        await manager.endSession()
        XCTAssertNil(manager.getSessionStartMs())
    }
}
