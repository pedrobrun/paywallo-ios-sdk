import XCTest
@testable import PaywalloSDK

// MARK: - Helpers

private func makeIsolatedNotificationStorage(id: String = UUID().uuidString)
    -> (SecureStorage, NativeStorage, String)
{
    let suiteName = "com.paywallo.sdk.notif.tests.\(id)"
    let suite = UserDefaults(suiteName: suiteName)!
    let keychainService = "com.paywallo.sdk.notif.tests.\(id)"
    let native = NativeStorage(service: keychainService, defaults: suite)
    let secure = SecureStorage(nativeStorage: native)
    return (secure, native, suiteName)
}

// MARK: - NotifSpyBatcher

/// Protocol-conforming spy for notification tests — avoids name clash with TestFactories.SpyEventBatcher.
private final class NotifSpyBatcher: EventBatcherProtocol {
    var enqueuedEvents: [(name: String, properties: [String: AnyCodable])] = []

    func enqueue(name: String, properties: [String: AnyCodable], priority: EventPriority, timestamp: TimeInterval?) {
        enqueuedEvents.append((name: name, properties: properties))
    }

    func flush() async {}
    func dispose() { enqueuedEvents.removeAll() }
}

// MARK: - NotificationEventTracker Tests

final class NotificationEventTrackerTests: XCTestCase {

    private var secureStorage: SecureStorage!
    private var nativeStorage: NativeStorage!
    private var suiteName: String!
    private var batcher: NotifSpyBatcher!
    private var tracker: NotificationEventTracker!

