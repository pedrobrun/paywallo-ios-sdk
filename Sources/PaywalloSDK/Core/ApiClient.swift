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
    /// Backs the cache-only reads that must never trigger a round trip (attribution flags).
    private let cache = ApiCache()
    private var eventContextProvider: (() -> IngestContext)?
    private var distinctIdProvider: (() -> String)?
    public var onError: ((PaywalloError) -> Void)?

    /// Resolves the API base URL from `config.apiUrl`, validating the format. Returns the
    /// default when there is no override, and THROWS on a malformed one — a typo silently
    /// falling back to production is how a device test ends up writing real events.
    public static func resolveApiUrl(_ overrideUrl: String?) throws -> String {
        guard let overrideUrl = overrideUrl, !overrideUrl.isEmpty else {
            return PaywalloConstants.defaultApiUrl
        }

        guard let parsed = URL(string: overrideUrl), let scheme = parsed.scheme else {
            throw ClientError(
                code: ClientErrorCode.invalidApiUrl,
                message: "config.apiUrl is not a valid URL: \"\(overrideUrl)\""
            )
        }

        let host = parsed.host ?? ""
        let isHttps = scheme == "https"
        let isLocalHttp = scheme == "http"
            && host.range(of: #"^(localhost|127\.0\.0\.1|192\.168\.\d{1,3}\.\d{1,3})$"#, options: .regularExpression) != nil
        guard isHttps || isLocalHttp else {
            throw ClientError(
                code: ClientErrorCode.invalidApiUrl,
                message: "config.apiUrl must be https, or http on localhost/192.168.x for local dev: \"\(overrideUrl)\""
            )
        }

        return overrideUrl
    }

    public init(
        serverUrl: String,
        appKey: String,
        debug: Bool = false,
        environment: Environment = .production,
        timeout: TimeInterval = PaywalloConstants.defaultTimeout
    ) {
        self.appKey = appKey
        self.debug = debug
        self.environment = environment
        self.httpClient = HttpClient(baseUrl: serverUrl, timeout: timeout, debug: debug)

        httpClient.setGlobalHeaders(Self.buildSdkHeaders(appKey: appKey, environment: environment))
    }

    /// Initializer for testing: accepts a pre-built HttpClient (e.g. backed by a mock URLSession).
    init(httpClient: HttpClient, appKey: String, debug: Bool = false, environment: Environment = .production) {
        self.appKey = appKey
        self.debug = debug
        self.environment = environment
        self.httpClient = httpClient

        httpClient.setGlobalHeaders(Self.buildSdkHeaders(appKey: appKey, environment: environment))
    }

    /// Baseline telemetry headers carried by every outgoing request. The User-Agent goes out
    /// twice on purpose: `User-Agent` is what ua-parser-js reads server-side, and
    /// `x-sdk-user-agent` survives the proxies and CDNs that rewrite the standard header.
    private static func buildSdkHeaders(appKey: String, environment: Environment) -> [String: String] {
        let userAgent = buildUserAgent(sdkVersion: PaywalloConstants.sdkVersion)
        return [
            "X-App-Key": appKey,
            "x-sdk-version": PaywalloConstants.sdkVersion,
            "x-sdk-platform": PaywalloConstants.sdkPlatform,
            "x-sdk-environment": environment.rawValue,
            "User-Agent": userAgent,
            "x-sdk-user-agent": userAgent,
        ]
    }

    // MARK: - Request primitives

    /// Fires `config.onError` without a real exception — used by callers outside ApiClient
    /// (e.g. an event dropped for lack of a distinctId).
    public func notifyError(_ error: Error) {
        guard let onError = onError else { return }
        onError(error as? PaywalloError
            ?? ClientError(code: ClientErrorCode.unknown, message: error.localizedDescription))
    }

    public func get<T: Decodable>(path: String, options: RequestOptions? = nil) async throws -> HttpResponse<T> {
        do {
            return try await httpClient.get(path: path, options: options)
        } catch {
            notifyError(error)
            throw error
        }
    }

    public func post(path: String, body: Data, skipRetry: Bool = false) async throws -> HttpResponse<Data> {
        do {
            let options = RequestOptions(method: "POST", body: body, skipRetry: skipRetry)
            return try await httpClient.requestRaw(path: path, options: options)
        } catch {
            notifyError(error)
            throw error
        }
    }

    /// Single entry point for the retry policy + durable retry of critical requests.
    /// `payload` is the FINAL encoded body: it is what `PendingRetry` persists and what it
    /// re-posts byte-for-byte, so nothing downstream may rebuild or re-wrap it.
    public func postWithQueue(
        url: String,
        payload: Data,
        label: String,
        priority: EventPriority = .normal
    ) async {
        await PaywalloSDK.postWithQueue(
            deps: queueDeps(),
            url: url,
            payload: payload,
            label: label,
            priority: priority
        )
    }

    private func queueDeps() -> QueueDeps {
        QueueDeps(
            getAppKey: { [appKey] in appKey },
            isDebug: { [weak self] in self?.debug ?? false },
            post: { [weak self] path, body, skipRetry in
                guard let self = self else {
                    throw ClientError(code: ClientErrorCode.notInitialized, message: "ApiClient released")
                }
                return try await self.post(path: path, body: body, skipRetry: skipRetry)
            },
            onError: { [weak self] error in self?.notifyError(error) }
        )
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

    // MARK: - Attribution Flags

    private static let attributionFlagsCacheKey = "attribution_flags"

    /// Cache-only read: `$app_installed` must NEVER wait for a round trip. A cache miss means
    /// "no answer yet", not "disabled", so the caller falls back to enabled.
    public func getAttributionFlagsFromCache() -> AttributionFlags? {
        cache.get(Self.attributionFlagsCacheKey)
    }

    /// Warms the cache for the next read — never awaited from an event-critical path.
    public func refreshAttributionFlags() async {
        struct Envelope: Decodable { let data: AttributionFlags }
        do {
            let response: HttpResponse<Envelope> = try await httpClient.get(path: "/sdk/flags")
            guard response.ok else { return }
            cache.set(Self.attributionFlagsCacheKey, value: response.data.data)
        } catch {
            // best-effort — callers fall back to their own default on a cache miss
        }
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
        func piiValue(_ key: String) -> String? {
            guard let outer = pii?[key], let value = outer, !value.isEmpty else { return nil }
            return value
        }
        if let phone = piiValue("phone") { body["phone"] = phone }
        if let firstName = piiValue("firstName") { body["firstName"] = firstName }
        if let lastName = piiValue("lastName") { body["lastName"] = lastName }
        if let dob = ApiClient.normalizeDateOfBirth(piiValue("dateOfBirth")) { body["dateOfBirth"] = dob }
        if let gender = ApiClient.normalizeGender(piiValue("gender") ?? "") { body["gender"] = gender }
        if let zipCode = piiValue("zipCode")?.trimmingCharacters(in: .whitespacesAndNewlines), !zipCode.isEmpty {
            body["zipCode"] = zipCode
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }
        // critical: identify carries PII plus the attribution signals (fbclid/utm/gclid) used
        // for matching — losing it on a network blip degrades attribution. A failure lands in
        // PendingRetry (durable).
        await postWithQueue(url: "/sdk/identity/identify", payload: jsonData, label: "identify", priority: .critical)
    }

    /// LGPD/GDPR erase signal — tells the server the local identity was wiped so downstream
    /// systems (CRM exports, CAPI/TikTok payloads) stop using it. critical: durable retry on
    /// 5xx/429/network failure, same as `identify()`.
    public func deleteUserData(distinctId: String, deviceId: String? = nil) async {
        var body: [String: Any] = ["distinct_id": distinctId]
        if let deviceId = deviceId, !deviceId.isEmpty { body["deviceId"] = deviceId }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }
        await postWithQueue(url: "/sdk/identity/delete", payload: jsonData, label: "delete_user_data", priority: .critical)
    }

    /// Post-ATT enrichment: the install fires immediately without waiting for the prompt, so
    /// the IDFA only exists after the app asks and the user accepts. Without this POST the
    /// server holds the dispatch until the deadline and sends the install with no madid.
    ///
    /// ATT is granted once: a network failure at this exact moment loses the IDFA for good —
    /// iOS's strongest identifier for CAPI — so the request is persisted for retry.
    public func enrichInstall(distinctId: String, idfa: String, attStatus: String) async {
        let body: [String: Any] = ["distinctId": distinctId, "idfa": idfa, "attStatus": attStatus]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }

        let path = "/sdk/attribution/install-enrich/\(appKey)"
        do {
            _ = try await post(path: path, body: jsonData)
        } catch {
            await PendingRetry.shared.save(url: path, body: jsonData, headers: ["X-App-Key": appKey])
        }
    }

    /// Validates dateOfBirth is in YYYY-MM-DD format.
    static func isValidDateOfBirth(_ dob: String) -> Bool {
        let pattern = #"^\d{4}-\d{2}-\d{2}$"#
        guard let _ = dob.range(of: pattern, options: .regularExpression) else { return false }
        return true
    }

    /// Accepts `YYYY-MM-DD` as-is and converts anything else the platform can parse. A value
    /// with a time component is read in UTC (it came from a timestamp); one without is read
    /// locally, so a date the user typed does not shift a day backwards west of Greenwich.
    static func normalizeDateOfBirth(_ raw: String?) -> String? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        if isValidDateOfBirth(raw) { return raw }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var parsed = iso.date(from: raw)
        if parsed == nil {
            iso.formatOptions = [.withInternetDateTime]
            parsed = iso.date(from: raw)
        }
        guard let date = parsed else { return nil }

        let hasTimeComponent = raw.contains("T") || raw.contains("Z")
        var calendar = Calendar(identifier: .gregorian)
        if hasTimeComponent { calendar.timeZone = TimeZone(identifier: "UTC") ?? .current }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
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
        let response: HttpResponse<PaywallConfig> = try await get(path: "/sdk/paywalls/\(placement)")
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

        let response: HttpResponse<CampaignResponse> = try await get(path: path)
        return response.data
    }

    public func getCampaignPlacements() async throws -> [String] {
        // Server returns { data: string[] } — RN reads res.data.data (one level into data wrapper)
        struct PlacementsResponse: Decodable {
            let data: [String]
        }
        let response: HttpResponse<PlacementsResponse> = try await get(path: "/sdk/campaigns/placements")
        return response.data.data
    }

    public func getPrimaryCampaign(distinctId: String?) async throws -> CampaignResponse? {
        guard let resolvedId = resolveDistinctId(distinctId) else { return nil }
        let encoded = resolvedId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? resolvedId
        let path = "/campaigns/public/primary?distinctId=\(encoded)"
        let response: HttpResponse<CampaignResponse> = try await get(path: path)
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
        let response: HttpResponse<[String: String?]> = try await get(path: "/sdk/flags/evaluate?keys=\(keysParam)", options: options)
        return response.data.mapValues { variantKey in
            FlagVariant(variant: variantKey)
        }
    }

    public func getVariant(key: String, distinctId: String?) async throws -> FlagVariant {
        guard let resolvedId = resolveDistinctId(distinctId) else { return FlagVariant(variant: nil) }
        let encoded = resolvedId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? resolvedId
        let path = "/sdk/flags/\(key)?distinctId=\(encoded)"
        let response: HttpResponse<FlagVariant> = try await get(path: path)
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
        let response: HttpResponse<ConditionalFlagResult> = try await get(path: path)
        return response.data
    }

    // MARK: - Emergency Paywall

    public func getEmergencyPaywall() async throws -> EmergencyPaywallResponse {
        let response: HttpResponse<EmergencyPaywallResponse> = try await get(path: "/sdk/emergency-paywall")
        return response.data
    }

    // MARK: - Purchases

    public func validatePurchase(_ body: [String: Any]) async throws -> ValidatePurchaseResponse {
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let options = RequestOptions(method: "POST", body: jsonData)
        let response = try await httpClient.requestRaw(path: "/sdk/purchases/validate", options: options)

        // The status has to be surfaced as a typed error, not swallowed by a decode failure.
        // Decoding a 4xx body throws a DecodingError, which carries no status, so the caller
        // could not tell a permanently rejected receipt from a transient blip and retried a
        // receipt that will never validate.
        guard response.ok else {
            throw PurchaseError(
                code: PurchaseErrorCode.validationFailed,
                message: "Server validation failed: HTTP \(response.status)",
                userCancelled: false,
                httpStatus: response.status
            )
        }

        // Server wraps response in V2 envelope: { data: { valid, subscription_id, ... }, meta: {...} }
        let envelope = try JSONDecoder().decode(V2Envelope<ValidatePurchaseResponse>.self, from: response.data)
        return envelope.data
    }

    public func getSubscriptionStatus(distinctId: String?) async throws -> SubscriptionStatusResponse {
        var path = "/sdk/purchases/status"
        if let distinctId = distinctId { path += "?distinctId=\(distinctId)" }
        // Server wraps response in V2 envelope: { data: { has_active_subscription, ... }, meta: {...} }
        let response: HttpResponse<V2Envelope<SubscriptionStatusResponse>> = try await get(path: path)
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
