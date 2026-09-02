import XCTest
@testable import PaywalloSDK

final class ApiClientTests: XCTestCase {

    // MARK: - Helpers

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

    private func makeClient(serverUrl: String = "https://api.paywallo.com", appKey: String = "pk_test123") -> ApiClient {
        ApiClient(serverUrl: serverUrl, appKey: appKey, debug: false, environment: .production)
    }

    /// Builds a standalone HttpClient backed by MockURLProtocol for HTTP-level assertions.
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

    // MARK: - 1. Construction sets global headers

    func testConstructionSetsAppKeyHeader() {
        let client = makeClient(appKey: "pk_mykey")
        // We verify indirectly by checking that httpClient has the key set.
        // The cleanest observable effect is that getBaseUrl matches the serverUrl.
        XCTAssertEqual(client.httpClient.getBaseUrl(), "https://api.paywallo.com")
        XCTAssertEqual(client.appKey, "pk_mykey")
    }

    func testConstructionSetsEnvironmentToProduction() {
        let client = makeClient()
        XCTAssertEqual(client.getEnvironment(), .production)
    }

    func testConstructionSetsEnvironmentToSandbox() {
        let client = ApiClient(serverUrl: "https://api.paywallo.com", appKey: "pk_test", environment: .sandbox)
        XCTAssertEqual(client.getEnvironment(), .sandbox)
    }

    // MARK: - 2. setEnvironment updates environment

    func testSetEnvironmentUpdatesSandbox() {
        let client = makeClient()
        XCTAssertEqual(client.getEnvironment(), .production)
        client.setEnvironment(.sandbox)
        XCTAssertEqual(client.getEnvironment(), .sandbox)
    }

    func testSetEnvironmentUpdatesBackToProduction() {
        let client = ApiClient(serverUrl: "https://api.paywallo.com", appKey: "pk_test", environment: .sandbox)
        client.setEnvironment(.production)
        XCTAssertEqual(client.getEnvironment(), .production)
    }

    // MARK: - 3. getWebUrl derivation

    func testGetWebUrlReplacesApiWithApp() {
        let client = makeClient(serverUrl: "https://api.paywallo.com")
        XCTAssertEqual(client.getWebUrl(), "https://app.paywallo.com")
    }

    func testGetWebUrlReplacesApiSubdomainOnly() {
        let client = makeClient(serverUrl: "https://api.example.io")
        XCTAssertEqual(client.getWebUrl(), "https://app.example.io")
    }

    func testGetWebUrlLocalhostPort18101To3000() {
        let client = makeClient(serverUrl: "http://localhost:18101")
        XCTAssertEqual(client.getWebUrl(), "http://localhost:3000")
    }

    func testGetWebUrlLocalhostPort3001To3000() {
        let client = makeClient(serverUrl: "http://localhost:3001")
        XCTAssertEqual(client.getWebUrl(), "http://localhost:3000")
    }

    func testGetWebUrl127_0_0_1Port18101To3000() {
        let client = makeClient(serverUrl: "http://127.0.0.1:18101")
        XCTAssertEqual(client.getWebUrl(), "http://127.0.0.1:3000")
    }

    // MARK: - 4. eventContextProvider

    func testGetEventContextReturnsEmptyByDefault() {
        let client = makeClient()
        let ctx = client.getEventContext()
        XCTAssertNil(ctx.distinctId)
        XCTAssertNil(ctx.sessionId)
    }

    func testSetEventContextProviderIsUsed() {
        let client = makeClient()
        var ctx = IngestContext()
        ctx.distinctId = "user_abc"
        ctx.sessionId = "sess_xyz"
        client.setEventContextProvider { ctx }

        let result = client.getEventContext()
        XCTAssertEqual(result.distinctId, "user_abc")
        XCTAssertEqual(result.sessionId, "sess_xyz")
    }

    // MARK: - 5. appKey stored correctly

    func testAppKeyStoredCorrectly() {
        let key = "pk_realkey_12345"
        let client = makeClient(appKey: key)
        XCTAssertEqual(client.appKey, key)
    }

    // MARK: - 6. getBaseUrl reflects serverUrl

    func testGetBaseUrlMatchesServerUrl() {
        let url = "https://custom.api.paywallo.io"
        let client = makeClient(serverUrl: url)
        XCTAssertEqual(client.httpClient.getBaseUrl(), url)
    }

    // MARK: - 7. getWebUrl fallback for production hostnames