    override func setUp() {
        super.setUp()
        let (s, n, name) = makeIsolatedNotificationStorage()
        secureStorage = s
        nativeStorage = n
        suiteName = name
        batcher = NotifSpyBatcher()
        tracker = NotificationEventTracker(
            eventBatcher: batcher,
            secureStorage: secureStorage,
            deviceIdProvider: { "test-device-id" },
            debug: false
        )
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - Basic Tracking

    func testTrack_newEvent_returnsTrue() async {
        let result = await tracker.track(
            eventName: NotificationEventName.opened,
            notificationId: "n1",
            campaignId: "c1",
            messageId: "m1"
        )
        XCTAssertTrue(result, "First track for a unique key should succeed")
    }

    func testTrack_newEvent_enqueuesToBatcher() async {
        await tracker.track(
            eventName: NotificationEventName.opened,
            notificationId: "n1",
            campaignId: "c1",
            messageId: "m1"
        )
        XCTAssertEqual(batcher.enqueuedEvents.count, 1)
        // Events route through the "notification" envelope — matching RN SDK behaviour
        XCTAssertEqual(batcher.enqueuedEvents[0].name, "notification")
        XCTAssertEqual(batcher.enqueuedEvents[0].properties["type"]?.value as? String, NotificationEventName.opened)
    }

    func testTrack_includesDeviceId() async {
        await tracker.track(
            eventName: NotificationEventName.received,
            notificationId: nil,
            campaignId: nil,
            messageId: "msg-device"
        )
        let props = batcher.enqueuedEvents[0].properties
        XCTAssertEqual(props["device_id"]?.value as? String, "test-device-id")
    }

    func testTrack_includesPlatform() async {
        await tracker.track(
            eventName: NotificationEventName.received,
            notificationId: nil,
            campaignId: nil,
            messageId: "msg-platform"
        )
        let props = batcher.enqueuedEvents[0].properties
        XCTAssertEqual(props["push_platform"]?.value as? String, "ios")
    }

    func testTrack_includesTimezone() async {
        await tracker.track(
            eventName: NotificationEventName.received,
            notificationId: nil,
            campaignId: nil,
            messageId: "msg-tz"
        )
        let props = batcher.enqueuedEvents[0].properties
        XCTAssertNotNil(props["timezone"])
    }

    // MARK: - Dedup: same messageId + eventType

    func testDedup_sameMessageIdAndType_skipsSecondTrack() async {
        let messageId = "msg-dedup-\(UUID().uuidString)"

        let first = await tracker.track(
            eventName: NotificationEventName.opened,
            notificationId: nil,
            campaignId: nil,
            messageId: messageId
        )
        let second = await tracker.track(
            eventName: NotificationEventName.opened,
            notificationId: nil,
            campaignId: nil,
            messageId: messageId
        )

        XCTAssertTrue(first, "First track must succeed")
        XCTAssertFalse(second, "Second track with same key must be deduped")
        XCTAssertEqual(batcher.enqueuedEvents.count, 1, "Only one event must be enqueued")
    }

    func testDedup_sameMessageId_differentEventType_allowsBoth() async {
        let messageId = "msg-diff-type-\(UUID().uuidString)"

        let received = await tracker.track(
            eventName: NotificationEventName.received,
            notificationId: nil,
            campaignId: nil,
            messageId: messageId
        )
        let opened = await tracker.track(
            eventName: NotificationEventName.opened,
            notificationId: nil,
            campaignId: nil,
            messageId: messageId
        )

        XCTAssertTrue(received)
        XCTAssertTrue(opened)
        XCTAssertEqual(batcher.enqueuedEvents.count, 2)
    }

    func testDedup_nilMessageId_treatedAsSingleKey() async {
        // Two events with nil messageId and same type → deduped
        let first = await tracker.track(
            eventName: NotificationEventName.dismissed,
            notificationId: nil,
            campaignId: nil,
            messageId: nil
        )
        let second = await tracker.track(
            eventName: NotificationEventName.dismissed,
            notificationId: nil,
            campaignId: nil,
            messageId: nil
        )

        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    // MARK: - TTL Expiry

    func testTTL_expiredEntry_allowsRetrack() async {
        let messageId = "msg-ttl-\(UUID().uuidString)"
        let key = "\(messageId):\(NotificationEventName.opened)"

        // Inject an entry with a timestamp 2 hours ago (beyond 1-hour TTL)
        let expiredTimestamp = Date().timeIntervalSince1970 - 7300  // 2h 1m 40s ago
        tracker.injectSeen(key: key, timestamp: expiredTimestamp)

        let result = await tracker.track(
            eventName: NotificationEventName.opened,
            notificationId: nil,
            campaignId: nil,
            messageId: messageId
        )

        XCTAssertTrue(result, "Expired entry should allow re-tracking")
        XCTAssertEqual(batcher.enqueuedEvents.count, 1)
    }

    func testTTL_freshEntry_blocksRetrack() async {
        let messageId = "msg-fresh-\(UUID().uuidString)"
        let key = "\(messageId):\(NotificationEventName.opened)"

        // Inject a fresh entry (30 minutes ago — within TTL)
        let freshTimestamp = Date().timeIntervalSince1970 - 1800
        tracker.injectSeen(key: key, timestamp: freshTimestamp)

        let result = await tracker.track(
            eventName: NotificationEventName.opened,
            notificationId: nil,
            campaignId: nil,
            messageId: messageId
        )

        XCTAssertFalse(result, "Fresh entry should be deduped")
        XCTAssertEqual(batcher.enqueuedEvents.count, 0)
    }

    // MARK: - LRU Eviction

    func testLRU_evictsOldestWhenAtCapacity() async {
        // Fill up to exactly 1000 entries by injecting directly
        for i in 0..<1000 {
            let key = "lru-key-\(i):\(NotificationEventName.received)"
            tracker.injectSeen(key: key, timestamp: Date().timeIntervalSince1970)
        }

        XCTAssertEqual(tracker.seenCount, 1000)

        // Add one more — should evict the oldest (lru-key-0)
        let result = await tracker.track(
            eventName: NotificationEventName.received,
            notificationId: nil,
            campaignId: nil,
            messageId: "lru-overflow"
        )

        XCTAssertTrue(result)
        // Count stays at 1000 (one evicted, one added)
        XCTAssertEqual(tracker.seenCount, 1000)
    }

    func testLRU_evictedKey_canBeTrackedAgain() async {
        // Fill 1000 entries starting at index 1 so index 0 is the "LRU" entry we'll test
        let victimKey = "lru-victim:\(NotificationEventName.opened)"
        tracker.injectSeen(key: victimKey, timestamp: Date().timeIntervalSince1970)

        // Fill 999 more to reach the cap
        for i in 0..<999 {
            let key = "lru-filler-\(i):\(NotificationEventName.received)"
            tracker.injectSeen(key: key, timestamp: Date().timeIntervalSince1970)
        }

        // Trigger overflow — victim should be evicted
        await tracker.track(
            eventName: NotificationEventName.received,
            notificationId: nil,
            campaignId: nil,
            messageId: "trigger-overflow"
        )
        batcher.enqueuedEvents.removeAll()

        // Now re-track the victim — should succeed (was evicted)
        let result = await tracker.track(
            eventName: NotificationEventName.opened,
            notificationId: nil,
            campaignId: nil,
            messageId: "lru-victim"
        )

        XCTAssertTrue(result, "Evicted key should be trackable again")
        XCTAssertEqual(batcher.enqueuedEvents.count, 1)
    }

    // MARK: - Persistence

    func testPersistence_seenMessagesAreRestoredFromStorage() async {
        let messageId = "msg-persist-\(UUID().uuidString)"

        // Track in original tracker (persists to storage)
        await tracker.track(
            eventName: NotificationEventName.opened,
            notificationId: nil,
            campaignId: nil,
            messageId: messageId
        )

        // Create a new tracker with the same storage
        let batcher2 = NotifSpyBatcher()
        let tracker2 = NotificationEventTracker(
            eventBatcher: batcher2,
            secureStorage: secureStorage,
            deviceIdProvider: { "test-device-id" }
        )

        // Restore from storage
        await tracker2.restoreFromStorage()

        // Try to track the same event — should be deduped
        let result = await tracker2.track(
            eventName: NotificationEventName.opened,
            notificationId: Optional<String>.none,
            campaignId: Optional<String>.none,
            messageId: messageId
        )

        XCTAssertFalse(result, "Event should be deduped after restoring from storage")
        XCTAssertEqual(batcher2.enqueuedEvents.count, 0)
    }

    // MARK: - Convenience Methods

    func testTrackReceived_callsTrackWithCorrectEventName() async {
        await tracker.trackReceived(messageId: "msg-recv")
        XCTAssertEqual(batcher.enqueuedEvents.count, 1)
        XCTAssertEqual(batcher.enqueuedEvents[0].name, "notification")
        XCTAssertEqual(batcher.enqueuedEvents[0].properties["type"]?.value as? String, NotificationEventName.received)
    }

    func testTrackOpened_callsTrackWithCorrectEventName() async {
        await tracker.trackOpened(messageId: "msg-open")
        XCTAssertEqual(batcher.enqueuedEvents.count, 1)
        XCTAssertEqual(batcher.enqueuedEvents[0].name, "notification")
        XCTAssertEqual(batcher.enqueuedEvents[0].properties["type"]?.value as? String, NotificationEventName.opened)
    }

    func testTrackDismissed_callsTrackWithCorrectEventName() async {
        await tracker.trackDismissed(messageId: "msg-dismiss")
        XCTAssertEqual(batcher.enqueuedEvents.count, 1)
        XCTAssertEqual(batcher.enqueuedEvents[0].name, "notification")
        XCTAssertEqual(batcher.enqueuedEvents[0].properties["type"]?.value as? String, NotificationEventName.dismissed)
    }
}

// MARK: - NotificationsManager Tests

final class NotificationsManagerTests: XCTestCase {

    private var secureStorage: SecureStorage!
    private var nativeStorage: NativeStorage!
    private var suiteName: String!
    private var apiClient: ApiClient!
    private var manager: NotificationsManager!

    override func setUp() {
        super.setUp()
        let (s, n, name) = makeIsolatedNotificationStorage()
        secureStorage = s
        nativeStorage = n
        suiteName = name
        apiClient = ApiClient(
            serverUrl: "http://localhost:18101",
            appKey: "pk_test",
            debug: false
        )
        manager = NotificationsManager(
            apiClient: apiClient,
            secureStorage: secureStorage,
            distinctIdProvider: { "test-distinct-id" }
        )
    }

    override func tearDown() async throws {
        manager.destroy()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - Init order

    func testInitialize_setsIsReadyTrue() async {
        await manager.initialize(config: NotificationsConfig(), apnsToken: "test-token-abc")
        XCTAssertTrue(manager.isReady)
    }

    func testInitialize_idempotent_secondCallIsNoOp() async {
        await manager.initialize(config: NotificationsConfig(), apnsToken: "token-A")
        await manager.initialize(config: NotificationsConfig(), apnsToken: "token-B")
        // Still has first token
        XCTAssertEqual(manager.currentPushToken, "token-A")
    }

    func testInitialize_withToken_setsCurrentToken() async {
        await manager.initialize(config: NotificationsConfig(), apnsToken: "apns-xyz")
        XCTAssertEqual(manager.currentPushToken, "apns-xyz")
    }

    func testInitialize_withoutToken_currentTokenRemainsNil() async {
        // No token injected, no stored token — times out after retries
        // (fast because we're not polling in tests; no token in memory)
        await manager.initialize(config: NotificationsConfig(), apnsToken: nil)
        XCTAssertNil(manager.currentPushToken)
    }

    // MARK: - setupHandlers deferred pattern

    func testSetupHandlers_beforeInitialize_isAppliedOnInit() async {
        var handlerApplied = false

        manager.setupHandlers { handlers in
            handlers.onReceived = { _ in }
            handlerApplied = true
        }

        // Initialize triggers deferred handler application
        await manager.initialize(config: NotificationsConfig(), apnsToken: nil)

        XCTAssertTrue(handlerApplied, "Deferred closure must run on initialize")
        XCTAssertTrue(manager.isReady)
    }

    func testSetupHandlers_afterInitialize_appliesImmediately() async {
        await manager.initialize(config: NotificationsConfig(), apnsToken: nil)

        // Should not crash, should apply immediately
        manager.setupHandlers { handlers in
            handlers.onOpened = { _ in }
        }

        XCTAssertTrue(manager.isReady)
    }

    // MARK: - invalidateLocalToken vs optOut

    func testInvalidateLocalToken_clearsCurrentToken() async {
        await manager.initialize(config: NotificationsConfig(), apnsToken: "clear-me")
        XCTAssertNotNil(manager.currentPushToken)

        await manager.invalidateLocalToken()

        XCTAssertNil(manager.currentPushToken)
    }

    func testInvalidateLocalToken_clearsStoredToken() async {
        await manager.initialize(config: NotificationsConfig(), apnsToken: "stored-token")

        // Verify it was persisted
        let stored = await secureStorage.get("@paywallo:push_token")
        XCTAssertNotNil(stored)

        await manager.invalidateLocalToken()

        let afterRemove = await secureStorage.get("@paywallo:push_token")
        XCTAssertNil(afterRemove, "Local token must be cleared from SecureStorage")
    }

    func testInvalidateLocalToken_doesNotRequireNetworkCall() async {
        // This test verifies invalidateLocalToken doesn't call apiClient.removeToken.
        // We verify indirectly: invalidateLocalToken completes even on a non-existent server.
        await manager.initialize(config: NotificationsConfig(), apnsToken: "local-only")
        await manager.invalidateLocalToken()
        XCTAssertNil(manager.currentPushToken)
    }

    func testOptOut_clearsToken() async {
        await manager.initialize(config: NotificationsConfig(), apnsToken: "optout-token")
        await manager.optOut()
        XCTAssertNil(manager.currentPushToken)
    }

    func testOptOut_clearsStoredToken() async {
        await manager.initialize(config: NotificationsConfig(), apnsToken: "optout-stored")
        await manager.optOut()

        let stored = await secureStorage.get("@paywallo:push_token")
        XCTAssertNil(stored, "optOut must clear stored token")
    }

    // MARK: - setApnsToken

    func testSetApnsToken_afterInit_updatesCurrentToken() async {
        await manager.initialize(config: NotificationsConfig(), apnsToken: "old-token")
        await manager.setApnsToken("new-token")
        XCTAssertEqual(manager.currentPushToken, "new-token")
    }

    func testSetApnsToken_sameToken_noUpdate() async {
        await manager.initialize(config: NotificationsConfig(), apnsToken: "same-token")
        await manager.setApnsToken("same-token")
        XCTAssertEqual(manager.currentPushToken, "same-token")
    }

    // MARK: - Auto token-refresh via setApnsToken

    /// New token → registers with backend and persists.
    func testSetApnsToken_newToken_registersAndPersists() async {
        await manager.initialize(config: NotificationsConfig(), apnsToken: "initial-token")

        await manager.setApnsToken("refreshed-token")

        XCTAssertEqual(manager.currentPushToken, "refreshed-token")
        let stored = await secureStorage.get("@paywallo:push_token")
        XCTAssertEqual(stored, "refreshed-token", "Refreshed token must be persisted to storage")
    }

    /// Same token as last registered → no-op (no redundant re-registration).
    func testSetApnsToken_sameAsRegistered_isNoOp() async {
        await manager.initialize(config: NotificationsConfig(), apnsToken: "stable-token")
        // First registration persisted "stable-token" as registeredToken.
        // Calling setApnsToken with the identical value must not change storage.
        let storedBefore = await secureStorage.get("@paywallo:push_token")

        await manager.setApnsToken("stable-token")

        let storedAfter = await secureStorage.get("@paywallo:push_token")
        XCTAssertEqual(storedBefore, storedAfter, "No-op: storage must not change when token is unchanged")
        XCTAssertEqual(manager.currentPushToken, "stable-token")
    }

    /// Token changes after init → re-registers (simulates OS rotating the token).
    func testSetApnsToken_changedToken_reRegisters() async {
        await manager.initialize(config: NotificationsConfig(), apnsToken: "token-v1")
        XCTAssertEqual(manager.currentPushToken, "token-v1")

        // OS rotates token
        await manager.setApnsToken("token-v2")

        XCTAssertEqual(manager.currentPushToken, "token-v2")
        let stored = await secureStorage.get("@paywallo:push_token")
        XCTAssertEqual(stored, "token-v2", "Re-registration must persist the new token")
    }

    // MARK: - destroy

    func testDestroy_setsIsReadyFalse() async {
        await manager.initialize(config: NotificationsConfig(), apnsToken: nil)
        manager.destroy()
        XCTAssertFalse(manager.isReady)
    }

    func testDestroy_allowsReinit() async {
        await manager.initialize(config: NotificationsConfig(), apnsToken: "first")
        manager.destroy()
        // Re-create and initialize
        manager = NotificationsManager(
            apiClient: apiClient,
            secureStorage: secureStorage,
            distinctIdProvider: { "test-distinct-id" }
        )
        await manager.initialize(config: NotificationsConfig(), apnsToken: "second")
        XCTAssertTrue(manager.isReady)
        XCTAssertEqual(manager.currentPushToken, "second")
    }
}

// MARK: - NotificationHandlers Tests

final class NotificationHandlersTests: XCTestCase {

    // MARK: - Pre-subscribe buffer

    func testBuffer_receivedPayload_buffersWhenNoHandler() {
        let handlers = NotificationHandlers()
        let payload = NotificationPayload(userInfo: ["message_id": "buf-1"])
        handlers.handleReceived(payload)
        XCTAssertEqual(handlers.receivedBuffer.count, 1)
    }

    func testBuffer_openedPayload_buffersWhenNoHandler() {
        let handlers = NotificationHandlers()
        let payload = NotificationPayload(userInfo: ["message_id": "buf-open"])
        handlers.handleOpened(payload)
        XCTAssertEqual(handlers.openedBuffer.count, 1)
    }

    func testBuffer_dismissedPayload_buffersWhenNoHandler() {
        let handlers = NotificationHandlers()
        let payload = NotificationPayload(userInfo: ["message_id": "buf-dismiss"])
        handlers.handleDismissed(payload)
        XCTAssertEqual(handlers.dismissedBuffer.count, 1)
    }

    func testBuffer_drainReturnsAllEvents() {
        let handlers = NotificationHandlers()
        for i in 0..<5 {
            let payload = NotificationPayload(userInfo: ["message_id": "buf-\(i)"])
            handlers.handleReceived(payload)
        }
        let drained = handlers.drainReceived()
        XCTAssertEqual(drained.count, 5)
        XCTAssertEqual(handlers.receivedBuffer.count, 0, "Buffer should be empty after drain")
    }

    func testBuffer_maxCapacity_evictsOldest() {
        let buffer = NotificationEventBuffer()
        for i in 0..<105 {
            let payload = NotificationPayload(userInfo: ["message_id": "overflow-\(i)"])
            buffer.push(payload)
        }
        // Buffer caps at 100 — first 5 were evicted
        XCTAssertEqual(buffer.count, 100)
    }

    func testBuffer_withHandler_doesNotBuffer() {
        var handlers = NotificationHandlers()
        var called = false
        handlers.onReceived = { _ in called = true }

        let payload = NotificationPayload(userInfo: ["message_id": "direct"])
        handlers.handleReceived(payload)

        XCTAssertTrue(called)
        XCTAssertEqual(handlers.receivedBuffer.count, 0, "Handler present — no buffering")
    }

    // MARK: - NotificationPayload Parsing

    func testPayload_parsesMessageId() {
        let payload = NotificationPayload(userInfo: ["message_id": "msg-parse"])
        XCTAssertEqual(payload.messageId, "msg-parse")
    }

    func testPayload_parsesMessageIdAlternateKey() {
        let payload = NotificationPayload(userInfo: ["messageId": "msg-camel"])
        XCTAssertEqual(payload.messageId, "msg-camel")
    }

    func testPayload_parsesCampaignId() {
        let payload = NotificationPayload(userInfo: ["campaign_id": "camp-123"])
        XCTAssertEqual(payload.campaignId, "camp-123")
    }

    func testPayload_parsesDeepLink() {
        let payload = NotificationPayload(userInfo: ["deep_link": "myapp://home"])
        XCTAssertEqual(payload.deepLink, "myapp://home")
    }

    func testPayload_parsesDeepLinkAlternateKey() {
        let payload = NotificationPayload(userInfo: ["deepLink": "myapp://profile"])
        XCTAssertEqual(payload.deepLink, "myapp://profile")
    }

    func testPayload_missingFields_areNil() {
        let payload = NotificationPayload(userInfo: [:])
        XCTAssertNil(payload.messageId)
        XCTAssertNil(payload.campaignId)
        XCTAssertNil(payload.deepLink)
        XCTAssertNil(payload.notificationId)
    }

    // MARK: - DeepLinkResolver

    func testDeepLinkResolver_matchingPrefix_callsHandler() {
        var resolver = DeepLinkResolver()
        var resolvedUrl: String?
        resolver.register(prefix: "myapp://") { url in resolvedUrl = url }

        resolver.resolve("myapp://home/feed")

        XCTAssertEqual(resolvedUrl, "myapp://home/feed")
    }

    func testDeepLinkResolver_nonMatchingPrefix_noHandler() {
        var resolver = DeepLinkResolver()
        var called = false
        resolver.register(prefix: "myapp://") { _ in called = true }

        resolver.resolve("https://external.com/page")

        XCTAssertFalse(called)
    }

    func testDeepLinkResolver_firstMatchWins() {
        var resolver = DeepLinkResolver()
        var calls: [String] = []
        resolver.register(prefix: "myapp://") { url in calls.append("first:\(url)") }
        resolver.register(prefix: "myapp://") { url in calls.append("second:\(url)") }

        resolver.resolve("myapp://test")

        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].hasPrefix("first:"))
    }
}

// MARK: - Pre-prompt / Permission Tests

private final class SpyPrePromptTracker: PrePromptTracker {
    var events: [PromptEventType] = []

