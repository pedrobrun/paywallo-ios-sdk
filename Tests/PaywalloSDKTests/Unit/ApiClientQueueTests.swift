import XCTest
@testable import PaywalloSDK

/// Policy layer of `postWithQueue`: immediate bounded retry, circuit breaker and the handoff
/// to `PendingRetry` for critical requests.
final class ApiClientQueueTests: XCTestCase {

    private var originalSleep: ((Int) async -> Void)!
    private var sleptMs: [Int] = []

    override func setUp() {
        super.setUp()
        RetryCircuitBreaker.shared.reset()
        originalSleep = RetryTiming.sleep
        sleptMs = []
        RetryTiming.sleep = { [self] ms in sleptMs.append(ms) }
    }

    override func tearDown() {
        RetryTiming.sleep = originalSleep
        RetryCircuitBreaker.shared.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func response(_ status: Int, headers: [String: String] = [:]) -> HttpResponse<Data> {
        HttpResponse(ok: (200..<300).contains(status), status: status, data: Data(), headers: headers)
    }

    /// `postWithQueue` writes through the `PendingRetry` singleton, so each critical test
    /// starts from a clean disk.
    private func clearPendingRetry() async {
        await PendingRetry.shared.clear()
    }

    private func makeDeps(
        onError: ((Error) -> Void)? = nil,
        post: @escaping (String, Data, Bool) async throws -> HttpResponse<Data>
    ) -> QueueDeps {
        QueueDeps(getAppKey: { "pk_test" }, isDebug: { false }, post: post, onError: onError)
    }

    // MARK: - computeBackoffDelayMs

    func testBackoff_isWithinSymmetricJitterBounds() {
        for attempt in 1...5 {
            let exponential = min(
                Double(PaywalloConstants.retryBaseDelayMs) * pow(2.0, Double(attempt - 1)),
                Double(PaywalloConstants.retryMaxDelayMs)
            )
            let lower = Int((exponential * (1 - PaywalloConstants.retryJitterRatio)).rounded()) - 1
            let upper = Int((exponential * (1 + PaywalloConstants.retryJitterRatio)).rounded()) + 1
            for _ in 0..<50 {
                let delay = computeBackoffDelayMs(attempt)
                XCTAssertGreaterThanOrEqual(delay, max(0, lower))
                XCTAssertLessThanOrEqual(delay, min(PaywalloConstants.retryMaxDelayMs, upper))
            }
        }
    }

    func testBackoff_neverExceedsMaxDelayEvenWithPositiveJitter() {
        for _ in 0..<200 {
            XCTAssertLessThanOrEqual(computeBackoffDelayMs(12), PaywalloConstants.retryMaxDelayMs)
            XCTAssertGreaterThanOrEqual(computeBackoffDelayMs(12), 0)
        }
    }

    // MARK: - parseRetryAfterMs

    func testRetryAfter_secondsAreConvertedToMs() {
        XCTAssertEqual(parseRetryAfterMs("2"), 2000)
    }

    func testRetryAfter_isClampedToMaxDelay() {
        XCTAssertEqual(parseRetryAfterMs("9999"), PaywalloConstants.retryMaxDelayMs)
    }

    func testRetryAfter_rejectsZeroAndNegative() {
        XCTAssertNil(parseRetryAfterMs("0"))
        XCTAssertNil(parseRetryAfterMs("-5"))
    }

    func testRetryAfter_nilAndGarbageFallThrough() {
        XCTAssertNil(parseRetryAfterMs(nil))
        XCTAssertNil(parseRetryAfterMs("later"))
    }

    func testRetryAfter_httpDateInThePastIsIgnored() {
        XCTAssertNil(parseRetryAfterMs("Wed, 21 Oct 2015 07:28:00 GMT"))
    }

    func testRetryAfter_httpDateInTheFutureIsHonoured() {
        let future = Date().addingTimeInterval(5)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        guard let parsed = parseRetryAfterMs(formatter.string(from: future)) else {
            return XCTFail("HTTP-date futura deve virar um delay")
        }
        XCTAssertGreaterThan(parsed, 0)
        XCTAssertLessThanOrEqual(parsed, PaywalloConstants.retryMaxDelayMs)
    }

    // MARK: - isSslError

    func testSslError_matchesUrlErrorCodes() {
        XCTAssertTrue(isSslError(URLError(.secureConnectionFailed)))
        XCTAssertTrue(isSslError(URLError(.serverCertificateUntrusted)))
        XCTAssertTrue(isSslError(URLError(.serverCertificateHasBadDate)))
        XCTAssertTrue(isSslError(URLError(.serverCertificateHasUnknownRoot)))
        XCTAssertTrue(isSslError(URLError(.serverCertificateNotYetValid)))
        XCTAssertTrue(isSslError(URLError(.clientCertificateRejected)))
        XCTAssertTrue(isSslError(URLError(.clientCertificateRequired)))
    }

    func testSslError_matchesMessagePatterns() {
        for message in ["ERR_CERT_AUTHORITY_INVALID", "self signed certificate", "TLS handshake failed", "x509: bad host"] {
            let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            XCTAssertTrue(isSslError(error), "\"\(message)\" deveria ser tratado como erro de SSL")
        }
    }

    func testSslError_doesNotMatchPlainNetworkErrors() {
        XCTAssertFalse(isSslError(URLError(.notConnectedToInternet)))
        XCTAssertFalse(isSslError(URLError(.timedOut)))
    }

    // MARK: - Retry policy

    func testSuccess_postsOnceAndDoesNotSleep() async {
        var attempts = 0
        let deps = makeDeps { _, _, _ in attempts += 1; return self.response(200) }

        await postWithQueue(deps: deps, url: "/sdk/ingest/batch", payload: Data("{}".utf8), label: "batch")

        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(sleptMs.isEmpty)
    }

    func testEveryPostSkipsTheHttpClientRetry() async {
        var skipRetryFlags: [Bool] = []
        let deps = makeDeps { _, _, skipRetry in skipRetryFlags.append(skipRetry); return self.response(500) }

        await postWithQueue(deps: deps, url: "/x", payload: Data(), label: "batch")

        XCTAssertEqual(skipRetryFlags, [true, true], "empilhar dois loops de retry multiplica a espera à toa")
    }

    func testServerError_retriesUpToMaxAttempts() async {
        var attempts = 0
        let deps = makeDeps { _, _, _ in attempts += 1; return self.response(500) }

        await postWithQueue(deps: deps, url: "/x", payload: Data(), label: "batch")

        XCTAssertEqual(attempts, PaywalloConstants.retryMaxAttempts)
        XCTAssertEqual(sleptMs.count, PaywalloConstants.retryMaxAttempts - 1)
    }

    func testPermanentClientError_stopsOnTheFirstAttempt() async {
        var attempts = 0
        let deps = makeDeps { _, _, _ in attempts += 1; return self.response(400) }

        await postWithQueue(deps: deps, url: "/x", payload: Data(), label: "batch")

        XCTAssertEqual(attempts, 1, "4xx permanente não muda com re-tentativa")
        XCTAssertTrue(sleptMs.isEmpty)
    }

    func test429_isRetriedNotDropped() async {
        var attempts = 0
        let deps = makeDeps { _, _, _ in attempts += 1; return self.response(429) }

        await postWithQueue(deps: deps, url: "/x", payload: Data(), label: "batch")

        XCTAssertEqual(attempts, PaywalloConstants.retryMaxAttempts, "429 é rate limit, não erro permanente")
    }

    func testRetryAfterHeaderTakesPrecedenceOverBackoff() async {
        let deps = makeDeps { _, _, _ in self.response(503, headers: ["retry-after": "7"]) }

        await postWithQueue(deps: deps, url: "/x", payload: Data(), label: "batch")

        XCTAssertEqual(sleptMs, [7000])
    }

    func testMalformedResponseIsRetryableNotPermanent() async {
        var attempts = 0
        // ok=false sem status utilizável (0): a resposta é malformada, não um 4xx.
        let deps = makeDeps { _, _, _ in attempts += 1; return HttpResponse(ok: false, status: 0, data: Data(), headers: [:]) }

        await postWithQueue(deps: deps, url: "/x", payload: Data(), label: "batch")

        XCTAssertEqual(attempts, PaywalloConstants.retryMaxAttempts, "resposta sem status não pode virar drop silencioso")
    }

    func testSslThrow_stopsOnTheFirstAttempt() async {
        var attempts = 0
        let deps = makeDeps { _, _, _ in attempts += 1; throw URLError(.serverCertificateUntrusted) }

        await postWithQueue(deps: deps, url: "/x", payload: Data(), label: "batch")

        XCTAssertEqual(attempts, 1, "certificado ruim não é transitório")
        XCTAssertTrue(sleptMs.isEmpty)
    }

    func testNetworkThrow_isRetried() async {
        var attempts = 0
        let deps = makeDeps { _, _, _ in attempts += 1; throw URLError(.notConnectedToInternet) }

        await postWithQueue(deps: deps, url: "/x", payload: Data(), label: "batch")

        XCTAssertEqual(attempts, PaywalloConstants.retryMaxAttempts)
    }

    // MARK: - Circuit breaker

    func testBreaker_opensAfterThresholdAndBlocksNormalRequests() async {
        let failing = makeDeps { _, _, _ in self.response(500) }
        // Cada chamada registra retryMaxAttempts falhas.
        let calls = Int(ceil(Double(PaywalloConstants.circuitBreakerThreshold) / Double(PaywalloConstants.retryMaxAttempts)))
        for _ in 0..<calls {
            await postWithQueue(deps: failing, url: "/x", payload: Data(), label: "batch")
        }

        var attemptsAfterOpen = 0
        let probe = makeDeps { _, _, _ in attemptsAfterOpen += 1; return self.response(200) }
        await postWithQueue(deps: probe, url: "/x", payload: Data(), label: "batch")

        XCTAssertEqual(attemptsAfterOpen, 0, "com o breaker aberto o request normal nem sai")
    }

    func testBreaker_doesNotBlockCriticalRequests() async {
        await clearPendingRetry()
        let failing = makeDeps { _, _, _ in self.response(500) }
        let calls = Int(ceil(Double(PaywalloConstants.circuitBreakerThreshold) / Double(PaywalloConstants.retryMaxAttempts)))
        for _ in 0..<calls {
            await postWithQueue(deps: failing, url: "/x", payload: Data(), label: "batch")
        }

        var attemptsAfterOpen = 0
        let probe = makeDeps { _, _, _ in attemptsAfterOpen += 1; return self.response(200) }
        await postWithQueue(deps: probe, url: "/x", payload: Data(), label: "install", priority: .critical)

        XCTAssertGreaterThan(attemptsAfterOpen, 0, "critical tem o PendingRetry atrás — barrá-lo só atrasa")
        await clearPendingRetry()
    }

    func testBreaker_permanentClientErrorDoesNotCount() async {
        let deps = makeDeps { _, _, _ in self.response(404) }
        for _ in 0..<(PaywalloConstants.circuitBreakerThreshold + 2) {
            await postWithQueue(deps: deps, url: "/x", payload: Data(), label: "batch")
        }

        var attempts = 0
        let probe = makeDeps { _, _, _ in attempts += 1; return self.response(200) }
        await postWithQueue(deps: probe, url: "/x", payload: Data(), label: "batch")

        XCTAssertEqual(attempts, 1, "4xx não é sinal de servidor fora")
    }

    func testBreaker_sslErrorDoesNotCount() async {
        let deps = makeDeps { _, _, _ in throw URLError(.secureConnectionFailed) }
        for _ in 0..<(PaywalloConstants.circuitBreakerThreshold + 2) {
            await postWithQueue(deps: deps, url: "/x", payload: Data(), label: "batch")
        }

        var attempts = 0
        let probe = makeDeps { _, _, _ in attempts += 1; return self.response(200) }
        await postWithQueue(deps: probe, url: "/x", payload: Data(), label: "batch")

        XCTAssertEqual(attempts, 1)
    }

    func testBreaker_successResetsTheCounter() async {
        let failing = makeDeps { _, _, _ in self.response(500) }
        await postWithQueue(deps: failing, url: "/x", payload: Data(), label: "batch")

        let ok = makeDeps { _, _, _ in self.response(200) }
        await postWithQueue(deps: ok, url: "/x", payload: Data(), label: "batch")

        // Depois do sucesso o contador zera: mais uma chamada falha não abre o breaker.
        await postWithQueue(deps: failing, url: "/x", payload: Data(), label: "batch")
        var attempts = 0
        let probe = makeDeps { _, _, _ in attempts += 1; return self.response(200) }
        await postWithQueue(deps: probe, url: "/x", payload: Data(), label: "batch")

        XCTAssertEqual(attempts, 1)
    }

    // MARK: - onError e PendingRetry

    func testNormalDrop_reportsThroughOnError() async {
        var reported: [Error] = []
        let deps = makeDeps(onError: { reported.append($0) }) { _, _, _ in self.response(503) }

        await postWithQueue(deps: deps, url: "/x", payload: Data(), label: "batch")

        XCTAssertEqual(reported.count, 1)
        let error = reported.first as? ClientError
        XCTAssertEqual(error?.code, ClientErrorCode.eventDeliveryFailed)
        XCTAssertEqual(error?.message, "\"batch\" dropped: non-4xx failure, priority=normal has no retry (status 503)")
    }

    func testNormalDrop_malformedResponseReportsUnknownStatus() async {
        var reported: [Error] = []
        let deps = makeDeps(onError: { reported.append($0) }) { _, _, _ in
            HttpResponse(ok: false, status: 0, data: Data(), headers: [:])
        }

        await postWithQueue(deps: deps, url: "/x", payload: Data(), label: "batch")

        XCTAssertEqual((reported.first as? ClientError)?.message,
                       "\"batch\" dropped: non-4xx failure, priority=normal has no retry (status unknown)")
    }

    func testPermanentClientError_reportsThroughOnError() async {
        var reported: [Error] = []
        let deps = makeDeps(onError: { reported.append($0) }) { _, _, _ in self.response(422) }

        await postWithQueue(deps: deps, url: "/x", payload: Data(), label: "identify")

        XCTAssertEqual((reported.first as? ClientError)?.message, "\"identify\" permanent client error (status 422)")
    }

    func testCriticalSuccess_leavesNothingOnDisk() async {
        await clearPendingRetry()
        let deps = makeDeps { _, _, _ in self.response(200) }

        await postWithQueue(deps: deps, url: "/x", payload: Data("{}".utf8), label: "install", priority: .critical)

        let size = await PendingRetry.shared.size()
        XCTAssertEqual(size, 0, "a reserva sai do disco no sucesso")
    }

    func testCriticalServerError_staysOnDiskForRetry() async {
        await clearPendingRetry()
        let payload = Data("{\"context\":{},\"events\":[]}".utf8)
        let deps = makeDeps { _, _, _ in self.response(500) }

        await postWithQueue(deps: deps, url: "/sdk/ingest/batch", payload: payload, label: "install", priority: .critical)

        let items = await PendingRetry.shared.snapshot()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].body, payload, "o item persistido é o body original, byte a byte")
        XCTAssertEqual(items[0].inFlight, false, "markFailed libera a reserva pro processador")
        XCTAssertNotEqual(items[0].deadLetter, true)
        await clearPendingRetry()
    }

    func testCriticalPermanentError_becomesDeadLetterInsteadOfVanishing() async {
        await clearPendingRetry()
        let deps = makeDeps { _, _, _ in self.response(400) }

        await postWithQueue(deps: deps, url: "/sdk/ingest/batch", payload: Data("{}".utf8), label: "install", priority: .critical)

        let items = await PendingRetry.shared.snapshot()
        XCTAssertEqual(items.count, 1, "um critical nunca some sem rastro — foi assim que o 03/08 perdeu 100% dos installs")
        XCTAssertEqual(items[0].deadLetter, true)
        await clearPendingRetry()
    }

    func testCriticalNetworkThrow_staysOnDiskForRetry() async {
        await clearPendingRetry()
        let deps = makeDeps { _, _, _ in throw URLError(.notConnectedToInternet) }

        await postWithQueue(deps: deps, url: "/sdk/ingest/batch", payload: Data("{}".utf8), label: "install", priority: .critical)

        let size = await PendingRetry.shared.size()
        XCTAssertEqual(size, 1)
        await clearPendingRetry()
    }

    func testNormalPriority_neverTouchesPendingRetry() async {
        await clearPendingRetry()
        let deps = makeDeps { _, _, _ in self.response(500) }

        await postWithQueue(deps: deps, url: "/x", payload: Data(), label: "batch", priority: .normal)

        let size = await PendingRetry.shared.size()
        XCTAssertEqual(size, 0, "normal é best-effort: dropa, não persiste")
    }

    func testPostedPayloadIsTheExactBytesGiven() async {
        var seen: [Data] = []
        let payload = Data("{\"context\":{},\"events\":[{\"id\":\"a\"}]}".utf8)
        let deps = makeDeps { _, body, _ in seen.append(body); return self.response(200) }

        await postWithQueue(deps: deps, url: "/sdk/ingest/batch", payload: payload, label: "batch")

        XCTAssertEqual(seen, [payload], "a camada de política não pode reembrulhar o body")
    }
}
