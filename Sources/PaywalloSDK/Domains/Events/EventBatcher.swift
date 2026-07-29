import Foundation

// MARK: - EventBatcherProtocol

public protocol EventBatcherProtocol: AnyObject {
    func enqueue(name: String, properties: [String: AnyCodable], priority: EventPriority, timestamp: TimeInterval?)
    func flush() async
    func dispose()
}

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

open class EventBatcher: EventBatcherProtocol {
    private var criticalQueue: [BatchEvent] = []
    private var normalQueue: [BatchEvent] = []
    private var flushTimer: Timer?
    private var criticalScheduled = false
    private var httpClient: HttpClient?
    private var contextProvider: (() -> IngestContext)?
    private var offlineQueue: OfflineQueue?
    private var appKey: String = ""
    private var debug = false
    private var disposed = false

    private let batchMaxSize = PaywalloConstants.batchMaxSize  // 25
    private let flushIntervalMs = PaywalloConstants.batchFlushMs  // 10000

    public init() {}

    public func initialize(httpClient: HttpClient, contextProvider: @escaping () -> IngestContext, offlineQueue: OfflineQueue? = nil, appKey: String = "", debug: Bool = false) {
        self.httpClient = httpClient
        self.contextProvider = contextProvider
        self.offlineQueue = offlineQueue
        self.appKey = appKey
        self.debug = debug
        self.disposed = false  // Reset disposed flag so enqueue works after fullReset + re-init
        startFlushTimer()
    }

    // MARK: - Enqueue

    open func enqueue(name: String, properties: [String: AnyCodable], priority: EventPriority = .normal, timestamp: TimeInterval? = nil) {
        guard !disposed else { return }

        // Check deprecated
        if EventFamilies.isDeprecated(name) {
            log("Dropped deprecated event: \(name)")
            return
        }

        // Validate name (warn only)
        if !EventFamilies.isValidEventName(name) {
            log("Event name '\(name)' doesn't match expected pattern")
        }

        let family = EventFamilies.detectFamily(name)

        // Inject platform
        var props = properties
        props["platform"] = AnyCodable("ios")

        let event = BatchEvent(
            name: name,
            family: family,
            properties: props,
            timestamp: timestamp ?? Date().timeIntervalSince1970 * 1000,
            priority: priority
        )

        if priority == .critical {
            criticalQueue.append(event)
            scheduleCriticalFlush()
        } else {
            normalQueue.append(event)
            if normalQueue.count >= batchMaxSize {
                Task { await self.flushNormal() }
            }
        }
    }

    // MARK: - Flush

    /// flush() only drains normalQueue
    public func flush() async {
        await flushNormal()
    }

    private func flushNormal() async {
        guard !normalQueue.isEmpty, let httpClient = httpClient else { return }

        let events = normalQueue
        normalQueue.removeAll()

        await postBatch(events, httpClient: httpClient)
    }

    private func scheduleCriticalFlush() {
        guard !criticalScheduled else { return }
        criticalScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.criticalScheduled = false

            Task { [weak self] in
                await self?.drainCritical()
            }
        }
    }

    private func drainCritical() async {
        guard let httpClient = httpClient else { return }

        while !criticalQueue.isEmpty {
            let event = criticalQueue.removeFirst()
            await postCritical(event, httpClient: httpClient)
        }
    }

    /// Post a single critical event via V2 /sdk/ingest/batch (batch-of-1).
    /// On failure, enqueue to OfflineQueue for retry with backoff.
    private func postCritical(_ event: BatchEvent, httpClient: HttpClient) async {
        let context = contextProvider?() ?? IngestContext()
        let eventTuple = (family: event.family, name: event.name, payload: event.properties, timestamp: event.timestamp)

        let envelope = V2EnvelopeBuilder.build(events: [eventTuple], providerContext: context)
        do {
            let body = try JSONEncoder().encode(envelope)
            let options = RequestOptions(method: "POST", body: body, skipRetry: true)
            let response = try await httpClient.requestRaw(path: "/sdk/ingest/batch", options: options)
            if response.ok { return }

            // 4xx = permanent failure, don't enqueue (except 429 = rate limit → retry)
            if (400..<500).contains(response.status), response.status != 429 {
                log("Critical event rejected (status \(response.status)): \(event.name)")
                return
            }

            // 5xx = transient, enqueue for retry
            log("Critical event failed (status \(response.status)), enqueueing for retry: \(event.name)")
            enqueueToOfflineQueue(envelope: envelope, priority: .critical)
        } catch {
            log("Critical event error, enqueueing for retry: \(event.name)")
            enqueueToOfflineQueue(envelope: envelope, priority: .critical)
        }
    }

    // MARK: - Post

    private func postBatch(_ events: [BatchEvent], httpClient: HttpClient) async {
        let context = contextProvider?() ?? IngestContext()

        let eventTuples = events.map { event in
            (family: event.family, name: event.name, payload: event.properties, timestamp: event.timestamp)
        }

        let envelope = V2EnvelopeBuilder.build(events: eventTuples, providerContext: context)

        do {
            let body = try JSONEncoder().encode(envelope)
            let options = RequestOptions(method: "POST", body: body, skipRetry: true)

            let response = try await httpClient.requestRaw(path: "/sdk/ingest/batch", options: options)

            if response.ok { return }

            // 4xx = permanent failure (bad payload), drop (except 429 = rate limit → retry)
            if (400..<500).contains(response.status), response.status != 429 {
                log("Batch rejected (status \(response.status)), dropping \(events.count) events")
                return
            }

            // 5xx = transient, enqueue for retry
            log("Batch failed (status \(response.status)), enqueueing \(events.count) events for retry")
            enqueueToOfflineQueue(envelope: envelope, priority: .normal)
        } catch {
            log("Batch error, enqueueing \(events.count) events for retry")
            enqueueToOfflineQueue(envelope: envelope, priority: .normal)
        }
    }

    // MARK: - Offline Queue Fallback

    /// Enqueue a failed V2 envelope to the OfflineQueue for retry by QueueProcessor.
    private func enqueueToOfflineQueue(envelope: IngestEnvelope, priority: QueueItemPriority) {
        guard let offlineQueue = offlineQueue else {
            log("No offline queue available, events lost")
            return
        }

        guard let body = try? JSONEncoder().encode(envelope) else {
            log("Failed to encode envelope for offline queue")
            return
        }

        let item = QueueItem(
            method: "POST",
            url: "/sdk/ingest/batch",
            payload: body,
            headers: [:],
            priority: priority,
            appKey: appKey,
            isEvent: true
        )
        offlineQueue.enqueue(item)
    }

    // MARK: - Timer

    private func startFlushTimer() {
        flushTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(flushIntervalMs) / 1000.0,
            repeats: true
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.flushNormal()
            }
        }
    }

    // MARK: - Dispose

    public func dispose() {
        disposed = true
        criticalQueue.removeAll()
        normalQueue.removeAll()
        flushTimer?.invalidate()
        flushTimer = nil
    }

    private func log(_ message: String) {
        guard debug else { return }
        print("[Paywallo:Batcher] \(message)")
    }
}
