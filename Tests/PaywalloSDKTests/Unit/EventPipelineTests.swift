import XCTest
@testable import PaywalloSDK

// MARK: - EventFamilies Tests

final class EventFamiliesTests: XCTestCase {

    // MARK: detectFamily

    func testDetectFamily_lifecycle() {
        XCTAssertEqual(EventFamilies.detectFamily("lifecycle"), .lifecycle)
    }

    func testDetectFamily_paywall() {
        XCTAssertEqual(EventFamilies.detectFamily("paywall"), .paywall)
    }

    func testDetectFamily_transaction() {
        XCTAssertEqual(EventFamilies.detectFamily("transaction"), .transaction)
    }

    func testDetectFamily_onboarding() {
        XCTAssertEqual(EventFamilies.detectFamily("onboarding"), .onboarding)
    }

    func testDetectFamily_notification() {
        XCTAssertEqual(EventFamilies.detectFamily("notification"), .notification)
    }

    func testDetectFamily_identify() {
        XCTAssertEqual(EventFamilies.detectFamily("identify"), .identify)
    }

    func testDetectFamily_customEvent_returnsCustom() {
        XCTAssertEqual(EventFamilies.detectFamily("custom_event"), .custom)
    }

    func testDetectFamily_unknownName_returnsCustom() {
        XCTAssertEqual(EventFamilies.detectFamily("anything_else"), .custom)
        XCTAssertEqual(EventFamilies.detectFamily("button_clicked"), .custom)
        XCTAssertEqual(EventFamilies.detectFamily("purchase_completed"), .custom)
    }

    // MARK: isDeprecated

    func testIsDeprecated_paywallPurchased() {
        XCTAssertTrue(EventFamilies.isDeprecated("$paywall_purchased"))
    }

    func testIsDeprecated_paywallProductSelected() {
        XCTAssertTrue(EventFamilies.isDeprecated("$paywall_product_selected"))
    }

    func testIsDeprecated_coreAction() {
        XCTAssertTrue(EventFamilies.isDeprecated("$core_action"))
    }

    func testIsDeprecated_campaignImpression() {
        XCTAssertTrue(EventFamilies.isDeprecated("$campaign_impression"))
    }

    func testIsDeprecated_appOpen() {
        XCTAssertTrue(EventFamilies.isDeprecated("$app_open"))
    }

    func testIsDeprecated_appBackground() {
        XCTAssertTrue(EventFamilies.isDeprecated("$app_background"))
    }

    func testIsDeprecated_appForeground() {
        XCTAssertTrue(EventFamilies.isDeprecated("$app_foreground"))
    }

    func testIsDeprecated_sessionEnd() {
        XCTAssertTrue(EventFamilies.isDeprecated("session.end"))
    }

    func testIsDeprecated_validName_returnsFalse() {
        XCTAssertFalse(EventFamilies.isDeprecated("lifecycle"))
        XCTAssertFalse(EventFamilies.isDeprecated("purchase_completed"))
        XCTAssertFalse(EventFamilies.isDeprecated("custom_event"))
    }

    // MARK: isValidEventName

    func testIsValidEventName_snakeCase_returnsTrue() {
        XCTAssertTrue(EventFamilies.isValidEventName("valid_name"))
    }

    func testIsValidEventName_dollarPrefixedWithLetters_returnsTrue() {
        XCTAssertTrue(EventFamilies.isValidEventName("$reserved"))
    }

    func testIsValidEventName_dollarPrefixedWithNumbersAndUnderscores_returnsTrue() {
        XCTAssertTrue(EventFamilies.isValidEventName("$with_numbers_123"))
    }

    func testIsValidEventName_lowercase_returnsTrue() {
        XCTAssertTrue(EventFamilies.isValidEventName("abc"))
    }

    func testIsValidEventName_lowercase_withNumbers_returnsTrue() {
        XCTAssertTrue(EventFamilies.isValidEventName("event123"))
    }

