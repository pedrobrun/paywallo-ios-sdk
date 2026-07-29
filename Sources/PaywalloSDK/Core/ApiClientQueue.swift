import Foundation

/// Wrapper around ApiClient that checks network reachability before executing requests.
/// When the device is offline, POST/PUT/DELETE/PATCH requests are enqueued in the
/// OfflineQueue for later replay. GET requests are allowed through immediately since
/// they are idempotent and safe to fail (caller handles the error).
public final class ApiClientQueue {
    public let apiClient: ApiClient
    private let offlineQueue: OfflineQueue
    private let networkMonitor: NetworkMonitor
    private var debug: Bool

    public init(
        apiClient: ApiClient,
        offlineQueue: OfflineQueue,
        networkMonitor: NetworkMonitor = .shared,
        debug: Bool = false
    ) {
        self.apiClient = apiClient
        self.offlineQueue = offlineQueue
        self.networkMonitor = networkMonitor
        self.debug = debug
    }

    // MARK: - Public interface

    /// Checks connectivity and either executes the request or enqueues it for later.
    ///
    /// - Parameters:
    ///   - method: HTTP method (GET, POST, PUT, DELETE, …)
    ///   - path: URL path relative to the API base URL
    ///   - body: Optional JSON-serialisable body
    ///   - headers: Additional per-request headers
    ///   - priority: Queue priority used when offline
    ///   - isEvent: Whether this is an analytics event (affects DLQ strategy)
    ///
    /// - Returns: Raw `HttpResponse<Data>` on success, or nil when the request
    ///            was enqueued offline (caller should treat this as a deferred success).
    @discardableResult
    public func execute(
        method: String,
        path: String,
        body: Data? = nil,
        headers: [String: String]? = nil,
        priority: QueueItemPriority = .normal,
        isEvent: Bool = false
    ) async -> HttpResponse<Data>? {
        let isMutating = isMutatingMethod(method)

        // If offline and this is a mutating request → enqueue and return nil
        if !networkMonitor.isOnline(), isMutating {
            enqueue(method: method, path: path, body: body, headers: headers, priority: priority, isEvent: isEvent)
            return nil
        }

        // Attempt the request
        do {
            let options = RequestOptions(method: method, headers: headers, body: body)
            let response = try await apiClient.httpClient.requestRaw(path: path, options: options)
            return response
        } catch {
            // Network error on a mutating request → enqueue for later
            if isMutating {
                log("Network error on \(method) \(path) — enqueueing offline")
                enqueue(method: method, path: path, body: body, headers: headers, priority: priority, isEvent: isEvent)
            }
            return nil
        }
    }

    // MARK: - Offline queue management

    /// Drain queued items: call this when the device comes back online.
    public func drainQueue() async {
        guard networkMonitor.isOnline() else { return }

        let ready = offlineQueue.dequeueReady()
        guard !ready.isEmpty else { return }

        log("Draining \(ready.count) queued items")

        for item in ready {
            await replay(item: item)
        }
    }

    // MARK: - Private helpers

    private func enqueue(
        method: String,
        path: String,
        body: Data?,
        headers: [String: String]?,
        priority: QueueItemPriority,
        isEvent: Bool
    ) {
        let baseUrl = apiClient.httpClient.getBaseUrl()
        let fullUrl = "\(baseUrl)\(path)"

        // Merge global headers with per-request headers
        var mergedHeaders: [String: String] = [
            "Content-Type": "application/json",
            "X-App-Key": apiClient.appKey,
            "x-sdk-version": PaywalloConstants.sdkVersion,
            "x-sdk-platform": PaywalloConstants.sdkPlatform,
        ]
        if let h = headers { mergedHeaders.merge(h) { _, new in new } }

        let item = QueueItem(
            method: method,
            url: fullUrl,
            payload: body,
            headers: mergedHeaders,
            priority: priority,
            appKey: apiClient.appKey,
            isEvent: isEvent
        )

        offlineQueue.enqueue(item)
        log("Enqueued offline: \(method) \(path) (priority: \(priority.rawValue))")
    }

    private func replay(item: QueueItem) async {
        guard let url = URL(string: item.url) else {
            offlineQueue.markSuccess(item.id)  // drop invalid URL
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = item.method
        request.httpBody = item.payload
        for (k, v) in item.headers {
            request.setValue(v, forHTTPHeaderField: k)
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                offlineQueue.markSuccess(item.id)
                log("Replayed: \(item.method) \(item.url) → \(http.statusCode)")
            } else {
                offlineQueue.markFailure(item.id)
            }
        } catch {
            offlineQueue.markFailure(item.id)
            log("Replay failed: \(item.method) \(item.url) — \(error.localizedDescription)")
        }
    }

    private func isMutatingMethod(_ method: String) -> Bool {
        let m = method.uppercased()
        return m == "POST" || m == "PUT" || m == "PATCH" || m == "DELETE"
    }

    private func log(_ msg: String) {
        guard debug else { return }
        print("[Paywallo:ApiQueue] \(msg)")
    }
}
