import Foundation

/// Result of one delivery attempt: `ok` plus the HTTP status (0 when unknown).
public typealias PendingRetryPoster = @Sendable (String, Data, [String: String]) async -> (ok: Bool, status: Int)

public struct PendingItem: Codable, Sendable, Equatable {
    public let id: String
    public let url: String
    /// The complete, already-encoded request body. Stored as raw bytes and re-posted
    /// byte-for-byte — never decoded, merged, re-wrapped or batched with anything else.
    public let body: Data
    public let headers: [String: String]
    public var attempts: Int
    /// Epoch milliseconds.
    public var nextAt: Double
    /// True while this reservation's original POST is still in flight in THIS session —
    /// `process()` skips those so the write-ahead never races its own delivery.
    /// NEVER trusted across a restart: `load()` clears the flag, because an item persisted
    /// as in-flight means the app died mid-delivery, which is exactly the case the
    /// write-ahead exists to recover.
    public var inFlight: Bool?
    /// True once a definitive 4xx answered this item: it stops being retried (a retry
    /// cannot change the outcome), but the critical event does not vanish without a
    /// trace — it stays on disk until eviction or an explicit `remove()`.
    public var deadLetter: Bool?
}

private enum PostOutcome {
    case success
    case clientError
    case retryable
}

/// Minimal, auditable persisted retry for CRITICAL requests only. Replaces the
/// OfflineQueue (incident 03/08/2026: a batch processor re-wrapped the V2 envelope,
/// dropping 100% of `$app_installed`). Every item's `body` is a complete, already-built
/// request — `process()` re-posts it byte-for-byte, and never merges or re-wraps items.
///
/// See `docs/incidents/2026-08-03-critical-event-loss.md` in the React Native SDK.
///
/// Implemented as an `actor`, which serialises access to the stored properties. Note that
/// this is NOT enough on its own: a Swift actor releases its isolation at every `await`, so
/// two `process()` calls interleave across the network hop. `processingLock` below is the
/// explicit guard for that, mirroring the RN implementation.
public actor PendingRetry {
    public static let shared = PendingRetry()

    private var items: [PendingItem] = []
    private var poster: PendingRetryPoster?
    private var debug = false
    private var loaded = false
    /// Actors are re-entrant: an `await` inside `process()` lets another `process()` in.
    /// There are three independent entry points (the 30s timer, the network-recovery
    /// listener and `initialize()`), so without this flag the same item is POSTed twice in
    /// parallel and BOTH outcomes are applied to it — two retryable results burn
    /// `attempts` 0→1→2 inside one second, collapsing the 1min/5min policy and dropping a
    /// critical event from disk with only a debug-gated log.
    private var processingLock = false
    private var timerTask: Task<Void, Never>?
    private var networkUnsubscribe: (() -> Void)?

    private let storage: NativeStorage
    private let storageKey: String

    public init(storage: NativeStorage = .shared, storageKey: String = PaywalloConstants.pendingRetryKey) {
        self.storage = storage
        self.storageKey = storageKey
    }

    // MARK: - Lifecycle

    public func initialize(poster: @escaping PendingRetryPoster) async {
        self.poster = poster
        await ensureLoaded()

        if timerTask == nil {
            let intervalNs = UInt64(PaywalloConstants.pendingRetryProcessIntervalMs) * 1_000_000
            timerTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: intervalNs)
                    if Task.isCancelled { return }
                    await self?.process()
                }
            }
        }

        if networkUnsubscribe == nil {
            networkUnsubscribe = NetworkMonitor.shared.addListener { [weak self] online in
                guard online else { return }
                Task { await self?.process() }
            }
        }

        // Fire-and-forget, deliberately: awaiting it would put the sequential network
        // delivery of every recovered item on init's critical path. A device that queued a
        // few criticals while offline would then block `initialize()` for as long as those
        // POSTs take (each bounded only by the 10s HTTP timeout) — no session, no event
        // context, no $app_installed for the current launch. Registering the listener above
        // first also means an offline→online flip during this drain is not missed.
        Task { await self.process() }
    }

    public func setDebug(_ debug: Bool) {
        self.debug = debug
    }

    /// Test seam: installs the poster WITHOUT arming the timer, the network listener or the
    /// initial drain, so a test can drive `process()` deterministically.
    func setPosterForTesting(_ poster: @escaping PendingRetryPoster) {
        self.poster = poster
    }

    public func dispose() {
        timerTask?.cancel()
        timerTask = nil
        networkUnsubscribe?()
        networkUnsubscribe = nil
        poster = nil
        loaded = false
        items = []
    }

    // MARK: - Write paths

    /// Persist a request after a failure, for the interval processor to pick up.
    @discardableResult
    public func save(url: String, body: Data, headers: [String: String]) async -> String? {
        await push(url: url, body: body, headers: headers, inFlight: false)
    }

    /// Write-ahead: persist the request BEFORE the network attempt and return the reservation id.
    ///
    /// Why (regression 04/08/2026): write-ahead was introduced to fix a measured ~39% loss of
    /// `$app_installed` — the app being killed during the cold-start network `await` (ATT prompt,
    /// store redirect, impatient user). Removing the journal along with the OfflineQueue moved the
    /// save to AFTER the failure, so a process killed in flight lost the event with no log and no retry.
    ///
    /// Difference from the old design: there, critical NEVER posted directly — delivery was delegated
    /// to the QueueProcessor, which re-wrapped the V2 envelope and dropped 100% of installs on 03/08.
    /// Here delivery remains the direct POST of 2.7.0; only the write was moved earlier. The item is
    /// removed on success.
    ///
    /// Duplicate window: an app killed AFTER the 200 and BEFORE `remove()` re-sends on next boot.
    /// Covered server-side for the two cases that matter — `$app_installed` carries a deterministic
    /// `installEventId`, and a purchase hits the unique `transactions_dedup` index.
    @discardableResult
    public func reserve(url: String, body: Data, headers: [String: String]) async -> String? {
        await push(url: url, body: body, headers: headers, inFlight: true)
    }

    /// Delivery confirmed (or definitive 4xx): the reservation leaves the disk.
    public func remove(_ id: String) async {
        await ensureLoaded()
        let before = items.count
        items.removeAll { $0.id == id }
        guard items.count != before else {
            log("remove() id não encontrado: \(id)")
            return
        }
        await persist()
    }

    /// Retryable failure: releases the reservation for the interval `process()` to take over.
    ///
    /// `nextAt` is recomputed FROM THE FAILURE, not from the reservation. Without this the
    /// write-ahead would silently change the retry policy: a POST that takes 90s to fail would
    /// already be born overdue and retried immediately, instead of the 1min the policy states.
    public func markFailed(_ id: String) async {
        await ensureLoaded()
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].inFlight == true else {
            log("markFailed() id não encontrado ou não está em voo: \(id)")
            return
        }
        items[index].inFlight = false
        items[index].nextAt = Self.nowMs() + Double(PaywalloConstants.pendingRetryDelaysMs[0])
        await persist()
    }

    /// Definitive 4xx on the FIRST attempt. Re-sending cannot change the outcome, but the
    /// critical event must not disappear from disk — that is how the 03/08 incident lost
    /// 100% of `$app_installed`.
    public func markDeadLetter(_ id: String) async {
        await ensureLoaded()
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            log("markDeadLetter() id não encontrado: \(id)")
            return
        }
        items[index].inFlight = false
        items[index].deadLetter = true
        await persist()
    }

    private func push(url: String, body: Data, headers: [String: String], inFlight: Bool) async -> String? {
        await ensureLoaded()
        let candidate = PendingItem(
            id: UUID().uuidString,
            url: url,
            body: body,
            headers: headers,
            attempts: 0,
            nextAt: Self.nowMs() + Double(PaywalloConstants.pendingRetryDelaysMs[0]),
            inFlight: inFlight,
            deadLetter: nil
        )

        // Verify encodability BEFORE the item enters the array: one non-encodable item
        // would poison every subsequent persist() of the whole array.
        guard (try? JSONEncoder().encode(candidate)) != nil else {
            log("item não-serializável, descartando sem persistir: \(url)")
            return nil
        }

        if items.count >= PaywalloConstants.pendingRetryMaxItems {
            evictOldest()
        }
        items.append(candidate)
        await persist()
        log("\(inFlight ? "reserved" : "saved") \(url) size: \(items.count)")
        return candidate.id
    }

    /// Prefers evicting the oldest dead-letter first (it will not be retried anyway), then the
    /// oldest idle non-in-flight item; only falls back to a plain drop when everything is in flight.
    private func evictOldest() {
        if let deadIndex = items.firstIndex(where: { $0.deadLetter == true }) {
            let evicted = items.remove(at: deadIndex)
            log("cap MAX_ITEMS atingido — descartando dead-letter mais antigo: \(evicted.url)")
            return
        }
        if let idleIndex = items.firstIndex(where: { $0.inFlight != true }) {
            let evicted = items.remove(at: idleIndex)
            log("cap MAX_ITEMS atingido — descartando ocioso mais antigo: \(evicted.url)")
            return
        }
        // Queue full and everything in flight: we drop a request that can still fail, with no
        // trace left to retry it. Logged OUTSIDE the debug guard — silent loss is what caused
        // the 03/08 incident, and this is the only path in PendingRetry that actually loses data.
        guard !items.isEmpty else { return }
        let evicted = items.removeFirst()
        print("[Paywallo:PendingRetry] PERDA: fila cheia com tudo em voo, descartando: \(evicted.url)")
    }

    // MARK: - Processing

    public func process() async {
        guard let poster = poster else { return }
        // Do not burn an attempt while offline: wait for the network to come back (the
        // NetworkMonitor listener fires process() on "online"). Without this gate the 30s
        // interval would spend both attempts in ~6min offline and the critical event would
        // die before the connection returned.
        guard NetworkMonitor.shared.isOnline() else { return }
        // Checked and set with no `await` in between, so this is atomic within the actor.
        guard !processingLock else { return }
        processingLock = true
        defer { processingLock = false }

        await ensureLoaded()
        let now = Self.nowMs()
        // `inFlight` excluded: that reservation's original POST is still in flight in this
        // session. Without the filter, a POST slower than the first retry delay (60s) would be
        // re-sent in parallel by the 30s interval — a duplicate created by the write-ahead itself.
        let due = items.filter { $0.inFlight != true && $0.deadLetter != true && $0.nextAt <= now }
        for item in due {
            await processItem(item, poster: poster)
        }
    }

    private func processItem(_ item: PendingItem, poster: @escaping PendingRetryPoster) async {
        let outcome = await attemptPost(item, poster: poster)

        switch outcome {
        case .success:
            items.removeAll { $0.id == item.id }
            await persist()

        case .clientError:
            // Definitive 4xx: re-sending the same body cannot change the outcome, but the
            // critical event (e.g. $app_installed) must not vanish without a trace — it
            // becomes a dead letter instead of being deleted.
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].deadLetter = true
            }
            await persist()

        case .retryable:
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            items[index].attempts += 1
            if items[index].attempts >= PaywalloConstants.pendingRetryDelaysMs.count {
                let url = items[index].url
                items.remove(at: index)
                log("gave up \(url)")
                await persist()
                return
            }
            items[index].nextAt = Self.nowMs() + Double(PaywalloConstants.pendingRetryDelaysMs[items[index].attempts])
            await persist()
        }
    }

    private func attemptPost(_ item: PendingItem, poster: @escaping PendingRetryPoster) async -> PostOutcome {
        let result = await poster(item.url, item.body, item.headers)
        if result.ok { return .success }
        // A malformed response (no numeric status → 0) is a RETRY, not a drop (fix in 2.7.1).
        if result.status == 429 || result.status >= 500 || result.status == 0 { return .retryable }
        return .clientError
    }

    // MARK: - Persistence

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true
        guard let raw = storage.get(storageKey), let data = raw.data(using: .utf8) else {
            items = []
            return
        }
        guard var parsed = try? JSONDecoder().decode([PendingItem].self, from: data) else {
            items = []
            return
        }
        // An item left on disk as in-flight means the app died mid-delivery. That is precisely
        // the case the write-ahead exists to recover, so it becomes eligible again.
        for index in parsed.indices { parsed[index].inFlight = false }
        items = parsed
    }

    private func persist() async {
        guard let data = try? JSONEncoder().encode(items),
              let snapshot = String(data: data, encoding: .utf8)
        else {
            // Defence in depth: push() already rejects non-encodable items, but persist() is
            // best-effort and must never throw to the caller.
            log("persist falhou ao serializar o array — pulando gravação")
            return
        }

        storage.set(storageKey, value: snapshot)
        // UserDefaults never signals a write failure, so verify by read-back. Without this
        // signal, critical items silently fail to persist and vanish on restart (incident 03/08).
        if storage.get(storageKey) != snapshot {
            print("[Paywallo:PendingRetry] persist NÃO gravou (storage indisponível) — itens críticos podem se perder no restart")
        }
    }

    // MARK: - Introspection

    public func size() async -> Int {
        await ensureLoaded()
        return items.count
    }

    /// Snapshot of the queue — for tests and diagnostics.
    public func snapshot() async -> [PendingItem] {
        await ensureLoaded()
        return items
    }

    public func clear() async {
        await ensureLoaded()
        items = []
        await persist()
    }

    // MARK: - Helpers

    private static func nowMs() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    private func log(_ message: String) {
        guard debug else { return }
        print("[Paywallo:PendingRetry] \(message)")
    }
}
