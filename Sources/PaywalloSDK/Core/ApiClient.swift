import Foundation

/// Server V2 response envelope: `{ data: T, meta: { version, request_id, timestamp } }`.
/// Used by /sdk/purchases/validate, /sdk/purchases/status and other V2 endpoints.
struct V2Envelope<T: Decodable>: Decodable {
    let data: T
}

public final class ApiClient {
    public let httpClient: HttpClient
    public let appKey: String
    private var environment: Environment
    private var debug: Bool
    private var eventContextProvider: (() -> IngestContext)?
    private var distinctIdProvider: (() -> String)?
    public var onError: ((PaywalloError) -> Void)?

    public init(serverUrl: String, appKey: String, debug: Bool = false, environment: Environment = .production) {
        self.appKey = appKey
        self.debug = debug
        self.environment = environment
        self.httpClient = HttpClient(baseUrl: serverUrl, debug: debug)

        httpClient.setGlobalHeaders([
            "X-App-Key": appKey,
            "x-sdk-version": PaywalloConstants.sdkVersion,
            "x-sdk-platform": PaywalloConstants.sdkPlatform,
            "x-sdk-environment": environment.rawValue,
        ])
    }

    /// Initializer for testing: accepts a pre-built HttpClient (e.g. backed by a mock URLSession).
    init(httpClient: HttpClient, appKey: String, debug: Bool = false, environment: Environment = .production) {
        self.appKey = appKey
        self.debug = debug
        self.environment = environment
        self.httpClient = httpClient

        httpClient.setGlobalHeaders([
            "X-App-Key": appKey,
            "x-sdk-version": PaywalloConstants.sdkVersion,
            "x-sdk-platform": PaywalloConstants.sdkPlatform,
            "x-sdk-environment": environment.rawValue,
        ])
    }

    public func setDistinctIdProvider(_ provider: @escaping () -> String) {
        self.distinctIdProvider = provider
    }

    private func resolveDistinctId(_ distinctId: String?) -> String? {
        if let id = distinctId, !id.isEmpty { return id }
        let fallback = distinctIdProvider?() ?? ""
        return fallback.isEmpty ? nil : fallback
    }

    public func setEnvironment(_ env: Environment) {
        self.environment = env
        httpClient.setGlobalHeaders(["x-sdk-environment": env.rawValue])
    }

    public func getEnvironment() -> Environment { environment }

    public func setEventContextProvider(_ provider: @escaping () -> IngestContext) {
        self.eventContextProvider = provider
    }

    public func getEventContext() -> IngestContext {
        eventContextProvider?() ?? IngestContext()
    }

