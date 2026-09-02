import XCTest
@testable import PaywalloSDK

/// Records everything the batcher hands to `postWithQueue`, so the tests can assert on the
/// exact bytes the SDK would put on the wire.
private final class PostRecorder {
    struct Call {
        let url: String
        let body: Data
        let label: String
        let priority: EventPriority
    }

    private let lock = NSLock()
    private var storedCalls: [Call] = []
    /// Blocks the post until released — used to prove `track()` awaits a critical delivery.
    var gate: (() async -> Void)?

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return storedCalls
    }

    func makePostFn() -> EventPostFn {
        { [self] url, body, label, priority in
            await gate?()
            lock.lock()
            storedCalls.append(Call(url: url, body: body, label: label, priority: priority))
            lock.unlock()
        }
    }

    func envelope(at index: Int) throws -> [String: Any] {
        let data = calls[index].body
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "test", code: 1)
        }
        return json
    }
}

private func makeBatcher(_ recorder: PostRecorder, distinctId: String = "user_1") -> EventBatcher {
    let batcher = EventBatcher()
    batcher.initialize(
        post: recorder.makePostFn(),
        contextProvider: { IngestContext() },
        distinctIdProvider: { distinctId },
        debug: false
    )
    return batcher
}

final class EventBatcherTests: XCTestCase {

    // MARK: - Critical posts directly and is awaited

    func testCritical_postsImmediately_andTrackAwaitsIt() async {
        let recorder = PostRecorder()
        let batcher = makeBatcher(recorder)

        await batcher.track(name: "lifecycle", properties: ["type": AnyCodable("install")], priority: .critical, timestamp: nil)

        // No sleep, no flush: if track() returned before the post the incident is back.
        XCTAssertEqual(recorder.calls.count, 1, "critical deve postar direto dentro do track()")
        XCTAssertEqual(recorder.calls[0].priority, .critical)
        XCTAssertEqual(recorder.calls[0].url, EventBatcher.v2BatchEndpoint)
        XCTAssertEqual(recorder.calls[0].label, "event_critical:lifecycle")
    }

    func testCritical_isNeverBuffered() async {
        let recorder = PostRecorder()
        let batcher = makeBatcher(recorder)

        await batcher.track(name: "transaction", properties: ["type": AnyCodable("completed")], priority: .critical, timestamp: nil)
        await batcher.flush()

        XCTAssertEqual(recorder.calls.count, 1, "flush() não pode reenviar um critical já entregue")
    }

    func testCritical_trackDoesNotReturnBeforePostCompletes() async {
        let recorder = PostRecorder()
        let released = expectation(description: "post released")
        recorder.gate = {
            try? await Task.sleep(nanoseconds: 50_000_000)
            released.fulfill()
        }
        let batcher = makeBatcher(recorder)

        await batcher.track(name: "identify", properties: ["distinct_id": AnyCodable("u1")], priority: .critical, timestamp: nil)

        await fulfillment(of: [released], timeout: 1)
        XCTAssertEqual(recorder.calls.count, 1)
    }

    // MARK: - Normal buffers and flushes