    func testIsValidEventName_uppercase_returnsFalse() {
        XCTAssertFalse(EventFamilies.isValidEventName("UPPERCASE"))
    }

    func testIsValidEventName_hasSpace_returnsFalse() {
        XCTAssertFalse(EventFamilies.isValidEventName("has space"))
    }

    func testIsValidEventName_empty_returnsFalse() {
        XCTAssertFalse(EventFamilies.isValidEventName(""))
    }

    func testIsValidEventName_startsWithNumber_returnsFalse() {
        XCTAssertFalse(EventFamilies.isValidEventName("123start"))
    }

    func testIsValidEventName_mixedCase_returnsFalse() {
        XCTAssertFalse(EventFamilies.isValidEventName("camelCase"))
    }

    // MARK: validateEvent

    func testValidateEvent_lifecycle_validType_returnsOk() {
        let (ok, family) = EventFamilies.validateEvent(
            eventName: "lifecycle",
            properties: ["type": "cold_start"]
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(family, .lifecycle)
    }

    func testValidateEvent_lifecycle_invalidType_returnsNotOk() {
        let (ok, family) = EventFamilies.validateEvent(
            eventName: "lifecycle",
            properties: ["type": "invalid_type"]
        )
        XCTAssertFalse(ok)
        XCTAssertEqual(family, .lifecycle)
    }

    func testValidateEvent_lifecycle_allValidTypes() {
        let validTypes = ["install", "cold_start", "foreground", "background", "session_start", "session_end"]
        for type_ in validTypes {
            let (ok, _) = EventFamilies.validateEvent(eventName: "lifecycle", properties: ["type": type_])
            XCTAssertTrue(ok, "Expected lifecycle type '\(type_)' to be valid")
        }
    }

    func testValidateEvent_paywall_validType_returnsOk() {
        let (ok, family) = EventFamilies.validateEvent(
            eventName: "paywall",
            properties: ["type": "viewed"]
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(family, .paywall)
    }

    func testValidateEvent_paywall_invalidType_returnsNotOk() {
        let (ok, _) = EventFamilies.validateEvent(
            eventName: "paywall",
            properties: ["type": "unknown_action"]
        )
        XCTAssertFalse(ok)
    }

    func testValidateEvent_transaction_validType_returnsOk() {
        let (ok, _) = EventFamilies.validateEvent(
            eventName: "transaction",
            properties: ["type": "completed"]
        )
        XCTAssertTrue(ok)
    }

    func testValidateEvent_transaction_invalidType_returnsNotOk() {
        let (ok, _) = EventFamilies.validateEvent(
            eventName: "transaction",
            properties: ["type": "zap"]
        )
        XCTAssertFalse(ok)
    }

    func testValidateEvent_transaction_invalidCurrencyLength_returnsNotOk() {
        let (ok, _) = EventFamilies.validateEvent(
            eventName: "transaction",
            properties: ["currency": "US"]  // must be 3 chars
        )
        XCTAssertFalse(ok)
    }

    func testValidateEvent_transaction_validCurrencyLength_returnsOk() {
        let (ok, _) = EventFamilies.validateEvent(
            eventName: "transaction",
            properties: ["currency": "USD"]
        )
        XCTAssertTrue(ok)
    }

    func testValidateEvent_noProperties_returnsOk() {
        let (ok, family) = EventFamilies.validateEvent(eventName: "lifecycle", properties: nil)
        XCTAssertTrue(ok)
        XCTAssertEqual(family, .lifecycle)
    }

    func testValidateEvent_emptyProperties_returnsOk() {
        let (ok, _) = EventFamilies.validateEvent(eventName: "lifecycle", properties: [:])
        XCTAssertTrue(ok)
    }

    func testValidateEvent_custom_alwaysOk() {
        let (ok, family) = EventFamilies.validateEvent(
            eventName: "my_custom_event",
            properties: ["type": "anything"]
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(family, .custom)
    }

    func testValidateEvent_identify_alwaysOk() {
        let (ok, family) = EventFamilies.validateEvent(
            eventName: "identify",
            properties: ["user_id": "abc123"]
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(family, .identify)
    }

    func testValidateEvent_notification_validType_returnsOk() {
        for type_ in ["delivered", "displayed", "clicked", "dismissed"] {
            let (ok, _) = EventFamilies.validateEvent(eventName: "notification", properties: ["type": type_])
            XCTAssertTrue(ok, "Expected notification type '\(type_)' to be valid")
        }
    }

    func testValidateEvent_onboarding_validType_returnsOk() {
        for type_ in ["step", "complete", "drop"] {
            let (ok, _) = EventFamilies.validateEvent(eventName: "onboarding", properties: ["type": type_])
            XCTAssertTrue(ok, "Expected onboarding type '\(type_)' to be valid")
        }
    }

    func testValidateEvent_paywall_viewedType_returnsOk() {
        let (ok, family) = EventFamilies.validateEvent(
            eventName: "paywall",
            properties: ["type": "viewed"]
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(family, .paywall)
    }

    func testValidateEvent_transaction_trialStarted_returnsOk() {
        let (ok, family) = EventFamilies.validateEvent(
            eventName: "transaction",
            properties: ["type": "trial_started"]
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(family, .transaction)
    }

    func testValidateEvent_notification_noPrefix_returnsOk() {
        for type_ in ["delivered", "displayed", "clicked", "dismissed"] {
            let (ok, _) = EventFamilies.validateEvent(eventName: "notification", properties: ["type": type_])
            XCTAssertTrue(ok, "Expected notification type '\(type_)' (without prefix) to be valid")
        }
    }
}

// MARK: - V2EnvelopeBuilder Tests

final class V2EnvelopeBuilderTests: XCTestCase {

    private func makeEvent(
        family: EventFamily = .custom,
        name: String = "test_event",
        payload: [String: AnyCodable] = [:],
        timestamp: TimeInterval = 1_000_000
    ) -> (family: EventFamily, name: String, payload: [String: AnyCodable], timestamp: TimeInterval) {
        (family: family, name: name, payload: payload, timestamp: timestamp)
    }

    // MARK: Baseline context fields

    func testBuild_setsSDKVersion() {
        let envelope = V2EnvelopeBuilder.build(events: [makeEvent()])
        XCTAssertEqual(envelope.context.sdkVersion, PaywalloConstants.sdkVersion)
    }

    func testBuild_setsPlatformToIOS() {
        let envelope = V2EnvelopeBuilder.build(events: [makeEvent()])
        XCTAssertEqual(envelope.context.platform, "ios")
    }

    func testBuild_noEvents_returnsEmptyEnvelope() {
        let envelope = V2EnvelopeBuilder.build(events: [])
        XCTAssertTrue(envelope.events.isEmpty)
        XCTAssertEqual(envelope.context.sdkVersion, PaywalloConstants.sdkVersion)
    }

    // MARK: UUID per event

    func testBuild_eachEventHasUniqueID() {
        let events = [makeEvent(), makeEvent(), makeEvent()]
        let envelope = V2EnvelopeBuilder.build(events: events)
        let ids = envelope.events.map(\.id)
        let uniqueIDs = Set(ids)
        XCTAssertEqual(uniqueIDs.count, ids.count, "Each event must have a unique ID")
    }

    func testBuild_eventIDIsNonEmpty() {
        let envelope = V2EnvelopeBuilder.build(events: [makeEvent()])
        XCTAssertFalse(envelope.events[0].id.isEmpty)
    }

    // MARK: Context promotion — distinct_id

    func testBuild_distinctIdInPayload_promotedToContext() {
        let event = makeEvent(payload: ["distinct_id": AnyCodable("user_123")])
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertEqual(envelope.context.distinctId, "user_123")
    }

    func testBuild_distinctIdInPayload_removedFromEventPayload() {
        let event = makeEvent(payload: ["distinct_id": AnyCodable("user_123")])
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertNil(envelope.events[0].payload["distinct_id"])
    }

    func testBuild_camelCaseDistinctIdInPayload_promotedToContext() {
        let event = makeEvent(payload: ["distinctId": AnyCodable("user_456")])
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertEqual(envelope.context.distinctId, "user_456")
    }

    // MARK: Provider context wins

    func testBuild_providerDistinctIdWinsOverPayload() {
        var providerContext = IngestContext()
        providerContext.distinctId = "provider_user"

        let event = makeEvent(payload: ["distinct_id": AnyCodable("payload_user")])
        let envelope = V2EnvelopeBuilder.build(events: [event], providerContext: providerContext)

        XCTAssertEqual(envelope.context.distinctId, "provider_user",
                       "Provider context must win over payload value")
    }

    func testBuild_providerSDKVersionWinsOverDefault() {
        var providerContext = IngestContext()
        providerContext.sdkVersion = "9.9.9"

        let envelope = V2EnvelopeBuilder.build(events: [makeEvent()], providerContext: providerContext)
        XCTAssertEqual(envelope.context.sdkVersion, "9.9.9")
    }

    func testBuild_providerPlatformWinsOverDefault() {
        var providerContext = IngestContext()
        providerContext.platform = "android"

        let envelope = V2EnvelopeBuilder.build(events: [makeEvent()], providerContext: providerContext)
        XCTAssertEqual(envelope.context.platform, "android")
    }

    // MARK: Custom events inject event_name

    func testBuild_customEvent_injectsEventNameInPayload() {
        let event = makeEvent(family: .custom, name: "button_clicked")
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertEqual(envelope.events[0].payload["event_name"]?.value as? String, "button_clicked")
    }

    func testBuild_nonCustomEvent_doesNotInjectEventName() {
        let event = makeEvent(family: .lifecycle, name: "lifecycle")
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertNil(envelope.events[0].payload["event_name"])
    }

    // MARK: Context promotion — other fields

    func testBuild_sessionIdInPayload_promotedToContext() {
        let event = makeEvent(payload: ["session_id": AnyCodable("sess_abc")])
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertEqual(envelope.context.sessionId, "sess_abc")
        XCTAssertNil(envelope.events[0].payload["session_id"])
    }

    func testBuild_deviceIdInPayload_promotedToContext() {
        let event = makeEvent(payload: ["device_id": AnyCodable("dev_xyz")])
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertEqual(envelope.context.deviceId, "dev_xyz")
        XCTAssertNil(envelope.events[0].payload["device_id"])
    }

    func testBuild_timezoneInPayload_promotedToContext() {
        let event = makeEvent(payload: ["timezone": AnyCodable("America/Sao_Paulo")])
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertEqual(envelope.context.timezone, "America/Sao_Paulo")
    }

    func testBuild_attributionDictInPayload_promotedToContext() {
        let event = makeEvent(payload: ["attribution": AnyCodable(["fbclid": "fb_123"])])
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertNotNil(envelope.context.attribution)
        XCTAssertNil(envelope.events[0].payload["attribution"])
    }

    func testBuild_idsDictInPayload_promotedToContext() {
        let event = makeEvent(payload: ["ids": AnyCodable(["idfa": "abc-123"])])
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertNotNil(envelope.context.ids)
        XCTAssertNil(envelope.events[0].payload["ids"])
    }

    // MARK: Timestamp preserved

    func testBuild_timestampPreservedInEvent() {
        let ts: Int64 = 1_700_000_000_000
        let event = makeEvent(timestamp: TimeInterval(ts))
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertEqual(envelope.events[0].timestamp, ts)
    }

    // MARK: Multiple events

    func testBuild_multipleEvents_allIncluded() {
        let events = [
            makeEvent(family: .lifecycle, name: "lifecycle"),
            makeEvent(family: .custom, name: "button_clicked"),
            makeEvent(family: .transaction, name: "transaction"),
        ]
        let envelope = V2EnvelopeBuilder.build(events: events)
        XCTAssertEqual(envelope.events.count, 3)
    }

    func testBuild_firstEventDistinctIdUsedAsFallback() {
        // No provider context, first event has distinct_id
        let event1 = makeEvent(payload: ["distinct_id": AnyCodable("first_user")])
        let event2 = makeEvent(payload: [:])
        let envelope = V2EnvelopeBuilder.build(events: [event1, event2])
        XCTAssertEqual(envelope.context.distinctId, "first_user")
    }
}

// MARK: - EventPipelineBridge Tests

final class EventPipelineBridgeTests: XCTestCase {

    // MARK: Primitive pass-through

    func testSerialize_stringPassesThrough() {
        let result = EventPipelineBridge.serializeProperties(["key": "hello"])
        XCTAssertEqual(result?["key"]?.value as? String, "hello")
    }

    func testSerialize_intPassesThrough() {
        let result = EventPipelineBridge.serializeProperties(["count": 42])
        XCTAssertEqual(result?["count"]?.value as? Int, 42)
    }

    func testSerialize_doublePassesThrough() {
        let result = EventPipelineBridge.serializeProperties(["price": 9.99])
        XCTAssertEqual(result?["price"]?.value as? Double, 9.99)
    }

    func testSerialize_boolPassesThrough() {
        let result = EventPipelineBridge.serializeProperties(["active": true])
        XCTAssertEqual(result?["active"]?.value as? Bool, true)
    }

    func testSerialize_boolFalsePassesThrough() {
        let result = EventPipelineBridge.serializeProperties(["active": false])
        XCTAssertEqual(result?["active"]?.value as? Bool, false)
    }

    // MARK: Nil / NSNull handling

    func testSerialize_nilInput_returnsNil() {
        let result = EventPipelineBridge.serializeProperties(nil)
        XCTAssertNil(result)
    }

    func testSerialize_nsNull_passesThrough() {
        let result = EventPipelineBridge.serializeProperties(["key": NSNull()])
        XCTAssertTrue(result?["key"]?.value is NSNull)
    }

    // MARK: Complex types → JSON string

    func testSerialize_dictBecomesJSONString() throws {
        let dict: [String: Any] = ["nested": ["a": 1]]
        let result = EventPipelineBridge.serializeProperties(["data": dict])
        let jsonStr = result?["data"]?.value as? String
        XCTAssertNotNil(jsonStr, "Dict must be serialized to a JSON string")

        // Verify it's valid JSON
        let data = try XCTUnwrap(jsonStr?.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed)
    }

    func testSerialize_arrayBecomesJSONString() throws {
        let array: [Any] = [1, 2, 3]
        let result = EventPipelineBridge.serializeProperties(["items": array])
        let jsonStr = result?["items"]?.value as? String
        XCTAssertNotNil(jsonStr, "Array must be serialized to a JSON string")

        let data = try XCTUnwrap(jsonStr?.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [Int]
        XCTAssertEqual(parsed, [1, 2, 3])
    }

    // MARK: Empty input

    func testSerialize_emptyDict_returnsNil() {
        let result = EventPipelineBridge.serializeProperties([:])
        XCTAssertNil(result, "Empty properties dict must return nil")
    }

    // MARK: Multiple keys

    func testSerialize_multipleKeys_allPresent() {
        let props: [String: Any] = [
            "name": "Alice",
            "age": 30,
            "score": 9.5,
            "active": true,
        ]
        let result = EventPipelineBridge.serializeProperties(props)
        XCTAssertEqual(result?.count, 4)
        XCTAssertEqual(result?["name"]?.value as? String, "Alice")
        XCTAssertEqual(result?["age"]?.value as? Int, 30)
        XCTAssertEqual(result?["score"]?.value as? Double, 9.5)
        XCTAssertEqual(result?["active"]?.value as? Bool, true)
    }
}

// MARK: - OfflineQueue Tests

final class OfflineQueueTests: XCTestCase {

    private var queue: OfflineQueue!
    private var storage: NativeStorage!
    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        let id = UUID().uuidString
        suiteName = "com.paywallo.sdk.tests.queue.\(id)"
        suite = UserDefaults(suiteName: suiteName)!
        storage = NativeStorage(service: "com.paywallo.sdk.tests.\(id)", defaults: suite)

        // Use very small maxAttempts (3) so tests don't have to iterate 10 times
        queue = OfflineQueue(
            storage: storage,
            maxCapacity: 1000,
            maxAttempts: 3,
            maxAge: 7 * 24 * 3600,
            baseRetryDelay: 0.001,
            maxRetryDelay: 0.001
        )
    }

    override func tearDown() {
        queue.dispose()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: Helpers

    private func makeItem(
        id: String = UUID().uuidString,
        priority: QueueItemPriority = .normal,
        appKey: String = "pk_test",
        attempts: Int = 0,
        nextRetryAt: Date? = nil
    ) -> QueueItem {
        QueueItem(
            id: id,
            method: "POST",
            url: "/sdk/ingest/batch",
            payload: nil,
            headers: [:],
            priority: priority,
            appKey: appKey,
            createdAt: Date(),
            attempts: attempts,
            nextRetryAt: nextRetryAt,
            isEvent: true
        )
    }

    // MARK: Basic enqueue + dequeueReady

    func testEnqueueAndDequeueReady_returnsItem() {
        let item = makeItem()
        queue.enqueue(item)
        let ready = queue.dequeueReady()
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(ready[0].id, item.id)
    }

    func testDequeueReady_emptyQueue_returnsEmpty() {
        XCTAssertTrue(queue.dequeueReady().isEmpty)
    }

    // MARK: Dedup

    func testDedup_sameId_doesNotDuplicate() {
        let id = UUID().uuidString
        queue.enqueue(makeItem(id: id))
        queue.enqueue(makeItem(id: id))
        XCTAssertEqual(queue.count, 1)
    }

    func testDedup_differentIds_bothEnqueued() {
        queue.enqueue(makeItem(id: "id_1"))
        queue.enqueue(makeItem(id: "id_2"))
        XCTAssertEqual(queue.count, 2)
    }

    // MARK: Priority upgrade

    func testPriorityUpgrade_normalToCritical() {
        let id = UUID().uuidString
        queue.enqueue(makeItem(id: id, priority: .normal))
        queue.enqueue(makeItem(id: id, priority: .critical))

        let items = queue.getAll()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].priority, .critical, "Item priority must be upgraded to critical")
    }

    func testPriorityUpgrade_criticalToNormal_staysCritical() {
        let id = UUID().uuidString
        queue.enqueue(makeItem(id: id, priority: .critical))
        queue.enqueue(makeItem(id: id, priority: .normal))

        let items = queue.getAll()
        XCTAssertEqual(items[0].priority, .critical, "Critical priority must not be downgraded")
    }

    // MARK: markSuccess

    func testMarkSuccess_removesItem() {
        let item = makeItem()
        queue.enqueue(item)
        queue.markSuccess(item.id)
        XCTAssertEqual(queue.count, 0)
    }

    func testMarkSuccess_nonExistentId_doesNotCrash() {
        queue.markSuccess("nonexistent_id")  // must not throw/crash
        XCTAssertEqual(queue.count, 0)
    }

    // MARK: markFailure

    func testMarkFailure_incrementsAttempts() {
        let item = makeItem()
        queue.enqueue(item)
        queue.markFailure(item.id)

        let items = queue.getAll()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].attempts, 1)
    }

    func testMarkFailure_setsNextRetryAt() {
        let item = makeItem()
        queue.enqueue(item)
        queue.markFailure(item.id)

        let items = queue.getAll()
        XCTAssertNotNil(items[0].nextRetryAt, "nextRetryAt must be set after failure")
    }

    func testMarkFailure_itemWithFutureRetry_notReturnedByDequeueReady() {
        // Create item with a very future nextRetryAt
        let futureRetry = Date().addingTimeInterval(3600)
        let item = makeItem(nextRetryAt: futureRetry)
        queue.enqueue(item)

        let ready = queue.dequeueReady()
        XCTAssertTrue(ready.isEmpty, "Item with future retry should not be returned")
    }

    // MARK: maxAttempts → removed from main queue

    func testMaxAttempts_itemRemovedFromMainQueue() {
        let item = makeItem()
        queue.enqueue(item)

        // Fail it maxAttempts (3) times
        for _ in 0..<3 {
            queue.markFailure(item.id)
        }

        // Item must be removed from main queue (moved to DLQ)
        XCTAssertEqual(queue.count, 0,
                       "Item must be removed from main queue after maxAttempts failures")
    }

    // MARK: clearItemsWithInvalidAppKey

    func testClearItemsWithInvalidAppKey_removesWrongKey() {
        queue.enqueue(makeItem(id: "a", appKey: "pk_correct"))
        queue.enqueue(makeItem(id: "b", appKey: "pk_wrong"))
        queue.clearItemsWithInvalidAppKey("pk_correct")
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.getAll()[0].id, "a")
    }

    func testClearItemsWithInvalidAppKey_keepsAllIfAllMatch() {
        queue.enqueue(makeItem(id: "a", appKey: "pk_test"))
        queue.enqueue(makeItem(id: "b", appKey: "pk_test"))
        queue.clearItemsWithInvalidAppKey("pk_test")
        XCTAssertEqual(queue.count, 2)
    }

    func testClearItemsWithInvalidAppKey_removesAllIfNoneMatch() {
        queue.enqueue(makeItem(id: "a", appKey: "pk_old"))
        queue.enqueue(makeItem(id: "b", appKey: "pk_old"))
        queue.clearItemsWithInvalidAppKey("pk_new")
        XCTAssertEqual(queue.count, 0)
    }

    // MARK: clear

    func testClear_removesEverything() {
        queue.enqueue(makeItem(id: "a"))
        queue.enqueue(makeItem(id: "b"))
        queue.clear()
        XCTAssertEqual(queue.count, 0)
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: count and isEmpty

    func testCount_emptyQueue_isZero() {
        XCTAssertEqual(queue.count, 0)
    }

    func testIsEmpty_emptyQueue_isTrue() {
        XCTAssertTrue(queue.isEmpty)
    }

    func testCount_afterEnqueue_isCorrect() {
        queue.enqueue(makeItem(id: "a"))
        queue.enqueue(makeItem(id: "b"))
        XCTAssertEqual(queue.count, 2)
        XCTAssertFalse(queue.isEmpty)
    }

    func testCount_afterMarkSuccess_decrements() {
        let item = makeItem()
        queue.enqueue(item)
        XCTAssertEqual(queue.count, 1)
        queue.markSuccess(item.id)
        XCTAssertEqual(queue.count, 0)
    }

    // MARK: onFlushRequested callback

    func testOnFlushRequested_calledForCriticalItem() {
        let expectation = self.expectation(description: "onFlushRequested called")
        queue.onFlushRequested = {
            expectation.fulfill()
        }
        queue.enqueue(makeItem(priority: .critical))
        waitForExpectations(timeout: 1.0)
    }

    func testOnFlushRequested_notCalledForNormalItem() {
        var called = false
        queue.onFlushRequested = { called = true }
        queue.enqueue(makeItem(priority: .normal))
        // Give brief time for any async callback
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(called, "onFlushRequested must not be called for normal priority items")
    }

    // MARK: dequeueReady — attempts filter

    func testDequeueReady_itemAtMaxAttempts_notReturned() {
        // We test via marking failure 3 times on an enqueued item
        let freshItem = makeItem()
        queue.enqueue(freshItem)
        queue.markFailure(freshItem.id)
        queue.markFailure(freshItem.id)
        queue.markFailure(freshItem.id)
        // After 3 failures with maxAttempts=3, item moves to DLQ
        XCTAssertEqual(queue.count, 0)
        XCTAssertTrue(queue.dequeueReady().isEmpty)
    }
}
