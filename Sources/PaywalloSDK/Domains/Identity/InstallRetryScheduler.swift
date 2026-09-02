import Foundation

/// Persisted deferred-match retry state.
///
/// `payload` holds the already-encoded request body as raw bytes and is re-posted
/// byte-for-byte — never decoded, rebuilt or re-wrapped (incident 03/08: a processor
/// re-wrapped a persisted envelope and dropped 100% of the critical events).
struct DeferredMatchState: Codable, Equatable {
    let payload: Data
    let firstAttemptAt: Double
    var attempts: Int
    var nextAttemptAt: Double
    /// Absent in state persisted before this field existed (an older app version in the
    /// field) — read everywhere as "no explicit backpressure".
    var retryAfterUntil: Double?
    var lastForcedAttemptAt: Double?
}

/// Process-wide in-flight guard. `refreshDeferredAttributionNow` builds a fresh
/// scheduler on every call, so an instance flag would not stop two paywalls registering
/// in the same second from firing two POSTs at the server's priciest endpoint.
private final class DeferredMatchInFlight: @unchecked Sendable {
    static let shared = DeferredMatchInFlight()

    private let lock = NSLock()
    private var inFlight = false

    /// Reads and claims inside one critical section; `false` means the caller lost the race.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if inFlight { return false }
        inFlight = true
        return true
    }

    func release() {
        lock.lock()
        inFlight = false
        lock.unlock()
    }
}

/// Deferred-match POST plus its backoff/retry lifecycle. Split out of `InstallTracker`
/// (which owns install-event assembly) so the two concerns stay separately testable.
public final class InstallRetryScheduler {
    private let storage: SecureStorage
    private let attributionTracker: AttributionTracker
    private let deepLinkStore: DeferredDeepLinkStore
    private let debug: Bool

    public init(
        debug: Bool = false,
        storage: SecureStorage = .shared,
        attributionTracker: AttributionTracker = .shared,
        deepLinkStore: DeferredDeepLinkStore = .shared
    ) {
        self.debug = debug
        self.storage = storage
        self.attributionTracker = attributionTracker
        self.deepLinkStore = deepLinkStore
    }

    // MARK: - Entry points

    /// Builds the match payload, writes it ahead of the first attempt, and fires it.
    ///
    /// `distinctId` is mandatory: without it the server stores the attribution with an
    /// empty distinct_id, and the reader joins
    /// `install_attributions.distinct_id = app_users.external_id` — so the row never
    /// matches anything.
    public func start(
        apiClient: ApiClient,
        distinctId: String,
        deviceData: DeviceData?,
        country: String?,
        idfv: String?,
        anonId: String?,
        installedAt: Double,
        rawReferrer: String?
    ) async {
        if await storage.get(PaywalloConstants.deferredMatchDoneKey) != nil { return }

        let payload = buildDeferredMatchPayload(
            distinctId: distinctId,
            deviceData: deviceData,
            country: country,
            idfv: idfv,
            anonId: anonId,
            installedAt: installedAt,
            rawReferrer: rawReferrer
        )
        guard let payload = payload else { return }

        let state = DeferredMatchState(
            payload: payload,
            firstAttemptAt: nowMs(),
            attempts: 0,
            nextAttemptAt: 0,
            retryAfterUntil: nil,
            lastForcedAttemptAt: nil
        )
        // Write-ahead: persists the exact request body before the first attempt, so a
        // later cold-start retry reposts it verbatim instead of rebuilding it.
        await persist(state)

        await attemptDeferredMatch(apiClient: apiClient, state: state)
    }

    /// Retries a pending deferred match on cold start. No timers and no queue — it is a
    /// check-on-launch against the persisted `nextAttemptAt`, the same policy shape as
    /// the reference Android SDK: retry until the 24h ceiling with backoff + jitter.
    public func retryIfDue(apiClient: ApiClient, force: Bool = false) async {
        if await storage.get(PaywalloConstants.deferredMatchDoneKey) != nil { return }

        guard let raw = await storage.get(PaywalloConstants.deferredMatchStateKey) else { return }
        guard let data = raw.data(using: .utf8),
              let state = try? JSONDecoder().decode(DeferredMatchState.self, from: data)
        else {
            await storage.remove(PaywalloConstants.deferredMatchStateKey)
            return
        }

        let now = nowMs()
        if now - state.firstAttemptAt >= Double(PaywalloConstants.deferredMatchMaxAgeMs) {
            await storage.remove(PaywalloConstants.deferredMatchStateKey)
            return
        }

        // Backpressure the server asked for explicitly (429/503 Retry-After) binds even
        // through `force` — only the local optimistic backoff is force-skippable.
        if let retryAfterUntil = state.retryAfterUntil, now < retryAfterUntil { return }

        if force {
            // Floor between forced pings so N registers/paywalls in the same minute do
            // not become N synchronous POSTs. Never gates the FIRST forced call — that
            // immediacy is the whole point of the just-in-time ask.
            if let lastForced = state.lastForcedAttemptAt,
               now - lastForced < Double(PaywalloConstants.forcedMatchMinIntervalMs) {
                return
            }
            var forcedState = state
            forcedState.lastForcedAttemptAt = now
            await attemptDeferredMatch(apiClient: apiClient, state: forcedState)
            return
        }

        // Without `force`, `nextAttemptAt` (local backoff OR Retry-After) still holds.
        if now < state.nextAttemptAt { return }

        await attemptDeferredMatch(apiClient: apiClient, state: state)
    }