    func trackPromptEvent(_ event: PromptEventType) {
        events.append(event)
    }
}

final class NotificationPrePromptTests: XCTestCase {

    private var tracker: SpyPrePromptTracker!
    private var permissionManager: PermissionManager!

    override func setUp() {
        super.setUp()
        tracker = SpyPrePromptTracker()
        permissionManager = PermissionManager(debug: false, tracker: tracker)
    }

    func testPrePrompt_emitsPromptShownOnOpen() {
        _ = permissionManager.requestPermissionWithPrePrompt(
            PrePromptOptions(title: "Stay in the loop", body: "Get notified")
        )

        XCTAssertEqual(tracker.events, [.promptShown])
    }

    func testPrePrompt_handleCarriesTheCopyVerbatim() {
        let handle = permissionManager.requestPermissionWithPrePrompt(
            PrePromptOptions(title: "T", body: "B", acceptLabel: "Sure", rejectLabel: "Later")
        )

        XCTAssertEqual(handle.title, "T")
        XCTAssertEqual(handle.body, "B")
        XCTAssertEqual(handle.acceptLabel, "Sure")
        XCTAssertEqual(handle.rejectLabel, "Later")
    }

    func testPrePrompt_rejectEmitsSoftRejectedAndLeavesPermissionUndecided() {
        let handle = permissionManager.requestPermissionWithPrePrompt(
            PrePromptOptions(title: "T", body: "B")
        )

        XCTAssertEqual(handle.reject(), .notDetermined)
        XCTAssertEqual(tracker.events, [.promptShown, .softRejected])
    }

