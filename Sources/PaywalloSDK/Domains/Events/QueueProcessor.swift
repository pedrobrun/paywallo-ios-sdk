import Foundation

public final class QueueProcessor {
    private let queue: OfflineQueue
    private let networkMonitor: NetworkMonitor
    private var getFreshHeaders: (() -> [String: String])?
    private var httpClient: HttpClient?

    private var retryTimer: Timer?
    private var networkCleanup: (() -> Void)?
    private var isProcessing = false
    private let retryInterval: TimeInterval = 60
    private let batchSize = 50

    public init(
        queue: OfflineQueue,
        networkMonitor: NetworkMonitor = .shared
    ) {
        self.queue = queue
        self.networkMonitor = networkMonitor
    }

    public func initialize(
        httpClient: HttpClient,
        getFreshHeaders: @escaping () -> [String: String]
    ) {
        self.httpClient = httpClient
        self.getFreshHeaders = getFreshHeaders

        // Listen for network recovery
        networkCleanup = networkMonitor.addListener { [weak self] online in
            if online {
                Task { [weak self] in
                    await self?.processQueue()
                }
            }
        }

        // Listen for flush:requested (critical items)
        queue.onFlushRequested = { [weak self] in
            guard let self = self, self.networkMonitor.isOnline() else { return }
            Task { [weak self] in
                await self?.processQueue()
            }
        }

        // Start retry timer
        startRetryTimer()
    }

    // MARK: - Processing

    @discardableResult
    public func processQueue() async -> OfflineQueueResult {
        guard !isProcessing else { return OfflineQueueResult(processed: 0, failed: 0) }
        guard networkMonitor.isOnline() else { return OfflineQueueResult(processed: 0, failed: 0) }
        guard !queue.isEmpty else { return OfflineQueueResult(processed: 0, failed: 0) }

        isProcessing = true
        defer { isProcessing = false }

        let ready = queue.dequeueReady()
        guard !ready.isEmpty else { return OfflineQueueResult(processed: 0, failed: 0) }

        // Separate events from non-events
        let events = ready.filter { $0.isEvent }
        let nonEvents = ready.filter { !$0.isEvent }

        var processed = 0
        var failed = 0

        // Process events in batches of batchSize
        if !events.isEmpty {
            let batches = stride(from: 0, to: events.count, by: batchSize).map {
                Array(events[$0..<min($0 + batchSize, events.count)])
            }
            for batch in batches {
                let result = await processBatch(batch)
                processed += result.processed
                failed += result.failed
            }
        }

        // Process non-events individually
        for item in nonEvents {
            let ok = await processItem(item)
            if ok { processed += 1 } else { failed += 1 }
        }

        return OfflineQueueResult(processed: processed, failed: failed)
    }

    /// Process event items individually via V2 /sdk/ingest/batch.
    /// Each QueueItem.payload is already a serialized V2 IngestEnvelope
    /// (enqueued by EventBatcher). We send each one as-is.
    private func processBatch(_ items: [QueueItem]) async -> OfflineQueueResult {
        guard let httpClient = httpClient else { return OfflineQueueResult(processed: 0, failed: items.count) }

        let headers = getFreshHeaders?() ?? [:]

        var processed = 0
        var failed = 0

        for item in items {
            guard let payload = item.payload else {
                queue.markSuccess(item.id)
                processed += 1
                continue
            }

            let path = item.url.isEmpty ? "/sdk/ingest/batch" : item.url
            let options = RequestOptions(
                method: "POST",
                headers: headers,
                body: payload,
                skipRetry: true
            )

            do {
                let response = try await httpClient.requestRaw(path: path, options: options)

                if response.ok || (400..<500).contains(response.status) {
                    queue.markSuccess(item.id)
                    processed += 1
                } else {
                    queue.markFailure(item.id)
                    failed += 1
                }
            } catch {
                queue.markFailure(item.id)
                failed += 1
            }
        }

        return OfflineQueueResult(processed: processed, failed: failed)
    }

    private func processItem(_ item: QueueItem) async -> Bool {
        guard let httpClient = httpClient else { return false }

        let freshHeaders = getFreshHeaders?() ?? [:]
        let mergedHeaders = item.headers.merging(freshHeaders) { _, new in new }

        let options = RequestOptions(
            method: item.method,
            headers: mergedHeaders,
            body: item.payload,
            skipRetry: true
        )

        do {
            let response = try await httpClient.requestRaw(path: item.url, options: options)

            if response.ok || (400..<500).contains(response.status) {
                queue.markSuccess(item.id)
                return true
            } else {
                queue.markFailure(item.id)
                return false
            }
        } catch {
            queue.markFailure(item.id)
            return false
        }
    }

    // MARK: - Timer

    private func startRetryTimer() {
        retryTimer = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.networkMonitor.isOnline(), !self.queue.isEmpty else { return }
            Task { [weak self] in
                await self?.processQueue()
            }
        }
    }

    public func dispose() {
        retryTimer?.invalidate()
        retryTimer = nil
        networkCleanup?()
        networkCleanup = nil
        queue.onFlushRequested = nil
    }
}
