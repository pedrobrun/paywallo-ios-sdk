import Foundation

/// Collaborators the retry-policy layer needs, injected so it stays testable without an
/// `ApiClient`. Mirrors RN `QueueDeps`.
public struct QueueDeps {
    public let getAppKey: () -> String
    public let isDebug: () -> Bool
    /// POST that RESOLVES on HTTP error statuses (`ok: false`) and only THROWS on network
    /// failures — the `HttpClient.requestRaw` contract. `skipRetry` is always `true` here.
    public let post: (String, Data, Bool) async throws -> HttpResponse<Data>
    /// Mirrors `config.onError`. Called when the request is definitively dropped (no
    /// pending retry left behind).
    public let onError: ((Error) -> Void)?

    public init(
        getAppKey: @escaping () -> String,
        isDebug: @escaping () -> Bool,
        post: @escaping (String, Data, Bool) async throws -> HttpResponse<Data>,
        onError: ((Error) -> Void)? = nil
    ) {
        self.getAppKey = getAppKey
        self.isDebug = isDebug
        self.post = post
        self.onError = onError
    }
}

/// Injectable so tests don't wait real seconds between attempts.
enum RetryTiming {
    static var sleep: (Int) async -> Void = { ms in
        guard ms > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }
}

/// `attempt` is the attempt that just failed (1-indexed). Jitter is symmetric (±25%) and the
/// result is clamped to `[0, retryMaxDelayMs]` so a positive jitter can never exceed the cap.
func computeBackoffDelayMs(_ attempt: Int) -> Int {
    let exponential = min(
        Double(PaywalloConstants.retryBaseDelayMs) * pow(2.0, Double(attempt - 1)),
        Double(PaywalloConstants.retryMaxDelayMs)
    )
    let jitter = (Double.random(in: 0...1) * 2 - 1) * PaywalloConstants.retryJitterRatio * exponential
    return min(PaywalloConstants.retryMaxDelayMs, max(0, Int((exponential + jitter).rounded())))
}

/// Accepts seconds or an HTTP-date. Returns nil when absent/invalid/in the past — the caller
/// then falls back to the exponential backoff.
func parseRetryAfterMs(_ headerValue: String?) -> Int? {
    guard let headerValue = headerValue else { return nil }
    if let seconds = Double(headerValue), seconds > 0 {
        return min(Int(seconds * 1000), PaywalloConstants.retryMaxDelayMs)
    }
    if let date = HttpDate.parse(headerValue) {
        let ms = Int(date.timeIntervalSinceNow * 1000)
        if ms > 0 { return min(ms, PaywalloConstants.retryMaxDelayMs) }
    }
    return nil
}

func isSslError(_ error: Error) -> Bool {
    SslError.matches(error)
}

/// State SHARED across `postWithQueue` calls (not per request): opens after
/// `circuitBreakerThreshold` consecutive retryable failures and stops hitting the network for
/// `circuitBreakerOpenMs` — saves battery and radio when the server is plainly down, without
/// making its load worse. Permanent 4xx and SSL errors do NOT count: neither is a "server
/// down" signal.
final class RetryCircuitBreaker {
    static let shared = RetryCircuitBreaker()

    private let lock = NSLock()
    private var consecutiveFailures = 0
    private var openedAt: Date?

    func isOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let openedAt = openedAt else { return false }
        // Window elapsed → half-open: one request is let through to probe the server. The
        // failure counter is deliberately NOT reset, so a still-dead server re-opens on the
        // very next failure instead of needing another five.
        return Date().timeIntervalSince(openedAt) * 1000 < Double(PaywalloConstants.circuitBreakerOpenMs)
    }

    func recordSuccess() {
        lock.lock()
        defer { lock.unlock() }
        consecutiveFailures = 0
        openedAt = nil
    }

    func recordFailure() {
        lock.lock()
        defer { lock.unlock() }
        consecutiveFailures += 1
        if consecutiveFailures >= PaywalloConstants.circuitBreakerThreshold {
            openedAt = Date()
        }
    }

    /// Tests only — resets the singleton between cases.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        consecutiveFailures = 0
        openedAt = nil
    }
}

private enum PolicyOutcome {
    case response(HttpResponse<Data>)
    case failure(Error)
}

/// The `HttpClient` resolves (does not throw) on HTTP error statuses, so `ok == false` is a
/// server answer and only network failures reach the `catch`.
private func isSuccess(_ response: HttpResponse<Data>) -> Bool {
    response.ok
}

/// 4xx (except 429) is a permanent client error — invalid receipt, bad request — where
/// retrying cannot change the answer, so the request is dropped. A malformed response with no
/// usable status is NOT permanent: it becomes retryable so a critical event is never lost in
/// silence (fix in 2.7.1).
private func isPermanentClientError(_ response: HttpResponse<Data>) -> Bool {
    !response.ok && (400..<500).contains(response.status) && response.status != 429
}

/// `0` is what `HttpResponse` carries when no HTTP status could be read.
private func statusLabel(_ response: HttpResponse<Data>) -> String {
    response.status == 0 ? "unknown" : String(response.status)
}