    // MARK: - Attempt

    private func attemptDeferredMatch(apiClient: ApiClient, state: DeferredMatchState) async {
        guard DeferredMatchInFlight.shared.claim() else { return }
        defer { DeferredMatchInFlight.shared.release() }

        let options = RequestOptions(
            method: "POST",
            body: state.payload,
            skipRetry: true,
            timeout: PaywalloConstants.deferredMatchTimeout
        )

        do {
            let response = try await apiClient.httpClient.requestRaw(
                path: "/sdk/attribution/deferred-match/\(apiClient.appKey)",
                options: options
            )

            let matched = await applyDeferredMatchResponseIfMatched(response.data)

            // The flag only sticks on a confirmed answer (2xx AND a real payload). A
            // 5xx/429 or a bare `matched:false` must NOT seal the device — both leave
            // the question genuinely open.
            if response.ok && matched {
                await storage.set(PaywalloConstants.deferredMatchDoneKey, value: "1")
                await storage.remove(PaywalloConstants.deferredMatchStateKey)
                return
            }
            await scheduleDeferredMatchRetry(state, retryAfter: response.headers["retry-after"])
        } catch {
            // Network error / timeout — the server never answered, so "no match" cannot
            // be told apart from "couldn't ask". Retry rather than give up.
            await scheduleDeferredMatchRetry(state, retryAfter: nil)
        }
    }

    private func scheduleDeferredMatchRetry(_ state: DeferredMatchState, retryAfter: String?) async {
        let now = nowMs()
        if now - state.firstAttemptAt >= Double(PaywalloConstants.deferredMatchMaxAgeMs) {
            await storage.remove(PaywalloConstants.deferredMatchStateKey)
            return
        }

        let retryAfterMs = parseRetryAfterMs(retryAfter, now: now)
        let steps = PaywalloConstants.deferredMatchBackoffMs
        let baseDelay = Double(steps[min(state.attempts, steps.count - 1)])

        var next = state
        next.attempts = state.attempts + 1
        next.nextAttemptAt = now + (retryAfterMs ?? jitter(baseDelay))
        // Recomputed from THIS response only: an explicit Retry-After sets the floor that
        // binds `force`; its absence CLEARS an earlier one instead of carrying it forward.
        next.retryAfterUntil = retryAfterMs.map { now + $0 }

        await persist(next)
    }

    // MARK: - Response

    private func applyDeferredMatchResponseIfMatched(_ data: Data) async -> Bool {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Malformed / empty body — deferred-match feedback is best-effort.
            return false
        }

        // The server wraps the match in the standard `{ data: {...} }` envelope. Unwrap
        // it, falling back to the top level for a hypothetical un-enveloped body.
        let source = (body["data"] as? [String: Any]) ?? body
        guard (source["matched"] as? Bool) == true else { return false }

        var attribution = extractDeferredAttribution(source["attribution"])
        if attribution != nil {
            // `matchType` lives one level ABOVE, outside the `attribution` object.
            if let matchType = source["matchType"] as? String, !matchType.isEmpty {
                attribution?.matchType = matchType
            }
            attribution?.installReferrerSource = "deferred_match"
            // promoteFromServerMatch, not capture: an organic/weak capture may already be
            // on disk, and first-write-wins would discard this result in silence — that
            // is how a real Meta Ads click disappeared from the device.
            await attributionTracker.promoteFromServerMatch(attribution!)
        }

        // Deferred deep link: additive and independent of the attribution/CAPI pipeline
        // above — an older server never sends `deepLink`, and its absence affects nothing.
        let deepLink = parseDeferredDeepLink(source["deepLink"])
        if let deepLink = deepLink {
            await deepLinkStore.capture(deepLink)
        }

        // The server's organic fallback ALWAYS answers `matched:true`, so that flag alone
        // means "waterfall exhausted", not "found". Seal the device only when a real
        // payload came back — otherwise keep retrying.
        return attribution != nil || deepLink != nil
    }

    // MARK: - Helpers

    private func persist(_ state: DeferredMatchState) async {
        guard let encoded = try? JSONEncoder().encode(state),
              let json = String(data: encoded, encoding: .utf8) else { return }
        await storage.set(PaywalloConstants.deferredMatchStateKey, value: json)
    }

    private func nowMs() -> Double {
        Date().timeIntervalSince1970 * 1000
    }
}

