import XCTest
@testable import PaywalloSDK

/// The lock on the 03/08/2026 incident (`docs/incidents/2026-08-03-critical-event-loss.md`).
///
/// The OfflineQueue's processor re-wrapped an already complete V2 envelope as
/// `{events: [envelope, …]}`, the server answered 400 and 100% of `$app_installed` were lost.
/// Every test here exists to prove the same thing from a different angle: whatever is
/// persisted for retry is re-posted BYTE FOR BYTE, and the shape on the wire is always
/// `{context, events: [{id, ts, name, payload}]}`.
final class PendingRetryWireTests: XCTestCase {

    private var suiteName: String!
    private var suite: UserDefaults!
    private var storage: NativeStorage!
    private let storageKey = "@paywallo:pending_retry_test"

    override func setUp() {
        super.setUp()
        suiteName = "com.paywallo.sdk.tests.pendingretry.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        storage = NativeStorage(service: suiteName, defaults: suite)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeRetry() -> PendingRetry {
        PendingRetry(storage: storage, storageKey: storageKey)
    }

    /// A real V2 envelope, built the same way the EventBatcher builds it.
    private func makeEnvelopeBody() throws -> Data {
        var context = IngestContext()
        context.distinctId = "user_wire"
        context.sessionId = "sess_wire"
        let event = EventInput(
            family: .lifecycle,
            name: "lifecycle",
            payload: ["type": AnyCodable("install"), "install_referrer_source": AnyCodable("meta")],
            timestamp: 1_715_000_000_000,
            distinctId: "user_wire"
        )
        let envelope = V2EnvelopeBuilder.build(events: [event], providerContext: context)
        return try JSONEncoder().encode(envelope)
    }