/// Runs up to `retryMaxAttempts` with `skipRetry: true` (the HttpClient must not retry
/// underneath — stacking two retry loops multiplies the wait for nothing). Permanent 4xx and
/// SSL end on the first attempt. 429/5xx/network errors retry honouring `Retry-After` when
/// present, otherwise exponential backoff + jitter.
private func runWithRetryPolicy(
    deps: QueueDeps,
    url: String,
    payload: Data,
    label: String,
    isCritical: Bool
) async -> PolicyOutcome {
    let breaker = RetryCircuitBreaker.shared

    for attempt in 1...PaywalloConstants.retryMaxAttempts {
        // The breaker OBSERVES every request (so it opens correctly even on
        // critical-dominated traffic) but only BLOCKS the non-critical ones: a critical
        // request has the durable PendingRetry behind it, so blocking it here would only
        // delay what the retry would deliver anyway.
        if !isCritical, breaker.isOpen() {
            if deps.isDebug() { print("[Paywallo:ApiClient] circuit breaker aberto, pulando tentativa: \(label)") }
            return .failure(ClientError(
                code: ClientErrorCode.eventDeliveryFailed,
                message: "\"\(label)\" circuit breaker open"
            ))
        }

        do {
            let response = try await deps.post(url, payload, true)
            if isSuccess(response) {
                breaker.recordSuccess()
                return .response(response)
            }
            if isPermanentClientError(response) { return .response(response) }
            breaker.recordFailure()
            if attempt == PaywalloConstants.retryMaxAttempts { return .response(response) }
            let delay = parseRetryAfterMs(response.headers["retry-after"]) ?? computeBackoffDelayMs(attempt)
            if deps.isDebug() { print("[Paywallo:ApiClient] falha retentável, aguardando: \(label) \(delay)") }
            await RetryTiming.sleep(delay)
        } catch {
            if isSslError(error) { return .failure(error) }
            breaker.recordFailure()
            if attempt == PaywalloConstants.retryMaxAttempts { return .failure(error) }
            await RetryTiming.sleep(computeBackoffDelayMs(attempt))
        }
    }

    return .failure(ClientError(code: ClientErrorCode.unknown, message: "runWithRetryPolicy: unreachable"))
}

/// POST with an immediate bounded retry (`runWithRetryPolicy`), with no offline fallback.
/// On 4xx (≠429) the request is dropped. On 5xx/429/network error that survives the
/// attempts: `critical` stays persisted in `PendingRetry` (bounded — 2 re-attempts, 1min/5min
/// backoff) as a backstop, and `normal` is dropped.
///
/// `critical` is written BEFORE the POST (write-ahead) and removed on success, so the
/// reservation sits on disk for ALL the immediate attempts, not just the first. Without it a
/// process killed during the network `await` — ATT prompt, store redirect, cold-start app kill
/// — loses the event with no log and no retry.
///
/// Incident 03/08/2026: the OfflineQueue (write-ahead journal + a processor that re-wrapped
/// the V2 envelope in a batch) was removed entirely after dropping 100% of `$app_installed`.
/// What came back here is ONLY the early write — delivery is still this direct POST, with no
/// batch processor and no envelope re-wrapping.
public func postWithQueue(
    deps: QueueDeps,
    url: String,
    payload: Data,
    label: String,
    priority: EventPriority = .normal
) async {
    let isCritical = priority == .critical
    let headers = ["X-App-Key": deps.getAppKey()]
    var reservationId: String?
    if isCritical {
        // A failed reservation must not cancel the send: losing the write-ahead is better
        // than losing the event.
        reservationId = await PendingRetry.shared.reserve(url: url, body: payload, headers: headers)
    }

    let outcome = await runWithRetryPolicy(deps: deps, url: url, payload: payload, label: label, isCritical: isCritical)

    switch outcome {
    case .response(let response):
        if isSuccess(response) {
            if let reservationId = reservationId { await PendingRetry.shared.remove(reservationId) }
            return
        }
        if isPermanentClientError(response) {
            if deps.isDebug() { print("[Paywallo:ApiClient] 4xx permanente: \(label)") }
            deps.onError?(ClientError(
                code: ClientErrorCode.eventDeliveryFailed,
                message: "\"\(label)\" permanent client error (status \(statusLabel(response)))"
            ))
            // Critical becomes a dead letter and never silently leaves the disk (incident
            // 03/08). Without a reservation this is priority "normal", which has no retry —
            // there the drop IS the policy.
            if let reservationId = reservationId { await PendingRetry.shared.markDeadLetter(reservationId) }
            return
        }
        if let reservationId = reservationId {
            if deps.isDebug() { print("[Paywallo:ApiClient] falha não-4xx, saved for retry: \(label)") }
            await PendingRetry.shared.markFailed(reservationId)
        } else {
            if deps.isDebug() { print("[Paywallo:ApiClient] falha não-4xx, dropping (normal): \(label)") }
            // priority "normal" has no retry — this is the last chance to report the failure.
            deps.onError?(ClientError(
                code: ClientErrorCode.eventDeliveryFailed,
                message: "\"\(label)\" dropped: non-4xx failure, priority=normal has no retry (status \(statusLabel(response)))"
            ))
        }

    case .failure(let error):
        if deps.isDebug() { print("[Paywallo:ApiClient] Request failed: \(label) \(error)") }
        if let reservationId = reservationId {
            await PendingRetry.shared.markFailed(reservationId)
        } else {
            deps.onError?(error)
        }
    }
}

/// One-shot erasure of the three storage keys the deleted OfflineQueue left behind. Without
/// it every device that ever ran ≤2.6.x keeps an orphan queue on disk forever — including
/// event bodies that will never be delivered.
public enum LegacyOfflineQueueCleanup {
    private static let lock = NSLock()
    private static var done = false

    public static func run(storage: NativeStorage = .shared) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        for key in [
            PaywalloConstants.offlineQueueKey,
            PaywalloConstants.offlineQueueJournalKey,
            PaywalloConstants.queueDlqKey,
        ] {
            _ = storage.remove(key)
        }
    }
}