    func testNormal_isBufferedUntilFlush() async {
        let recorder = PostRecorder()
        let batcher = makeBatcher(recorder)

        await batcher.track(name: "lifecycle", properties: ["type": AnyCodable("cold_start")], priority: .normal, timestamp: nil)
        XCTAssertTrue(recorder.calls.isEmpty, "normal não posta na hora")

        await batcher.flush()
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls[0].priority, .normal)
        XCTAssertEqual(recorder.calls[0].label, "event_batch:1")
    }

    func testNormal_flushesWhenBatchMaxSizeIsReached() async {
        let recorder = PostRecorder()
        let batcher = makeBatcher(recorder)

        for _ in 0..<PaywalloConstants.batchMaxSize {
            await batcher.track(name: "lifecycle", properties: ["type": AnyCodable("foreground")], priority: .normal, timestamp: nil)
        }

        XCTAssertEqual(recorder.calls.count, 1, "o 25º evento dispara o flush por tamanho")
        XCTAssertEqual(recorder.calls[0].label, "event_batch:\(PaywalloConstants.batchMaxSize)")
    }

    func testFlush_onEmptyQueue_postsNothing() async {
        let recorder = PostRecorder()
        let batcher = makeBatcher(recorder)

        await batcher.flush()
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func testDispose_dropsBufferedEventsAndStopsTracking() async {
        let recorder = PostRecorder()
        let batcher = makeBatcher(recorder)

        await batcher.track(name: "lifecycle", properties: ["type": AnyCodable("foreground")], priority: .normal, timestamp: nil)
        batcher.dispose()
        await batcher.track(name: "lifecycle", properties: ["type": AnyCodable("background")], priority: .normal, timestamp: nil)
        await batcher.flush()

        XCTAssertTrue(recorder.calls.isEmpty)
    }

    // MARK: - Envelope shape

    func testEnvelope_isNeverDoubleWrapped() throws {
        let recorder = PostRecorder()
        let batcher = makeBatcher(recorder)

        let done = expectation(description: "posted")
        Task {
            await batcher.track(name: "lifecycle", properties: ["type": AnyCodable("install")], priority: .critical, timestamp: nil)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        let envelope = try recorder.envelope(at: 0)
        XCTAssertNotNil(envelope["context"], "envelope V2 precisa de context no topo")
        let events = envelope["events"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 1)
        // Se voltasse o double-wrap do incidente 03/08, events[0] seria um envelope inteiro
        // (com "context"/"events") em vez de {id, ts, name, payload}.
        XCTAssertNil(events?[0]["context"], "events[0] não pode conter um envelope aninhado")
        XCTAssertNil(events?[0]["events"])
        XCTAssertNotNil(events?[0]["id"])
        XCTAssertNotNil(events?[0]["ts"])
        XCTAssertNotNil(events?[0]["name"])
        XCTAssertNotNil(events?[0]["payload"])
    }

    func testEnvelope_usesDistinctIdProviderAsFallback() throws {
        let recorder = PostRecorder()
        let batcher = makeBatcher(recorder, distinctId: "user_from_provider")

        let done = expectation(description: "posted")
        Task {
            await batcher.track(name: "lifecycle", properties: ["type": AnyCodable("install")], priority: .critical, timestamp: nil)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        let envelope = try recorder.envelope(at: 0)
        let context = envelope["context"] as? [String: Any]
        XCTAssertEqual(context?["distinct_id"] as? String, "user_from_provider")
    }

    func testEnvelope_injectsPlatform() throws {
        let recorder = PostRecorder()
        let batcher = makeBatcher(recorder)

        let done = expectation(description: "posted")
        Task {
            await batcher.track(name: "my_custom_event", properties: [:], priority: .critical, timestamp: nil)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        let envelope = try recorder.envelope(at: 0)
        let context = envelope["context"] as? [String: Any]
        XCTAssertEqual(context?["platform"] as? String, "ios")
    }

    // MARK: - Taxonomy gates

    func testDeprecatedEvent_isDroppedBeforePosting() async {
        let recorder = PostRecorder()
        let batcher = makeBatcher(recorder)

        await batcher.track(name: "$app_open", properties: [:], priority: .critical, timestamp: nil)
        await batcher.flush()

        XCTAssertTrue(recorder.calls.isEmpty, "evento deprecated não pode chegar ao servidor")
    }

    func testInvalidSchema_stillFlows() async {
        let recorder = PostRecorder()
        let batcher = makeBatcher(recorder)

        // paywall sem paywall_id reprova na validação, mas o evento continua fluindo:
        // a validação é sinal pro dev, não um gate de entrega.
        await batcher.track(name: "paywall", properties: ["type": AnyCodable("viewed")], priority: .critical, timestamp: nil)

        XCTAssertEqual(recorder.calls.count, 1)
    }

    // MARK: - Event observer (SKAN choke point)

    func testEventObserver_isCalledWithRawProperties() async {
        let recorder = PostRecorder()
        let batcher = makeBatcher(recorder)

        var seen: [(String, [String: AnyCodable])] = []
        batcher.setEventObserver { name, props in seen.append((name, props)) }

        await batcher.track(name: "transaction", properties: ["type": AnyCodable("completed"), "value": AnyCodable(9.99)], priority: .critical, timestamp: nil)

        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].0, "transaction")
        XCTAssertEqual(seen[0].1["value"]?.value as? Double, 9.99)
        XCTAssertNil(seen[0].1["platform"], "o observer vê as properties do chamador, antes do enriquecimento")
    }

    func testEventObserver_isNotCalledForDeprecatedEvents() async {
        let recorder = PostRecorder()
        let batcher = makeBatcher(recorder)

        var callCount = 0
        batcher.setEventObserver { _, _ in callCount += 1 }

        await batcher.track(name: "$app_open", properties: [:], priority: .normal, timestamp: nil)
        XCTAssertEqual(callCount, 0)
    }

    func testEventObserver_canBeCleared() async {
        let recorder = PostRecorder()
        let batcher = makeBatcher(recorder)

        var callCount = 0
        batcher.setEventObserver { _, _ in callCount += 1 }
        batcher.setEventObserver(nil)

        await batcher.track(name: "lifecycle", properties: ["type": AnyCodable("foreground")], priority: .normal, timestamp: nil)
        XCTAssertEqual(callCount, 0)
    }
}