    private func assertIsV2Envelope(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("body não é um objeto JSON", file: file, line: line)
        }
        XCTAssertNotNil(json["context"], "envelope V2 precisa de `context` no topo", file: file, line: line)
        guard let events = json["events"] as? [[String: Any]], let first = events.first else {
            return XCTFail("envelope V2 precisa de `events[]`", file: file, line: line)
        }
        for key in ["id", "ts", "name", "payload"] {
            XCTAssertNotNil(first[key], "events[0].\(key) é obrigatório no schema V2", file: file, line: line)
        }
        // O double-wrap do incidente: events[0] era um envelope inteiro.
        XCTAssertNil(first["context"], "events[0] não pode conter um envelope aninhado", file: file, line: line)
        XCTAssertNil(first["events"], "events[0] não pode conter um envelope aninhado", file: file, line: line)
    }

    // MARK: - Bytes persistidos == bytes construídos

    func testSavedBodyIsByteIdenticalToTheBuiltEnvelope() async throws {
        let body = try makeEnvelopeBody()
        let retry = makeRetry()

        _ = await retry.save(url: "/sdk/ingest/batch", body: body, headers: ["X-App-Key": "pk_test"])

        let items = await retry.snapshot()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].body, body, "PendingRetry não pode transformar o body que recebeu")
        try assertIsV2Envelope(items[0].body)
    }

    func testReservedBodyIsByteIdenticalToTheBuiltEnvelope() async throws {
        let body = try makeEnvelopeBody()
        let retry = makeRetry()

        _ = await retry.reserve(url: "/sdk/ingest/batch", body: body, headers: ["X-App-Key": "pk_test"])

        let items = await retry.snapshot()
        XCTAssertEqual(items[0].body, body, "o write-ahead grava o body exatamente como recebido")
    }

    func testBodySurvivesTheStorageRoundTripUnchanged() async throws {
        let body = try makeEnvelopeBody()
        let writer = makeRetry()
        _ = await writer.save(url: "/sdk/ingest/batch", body: body, headers: ["X-App-Key": "pk_test"])

        // Nova instância lendo do disco: é o cenário do restart do app, onde o incidente
        // reembrulhava o que tinha sido gravado.
        let reader = makeRetry()
        let items = await reader.snapshot()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].body, body, "o body precisa atravessar o storage inalterado")
        try assertIsV2Envelope(items[0].body)
    }

    func testMultipleItemsAreNeverMergedIntoOneBody() async throws {
        let first = try makeEnvelopeBody()
        let second = try JSONEncoder().encode(V2EnvelopeBuilder.build(
            events: [EventInput(family: .transaction, name: "transaction",
                                payload: ["type": AnyCodable("completed"), "transaction_id": AnyCodable("tx_1")],
                                timestamp: 1_715_000_000_001, distinctId: "user_wire")]
        ))

        let retry = makeRetry()
        _ = await retry.save(url: "/sdk/ingest/batch", body: first, headers: [:])
        _ = await retry.save(url: "/sdk/ingest/batch", body: second, headers: [:])

        let items = await retry.snapshot()
        XCTAssertEqual(items.count, 2, "cada request é um item — juntar itens foi o bug do batch")
        XCTAssertEqual(items[0].body, first)
        XCTAssertEqual(items[1].body, second)
    }

    // MARK: - Bytes repostados == bytes persistidos

    func testProcessRePostsTheExactBytesThatWereSaved() async throws {
        // `process()` só entrega com rede: sem ela o teste não tem o que provar.
        NetworkMonitor.shared.initialize()
        try await waitUntilOnline()

        let body = try makeEnvelopeBody()
        let retry = makeRetry()

        // Grava direto no storage com `nextAt` no passado: save() nasce agendado pra +1min,
        // e o objetivo aqui é a entrega, não o backoff.
        let item = PendingItem(
            id: UUID().uuidString,
            url: "/sdk/ingest/batch",
            body: body,
            headers: ["X-App-Key": "pk_test"],
            attempts: 0,
            nextAt: Date().timeIntervalSince1970 * 1000 - 1000,
            inFlight: false,
            deadLetter: nil
        )
        let seeded = try JSONEncoder().encode([item])
        _ = storage.set(storageKey, value: String(data: seeded, encoding: .utf8)!)

        let posted = PostedBodies()
        await retry.initialize { url, body, headers in
            await posted.record(url: url, body: body, headers: headers)
            return (ok: true, status: 200)
        }

        // O drain do initialize é fire-and-forget de propósito: aguardá-lo colocaria a
        // entrega sequencial de todo item recuperado no caminho crítico do init. Então o
        // teste espera pela entrega em vez de assumir que ela já aconteceu.
        try await waitUntil(timeout: 3) { await posted.all.count == 1 }

        let recorded = await posted.all
        XCTAssertEqual(recorded.count, 1, "o item vencido deve ser repostado")
        XCTAssertEqual(recorded[0].body, body, "o retry reposta o body EXATAMENTE como salvo")
        try assertIsV2Envelope(recorded[0].body)
        XCTAssertEqual(recorded[0].url, "/sdk/ingest/batch")
        XCTAssertEqual(recorded[0].headers["X-App-Key"], "pk_test")

        let remaining = await retry.size()
        XCTAssertEqual(remaining, 0, "sucesso remove o item do disco")
        await retry.dispose()
    }

    // MARK: - Reentrância

    /// Duas chamadas concorrentes de `process()` não podem entregar o MESMO item duas vezes.
    ///
    /// Um actor Swift é reentrante: ele solta o isolamento em todo `await`, então a chamada
    /// que suspende no POST deixa a outra entrar e reprocessar o mesmo item. Como há três
    /// entradas independentes (timer de 30s, listener de rede e o drain do init), sem o
    /// `processingLock` o item é postado em paralelo e AMBOS os resultados são aplicados a
    /// ele — dois retryables queimam `attempts` 0→1→2 no mesmo segundo, colapsam a política
    /// de 1min/5min e apagam o evento crítico do disco deixando só um log de debug.
    func testConcurrentProcessDoesNotDeliverTheSameItemTwice() async throws {
        NetworkMonitor.shared.initialize()
        try await waitUntilOnline()

        let body = try makeEnvelopeBody()
        let item = PendingItem(
            id: UUID().uuidString,
            url: "/sdk/ingest/batch",
            body: body,
            headers: [:],
            attempts: 0,
            nextAt: Date().timeIntervalSince1970 * 1000 - 1000,
            inFlight: false,
            deadLetter: nil
        )
        _ = storage.set(storageKey, value: String(data: try JSONEncoder().encode([item]), encoding: .utf8)!)

        let retry = makeRetry()
        let posted = PostedBodies()
        await retry.setPosterForTesting { url, body, headers in
            // Suspende dentro do POST: é exatamente aqui que o actor solta o isolamento.
            try? await Task.sleep(nanoseconds: 150_000_000)
            await posted.record(url: url, body: body, headers: headers)
            return (ok: true, status: 200)
        }

        async let first: Void = retry.process()
        async let second: Void = retry.process()
        _ = await (first, second)

        let recorded = await posted.all
        XCTAssertEqual(recorded.count, 1, "o item vencido só pode ser entregue uma vez")
        let remaining = await retry.size()
        XCTAssertEqual(remaining, 0)
    }

    /// Espera uma condição assíncrona virar verdadeira, com deadline.
    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condição não foi satisfeita em \(timeout)s")
    }

    private func waitUntilOnline(timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NetworkMonitor.shared.forceCheck() == .online { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw XCTSkip("NetworkMonitor não reportou online — PendingRetry.process() não entrega offline por design")
    }
}

/// Actor so the poster (which runs off the test's thread) can record without a data race.
private actor PostedBodies {
    struct Entry {
        let url: String
        let body: Data
        let headers: [String: String]
    }

    private(set) var all: [Entry] = []

    func record(url: String, body: Data, headers: [String: String]) {
        all.append(Entry(url: url, body: body, headers: headers))
    }
}
