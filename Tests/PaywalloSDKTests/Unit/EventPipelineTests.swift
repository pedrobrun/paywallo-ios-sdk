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
            properties: ["type": "viewed", "paywall_id": "pw_1"]
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(family, .paywall)
    }

    func testValidateEvent_paywall_missingPaywallId_returnsNotOk() {
        let (ok, family) = EventFamilies.validateEvent(
            eventName: "paywall",
            properties: ["type": "viewed"]
        )
        XCTAssertFalse(ok, "paywall sem paywall_id deve reprovar")
        XCTAssertEqual(family, .paywall)
    }

    func testValidateEvent_paywall_emptyPaywallId_returnsNotOk() {
        let (ok, _) = EventFamilies.validateEvent(
            eventName: "paywall",
            properties: ["type": "viewed", "paywall_id": ""]
        )
        XCTAssertFalse(ok, "paywall_id vazio conta como ausente")
    }

    func testValidateEvent_paywall_invalidType_returnsNotOk() {
        let (ok, _) = EventFamilies.validateEvent(
            eventName: "paywall",
            properties: ["type": "unknown_action", "paywall_id": "pw_1"]
        )
        XCTAssertFalse(ok)
    }

    func testValidateEvent_transaction_validType_returnsOk() {
        let (ok, _) = EventFamilies.validateEvent(
            eventName: "transaction",
            properties: ["type": "completed", "transaction_id": "tx_1"]
        )
        XCTAssertTrue(ok)
    }

    func testValidateEvent_transaction_missingTransactionId_returnsNotOk() {
        let (ok, _) = EventFamilies.validateEvent(
            eventName: "transaction",
            properties: ["type": "completed"]
        )
        XCTAssertFalse(ok, "transaction sem transaction_id nem tx_id deve reprovar")
    }

    func testValidateEvent_transaction_legacyTxIdAccepted() {
        let (ok, _) = EventFamilies.validateEvent(
            eventName: "transaction",
            properties: ["type": "completed", "tx_id": "tx_legacy"]
        )
        XCTAssertTrue(ok, "tx_id legado ainda satisfaz o requisito de id")
    }

    func testValidateEvent_transaction_invalidType_returnsNotOk() {
        let (ok, _) = EventFamilies.validateEvent(
            eventName: "transaction",
            properties: ["type": "zap", "transaction_id": "tx_1"]
        )
        XCTAssertFalse(ok)
    }

    func testValidateEvent_transaction_invalidCurrencyLength_returnsNotOk() {
        let (ok, _) = EventFamilies.validateEvent(
            eventName: "transaction",
            properties: ["currency": "US", "transaction_id": "tx_1"]  // must be 3 chars
        )
        XCTAssertFalse(ok)
    }

    func testValidateEvent_transaction_validCurrencyLength_returnsOk() {
        let (ok, _) = EventFamilies.validateEvent(
            eventName: "transaction",
            properties: ["currency": "USD", "transaction_id": "tx_1"]
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

    func testValidateEvent_identify_withDistinctId_returnsOk() {
        let (ok, family) = EventFamilies.validateEvent(
            eventName: "identify",
            properties: ["distinct_id": "abc123"]
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(family, .identify)
    }

    func testValidateEvent_identify_missingDistinctId_returnsNotOk() {
        let (ok, family) = EventFamilies.validateEvent(
            eventName: "identify",
            properties: ["user_id": "abc123"]
        )
        XCTAssertFalse(ok, "identify sem distinct_id deve reprovar")
        XCTAssertEqual(family, .identify)
    }

    func testValidateEvent_identify_emptyDistinctId_returnsNotOk() {
        let (ok, _) = EventFamilies.validateEvent(
            eventName: "identify",
            properties: ["distinct_id": ""]
        )
        XCTAssertFalse(ok, "distinct_id vazio conta como ausente")
    }

    func testValidateEvent_notification_validType_returnsOk() {
        for type_ in ["delivered", "displayed", "clicked", "dismissed"] {
            let (ok, _) = EventFamilies.validateEvent(eventName: "notification", properties: ["type": type_])
            XCTAssertTrue(ok, "Expected notification type '\(type_)' to be valid")
        }
    }

    func testValidateEvent_onboarding_validType_returnsOk() {
        for type_ in ["step", "complete"] {
            let (ok, _) = EventFamilies.validateEvent(eventName: "onboarding", properties: ["type": type_])
            XCTAssertTrue(ok, "Expected onboarding type '\(type_)' to be valid")
        }
    }

    func testValidateEvent_onboarding_dropTypeRemoved_returnsNotOk() {
        // `drop` saiu da taxonomia V2 — o servidor rejeita.
        let (ok, _) = EventFamilies.validateEvent(eventName: "onboarding", properties: ["type": "drop"])
        XCTAssertFalse(ok, "onboarding type 'drop' foi removido da taxonomia")
    }

    func testValidateEvent_paywall_viewedType_returnsOk() {
        let (ok, family) = EventFamilies.validateEvent(
            eventName: "paywall",
            properties: ["type": "viewed", "paywall_id": "pw_1"]
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(family, .paywall)
    }

    func testValidateEvent_transaction_trialStarted_returnsOk() {
        let (ok, family) = EventFamilies.validateEvent(
            eventName: "transaction",
            properties: ["type": "trial_started", "transaction_id": "tx_1"]
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
        timestamp: TimeInterval = 1_000_000,
        distinctId: String = ""
    ) -> EventInput {
        EventInput(family: family, name: name, payload: payload, timestamp: timestamp, distinctId: distinctId)
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

    // MARK: Novos slots de context (2.9.0)

    func testBuild_appBuildAndBundleIdPromotedFromPayload() {
        let event = makeEvent(payload: [
            "app_build": AnyCodable("4211"),
            "bundle_id": AnyCodable("com.acme.app"),
        ])
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertEqual(envelope.context.appBuild, "4211")
        XCTAssertEqual(envelope.context.bundleId, "com.acme.app")
        XCTAssertNil(envelope.events[0].payload["app_build"])
        XCTAssertNil(envelope.events[0].payload["bundle_id"])
    }

    func testBuild_carrierPromotedFromPayload() {
        let envelope = V2EnvelopeBuilder.build(events: [makeEvent(payload: ["carrier": AnyCodable("Vivo")])])
        XCTAssertEqual(envelope.context.carrier, "Vivo")
    }

    func testBuild_screenMetricsAreNumericInContext() {
        let event = makeEvent(payload: [
            "screen_width": AnyCodable(390),
            "screen_height": AnyCodable(844.0),
            "screen_density": AnyCodable(3.0),
        ])
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertEqual(envelope.context.screenWidth, 390)
        XCTAssertEqual(envelope.context.screenHeight, 844)
        XCTAssertEqual(envelope.context.screenDensity, 3)
    }

    func testBuild_camelCaseScreenKeysStayInPayload() {
        // Promover screenWidth/screenHeight deletaria as chaves que o server lê do
        // payload do $app_installed — por isso NÃO existe alias camelCase.
        let event = makeEvent(payload: [
            "screenWidth": AnyCodable(390),
            "screenHeight": AnyCodable(844),
        ])
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertNotNil(envelope.events[0].payload["screenWidth"])
        XCTAssertNotNil(envelope.events[0].payload["screenHeight"])
        XCTAssertNil(envelope.context.screenWidth)
    }

    func testBuild_countryIsCopiedNotMoved() {
        let event = makeEvent(payload: ["country": AnyCodable("MX")])
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertEqual(envelope.context.country, "MX")
        XCTAssertEqual(envelope.events[0].payload["country"]?.value as? String, "MX",
                       "country precisa ficar no payload: é o trait explícito do identify()")
    }

    func testBuild_regionCodeAliasFeedsCountry() {
        let envelope = V2EnvelopeBuilder.build(events: [makeEvent(payload: ["regionCode": AnyCodable("BR")])])
        XCTAssertEqual(envelope.context.country, "BR")
    }

    // MARK: installEventId / installClassification

    func testBuild_validUUIDv4InstallEventIdBecomesEventId() {
        let installId = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
        let event = makeEvent(payload: ["installEventId": AnyCodable(installId)])
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertEqual(envelope.events[0].id, installId, "o dedup de install no servidor depende desse id")
        XCTAssertNil(envelope.events[0].payload["installEventId"])
    }

    func testBuild_invalidInstallEventIdFallsBackToNewUUID() {
        let event = makeEvent(payload: ["installEventId": AnyCodable("not-a-uuid")])
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertNotEqual(envelope.events[0].id, "not-a-uuid")
        XCTAssertFalse(envelope.events[0].id.isEmpty)
    }

    func testBuild_uuidV1IsRejectedAsInstallEventId() {
        // Versão 1 (dígito 1 no 3º grupo) não é v4 — o servidor só dedupa v4.
        let event = makeEvent(payload: ["installEventId": AnyCodable("3f2504e0-4f89-11d3-9a0c-0305e82c3301")])
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertNotEqual(envelope.events[0].id, "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
    }

    func testBuild_installClassificationBecomesEventSibling() throws {
        let event = makeEvent(payload: ["installClassification": AnyCodable("paid")])
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertEqual(envelope.events[0].installClassification, "paid")
        XCTAssertNil(envelope.events[0].payload["installClassification"])

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any]
        let firstEvent = (json?["events"] as? [[String: Any]])?.first
        XCTAssertEqual(firstEvent?["installClassification"] as? String, "paid",
                       "installClassification é irmão de payload, não filho")
    }

    func testBuild_emptyInstallClassificationIsIgnored() {
        let envelope = V2EnvelopeBuilder.build(events: [makeEvent(payload: ["installClassification": AnyCodable("")])])
        XCTAssertNil(envelope.events[0].installClassification)
    }

    func testBuild_noInstallClassificationKeyOmittedFromJSON() throws {
        let envelope = V2EnvelopeBuilder.build(events: [makeEvent()])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any]
        let firstEvent = (json?["events"] as? [[String: Any]])?.first
        XCTAssertNil(firstEvent?["installClassification"])
    }

    // MARK: context.ids espelhado do payload (copy, não move)

    func testBuild_idsMirroredFromPayloadButKept() {
        let event = makeEvent(payload: [
            "idfv": AnyCodable("IDFV-1"),
            "idfa": AnyCodable("IDFA-1"),
            "fbAnonId": AnyCodable("fb-anon-1"),
        ])
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertEqual(envelope.context.ids?["idfv"]?.value as? String, "IDFV-1")
        XCTAssertEqual(envelope.context.ids?["idfa"]?.value as? String, "IDFA-1")
        XCTAssertEqual(envelope.context.ids?["fb_anon_id"]?.value as? String, "fb-anon-1")
        XCTAssertEqual(envelope.events[0].payload["idfv"]?.value as? String, "IDFV-1",
                       "ids são copiados, não movidos — o parser antigo lê do payload")
    }

    func testBuild_providerIdsWinOverPayloadIds() {
        var ctx = IngestContext()
        ctx.ids = ["idfv": AnyCodable("PROVIDER")]
        let event = makeEvent(payload: ["idfv": AnyCodable("PAYLOAD")])
        let envelope = V2EnvelopeBuilder.build(events: [event], providerContext: ctx)
        XCTAssertEqual(envelope.context.ids?["idfv"]?.value as? String, "PROVIDER")
    }

    // MARK: distinct_id do EventInput

    func testBuild_eventInputDistinctIdUsedWhenPayloadHasNone() {
        let event = makeEvent(payload: [:], distinctId: "from_input")
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertEqual(envelope.context.distinctId, "from_input")
    }

    func testBuild_payloadDistinctIdWinsOverEventInput() {
        let event = makeEvent(payload: ["distinct_id": AnyCodable("from_payload")], distinctId: "from_input")
        let envelope = V2EnvelopeBuilder.build(events: [event])
        XCTAssertEqual(envelope.context.distinctId, "from_payload")
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