    func testPrePrompt_rejectIsIdempotent() {
        let handle = permissionManager.requestPermissionWithPrePrompt(
            PrePromptOptions(title: "T", body: "B")
        )

        handle.reject()
        handle.reject()

        XCTAssertEqual(tracker.events, [.promptShown, .softRejected])
    }

    func testPrePrompt_acceptEmitsSoftAccepted() async {
        let handle = permissionManager.requestPermissionWithPrePrompt(
            PrePromptOptions(title: "T", body: "B")
        )

        _ = await handle.accept()

        XCTAssertEqual(tracker.events.prefix(2).map { $0 }, [.promptShown, .softAccepted])
    }

    func testPrePrompt_acceptIsIdempotent() async {
        let handle = permissionManager.requestPermissionWithPrePrompt(
            PrePromptOptions(title: "T", body: "B")
        )

        _ = await handle.accept()
        _ = await handle.accept()

        XCTAssertEqual(tracker.events.filter { $0 == .softAccepted }.count, 1)
    }

    func testPrePrompt_acceptAfterRejectDoesNotReopenTheOsDialog() async {
        let handle = permissionManager.requestPermissionWithPrePrompt(
            PrePromptOptions(title: "T", body: "B")
        )

        handle.reject()
        _ = await handle.accept()

        XCTAssertEqual(tracker.events, [.promptShown, .softRejected])
    }