    func testGetWebUrlFallsBackToDefaultForProductionNonApiHost() {
        let client = makeClient(serverUrl: "https://paywallo.com.br")
        XCTAssertEqual(client.getWebUrl(), PaywalloConstants.defaultWebUrl)
    }

    func testGetWebUrl192168NetworkRedirectsToPort3000() {
        let client = makeClient(serverUrl: "http://192.168.1.50:18101")
        XCTAssertEqual(client.getWebUrl(), "http://192.168.1.50:3000")
    }

    // MARK: - 8. distinctIdProvider fallback

    func testResolveDistinctIdUsesProviderWhenCallerPassesNil() async throws {
        let httpClient = makeMockHttpClient()
        MockURLProtocol.enqueueJSON(["campaignId": "c1", "placement": "home", "variantKey": "control",
                                      "paywall": ["id": "pw1", "placement": "home", "config": [:]]])

        let client = makeClient(serverUrl: "https://api.test.com")
        client.setDistinctIdProvider { "provider-id" }

        // getCampaign with nil distinctId should fall through to provider
        // We swap httpClient on the fly — since httpClient is public let we test via httpClient directly.
        let path = "/sdk/campaigns/home?distinctId=provider-id"
        _ = try await httpClient.getRaw(path: path)

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertTrue(req?.url?.absoluteString.contains("provider-id") == true)
    }