// MARK: - Payload

/// Fields the server may return, mapped onto `AttributionInput`. Only non-empty strings
/// survive; anything else (absent, null, wrong type) is dropped so a partial or malformed
/// response can never poison the store.
func extractDeferredAttribution(_ raw: Any?) -> AttributionInput? {
    guard let source = raw as? [String: Any] else { return nil }

    func field(_ key: String) -> String? {
        guard let value = source[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    let input = AttributionInput(
        utmSource: field("utmSource"),
        utmMedium: field("utmMedium"),
        utmCampaign: field("utmCampaign"),
        utmContent: field("utmContent"),
        utmTerm: field("utmTerm"),
        fbclid: field("fbclid"),
        gclid: field("gclid"),
        ttclid: field("ttclid"),
        tiktokCampaignId: field("tiktokCampaignId"),
        tiktokAdgroupId: field("tiktokAdgroupId"),
        tiktokAdId: field("tiktokAdId"),
        adNetwork: field("adNetwork")
    )
    // `matchType` and `installReferrerSource` are stamped by the caller — kept out here
    // so `hasAnyField` reflects the server's own attribution fields only.
    guard input.hasAnyField else { return nil }
    return input
}

/// Body of `POST /sdk/attribution/deferred-match/{appKey}`. Returns nil when the body
/// cannot be encoded — there is nothing to write ahead in that case.
func buildDeferredMatchPayload(
    distinctId: String,
    deviceData: DeviceData?,
    country: String?,
    idfv: String?,
    anonId: String?,
    installedAt: Double,
    rawReferrer: String?
) -> Data? {
    var body: [String: Any] = [
        "platform": PaywalloConstants.sdkPlatform,
        "distinctId": distinctId,
        "installTimestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: installedAt / 1000)),
        // Sent even when nil: the server distinguishes "no Meta anon id on this device"
        // from "the SDK did not look", and drops the CAPI join only in the first case.
        "fbAnonId": anonId ?? NSNull(),
    ]

    if let idfv = idfv, !idfv.isEmpty { body["idfv"] = idfv }
    if let rawReferrer = rawReferrer, !rawReferrer.isEmpty { body["installReferrer"] = rawReferrer }
    if let country = country, !country.isEmpty { body["country"] = country }

    if let device = deviceData {
        body["deviceModel"] = device.modelId.isEmpty ? device.model : device.modelId
        body["osVersion"] = device.systemVersion
        body["screenWidth"] = Int(device.screenWidth)
        body["screenHeight"] = Int(device.screenHeight)
        body["timezone"] = device.timezone
        body["language"] = device.locale
    }

    return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
}

// MARK: - Backoff

/// Equal jitter (0.5x–1x of base) — spreads retries without ever dropping below half the
/// intended backoff, so a cold-start storm cannot hammer the endpoint.
func jitter(_ baseMs: Double) -> Double {
    baseMs / 2 + Double.random(in: 0..<1) * (baseMs / 2)
}

/// `Retry-After` is either delta-seconds or an HTTP date.
func parseRetryAfterMs(_ headerValue: String?, now: Double) -> Double? {
    guard let headerValue = headerValue?.trimmingCharacters(in: .whitespaces), !headerValue.isEmpty else {
        return nil
    }
    if let seconds = Double(headerValue) { return max(0, seconds) * 1000 }
    if let date = httpDateFormatter.date(from: headerValue) {
        return max(0, date.timeIntervalSince1970 * 1000 - now)
    }
    return nil
}

private let httpDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter
}()

// MARK: - Just-in-time refresh

/// Asks the server NOW whether this install matches a click, skipping the backoff wait
/// (30s/120s/600s) — which, besides being long, is only re-evaluated on cold start. The
/// answer lands in the `AttributionTracker` via `promoteFromServerMatch`, so whoever
/// listens on `onCapture` reacts on its own.
///
/// Exists for the moment attribution is worth money: right before the paywall, because
/// audience rules are evaluated on-device at `register()` and the variant chosen there
/// sticks to the user until the assignment is reset. Arriving with the attribution after
/// that is worthless.
///
/// Silent no-op when there is no pending deferred match (already matched, expired, or the
/// install was never tracked). Never throws.
public func refreshDeferredAttributionNow(
    apiClient: ApiClient,
    debug: Bool = false,
    storage: SecureStorage = .shared,
    attributionTracker: AttributionTracker = .shared,
    deepLinkStore: DeferredDeepLinkStore = .shared
) async {
    let scheduler = InstallRetryScheduler(
        debug: debug,
        storage: storage,
        attributionTracker: attributionTracker,
        deepLinkStore: deepLinkStore
    )
    await scheduler.retryIfDue(apiClient: apiClient, force: true)
}
