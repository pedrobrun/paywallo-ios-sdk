import XCTest
@testable import PaywalloSDK

// MARK: - SessionTrackingTests

final class SessionTrackingTests: XCTestCase {

    private var spy: SpyEventBatcher!
    private var tracking: SessionTracking!

    override func setUp() {
        super.setUp()
        spy = SpyEventBatcher()
        tracking = SessionTracking(
            batcher: spy,
            distinctIdProvider: { "user_test_123" },
            debug: false
        )
    }

    // MARK: - trackSessionStart

    func testTrackSessionStart_emitsSessionStartEventName() async {
        await tracking.trackSessionStart(sessionId: "sess_abc")

        XCTAssertEqual(spy.enqueuedEvents.count, 1)
        XCTAssertEqual(spy.enqueuedEvents[0].name, "$session_start")
    }

    func testTrackSessionStart_includesSessionId() async {
        await tracking.trackSessionStart(sessionId: "sess_abc")

        let props = spy.enqueuedEvents[0].properties
        XCTAssertEqual(props["sessionId"]?.value as? String, "sess_abc")
    }

    func testTrackSessionStart_includesTimestamp() async {
        let before = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-1))
        await tracking.trackSessionStart(sessionId: "sess_abc")
        let after = ISO8601DateFormatter().string(from: Date().addingTimeInterval(1))

        let props = spy.enqueuedEvents[0].properties
        let ts = props["timestamp"]?.value as? String
        XCTAssertNotNil(ts)
        XCTAssertGreaterThanOrEqual(ts!, before)
        XCTAssertLessThanOrEqual(ts!, after)
    }

    func testTrackSessionStart_includesAppVersion() async {
        await tracking.trackSessionStart(sessionId: "sess_abc")

        let props = spy.enqueuedEvents[0].properties
        XCTAssertNotNil(props["appVersion"])
    }

    func testTrackSessionStart_includesDeviceModel() async {
        await tracking.trackSessionStart(sessionId: "sess_abc")

        let props = spy.enqueuedEvents[0].properties
        XCTAssertNotNil(props["deviceModel"])
    }

    func testTrackSessionStart_includesOsVersion() async {
        await tracking.trackSessionStart(sessionId: "sess_abc")

        let props = spy.enqueuedEvents[0].properties
        XCTAssertNotNil(props["osVersion"])
    }

    func testTrackSessionStart_sessionIdMatchesProvided() async {
        await tracking.trackSessionStart(sessionId: "my_session_id")

        let props = spy.enqueuedEvents[0].properties
        XCTAssertEqual(props["sessionId"]?.value as? String, "my_session_id")
    }

    // MARK: - trackSessionEnd

    func testTrackSessionEnd_emitsLifecycleEvent() {
        tracking.trackSessionEnd(sessionId: "sess_abc", durationS: 42.0)

        XCTAssertEqual(spy.enqueuedEvents.count, 1)
        XCTAssertEqual(spy.enqueuedEvents[0].name, "lifecycle")
    }

    func testTrackSessionEnd_typeIsSessionEnd() {
        tracking.trackSessionEnd(sessionId: "sess_abc", durationS: 42.0)

        let props = spy.enqueuedEvents[0].properties
        XCTAssertEqual(props["type"]?.value as? String, "session_end")
    }

    func testTrackSessionEnd_includesSessionId() {
        tracking.trackSessionEnd(sessionId: "sess_abc", durationS: 42.0)

        let props = spy.enqueuedEvents[0].properties
        XCTAssertEqual(props["session_id"]?.value as? String, "sess_abc")
    }

    func testTrackSessionEnd_includesDurationS() {
        tracking.trackSessionEnd(sessionId: "sess_abc", durationS: 42.0)

        let props = spy.enqueuedEvents[0].properties
        XCTAssertEqual(props["duration_s"]?.value as? Double, 42.0)
    }

    func testTrackSessionEnd_includesEndedAt() {
        let before = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-1))
        tracking.trackSessionEnd(sessionId: "sess_abc", durationS: 0)
        let after = ISO8601DateFormatter().string(from: Date().addingTimeInterval(1))

        let props = spy.enqueuedEvents[0].properties
        let endedAt = props["ended_at"]?.value as? String
        XCTAssertNotNil(endedAt)
        XCTAssertGreaterThanOrEqual(endedAt!, before)
        XCTAssertLessThanOrEqual(endedAt!, after)
    }

    func testTrackSessionEnd_withStartedAtMs_includesStartedAt() {
        let startMs = Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1000)
        tracking.trackSessionEnd(sessionId: "sess_abc", durationS: 60.0, startedAtMs: startMs)

        let props = spy.enqueuedEvents[0].properties
        XCTAssertNotNil(props["started_at"])
    }

    func testTrackSessionEnd_nilStartedAtMs_noStartedAtKey() {
        tracking.trackSessionEnd(sessionId: "sess_abc", durationS: 60.0, startedAtMs: nil)

        let props = spy.enqueuedEvents[0].properties
        XCTAssertNil(props["started_at"])
    }

    func testTrackSessionEnd_zeroDuration_isValid() {
        tracking.trackSessionEnd(sessionId: "sess_abc", durationS: 0.0)

        let props = spy.enqueuedEvents[0].properties
        XCTAssertEqual(props["duration_s"]?.value as? Double, 0.0)
    }

    // MARK: - trackAppOpen

    func testTrackAppOpen_emitsLifecycleEvent() {
        tracking.trackAppOpen(sessionId: "sess_abc")

        XCTAssertEqual(spy.enqueuedEvents.count, 1)
        XCTAssertEqual(spy.enqueuedEvents[0].name, "lifecycle")
    }

    func testTrackAppOpen_typeIsForeground() {
        tracking.trackAppOpen(sessionId: "sess_abc")

        let props = spy.enqueuedEvents[0].properties
        XCTAssertEqual(props["type"]?.value as? String, "foreground")
    }

    func testTrackAppOpen_includesSessionId() {
        tracking.trackAppOpen(sessionId: "sess_open")

        let props = spy.enqueuedEvents[0].properties
        XCTAssertEqual(props["session_id"]?.value as? String, "sess_open")
    }

    // MARK: - trackAppBackground

    func testTrackAppBackground_emitsLifecycleEvent() {
        tracking.trackAppBackground(sessionId: "sess_abc", durationS: 5.0)

        XCTAssertEqual(spy.enqueuedEvents.count, 1)
        XCTAssertEqual(spy.enqueuedEvents[0].name, "lifecycle")
    }

    func testTrackAppBackground_typeIsBackground() {
        tracking.trackAppBackground(sessionId: "sess_abc", durationS: 5.0)

        let props = spy.enqueuedEvents[0].properties
        XCTAssertEqual(props["type"]?.value as? String, "background")
    }

    func testTrackAppBackground_includesSessionId() {
        tracking.trackAppBackground(sessionId: "sess_bg", durationS: 5.0)

        let props = spy.enqueuedEvents[0].properties
        XCTAssertEqual(props["session_id"]?.value as? String, "sess_bg")
    }

    func testTrackAppBackground_includesDurationS() {
        tracking.trackAppBackground(sessionId: "sess_abc", durationS: 123.5)

        let props = spy.enqueuedEvents[0].properties
        XCTAssertEqual(props["duration_s"]?.value as? Double, 123.5)
    }

    func testTrackAppBackground_zeroDuration_isValid() {
        tracking.trackAppBackground(sessionId: "sess_abc", durationS: 0.0)

        let props = spy.enqueuedEvents[0].properties
        XCTAssertEqual(props["duration_s"]?.value as? Double, 0.0)
    }
}
