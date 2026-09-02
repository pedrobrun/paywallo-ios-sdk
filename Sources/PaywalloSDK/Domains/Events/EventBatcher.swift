import Foundation

// MARK: - EventBatcherProtocol

public protocol EventBatcherProtocol: AnyObject {
    /// Awaits delivery for `critical`; returns as soon as the event is buffered for `normal`.
    func track(name: String, properties: [String: AnyCodable], priority: EventPriority, timestamp: TimeInterval?) async
    func enqueue(name: String, properties: [String: AnyCodable], priority: EventPriority, timestamp: TimeInterval?)
    func flush() async
    func dispose()
}

public extension EventBatcherProtocol {
    /// Conformers that deliver synchronously (test spies, forwarding decorators) have nothing
    /// to await.
    func track(name: String, properties: [String: AnyCodable], priority: EventPriority, timestamp: TimeInterval?) async {
        enqueue(name: name, properties: properties, priority: priority, timestamp: timestamp)
    }
}

/// Posts one already-encoded envelope: `(url, body, label, priority)`. Wired to
/// `postWithQueue`, which owns the retry policy and the durable retry for `critical`.
public typealias EventPostFn = (String, Data, String, EventPriority) async -> Void

/// Funnel-milestone observer (SKAN), injected instead of imported so `Domains/Events` never
/// has to know about the attribution domain.
public typealias EventObserver = (String, [String: AnyCodable]) -> Void

public struct BatchEvent {
    public let name: String
    public let family: EventFamily
    public var properties: [String: AnyCodable]
    public let timestamp: TimeInterval
    public let priority: EventPriority

    public init(name: String, family: EventFamily, properties: [String: AnyCodable] = [:], timestamp: TimeInterval = Date().timeIntervalSince1970 * 1000, priority: EventPriority = .normal) {
        self.name = name
        self.family = family
        self.properties = properties
        self.timestamp = timestamp
        self.priority = priority
    }
}

/// Event priority controls delivery semantics:
///
/// - `critical` → posted immediately as a batch-of-1, and `track()` awaits the post. On
///   failure (5xx/429/network error) `postWithQueue` persists the request in `PendingRetry`
///   for a bounded retry. It is NEVER buffered or batched.
/// - `normal` → buffered and flushed on whichever comes first: `batchMaxSize` events or
///   `batchFlushMs`. A failure here is a deliberate drop, reported through `onError`.
///
/// There is no queue. Incident 03/08/2026: the OfflineQueue made critical events
/// queue-only and its processor re-wrapped the V2 envelope as `{events: [envelope, …]}`,
/// dropping 100% of `$app_installed`. See
/// `docs/incidents/2026-08-03-critical-event-loss.md` in the React Native SDK.
open class EventBatcher: EventBatcherProtocol {
    public static let v2BatchEndpoint = "/sdk/ingest/batch"

    private let lock = NSLock()
    private var normalQueue: [BatchEvent] = []
    private var flushTask: Task<Void, Never>?
    private var post: EventPostFn?
    private var contextProvider: (() -> IngestContext)?
    private var distinctIdProvider: (() -> String)?
    private var observer: EventObserver?
    private var debug = false
    private var disposed = false

    private let batchMaxSize = PaywalloConstants.batchMaxSize  // 25
    private let flushIntervalMs = PaywalloConstants.batchFlushMs  // 10000

    public init() {}

    public func initialize(
        post: @escaping EventPostFn,
        contextProvider: @escaping () -> IngestContext,
        distinctIdProvider: (() -> String)? = nil,
        debug: Bool = false
    ) {
        self.post = post
        self.contextProvider = contextProvider
        self.distinctIdProvider = distinctIdProvider
        self.debug = debug
        self.disposed = false  // Reset so enqueue works after fullReset + re-init
    }

    /// Funnel milestones (SKAN). Called synchronously and guarded — the observer must never
    /// delay nor break the event it observes.
    public func setEventObserver(_ observer: EventObserver?) {
        self.observer = observer
    }

    // MARK: - Track