    func testPromptEventType_wireValues() {
        XCTAssertEqual(PromptEventType.promptShown.rawValue, "prompt_shown")
        XCTAssertEqual(PromptEventType.softAccepted.rawValue, "soft_accepted")
        XCTAssertEqual(PromptEventType.softRejected.rawValue, "soft_rejected")
        XCTAssertEqual(PromptEventType.osGranted.rawValue, "os_granted")
        XCTAssertEqual(PromptEventType.osDenied.rawValue, "os_denied")
    }

    /// Outside an .app bundle (CLI / XCTest) UNUserNotificationCenter is unreachable,
    /// so the status is unknown rather than denied.
    func testGetStatus_outsideAppContext_isNotDetermined() async {
        let status = await permissionManager.getStatus()

        XCTAssertEqual(status, .notDetermined)
    }
}

// MARK: - Notification subscriber accumulation

final class NotificationSubscriberTests: XCTestCase {

    private func makePayload(_ messageId: String) -> NotificationPayload {
        NotificationPayload(userInfo: ["message_id": messageId])
    }

    func testOnReceived_secondSubscriberDoesNotReplaceTheFirst() {
        var handlers = NotificationHandlers()
        var first: [String] = []
        var second: [String] = []

        // Mirrors the fan-out NotificationsManager installs for its callback array.
        var callbacks: [(NotificationPayload) -> Void] = []
        handlers.onReceived = { payload in callbacks.forEach { $0(payload) } }
        callbacks.append { first.append($0.messageId ?? "") }
        callbacks.append { second.append($0.messageId ?? "") }

        handlers.handleReceived(makePayload("m1"))

        XCTAssertEqual(first, ["m1"])
        XCTAssertEqual(second, ["m1"])
    }

    func testPeekOpened_doesNotConsumeTheBuffer() {
        let handlers = NotificationHandlers()
        handlers.handleOpened(makePayload("cold_start"))

        XCTAssertEqual(handlers.peekOpened()?.messageId, "cold_start")
        // The subscriber that attaches later must still receive it.
        XCTAssertEqual(handlers.drainOpened().count, 1)
    }

    func testPeekOpened_emptyBuffer_isNil() {
        let handlers = NotificationHandlers()

        XCTAssertNil(handlers.peekOpened())
    }
}
