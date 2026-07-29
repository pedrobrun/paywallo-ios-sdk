import XCTest
@testable import PaywalloSDK

/// Wire-contract tests: prove that the Swift SDK emits EXACTLY the payload shape
/// the backend expects (same contract as Kotlin/RN 2.5.3).
///
/// Source of truth: sdks/_analysis/wire-contract.md
///
/// Rules:
/// - Inputs are FIXED — no randomness except where unavoidable (UUIDs from the SDK itself).
/// - Parse JSON and compare keys/values — no fragile string-match.
/// - If the Swift diverges from the wire-contract, the test FAILS (not adjusted).
final class WireContractTests: XCTestCase {

    // MARK: - Shared mock session plumbing

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        session = nil
        super.tearDown()
    }

    private func makeMockHttpClient(baseUrl: String = "https://api.test.com") -> HttpClient {
        HttpClient(
            baseUrl: baseUrl,
            timeout: 10,
            retryConfig: RetryConfig(maxRetries: 0, baseDelay: 0, maxDelay: 0),
            debug: false,
            globalHeaders: [:],
            session: session
        )
    }

    private func makeApiClient(appKey: String = "pk_test_wire") -> ApiClient {
        let httpClient = makeMockHttpClient()
        let client = ApiClient(httpClient: httpClient, appKey: appKey, debug: false, environment: .production)
        return client
    }

    // MARK: - Helpers

    /// Read request body from either httpBody or httpBodyStream.
    /// URLProtocol converts httpBody to a stream, so we must check both.
    private func bodyData(from request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count > 0 { data.append(buffer, count: count) }
        }
        return data.isEmpty ? nil : data
    }

    /// Decode raw JSON body from a captured URLRequest.
    private func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
        guard let data = bodyData(from: request),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Request has no JSON body")
            return [:]
        }
        return obj
    }

    // =========================================================================
    // MARK: - 1. Envelope V2 — context fields
    // =========================================================================

    func testEnvelopeV2_contextSnakeCaseKeys() throws {
        // Fixed provider context with ALL fields from wire-contract.md
        var ctx = IngestContext()
        ctx.distinctId   = "user_abc123"
        ctx.sessionId    = "sess_xyz"
        ctx.deviceId     = "device-idfv-0001"
        ctx.appVersion   = "2.5.3"
        ctx.sdkVersion   = "2.5.3"
        ctx.platform     = "ios"
        ctx.osVersion    = "17.4"
        ctx.deviceModel  = "iPhone15,2"
        ctx.timezone     = "America/Sao_Paulo"
        ctx.locale       = "pt_BR"
        ctx.attribution  = ["fbclid": AnyCodable("fb_123"), "utm_source": AnyCodable("facebook")]
        ctx.ids          = ["idfv": AnyCodable("device-idfv-0001"), "fb_anon_id": AnyCodable("fb_anon_xyz")]

        let envelope = V2EnvelopeBuilder.build(
            events: [(family: .lifecycle, name: "lifecycle", payload: ["type": AnyCodable("cold_start")], timestamp: 1_715_000_000_000)],
            providerContext: ctx
        )

        let data = try JSONEncoder().encode(envelope)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let context = json?["context"] as? [String: Any]

        // Wire-contract specifies EXACT snake_case keys in the context object
        XCTAssertEqual(context?["distinct_id"] as? String, "user_abc123",
                       "DESVIO: distinct_id ausente ou chave errada no context")
        XCTAssertEqual(context?["session_id"] as? String, "sess_xyz")
        XCTAssertEqual(context?["device_id"] as? String, "device-idfv-0001")
        XCTAssertEqual(context?["app_version"] as? String, "2.5.3")
        XCTAssertEqual(context?["sdk_version"] as? String, "2.5.3")
        XCTAssertEqual(context?["platform"] as? String, "ios")
        XCTAssertEqual(context?["os_version"] as? String, "17.4")
        XCTAssertEqual(context?["device_model"] as? String, "iPhone15,2")
        XCTAssertEqual(context?["timezone"] as? String, "America/Sao_Paulo")
        XCTAssertEqual(context?["locale"] as? String, "pt_BR")

        // attribution sub-object
        let attribution = context?["attribution"] as? [String: Any]
        XCTAssertEqual(attribution?["fbclid"] as? String, "fb_123",
                       "DESVIO: attribution.fbclid não chegou no context")
        XCTAssertEqual(attribution?["utm_source"] as? String, "facebook")

        // ids sub-object
        let ids = context?["ids"] as? [String: Any]
        XCTAssertEqual(ids?["idfv"] as? String, "device-idfv-0001")
        XCTAssertEqual(ids?["fb_anon_id"] as? String, "fb_anon_xyz")

        // Wire-contract: context MUST NOT contain camelCase duplicates of promoted keys
        XCTAssertNil(context?["distinctId"],   "DESVIO: camelCase 'distinctId' vazou pro context wire")
        XCTAssertNil(context?["sessionId"],    "DESVIO: camelCase 'sessionId' vazou pro context wire")
        XCTAssertNil(context?["deviceId"],     "DESVIO: camelCase 'deviceId' vazou pro context wire")
        XCTAssertNil(context?["appVersion"],   "DESVIO: camelCase 'appVersion' vazou pro context wire")
        XCTAssertNil(context?["sdkVersion"],   "DESVIO: camelCase 'sdkVersion' vazou pro context wire")
        XCTAssertNil(context?["osVersion"],    "DESVIO: camelCase 'osVersion' vazou pro context wire")
        XCTAssertNil(context?["deviceModel"],  "DESVIO: camelCase 'deviceModel' vazou pro context wire")
    }

    // MARK: - 2. Envelope V2 — event structure (id, name, ts, payload)

    func testEnvelopeV2_eventHasRequiredFields() throws {
        let fixedTs: TimeInterval = 1_715_000_000_000
        let envelope = V2EnvelopeBuilder.build(
            events: [(family: .lifecycle, name: "lifecycle", payload: ["type": AnyCodable("cold_start")], timestamp: fixedTs)],
            providerContext: nil
        )

        XCTAssertEqual(envelope.events.count, 1)
        let event = envelope.events[0]

        // Wire-contract: events[].name = canonical family (NOT event_name raw)
        XCTAssertEqual(event.family, "lifecycle",
                       "DESVIO: events[].name deve ser a família canônica, não o nome cru")

        // Wire-contract: ts must be Int64 milliseconds
        XCTAssertEqual(event.timestamp, Int64(fixedTs),
                       "DESVIO: events[].ts deve ser Int64 ms (não float)")

        // Wire-contract: events[].id must be non-empty
        XCTAssertFalse(event.id.isEmpty, "events[].id deve ser uuid não vazio")

        // Verify JSON encoding uses correct keys: "name", "ts" (not "family"/"timestamp")
        let data = try JSONEncoder().encode(envelope)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let events = json?["events"] as? [[String: Any]]
        let e0 = events?.first

        XCTAssertNotNil(e0?["id"],      "wire: events[].id deve estar presente")
        XCTAssertNotNil(e0?["name"],    "wire: events[].name (não 'family') deve estar presente")
        XCTAssertNotNil(e0?["ts"],      "wire: events[].ts (não 'timestamp') deve estar presente")
        XCTAssertNotNil(e0?["payload"], "wire: events[].payload deve estar presente")

        // ts deve ser inteiro, não float — verificar no JSON bruto que não há ponto decimal
        // (JSONSerialization retorna NSNumber para todos os números, então "is Double" seria sempre true)
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("\"ts\":1715000000000") == true,
                      "DESVIO: ts deve ser inteiro no JSON (sem .0 float)")
    }

    // MARK: - 3. Envelope V2 — 7 famílias canônicas

    func testEnvelopeV2_lifecycleFamily() throws {
        let envelope = V2EnvelopeBuilder.build(
            events: [(family: .lifecycle, name: "lifecycle",
                      payload: ["type": AnyCodable("cold_start"), "session_id": AnyCodable("sess_001")],
                      timestamp: 1_715_000_000_000)],
            providerContext: nil
        )
        XCTAssertEqual(envelope.events[0].family, "lifecycle")
        // session_id deve ser promovido para o context (alias contextual)
        XCTAssertNil(envelope.events[0].payload["session_id"],
                     "DESVIO: session_id deve ser promovido para context, não ficar no payload")
        XCTAssertEqual(envelope.context.sessionId, "sess_001",
                       "DESVIO: session_id promovido para context.session_id")
    }

    func testEnvelopeV2_identifyFamily() throws {
        let envelope = V2EnvelopeBuilder.build(
            events: [(family: .identify, name: "identify",
                      payload: ["distinct_id": AnyCodable("u_001"), "email": AnyCodable("a@b.com")],
                      timestamp: 1_715_000_000_001)],
            providerContext: nil
        )
        XCTAssertEqual(envelope.events[0].family, "identify")
        // distinct_id deve ser promovido para context
        XCTAssertNil(envelope.events[0].payload["distinct_id"],
                     "DESVIO: distinct_id deve ser promovido para context")
        XCTAssertEqual(envelope.context.distinctId, "u_001")
    }

    func testEnvelopeV2_paywallFamily() throws {
        let envelope = V2EnvelopeBuilder.build(
            events: [(family: .paywall, name: "paywall",
                      payload: ["type": AnyCodable("viewed"), "paywall_id": AnyCodable("pw_001")],
                      timestamp: 1_715_000_000_002)],
            providerContext: nil
        )
        XCTAssertEqual(envelope.events[0].family, "paywall")
        // paywall_id should remain in payload (not a context alias)
        XCTAssertEqual(envelope.events[0].payload["paywall_id"]?.value as? String, "pw_001")
    }

    func testEnvelopeV2_transactionFamily() throws {
        let envelope = V2EnvelopeBuilder.build(
            events: [(family: .transaction, name: "transaction",
                      payload: [
                          "type": AnyCodable("completed"),
                          "transaction_id": AnyCodable("tx_001"),
                          "amount": AnyCodable(99.99),
                          "currency": AnyCodable("BRL"),
                      ],
                      timestamp: 1_715_000_000_003)],
            providerContext: nil
        )
        XCTAssertEqual(envelope.events[0].family, "transaction")
        XCTAssertEqual(envelope.events[0].payload["transaction_id"]?.value as? String, "tx_001")
        XCTAssertEqual(envelope.events[0].payload["currency"]?.value as? String, "BRL")
    }

    func testEnvelopeV2_onboardingFamily() throws {
        let envelope = V2EnvelopeBuilder.build(
            events: [(family: .onboarding, name: "onboarding",
                      payload: ["type": AnyCodable("step"), "step_name": AnyCodable("welcome"), "order": AnyCodable(1)],
                      timestamp: 1_715_000_000_004)],
            providerContext: nil
        )
        XCTAssertEqual(envelope.events[0].family, "onboarding")
    }

    func testEnvelopeV2_notificationFamily() throws {
        let envelope = V2EnvelopeBuilder.build(
            events: [(family: .notification, name: "notification",
                      payload: [
                          "type": AnyCodable("clicked"),
                          "notification_id": AnyCodable("notif_001"),
                          "campaign_id": AnyCodable("camp_001"),
                      ],
                      timestamp: 1_715_000_000_005)],
            providerContext: nil
        )
        XCTAssertEqual(envelope.events[0].family, "notification")
        XCTAssertEqual(envelope.events[0].payload["notification_id"]?.value as? String, "notif_001")
    }

    func testEnvelopeV2_customFamily_rawNameInPayload() throws {
        // Wire-contract: custom events get events[].name = "custom"
        // AND events[].payload.event_name = "<nome_original>"
        let envelope = V2EnvelopeBuilder.build(
            events: [(family: .custom, name: "my_button_click",
                      payload: ["button": AnyCodable("subscribe")],
                      timestamp: 1_715_000_000_006)],
            providerContext: nil
        )
        XCTAssertEqual(envelope.events[0].family, "custom",
                       "DESVIO: custom events devem ter family='custom'")
        XCTAssertEqual(envelope.events[0].payload["event_name"]?.value as? String, "my_button_click",
                       "DESVIO: nome cru deve estar em payload.event_name para eventos custom")
        // original props devem permanecer no payload
        XCTAssertEqual(envelope.events[0].payload["button"]?.value as? String, "subscribe")
    }

    func testEnvelopeV2_appInstalledCustomEvent_preservesEventName() throws {
        // $app_installed is NOT deprecated — treated as custom (family=custom),
        // with payload.event_name = "$app_installed"
        let envelope = V2EnvelopeBuilder.build(
            events: [(family: .custom, name: "$app_installed",
                      payload: ["platform": AnyCodable("ios"), "installedAt": AnyCodable(1_715_000_000_000.0)],
                      timestamp: 1_715_000_000_007)],
            providerContext: nil
        )
        XCTAssertEqual(envelope.events[0].family, "custom")
        XCTAssertEqual(envelope.events[0].payload["event_name"]?.value as? String, "$app_installed",
                       "DESVIO: $app_installed deve ter payload.event_name='$app_installed'")
    }

    // MARK: - 4. Context key promotion (camelCase → snake_case)

    func testEnvelopeV2_promotesDeviceModelFromPayload() throws {
        let envelope = V2EnvelopeBuilder.build(
            events: [(family: .custom, name: "my_event",
                      payload: ["deviceModel": AnyCodable("iPhone15,2"), "prop": AnyCodable("value")],
                      timestamp: 1_715_000_000_008)],
            providerContext: nil
        )
        XCTAssertEqual(envelope.context.deviceModel, "iPhone15,2",
                       "DESVIO: deviceModel deve ser promovido do payload para context.device_model")
        XCTAssertNil(envelope.events[0].payload["deviceModel"],
                     "DESVIO: deviceModel deve ser removido do payload após promoção")
        XCTAssertNil(envelope.events[0].payload["device_model"],
                     "DESVIO: device_model não deve aparecer no payload após promoção")
    }

    func testEnvelopeV2_promotesOsVersionAlias() throws {
        // Wire-contract: systemVersion → os_version in context
        let envelope = V2EnvelopeBuilder.build(
            events: [(family: .custom, name: "my_event",
                      payload: ["systemVersion": AnyCodable("17.4")],
                      timestamp: 1_715_000_000_009)],
            providerContext: nil
        )
        XCTAssertEqual(envelope.context.osVersion, "17.4",
                       "DESVIO: systemVersion alias deve promover para context.os_version")
        XCTAssertNil(envelope.events[0].payload["systemVersion"])
    }

    func testEnvelopeV2_providerContextWinsOverEventPayload() throws {
        // Wire-contract: provider vence — só promove se context slot está nil
        var ctx = IngestContext()
        ctx.distinctId = "provider_user"

        let envelope = V2EnvelopeBuilder.build(
            events: [(family: .custom, name: "my_event",
                      payload: ["distinct_id": AnyCodable("payload_user")],
                      timestamp: 1_715_000_000_010)],
            providerContext: ctx
        )
        XCTAssertEqual(envelope.context.distinctId, "provider_user",
                       "DESVIO: provider context deve vencer sobre promoção de payload")
    }

    func testEnvelopeV2_distinctIdFallbackFromFirstEvent() throws {
        // Wire-contract: if provider doesn't set distinct_id, falls back to events[0].payload.distinct_id
        let envelope = V2EnvelopeBuilder.build(
            events: [(family: .custom, name: "my_event",
                      payload: ["distinct_id": AnyCodable("fallback_user")],
                      timestamp: 1_715_000_000_011)],
            providerContext: nil
        )
        // After promotion, distinct_id should be in context (via alias promotion path)
        XCTAssertEqual(envelope.context.distinctId, "fallback_user",
                       "DESVIO: distinct_id do payload deve virar context.distinct_id")
    }

    func testEnvelopeV2_idsSubObjectInContext() throws {
        // Wire-contract: ids dict in payload is hoisted to context.ids
        let envelope = V2EnvelopeBuilder.build(
            events: [(family: .custom, name: "my_event",
                      payload: ["ids": AnyCodable(["idfv": "idfv-001", "fb_anon_id": "anon-001"])],
                      timestamp: 1_715_000_000_012)],
            providerContext: nil
        )
        XCTAssertNotNil(envelope.context.ids, "DESVIO: ids do payload deve ser promovido para context.ids")
        XCTAssertEqual(envelope.context.ids?["idfv"]?.value as? String, "idfv-001")
        XCTAssertEqual(envelope.context.ids?["fb_anon_id"]?.value as? String, "anon-001")
        XCTAssertNil(envelope.events[0].payload["ids"],
                     "DESVIO: ids deve ser removido do evento após promoção")
    }

    func testEnvelopeV2_attributionSubObjectInContext() throws {
        // Wire-contract: attribution dict in payload is hoisted to context.attribution
        let envelope = V2EnvelopeBuilder.build(
            events: [(family: .custom, name: "my_event",
                      payload: ["attribution": AnyCodable(["fbclid": "fb_test_123", "utm_source": "fb"])],
                      timestamp: 1_715_000_000_013)],
            providerContext: nil
        )
        XCTAssertNotNil(envelope.context.attribution,
                        "DESVIO: attribution do payload deve ser promovido para context.attribution")
        XCTAssertEqual(envelope.context.attribution?["fbclid"]?.value as? String, "fb_test_123")
        XCTAssertNil(envelope.events[0].payload["attribution"],
                     "DESVIO: attribution deve ser removido do evento após promoção")
    }

    // MARK: - 5. Default platform/sdkVersion injection

    func testEnvelopeV2_defaultsInjectedWhenContextIsNil() throws {
        let envelope = V2EnvelopeBuilder.build(
            events: [(family: .lifecycle, name: "lifecycle", payload: [:], timestamp: 1_715_000_000_014)],
            providerContext: nil
        )
        // Wire-contract: sdk_version and platform default to SDK constants
        XCTAssertEqual(envelope.context.sdkVersion, PaywalloConstants.sdkVersion,
                       "DESVIO: sdk_version deve ter default de PaywalloConstants.sdkVersion")
        XCTAssertEqual(envelope.context.platform, PaywalloConstants.sdkPlatform,
                       "DESVIO: platform deve ter default de PaywalloConstants.sdkPlatform ('ios')")
    }

    // MARK: - 6. Deprecated events — family detection

    func testEventFamilies_deprecatedSetMatchesWireContract() {
        // Wire-contract: exact list of deprecated names (silently dropped)
        let expected: Set<String> = [
            "$paywall_purchased",
            "$paywall_product_selected",
            "$core_action",
            "$campaign_impression",
            "$app_open",
            "$app_background",
            "$app_foreground",
            "session.end",
        ]
        XCTAssertEqual(EventFamilies.deprecatedEventNames, expected,
                       "DESVIO: lista de eventos deprecados diverge do wire-contract")
    }

    func testEventFamilies_appInstalledIsNotDeprecated() {
        XCTAssertFalse(EventFamilies.isDeprecated("$app_installed"),
                       "DESVIO: $app_installed não é deprecado — é evento crítico no wire-contract")
    }

    func testEventFamilies_canonicalNamesDetectedCorrectly() {
        // Wire-contract: detectFamily maps exactly 6 canonical names
        XCTAssertEqual(EventFamilies.detectFamily("lifecycle"),    .lifecycle)
        XCTAssertEqual(EventFamilies.detectFamily("identify"),     .identify)
        XCTAssertEqual(EventFamilies.detectFamily("paywall"),      .paywall)
        XCTAssertEqual(EventFamilies.detectFamily("transaction"),  .transaction)
        XCTAssertEqual(EventFamilies.detectFamily("onboarding"),   .onboarding)
        XCTAssertEqual(EventFamilies.detectFamily("notification"), .notification)
        XCTAssertEqual(EventFamilies.detectFamily("my_event"),     .custom,
                       "DESVIO: nome não-canônico deve cair em .custom")
        XCTAssertEqual(EventFamilies.detectFamily("$app_installed"), .custom,
                       "DESVIO: $app_installed deve cair em .custom (não é família)")
    }

    // MARK: - 7. Request: /sdk/identity/identify — body shape

    func testIdentifyRequest_pathAndMethod() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let client = makeApiClient()
        await client.identify("user_001", properties: nil, email: "test@example.com", deviceId: "dev-001")

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(req?.httpMethod, "POST",
                       "DESVIO: /sdk/identity/identify deve ser POST")
        XCTAssertTrue(req?.url?.path.hasSuffix("/sdk/identity/identify") == true,
                      "DESVIO: path deve ser /sdk/identity/identify")
    }

    func testIdentifyRequest_bodyHasDistinctId() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let client = makeApiClient()
        await client.identify("user_wire_001", properties: nil, email: nil, deviceId: nil)

        let req = MockURLProtocol.capturedRequests.first
        let body = try bodyJSON(req!)
        XCTAssertEqual(body["distinct_id"] as? String, "user_wire_001",
                       "DESVIO: body.distinct_id ausente no /sdk/identity/identify")
    }

    func testIdentifyRequest_traitsHasPlatformIos() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let client = makeApiClient()
        await client.identify("user_wire_002", properties: nil, email: "a@b.com", deviceId: nil)

        let req = MockURLProtocol.capturedRequests.first
        let body = try bodyJSON(req!)
        let traits = body["traits"] as? [String: Any]
        XCTAssertEqual(traits?["platform"] as? String, "ios",
                       "DESVIO: traits.platform deve ser 'ios' (hardcoded wire-contract)")
        XCTAssertEqual(traits?["email"] as? String, "a@b.com")
    }

    func testIdentifyRequest_attributionKeysRouteToAttributionField() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let client = makeApiClient()
        let props: [String: AnyCodable] = [
            "utm_source": AnyCodable("facebook"),
            "fbclid": AnyCodable("fb_abc"),
            "name": AnyCodable("John"),  // trait key — goes to traits
        ]
        await client.identify("user_wire_003", properties: props, email: nil, deviceId: nil)

        let req = MockURLProtocol.capturedRequests.first
        let body = try bodyJSON(req!)
        let attribution = body["attribution"] as? [String: Any]
        let traits = body["traits"] as? [String: Any]

        XCTAssertEqual(attribution?["utm_source"] as? String, "facebook",
                       "DESVIO: utm_source deve estar em body.attribution, não em traits")
        XCTAssertEqual(attribution?["fbclid"] as? String, "fb_abc",
                       "DESVIO: fbclid deve estar em body.attribution")
        XCTAssertEqual(traits?["name"] as? String, "John",
                       "DESVIO: name deve estar em body.traits")
        XCTAssertNil(traits?["fbclid"],  "DESVIO: fbclid não deve aparecer em traits")
        XCTAssertNil(traits?["utm_source"], "DESVIO: utm_source não deve aparecer em traits")
    }

    func testIdentifyRequest_emptyAttributionOmittedFromBody() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let client = makeApiClient()
        // No attribution keys in properties → attribution field must be absent
        await client.identify("user_wire_004", properties: nil, email: nil, deviceId: nil)

        let req = MockURLProtocol.capturedRequests.first
        let body = try bodyJSON(req!)
        XCTAssertNil(body["attribution"],
                     "DESVIO: attribution deve ser omitido quando vazio (wire-contract)")
    }

    // MARK: - 8. Request: /sdk/purchases/validate — body shape

    func testValidatePurchaseRequest_pathAndMethod() async throws {
        // Enqueue a valid validate response (V2 envelope)
        let responseEnvelope: [String: Any] = [
            "data": [
                "valid": true,
                "subscription_id": "sub_001",
                "expires_at": "2027-01-01T00:00:00Z",
                "subscription_status": "active",
                "platform": "ios",
            ]
        ]
        MockURLProtocol.enqueueJSON(responseEnvelope)

        let client = makeApiClient()
        let purchaseBody: [String: Any] = [
            "platform": "ios",
            "receipt_data": "base64_receipt_data_here",
            "product_id": "com.app.pro.monthly",
            "transaction_id": "1000000123456789",
            "price_local": 99.99,
            "currency": "BRL",
            "country": "BR",
            "distinct_id": "user_wire_005",
        ]
        _ = try await client.validatePurchase(purchaseBody)

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(req?.httpMethod, "POST",
                       "DESVIO: /sdk/purchases/validate deve ser POST")
        XCTAssertTrue(req?.url?.path.hasSuffix("/sdk/purchases/validate") == true,
                      "DESVIO: path deve ser /sdk/purchases/validate")

        let body = try bodyJSON(req!)
        // Wire-contract specifies these fields in the request body
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertNotNil(body["receipt_data"], "DESVIO: receipt_data deve estar no body")
        XCTAssertEqual(body["product_id"] as? String, "com.app.pro.monthly")
        XCTAssertEqual(body["transaction_id"] as? String, "1000000123456789")
        XCTAssertEqual(body["distinct_id"] as? String, "user_wire_005")
    }

    // MARK: - 9. Request: /sdk/attribution/deferred-match/{appKey} — body + path

    func testDeferredMatchRequest_pathContainsAppKey() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let storage = makeIsolatedStorage()
        let tracker = InstallTracker(storage: storage)
        let httpClient = HttpClient(
            baseUrl: "https://api.test.com",
            timeout: 5,
            retryConfig: RetryConfig(maxRetries: 0, baseDelay: 0, maxDelay: 0),
            debug: false,
            globalHeaders: [:],
            session: session
        )

        await tracker.performDeferredMatch(
            appKey: "pk_wire_test",
            httpClient: httpClient,
            deviceData: nil,
            advertisingIds: nil
        )

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertNotNil(req, "Deferred match deve ter feito uma request HTTP")
        XCTAssertTrue(req?.url?.path.contains("deferred-match/pk_wire_test") == true,
                      "DESVIO: appKey deve estar no PATH /sdk/attribution/deferred-match/{appKey}")
        XCTAssertEqual(req?.httpMethod, "POST")
    }

    func testDeferredMatchRequest_bodyHasRequiredFields() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let storage = makeIsolatedStorage()
        let tracker = InstallTracker(storage: storage)
        let httpClient = HttpClient(
            baseUrl: "https://api.test.com",
            timeout: 5,
            retryConfig: RetryConfig(maxRetries: 0, baseDelay: 0, maxDelay: 0),
            debug: false,
            globalHeaders: [:],
            session: session
        )
        let device = DeviceData(
            deviceId: "idfv-deferred-001",
            model: "iPhone",
            modelId: "iPhone15,2",
            systemName: "iOS",
            systemVersion: "17.4",
            appVersion: "2.5.3",
            buildNumber: "100",
            bundleId: "com.app.test",
            brand: "Apple",
            totalDisk: 128_000_000_000,
            freeDisk: 64_000_000_000,
            totalRam: 8_000_000_000,
            carrier: "Vivo",
            darwinVersion: nil,
            screenWidth: 390,
            screenHeight: 844,
            screenDensity: 3.0,
            locale: "pt_BR",
            language: "pt_BR",
            timezone: "America/Sao_Paulo"
        )
        let ads = AdvertisingIdResult(idfv: "idfv-deferred-001", idfa: nil, attStatus: .undetermined)

        await tracker.performDeferredMatch(
            appKey: "pk_wire_test",
            httpClient: httpClient,
            deviceData: device,
            advertisingIds: ads,
            fbAnonymousId: "fb_anon_deferred"
        )

        let req = MockURLProtocol.capturedRequests.first
        let body = try bodyJSON(req!)

        // Wire-contract deferred-match body fields
        XCTAssertEqual(body["platform"] as? String, "ios",
                       "DESVIO: deferred-match body.platform deve ser 'ios'")
        XCTAssertNotNil(body["installTimestamp"],
                        "DESVIO: deferred-match body.installTimestamp deve estar presente (ISO string)")
        XCTAssertEqual(body["deviceModel"] as? String, "iPhone15,2",
                       "DESVIO: deferred-match body.deviceModel deve estar presente")
        XCTAssertEqual(body["osVersion"] as? String, "17.4")
        XCTAssertEqual(body["language"] as? String, "pt_BR",
                       "DESVIO: wire-contract usa 'language' (= locale), não 'locale'")
        XCTAssertEqual(body["timezone"] as? String, "America/Sao_Paulo")
        XCTAssertEqual(body["screenWidth"] as? Int, 390)
        XCTAssertEqual(body["screenHeight"] as? Int, 844)
        XCTAssertEqual(body["idfv"] as? String, "idfv-deferred-001")
        XCTAssertEqual(body["fbAnonId"] as? String, "fb_anon_deferred")

        // Wire-contract: deferred-match DOES NOT carry global headers (fetch cru)
        // Verificamos que x-sdk-version/x-sdk-platform/x-sdk-environment NÃO estão presentes
        XCTAssertNil(req?.value(forHTTPHeaderField: "x-sdk-version"),
                     "DESVIO: deferred-match não deve enviar x-sdk-version (sem headers globais)")
        XCTAssertNil(req?.value(forHTTPHeaderField: "x-sdk-platform"),
                     "DESVIO: deferred-match não deve enviar x-sdk-platform (sem headers globais)")
        XCTAssertNil(req?.value(forHTTPHeaderField: "x-sdk-environment"),
                     "DESVIO: deferred-match não deve enviar x-sdk-environment (sem headers globais)")
    }

    // MARK: - 10. Request: /sdk/push-tokens — body shape

    func testPushTokensRegister_path() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 200)
        // registerToken calls DeviceInfo.shared.getDeviceInfo() which requires MainActor
        // We capture only the URL path since the body depends on live DeviceInfo.
        let client = makeApiClient()
        await client.registerToken("push_token_abc", distinctId: "user_wire_006")

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(req?.httpMethod, "POST")
        XCTAssertTrue(req?.url?.path.hasSuffix("/sdk/push-tokens") == true,
                      "DESVIO: push-tokens POST deve ir para /sdk/push-tokens")
    }

    func testPushTokensRegister_bodyFields() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let client = makeApiClient()
        await client.registerToken("push_token_abc", distinctId: "user_wire_006")

        let req = MockURLProtocol.capturedRequests.first
        let body = try bodyJSON(req!)

        // Wire-contract push-tokens body fields
        XCTAssertEqual(body["token"] as? String, "push_token_abc",
                       "DESVIO: body.token ausente no push-tokens")
        XCTAssertEqual(body["platform"] as? String, "ios",
                       "DESVIO: body.platform deve ser 'ios'")
        XCTAssertEqual(body["distinct_id"] as? String, "user_wire_006",
                       "DESVIO: body.distinct_id ausente")
        XCTAssertNotNil(body["sdk_version"],
                        "DESVIO: body.sdk_version ausente no push-tokens")
        XCTAssertNotNil(body["locale"],
                        "DESVIO: body.locale ausente no push-tokens")
        XCTAssertNotNil(body["timezone"],
                        "DESVIO: body.timezone ausente no push-tokens")
        // Wire-contract: environment must be lowercase "production" or "sandbox"
        let environment = body["environment"] as? String
        XCTAssertNotNil(environment, "DESVIO: body.environment ausente no push-tokens")
        XCTAssertTrue(environment == "production" || environment == "sandbox",
                      "DESVIO: environment deve ser 'production' ou 'sandbox' (lowercase)")
    }

    func testPushTokensDelete_pathAndMethod() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let client = makeApiClient()
        await client.removeToken("push_token_abc", distinctId: "user_wire_007")

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(req?.httpMethod, "DELETE",
                       "DESVIO: removeToken deve usar DELETE")
        XCTAssertTrue(req?.url?.path.hasSuffix("/sdk/push-tokens") == true,
                      "DESVIO: removeToken deve ir para /sdk/push-tokens")

        let body = try bodyJSON(req!)
        XCTAssertEqual(body["token"] as? String, "push_token_abc")
        XCTAssertEqual(body["distinct_id"] as? String, "user_wire_007")
    }

    // MARK: - 11. Global headers present on SDK requests

    func testGlobalHeaders_xAppKeyPresentOnIdentify() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let client = makeApiClient(appKey: "pk_wire_header")
        await client.identify("u1", properties: nil, email: nil, deviceId: nil)

        let req = MockURLProtocol.capturedRequests.first
        // X-App-Key must be present on all requests via ApiClient
        XCTAssertEqual(req?.value(forHTTPHeaderField: "X-App-Key"), "pk_wire_header",
                       "DESVIO: X-App-Key deve estar em toda request do ApiClient")
    }

    func testGlobalHeaders_sdkVersionPresentOnIdentify() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let client = makeApiClient()
        await client.identify("u1", properties: nil, email: nil, deviceId: nil)

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(req?.value(forHTTPHeaderField: "x-sdk-version"), PaywalloConstants.sdkVersion,
                       "DESVIO: x-sdk-version deve estar em toda request do ApiClient")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "x-sdk-platform"), "ios",
                       "DESVIO: x-sdk-platform deve ser 'ios'")
        XCTAssertNotNil(req?.value(forHTTPHeaderField: "x-sdk-environment"),
                        "DESVIO: x-sdk-environment deve estar presente")
    }

    // MARK: - 12. Constants match wire-contract

    func testConstants_defaultApiUrl() {
        // Wire-contract: DEFAULT_API_URL = "https://panel.lucasqueiroga.shop"
        XCTAssertEqual(PaywalloConstants.defaultApiUrl, "https://panel.lucasqueiroga.shop",
                       "DESVIO: defaultApiUrl diverge do wire-contract")
    }

    func testConstants_sdkVersion() {
        // Wire-contract: version 2.6.0
        XCTAssertEqual(PaywalloConstants.sdkVersion, "2.6.0",
                       "DESVIO: sdkVersion diverge do wire-contract (esperado 2.6.0)")
    }

    func testConstants_sdkPlatform() {
        XCTAssertEqual(PaywalloConstants.sdkPlatform, "ios")
    }

    func testConstants_batchMaxSize() {
        // Wire-contract: BATCH_MAX_SIZE = 25
        XCTAssertEqual(PaywalloConstants.batchMaxSize, 25,
                       "DESVIO: batchMaxSize diverge do wire-contract (esperado 25)")
    }

    func testConstants_batchFlushMs() {
        // Wire-contract: BATCH_FLUSH_MS = 10_000
        XCTAssertEqual(PaywalloConstants.batchFlushMs, 10_000,
                       "DESVIO: batchFlushMs diverge do wire-contract (esperado 10000ms)")
    }

    // MARK: - 13. IngestEvent JSON key names

    func testIngestEvent_jsonUsesCorrectCodingKeys() throws {
        let event = IngestEvent(id: "fixed-id-001", family: "lifecycle", timestamp: 1_715_000_000_000, payload: [:])
        let data = try JSONEncoder().encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Wire-contract CodingKeys: family→"name", timestamp→"ts"
        XCTAssertNotNil(json?["name"],      "DESVIO: family deve ser codificado como 'name'")
        XCTAssertNotNil(json?["ts"],        "DESVIO: timestamp deve ser codificado como 'ts'")
        XCTAssertNotNil(json?["id"],        "id deve estar presente")
        XCTAssertNotNil(json?["payload"],   "payload deve estar presente")
        XCTAssertNil(json?["family"],       "DESVIO: 'family' não deve aparecer no JSON (deve ser 'name')")
        XCTAssertNil(json?["timestamp"],    "DESVIO: 'timestamp' não deve aparecer no JSON (deve ser 'ts')")

        // ts deve ser inteiro no JSON (sem .0 float) — Zod usa z.number().int()
        // JSONSerialization sempre retorna NSNumber, então verificamos no JSON string bruto
        let rawJson = String(data: try JSONEncoder().encode(event), encoding: .utf8) ?? ""
        XCTAssertFalse(rawJson.contains("\"ts\":") && rawJson.contains(".0"),
                       "DESVIO: ts não deve ter decimal .0 no JSON (z.number().int())")
    }

    func testIngestContext_jsonUsesCorrectCodingKeys() throws {
        var ctx = IngestContext()
        ctx.distinctId  = "u1"
        ctx.sessionId   = "s1"
        ctx.deviceId    = "d1"
        ctx.appVersion  = "1.0"
        ctx.sdkVersion  = "2.5.3"
        ctx.platform    = "ios"
        ctx.osVersion   = "17.0"
        ctx.deviceModel = "iPhone15,2"

        let data = try JSONEncoder().encode(ctx)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Wire-contract: all context keys must be snake_case in wire
        XCTAssertNotNil(json?["distinct_id"])
        XCTAssertNotNil(json?["session_id"])
        XCTAssertNotNil(json?["device_id"])
        XCTAssertNotNil(json?["app_version"])
        XCTAssertNotNil(json?["sdk_version"])
        XCTAssertNotNil(json?["os_version"])
        XCTAssertNotNil(json?["device_model"])

        // Camel case must NOT appear
        XCTAssertNil(json?["distinctId"])
        XCTAssertNil(json?["sessionId"])
        XCTAssertNil(json?["deviceId"])
        XCTAssertNil(json?["appVersion"])
        XCTAssertNil(json?["sdkVersion"])
        XCTAssertNil(json?["osVersion"])
        XCTAssertNil(json?["deviceModel"])
    }

    // MARK: - Private helpers

    private func makeIsolatedStorage() -> SecureStorage {
        let suiteName = "com.paywallo.wire.tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        let native = NativeStorage(service: suiteName, defaults: suite)
        return SecureStorage(nativeStorage: native)
    }
}