    /// Derive web URL from server URL — mirrors RN `deriveWebUrl()`.
    /// - Local dev (localhost/192.168.x): same host at port 3000.
    /// - api.* hostnames: replace "api." with "app.".
    /// - Production (anything else): use default web URL (paywallo.com.br).
    public func getWebUrl() -> String {
        let baseUrl = httpClient.getBaseUrl()
        guard let url = URL(string: baseUrl), let host = url.host else {
            return PaywalloConstants.defaultWebUrl
        }
        if host == "localhost" || host.hasPrefix("192.168") || host == "127.0.0.1" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.port = 3000
            return components?.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? baseUrl
        }
        if host.hasPrefix("api.") {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.host = host.replacingOccurrences(of: "api.", with: "app.", options: .anchored)
            return components?.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? baseUrl
        }
        return PaywalloConstants.defaultWebUrl
    }

    // MARK: - Identity

    public func identify(_ distinctId: String, properties: [String: AnyCodable]?, email: String?, deviceId: String?, pii: [String: String?]? = nil) async {
        // V2 schema: { distinct_id, traits: { email?, platform?, name?, country?, locale?, app_version? },
        //              attribution: { fbclid?, gclid?, ttclid?, utm_*, referrer? },
        //              phone?, firstName?, lastName?, dateOfBirth?, gender? (top-level) }
        var traits: [String: Any] = ["platform": "ios"]
        if let email = email { traits["email"] = email }

        let traitKeys: Set<String> = ["name", "country", "locale", "app_version"]
        let attributionKeys: Set<String> = [
            "utm_source", "utm_medium", "utm_campaign", "utm_content", "utm_term",
            "fbclid", "gclid", "ttclid", "referrer",
        ]
        var attribution: [String: Any] = [:]
        if let props = properties {
            for (k, v) in props {
                if traitKeys.contains(k) { traits[k] = v.value }
                else if attributionKeys.contains(k) { attribution[k] = v.value }
            }
        }
        if let pii = pii {
            for (k, v) in pii {
                guard let v = v else { continue }
                if k == "email" { traits["email"] = v }
                else if traitKeys.contains(k) { traits[k] = v }
            }
        }

        var body: [String: Any] = ["distinct_id": distinctId, "traits": traits]
        if !attribution.isEmpty { body["attribution"] = attribution }
        if let deviceId = deviceId, !deviceId.isEmpty { body["deviceId"] = deviceId }

        // PII fields sent top-level (matches RN SDK buildPiiPayload)
        if let pii = pii {
            if let phone = pii["phone"] as? String, !phone.isEmpty {
                body["phone"] = phone
            }
            if let firstName = pii["firstName"] as? String, !firstName.isEmpty {
                body["firstName"] = firstName
            }
            if let lastName = pii["lastName"] as? String, !lastName.isEmpty {
                body["lastName"] = lastName
            }
            if let dob = pii["dateOfBirth"] as? String, ApiClient.isValidDateOfBirth(dob) {
                body["dateOfBirth"] = dob
            }
            if let rawGender = pii["gender"] as? String, let g = ApiClient.normalizeGender(rawGender) {
                body["gender"] = g
            }
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: body)
            let options = RequestOptions(method: "POST", body: jsonData, skipRetry: true)
            let _ = try await httpClient.requestRaw(path: "/sdk/identity/identify", options: options)
        } catch { /* non-critical */ }
    }

    /// Validates dateOfBirth is in YYYY-MM-DD format.
    static func isValidDateOfBirth(_ dob: String) -> Bool {
        let pattern = #"^\d{4}-\d{2}-\d{2}$"#
        guard let _ = dob.range(of: pattern, options: .regularExpression) else { return false }
        return true
    }

    /// Normalizes gender to "m" or "f". Returns nil for unrecognized values.
    static func normalizeGender(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "m", "male": return "m"
        case "f", "female": return "f"
        default: return nil
        }
    }

    // MARK: - Events

    public func reportError(_ error: PaywalloError) async {
        // Body shape must match RN SDK: { errorType, message, context?, sdkVersion, platform }
        var body: [String: Any] = [
            "errorType": error.code,
            "message": error.message,
            "platform": "ios",
            "sdkVersion": PaywalloConstants.sdkVersion,
        ]
        if !error.domain.isEmpty {
            body["context"] = ["domain": error.domain]
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: body)
            let options = RequestOptions(method: "POST", body: jsonData, skipRetry: true)
            let _ = try await httpClient.requestRaw(path: "/sdk/errors", options: options)
        } catch { /* fire and forget */ }
    }

    // MARK: - Paywall

    public func getPaywall(_ placement: String) async throws -> PaywallConfig {
        let response: HttpResponse<PaywallConfig> = try await httpClient.get(path: "/sdk/paywalls/\(placement)")
        return response.data
    }

    // MARK: - Campaign

    public func getCampaign(
        _ placement: String,
        distinctId: String?,
        context: [String: AnyCodable]? = nil
    ) async throws -> CampaignResponse {
        guard let resolvedId = resolveDistinctId(distinctId) else {
            throw CampaignError(code: CampaignErrorCode.fetchFailed, message: "distinctId is required")
        }

        var path = "/sdk/campaigns/\(placement)"
        var queryItems: [String] = []
        let encoded = resolvedId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? resolvedId
        queryItems.append("distinctId=\(encoded)")
        if let context = context {
            let raw = context.mapValues { $0.value }
            if let contextData = try? JSONSerialization.data(withJSONObject: raw),
               let contextStr = String(data: contextData, encoding: .utf8),
               let contextEncoded = contextStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                queryItems.append("context=\(contextEncoded)")
            }
        }
        path += "?" + queryItems.joined(separator: "&")

        let response: HttpResponse<CampaignResponse> = try await httpClient.get(path: path)
        return response.data
    }

    public func getCampaignPlacements() async throws -> [String] {
        // Server returns { data: string[] } — RN reads res.data.data (one level into data wrapper)
        struct PlacementsResponse: Decodable {
            let data: [String]
        }
        let response: HttpResponse<PlacementsResponse> = try await httpClient.get(path: "/sdk/campaigns/placements")
        return response.data.data
    }

    public func getPrimaryCampaign(distinctId: String?) async throws -> CampaignResponse? {
        guard let resolvedId = resolveDistinctId(distinctId) else { return nil }
        let encoded = resolvedId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? resolvedId
        let path = "/campaigns/public/primary?distinctId=\(encoded)"
        let response: HttpResponse<CampaignResponse> = try await httpClient.get(path: path)
        return response.data
    }

    // MARK: - Flags

    public func evaluateFlags(keys: [String], distinctId: String?) async throws -> [String: FlagVariant] {
        let resolvedId = resolveDistinctId(distinctId)
        guard let resolvedId = resolvedId else { return [:] }

        let keysParam = keys.joined(separator: ",")
        var options = RequestOptions()
        options.headers = ["x-distinct-id": resolvedId]
        // Server returns { key: string | null } — GET /sdk/flags/evaluate via FlagPublicController
        // Map string variant directly to FlagVariant
        let response: HttpResponse<[String: String?]> = try await httpClient.get(path: "/sdk/flags/evaluate?keys=\(keysParam)", options: options)
        return response.data.mapValues { variantKey in
            FlagVariant(variant: variantKey)
        }
    }

    public func getVariant(key: String, distinctId: String?) async throws -> FlagVariant {
        guard let resolvedId = resolveDistinctId(distinctId) else { return FlagVariant(variant: nil) }
        let encoded = resolvedId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? resolvedId
        let path = "/sdk/flags/\(key)?distinctId=\(encoded)"
        let response: HttpResponse<FlagVariant> = try await httpClient.get(path: path)
        return response.data
    }

    public func getConditionalFlag(key: String, context: ConditionalFlagContext?) async throws -> ConditionalFlagResult {
        var queryItems: [String] = []
        if let ctx = context {
            if let p = ctx.platform { queryItems.append("platform=\(p)") }
            if let v = ctx.appVersion { queryItems.append("appVersion=\(v)") }
            if let c = ctx.country { queryItems.append("country=\(c)") }
            if let d = ctx.distinctId { queryItems.append("distinctId=\(d)") }
        }
        var path = "/sdk/conditional-flags/\(key)"
        if !queryItems.isEmpty { path += "?" + queryItems.joined(separator: "&") }
        let response: HttpResponse<ConditionalFlagResult> = try await httpClient.get(path: path)
        return response.data
    }

    // MARK: - Emergency Paywall

    public func getEmergencyPaywall() async throws -> EmergencyPaywallResponse {
        let response: HttpResponse<EmergencyPaywallResponse> = try await httpClient.get(path: "/sdk/emergency-paywall")
        return response.data
    }

    // MARK: - Purchases

    public func validatePurchase(_ body: [String: Any]) async throws -> ValidatePurchaseResponse {
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let options = RequestOptions(method: "POST", body: jsonData)
        // Server wraps response in V2 envelope: { data: { valid, subscription_id, ... }, meta: {...} }
        let response: HttpResponse<V2Envelope<ValidatePurchaseResponse>> = try await httpClient.request(path: "/sdk/purchases/validate", options: options)
        return response.data.data
    }

    public func getSubscriptionStatus(distinctId: String?) async throws -> SubscriptionStatusResponse {
        var path = "/sdk/purchases/status"
        if let distinctId = distinctId { path += "?distinctId=\(distinctId)" }
        // Server wraps response in V2 envelope: { data: { has_active_subscription, ... }, meta: {...} }
        let response: HttpResponse<V2Envelope<SubscriptionStatusResponse>> = try await httpClient.get(path: path)
        return response.data.data
    }

    // MARK: - Offerings & Plans

    public func getOfferings(ids: [String]?) async throws -> Data {
        var path = "/sdk/offerings"
        if let ids = ids { path += "?ids=\(ids.joined(separator: ","))" }
        let response = try await httpClient.getRaw(path: path)
        return response.data
    }

    public func getPlans() async throws -> Data {
        let response = try await httpClient.getRaw(path: "/sdk/plans")
        return response.data
    }

    public func getAllPlans() async throws -> Data {
        let response = try await httpClient.getRaw(path: "/sdk/plans/all")
        return response.data
    }

    // MARK: - Push Tokens

    public func registerToken(_ token: String, distinctId: String?) async {
        // Body shape matches RN SDK TokenRegistration.buildRegistration()
        let device = await DeviceInfo.shared.getDeviceInfo()
        // Server schema requires distinct_id (non-optional z.string().min(1)).
        // Fall back to IDFV (deviceId) when the caller has not identified yet.
        let resolvedDistinctId = distinctId ?? device.deviceId
        var body: [String: Any] = [
            "token": token,
            "platform": "ios",
            "sdk_version": PaywalloConstants.sdkVersion,
            "app_version": device.appVersion,
            "locale": device.locale,
            "timezone": device.timezone,
            // Server schema: z.enum(["sandbox", "production"]) — must be lowercase
            "environment": environment.rawValue.lowercased(),
            "distinct_id": resolvedDistinctId,
        ]
        body["deviceId"] = device.deviceId

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: body)
            let options = RequestOptions(method: "POST", body: jsonData)
            let _ = try await httpClient.requestRaw(path: "/sdk/push-tokens", options: options)
        } catch { /* non-critical */ }
    }

    public func removeToken(_ token: String, distinctId: String?) async {
        // Server handler (PushTokenController.register) parses registerDeviceTokenV2Schema
        // from request.body for both POST and DELETE — must send token + distinct_id (required).
        let resolvedDistinctId = distinctId ?? DeviceInfo.shared.getCached()?.deviceId ?? "unknown"
        let body: [String: Any] = [
            "token": token,
            "platform": "ios",
            "environment": environment.rawValue.lowercased(),
            "distinct_id": resolvedDistinctId,
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: body)
            let options = RequestOptions(method: "DELETE", body: jsonData)
            let _ = try await httpClient.requestRaw(path: "/sdk/push-tokens", options: options)
        } catch { /* non-critical */ }
    }

    private func log(_ msg: String) {
        guard debug else { return }
        print("[Paywallo:Api] \(msg)")
    }
}