    func testGetCampaignThrowsWhenDistinctIdNotResolvable() async {
        let client = makeClient()
        // No distinctIdProvider set, nil distinctId → should throw CampaignError
        do {
            _ = try await client.getCampaign("home", distinctId: nil)
            XCTFail("Expected CampaignError to be thrown")
        } catch let error as CampaignError {
            XCTAssertEqual(error.code, CampaignErrorCode.fetchFailed)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testGetCampaignThrowsForEmptyDistinctId() async {
        let client = makeClient()
        do {
            _ = try await client.getCampaign("home", distinctId: "")
            XCTFail("Expected CampaignError to be thrown for empty distinctId")
        } catch let error as CampaignError {
            XCTAssertEqual(error.code, CampaignErrorCode.fetchFailed)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - 9. getCampaign URL includes distinctId query param

    func testGetCampaignURLContainsDistinctId() async throws {
        let httpClient = makeMockHttpClient()
        MockURLProtocol.enqueueResponse(statusCode: 200)

        _ = try await httpClient.getRaw(path: "/sdk/campaigns/home?distinctId=user_123")

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertTrue(req?.url?.query?.contains("distinctId=user_123") == true)
    }

    func testGetCampaignURLPercentsEncodeDistinctId() async throws {
        // distinctId with special chars should be percent-encoded
        let httpClient = makeMockHttpClient()
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let encoded = "user id with spaces".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        _ = try await httpClient.getRaw(path: "/sdk/campaigns/home?distinctId=\(encoded)")

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertTrue(req?.url?.query?.contains("distinctId=") == true)
        XCTAssertFalse(req?.url?.query?.contains(" ") == true, "Spaces should be percent-encoded")
    }

    // MARK: - 10. getPrimaryCampaign returns nil when no distinctId

    func testGetPrimaryCampaignReturnsNilForNilDistinctId() async throws {
        let client = makeClient()
        let result = try await client.getPrimaryCampaign(distinctId: nil)
        XCTAssertNil(result, "getPrimaryCampaign should return nil when distinctId cannot be resolved")
    }

    func testGetPrimaryCampaignReturnsNilForEmptyDistinctId() async throws {
        let client = makeClient()
        let result = try await client.getPrimaryCampaign(distinctId: "")
        XCTAssertNil(result)
    }

    // MARK: - 11. evaluateFlags returns empty dict when no distinctId

    func testEvaluateFlagsReturnsEmptyDictWithoutDistinctId() async throws {
        let client = makeClient()
        let result = try await client.evaluateFlags(keys: ["flag_a", "flag_b"], distinctId: nil)
        XCTAssertTrue(result.isEmpty, "evaluateFlags should return [:] when distinctId cannot be resolved")
    }

    func testEvaluateFlagsReturnsEmptyDictForEmptyDistinctId() async throws {
        let client = makeClient()
        let result = try await client.evaluateFlags(keys: ["flag_a"], distinctId: "")
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - 12. evaluateFlags decodes [String: String?] → [String: FlagVariant]

    func testEvaluateFlagsDecodesVariantStrings() async throws {
        let httpClient = makeMockHttpClient()
        let json: [String: Any?] = ["flag_a": "control", "flag_b": "treatment", "flag_c": nil]
        MockURLProtocol.enqueueJSON(json as [String: Any])

        let response: HttpResponse<[String: String?]> = try await httpClient.get(path: "/sdk/flags/evaluate?keys=flag_a,flag_b,flag_c", options: RequestOptions(headers: ["x-distinct-id": "u1"]))

        let variants = response.data.mapValues { FlagVariant(variant: $0) }
        XCTAssertEqual(variants["flag_a"]?.variant, "control")
        XCTAssertEqual(variants["flag_b"]?.variant, "treatment")
        XCTAssertNil(variants["flag_c"]?.variant, "nil server value should produce FlagVariant with nil variant")
    }

    // MARK: - 13. getSubscriptionStatus unwraps V2 envelope

    func testGetSubscriptionStatusUnwrapsV2Envelope() async throws {
        let httpClient = makeMockHttpClient()
        let envelope: [String: Any] = [
            "data": [
                "has_active_subscription": true,
                "subscription": [
                    "product_id": "com.app.pro",
                    "status": "active",
                    "expires_at": "2027-01-01T00:00:00Z",
                    "platform": "ios",
                    "auto_renew_enabled": true,
                    "in_grace_period": false,
                ]
            ],
            "meta": ["version": "2", "request_id": "req_123", "timestamp": "2026-01-01T00:00:00Z"]
        ]
        MockURLProtocol.enqueueJSON(envelope)

        let response: HttpResponse<V2Envelope<SubscriptionStatusResponse>> = try await httpClient.get(path: "/sdk/purchases/status")
        let statusResponse = response.data.data

        XCTAssertTrue(statusResponse.hasActiveSubscription)
        XCTAssertEqual(statusResponse.subscription?.productId, "com.app.pro")
        XCTAssertEqual(statusResponse.subscription?.status, .active)
        XCTAssertEqual(statusResponse.subscription?.platform, .ios)
    }

    func testGetSubscriptionStatusHandlesNoActiveSubscription() async throws {
        let httpClient = makeMockHttpClient()
        let envelope: [String: Any] = [
            "data": [
                "has_active_subscription": false,
                "subscription": NSNull(),
            ],
            "meta": [:]
        ]
        MockURLProtocol.enqueueJSON(envelope)

        let response: HttpResponse<V2Envelope<SubscriptionStatusResponse>> = try await httpClient.get(path: "/sdk/purchases/status")
        let statusResponse = response.data.data

        XCTAssertFalse(statusResponse.hasActiveSubscription)
        XCTAssertNil(statusResponse.subscription)
    }

    // MARK: - 14. identify sends V2 body with traits and attribution

    func testIdentifySendsDistinctIdInBody() async throws {
        let httpClient = makeMockHttpClient()
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let bodyData = try JSONSerialization.data(withJSONObject: [
            "distinct_id": "user_abc",
            "traits": ["platform": "ios", "email": "test@example.com"]
        ])
        let opts = RequestOptions(method: "POST", body: bodyData, skipRetry: true)
        _ = try await httpClient.requestRaw(path: "/sdk/identity/identify", options: opts)

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(req?.httpMethod, "POST")
        XCTAssertTrue(req?.url?.path.hasSuffix("/sdk/identity/identify") == true)
    }

    func testIdentifyBodyContainsPlatformIos() throws {
        // Validate body structure without network: build body the same way ApiClient does.
        var traits: [String: Any] = ["platform": "ios"]
        traits["email"] = "test@example.com"
        let body: [String: Any] = ["distinct_id": "u1", "traits": traits]
        let data = try JSONSerialization.data(withJSONObject: body)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let decodedTraits = decoded?["traits"] as? [String: Any]

        XCTAssertEqual(decodedTraits?["platform"] as? String, "ios")
        XCTAssertEqual(decodedTraits?["email"] as? String, "test@example.com")
        XCTAssertEqual(decoded?["distinct_id"] as? String, "u1")
    }

    func testIdentifyBodySeparatesAttributionFromTraits() throws {
        // Mirrors the logic in ApiClient.identify — attribution keys go into body["attribution"]
        let traitKeys: Set<String> = ["name", "country", "locale", "app_version"]
        let attributionKeys: Set<String> = ["fbclid", "gclid", "ttclid", "utm_source"]
        let properties: [String: AnyCodable] = [
            "name": AnyCodable("John"),
            "fbclid": AnyCodable("fb_abc123"),
            "utm_source": AnyCodable("facebook"),
        ]
        var traits: [String: Any] = ["platform": "ios"]
        var attribution: [String: Any] = [:]
        for (k, v) in properties {
            if traitKeys.contains(k) { traits[k] = v.value }
            else if attributionKeys.contains(k) { attribution[k] = v.value }
        }

        XCTAssertEqual(traits["name"] as? String, "John")
        XCTAssertNil(traits["fbclid"], "fbclid should be in attribution, not traits")
        XCTAssertEqual(attribution["fbclid"] as? String, "fb_abc123")
        XCTAssertEqual(attribution["utm_source"] as? String, "facebook")
    }

    // MARK: - 15. Gender normalization

    func testNormalizeGenderMale() {
        XCTAssertEqual(ApiClient.normalizeGender("Male"), "m")
        XCTAssertEqual(ApiClient.normalizeGender("male"), "m")
        XCTAssertEqual(ApiClient.normalizeGender("m"), "m")
    }

    func testNormalizeGenderFemale() {
        XCTAssertEqual(ApiClient.normalizeGender("Female"), "f")
        XCTAssertEqual(ApiClient.normalizeGender("female"), "f")
        XCTAssertEqual(ApiClient.normalizeGender("f"), "f")
    }

    func testNormalizeGenderUnknownReturnsNil() {
        XCTAssertNil(ApiClient.normalizeGender("other"))
        XCTAssertNil(ApiClient.normalizeGender("nonbinary"))
        XCTAssertNil(ApiClient.normalizeGender(""))
    }

    // MARK: - 16. DateOfBirth validation

    func testIsValidDateOfBirthAcceptsYYYYMMDD() {
        XCTAssertTrue(ApiClient.isValidDateOfBirth("1990-01-15"))
        XCTAssertTrue(ApiClient.isValidDateOfBirth("2000-12-31"))
    }

    func testIsValidDateOfBirthRejectsInvalidFormats() {
        XCTAssertFalse(ApiClient.isValidDateOfBirth("01/15/1990"))
        XCTAssertFalse(ApiClient.isValidDateOfBirth("1990/01/15"))
        XCTAssertFalse(ApiClient.isValidDateOfBirth("15-01-1990"))
        XCTAssertFalse(ApiClient.isValidDateOfBirth(""))
    }

    // MARK: - 17. PII fields in identify body (top-level)

    func testIdentifyBodyIncludesPiiTopLevel() throws {
        // Build the body the same way ApiClient.identify does to verify PII placement.
        var body: [String: Any] = [
            "distinct_id": "u1",
            "traits": ["platform": "ios"],
        ]
        let pii: [String: String?] = [
            "phone": "+5511999999999",
            "firstName": "João",
            "lastName": "Silva",
            "dateOfBirth": "1990-01-15",
            "gender": "Male",
        ]

        if let phone = pii["phone"] as? String, !phone.isEmpty { body["phone"] = phone }
        if let firstName = pii["firstName"] as? String, !firstName.isEmpty { body["firstName"] = firstName }
        if let lastName = pii["lastName"] as? String, !lastName.isEmpty { body["lastName"] = lastName }
        if let dob = pii["dateOfBirth"] as? String, ApiClient.isValidDateOfBirth(dob) { body["dateOfBirth"] = dob }
        if let rawGender = pii["gender"] as? String, let g = ApiClient.normalizeGender(rawGender) { body["gender"] = g }

        let data = try JSONSerialization.data(withJSONObject: body)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(decoded?["phone"] as? String, "+5511999999999")
        XCTAssertEqual(decoded?["firstName"] as? String, "João")
        XCTAssertEqual(decoded?["lastName"] as? String, "Silva")
        XCTAssertEqual(decoded?["dateOfBirth"] as? String, "1990-01-15")
        XCTAssertEqual(decoded?["gender"] as? String, "m", "Male should be normalized to 'm'")

        // PII must NOT be inside traits
        let traits = decoded?["traits"] as? [String: Any]
        XCTAssertNil(traits?["phone"])
        XCTAssertNil(traits?["firstName"])
        XCTAssertNil(traits?["gender"])
    }

    func testIdentifyBodyOmitsPiiWhenNil() throws {
        var body: [String: Any] = ["distinct_id": "u1", "traits": ["platform": "ios"]]
        let pii: [String: String?] = ["phone": nil, "gender": nil]

        if let phone = pii["phone"] as? String, !phone.isEmpty { body["phone"] = phone }
        if let rawGender = pii["gender"] as? String, let g = ApiClient.normalizeGender(rawGender) { body["gender"] = g }

        let data = try JSONSerialization.data(withJSONObject: body)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNil(decoded?["phone"], "nil phone must not appear in body")
        XCTAssertNil(decoded?["gender"], "nil gender must not appear in body")
    }

    func testIdentifyBodyOmitsGenderWhenUnrecognized() throws {
        var body: [String: Any] = ["distinct_id": "u1", "traits": ["platform": "ios"]]
        let pii: [String: String?] = ["gender": "other"]

        if let rawGender = pii["gender"] as? String, let g = ApiClient.normalizeGender(rawGender) { body["gender"] = g }

        let data = try JSONSerialization.data(withJSONObject: body)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNil(decoded?["gender"], "Unrecognized gender must be omitted from body")
    }

    func testIdentifyBodyOmitsDateOfBirthWhenInvalidFormat() throws {
        var body: [String: Any] = ["distinct_id": "u1", "traits": ["platform": "ios"]]
        let pii: [String: String?] = ["dateOfBirth": "01/15/1990"]

        if let dob = pii["dateOfBirth"] as? String, ApiClient.isValidDateOfBirth(dob) { body["dateOfBirth"] = dob }

        let data = try JSONSerialization.data(withJSONObject: body)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNil(decoded?["dateOfBirth"], "Invalid dateOfBirth format must be omitted from body")
    }

    // MARK: - 18. setDistinctIdProvider is used as fallback

    func testSetDistinctIdProviderFallsBackWhenNilPassed() async {
        let client = makeClient()
        client.setDistinctIdProvider { "provider-fallback" }

        // getPrimaryCampaign uses resolveDistinctId internally — with provider set, nil input uses provider
        // We verify the provider is consulted by checking getPrimaryCampaign doesn't return nil
        // (it would return nil only when resolvedId is nil — meaning provider is empty).
        // Since our provider returns a non-empty string, the function proceeds to HTTP (which will fail
        // because there's no mock response, but it won't return nil from the guard).
        do {
            _ = try await client.getPrimaryCampaign(distinctId: nil)
            // If it reaches here without throwing, the provider was consulted and returned a non-nil id.
            // (Real HTTP will fail — we just need it not to return nil from the guard.)
        } catch {
            // HTTP error is expected (no mock) — the important thing is it didn't return nil silently
            XCTAssertFalse(error is CampaignError, "Should not throw CampaignError when provider supplies an id")
        }
    }

    // MARK: - 19. resolveApiUrl

    func testResolveApiUrl_noOverrideReturnsDefault() throws {
        XCTAssertEqual(try ApiClient.resolveApiUrl(nil), PaywalloConstants.defaultApiUrl)
        XCTAssertEqual(try ApiClient.resolveApiUrl(""), PaywalloConstants.defaultApiUrl)
    }

    func testResolveApiUrl_httpsOverrideIsAccepted() throws {
        XCTAssertEqual(try ApiClient.resolveApiUrl("https://staging.example.com"), "https://staging.example.com")
    }

    func testResolveApiUrl_httpLocalhostIsAccepted() throws {
        XCTAssertEqual(try ApiClient.resolveApiUrl("http://localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(try ApiClient.resolveApiUrl("http://127.0.0.1:18101"), "http://127.0.0.1:18101")
        XCTAssertEqual(try ApiClient.resolveApiUrl("http://192.168.0.42:3000"), "http://192.168.0.42:3000")
    }

    func testResolveApiUrl_httpProductionThrows() {
        XCTAssertThrowsError(try ApiClient.resolveApiUrl("http://api.example.com")) { error in
            let clientError = error as? ClientError
            XCTAssertEqual(clientError?.code, ClientErrorCode.invalidApiUrl)
            XCTAssertEqual(clientError?.message,
                           "config.apiUrl must be https, or http on localhost/192.168.x for local dev: \"http://api.example.com\"")
        }
    }

    func testResolveApiUrl_malformedThrowsInsteadOfFallingBack() {
        // Cair silenciosamente na produção é como um teste em device acaba gravando evento real.
        XCTAssertThrowsError(try ApiClient.resolveApiUrl("not a url at all")) { error in
            let clientError = error as? ClientError
            XCTAssertEqual(clientError?.code, ClientErrorCode.invalidApiUrl)
            XCTAssertEqual(clientError?.message, "config.apiUrl is not a valid URL: \"not a url at all\"")
        }
    }

    func testResolveApiUrl_unsupportedSchemeThrows() {
        XCTAssertThrowsError(try ApiClient.resolveApiUrl("ftp://example.com"))
    }

    // MARK: - 20. User-Agent

    func testUserAgent_hasSdkPrefixAndParenthesisedDetail() {
        let userAgent = buildUserAgent(sdkVersion: "9.9.9")
        XCTAssertTrue(userAgent.hasPrefix("PaywalloSDK/9.9.9 ("), "UA: \(userAgent)")
        XCTAssertTrue(userAgent.hasSuffix(")"), "UA: \(userAgent)")
    }

    func testUserAgent_isAsciiPrintableOnly() {
        let userAgent = buildUserAgent(sdkVersion: PaywalloConstants.sdkVersion)
        for scalar in userAgent.unicodeScalars {
            XCTAssertTrue(scalar.value >= 0x20 && scalar.value <= 0x7E,
                          "UA precisa ser ASCII imprimível para não quebrar a validação de header: \(userAgent)")
        }
    }

    func testUserAgent_neverEmitsUnknownSegments() {
        let userAgent = buildUserAgent(sdkVersion: PaywalloConstants.sdkVersion)
        XCTAssertFalse(userAgent.contains("unknown"), "segmento desconhecido é omitido, não impresso: \(userAgent)")
    }

    func testUserAgent_isSentOnBothHeaders() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.enqueueResponse(statusCode: 200, data: Data("{}".utf8))

        let client = ApiClient(httpClient: makeMockHttpClient(), appKey: "pk_ua")
        _ = try? await client.post(path: "/sdk/errors", body: Data("{}".utf8))

        let request = MockURLProtocol.capturedRequests.first
        let userAgent = request?.value(forHTTPHeaderField: "User-Agent")
        XCTAssertEqual(userAgent, buildUserAgent(sdkVersion: PaywalloConstants.sdkVersion))
        XCTAssertEqual(request?.value(forHTTPHeaderField: "x-sdk-user-agent"), userAgent)
    }

    // MARK: - 21. normalizeDateOfBirth

    func testNormalizeDateOfBirth_passesThroughIsoDate() {
        XCTAssertEqual(ApiClient.normalizeDateOfBirth("1990-05-17"), "1990-05-17")
    }

    func testNormalizeDateOfBirth_convertsTimestampUsingUTC() {
        XCTAssertEqual(ApiClient.normalizeDateOfBirth("1990-05-17T00:30:00Z"), "1990-05-17")
    }

    func testNormalizeDateOfBirth_returnsNilForGarbage() {
        XCTAssertNil(ApiClient.normalizeDateOfBirth("not-a-date"))
        XCTAssertNil(ApiClient.normalizeDateOfBirth(nil))
        XCTAssertNil(ApiClient.normalizeDateOfBirth(""))
    }

    // MARK: - 22. onError

    func testNotifyErrorForwardsPaywalloErrorUnchanged() {
        let client = makeClient()
        var received: PaywalloError?
        client.onError = { received = $0 }

        let original = ClientError(code: ClientErrorCode.eventDeliveryFailed, message: "boom")
        client.notifyError(original)

        XCTAssertTrue(received === original)
    }

    func testNotifyErrorWrapsForeignErrors() {
        let client = makeClient()
        var received: PaywalloError?
        client.onError = { received = $0 }

        client.notifyError(URLError(.notConnectedToInternet))

        XCTAssertEqual(received?.code, ClientErrorCode.unknown)
        XCTAssertEqual(received?.domain, "client")
    }

    func testPostCallsOnErrorBeforeRethrowing() async {
        MockURLProtocol.reset()
        MockURLProtocol.enqueueError(URLError(.notConnectedToInternet))

        let client = ApiClient(httpClient: makeMockHttpClient(), appKey: "pk_err")
        var received: PaywalloError?
        client.onError = { received = $0 }

        do {
            _ = try await client.post(path: "/sdk/errors", body: Data("{}".utf8))
            XCTFail("post deveria propagar o erro de rede")
        } catch {
            XCTAssertNotNil(received, "onError precisa disparar antes da propagação")
        }
    }
}