    open func track(
        name: String,
        properties: [String: AnyCodable],
        priority: EventPriority = .normal,
        timestamp: TimeInterval? = nil
    ) async {
        guard !isDisposed() else { return }

        // V2 taxonomy: drop deprecated events at the source so no junk reaches the server.
        if EventFamilies.isDeprecated(name) {
            log("Dropped deprecated event: \(name)")
            return
        }

        if !EventFamilies.isValidEventName(name) {
            log("Event name '\(name)' doesn't match expected pattern")
        }

        // Warn-only: the event still flows so prod analytics never go silent; the warning is
        // the signal for the developer.
        let validation = EventFamilies.validateEvent(eventName: name, properties: properties, debug: debug)
        if !validation.ok {
            log("schema validation failed for \"\(name)\" (family=\(validation.family.rawValue))")
        }

        // Before the payload is assembled: this is the choke point SKAN hooks into, and it
        // must see the event exactly as the caller sent it. Synchronous by contract — the
        // observer is an auxiliary signal and must never delay the event behind it.
        observer?(name, properties)

        var props = properties
        props["platform"] = AnyCodable(PaywalloConstants.sdkPlatform)

        let event = BatchEvent(
            name: name,
            family: EventFamilies.detectFamily(name),
            properties: props,
            timestamp: timestamp ?? Date().timeIntervalSince1970 * 1000,
            priority: priority
        )

        if priority == .critical {
            await postBatch([event], label: "event_critical:\(event.name)", priority: .critical)
            return
        }

        if buffer(event) {
            cancelFlushTask()
            await flushNormal()
            return
        }

        scheduleFlush()
    }

    /// Fire-and-forget entry point for synchronous call sites. `critical` still posts
    /// directly — only the caller's `await` is dropped.
    open func enqueue(
        name: String,
        properties: [String: AnyCodable],
        priority: EventPriority = .normal,
        timestamp: TimeInterval? = nil
    ) {
        Task { [weak self] in
            await self?.track(name: name, properties: properties, priority: priority, timestamp: timestamp)
        }
    }

    // MARK: - Flush

    /// Force-flush the normal buffer. Critical events are never held here — they are posted
    /// (and awaited) inside `track()`.
    public func flush() async {
        cancelFlushTask()
        await flushNormal()
    }

    private func flushNormal() async {
        let events = drainBuffer()
        guard !events.isEmpty else { return }
        await postBatch(events, label: "event_batch:\(events.count)", priority: .normal)
    }

    private func scheduleFlush() {
        lock.lock()
        defer { lock.unlock() }
        guard flushTask == nil else { return }
        let intervalNs = UInt64(flushIntervalMs) * 1_000_000
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: intervalNs)
            guard !Task.isCancelled, let self = self else { return }
            self.clearFlushTask()
            await self.flushNormal()
        }
    }

    /// State access lives in synchronous helpers: `NSLock` may not be taken across an
    /// `await`, and `NSLocking.withLock` is not available on the macOS 12 deployment target.
    private func isDisposed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return disposed
    }

    /// Buffers the event and reports whether the size trigger fired.
    private func buffer(_ event: BatchEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        normalQueue.append(event)
        return normalQueue.count >= batchMaxSize
    }

    private func drainBuffer() -> [BatchEvent] {
        lock.lock()
        defer { lock.unlock() }
        let events = normalQueue
        normalQueue.removeAll()
        return events
    }

    private func cancelFlushTask() {
        lock.lock()
        let task = flushTask
        flushTask = nil
        lock.unlock()
        task?.cancel()
    }

    private func clearFlushTask() {
        lock.lock()
        flushTask = nil
        lock.unlock()
    }

    // MARK: - Post

    /// Builds the envelope and hands the ENCODED bytes to `post`. Encoding here (and not
    /// downstream) is what lets `PendingRetry` persist and re-post the exact same bytes —
    /// the envelope is never rebuilt, re-wrapped or merged with another one.
    private func postBatch(_ events: [BatchEvent], label: String, priority: EventPriority) async {
        guard let post = post else { return }

        let context = contextProvider?() ?? IngestContext()
        let fallbackDistinctId = distinctIdProvider?() ?? ""
        let inputs = events.map { event in
            EventInput(
                family: event.family,
                name: event.name,
                payload: event.properties,
                timestamp: event.timestamp,
                distinctId: fallbackDistinctId
            )
        }

        let envelope = V2EnvelopeBuilder.build(events: inputs, providerContext: context, debug: debug)
        guard let body = try? JSONEncoder().encode(envelope) else {
            log("Failed to encode envelope, dropping \(events.count) events")
            return
        }

        await post(Self.v2BatchEndpoint, body, label, priority)
    }

    // MARK: - Dispose

    public func dispose() {
        cancelFlushTask()
        lock.lock()
        disposed = true
        normalQueue.removeAll()
        lock.unlock()
    }

    private func log(_ message: String) {
        guard debug else { return }
        print("[Paywallo:Batcher] \(message)")
    }
}
