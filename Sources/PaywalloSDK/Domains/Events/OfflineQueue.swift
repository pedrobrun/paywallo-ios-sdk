import Foundation

public enum QueueItemPriority: String, Codable, Sendable {
    case critical
    case normal
}

public struct QueueItem: Codable, Sendable, Identifiable {
    public let id: String
    public let method: String
    public let url: String
    public let payload: Data?
    public let headers: [String: String]
    public let priority: QueueItemPriority
    public let appKey: String
    public let createdAt: Date
    public var attempts: Int
    public var nextRetryAt: Date?
    public var isEvent: Bool

    public init(
        id: String = UUID().uuidString,
        method: String,
        url: String,
        payload: Data?,
        headers: [String: String],
        priority: QueueItemPriority = .normal,
        appKey: String,
        createdAt: Date = Date(),
        attempts: Int = 0,
        nextRetryAt: Date? = nil,
        isEvent: Bool = true
    ) {
        self.id = id
        self.method = method
        self.url = url
        self.payload = payload
        self.headers = headers
        self.priority = priority
        self.appKey = appKey
        self.createdAt = createdAt
        self.attempts = attempts
        self.nextRetryAt = nextRetryAt
        self.isEvent = isEvent
    }
}

public final class OfflineQueue {
    private var items: [QueueItem] = []
    private var dlq: [QueueItem] = []
    private let storage: NativeStorage

    private let maxCapacity: Int
    private let maxAttempts: Int
    private let maxAge: TimeInterval  // 7 days default
    private let baseRetryDelay: TimeInterval
    private let maxRetryDelay: TimeInterval

    private var cleanupTimer: Timer?
    private var initialized = false

    // Callback for flush:requested (critical items)
    public var onFlushRequested: (() -> Void)?

    public init(
        storage: NativeStorage = .shared,
        maxCapacity: Int = 1000,
        maxAttempts: Int = 10,
        maxAge: TimeInterval = 7 * 24 * 3600,
        baseRetryDelay: TimeInterval = 1.0,
        maxRetryDelay: TimeInterval = 300.0
    ) {
        self.storage = storage
        self.maxCapacity = maxCapacity
        self.maxAttempts = maxAttempts
        self.maxAge = maxAge
        self.baseRetryDelay = baseRetryDelay
        self.maxRetryDelay = maxRetryDelay
    }

    // MARK: - Initialize

    public func initialize() {
        guard !initialized else { return }
        initialized = true

        // Load from storage
        loadFromStorage()

        // Merge journal with main queue (crash recovery)
        mergeJournal()

        // Start hourly cleanup
        startCleanupTimer()
    }

    // MARK: - Enqueue

    public func enqueue(_ item: QueueItem) {
        // Dedup check
        if let existingIndex = items.firstIndex(where: { $0.id == item.id }) {
            // Priority upgrade: if new item is critical, upgrade existing
            if item.priority == .critical && items[existingIndex].priority == .normal {
                items[existingIndex] = QueueItem(
                    id: items[existingIndex].id,
                    method: items[existingIndex].method,
                    url: items[existingIndex].url,
                    payload: items[existingIndex].payload,
                    headers: items[existingIndex].headers,
                    priority: .critical,
                    appKey: items[existingIndex].appKey,
                    createdAt: items[existingIndex].createdAt,
                    attempts: items[existingIndex].attempts,
                    nextRetryAt: items[existingIndex].nextRetryAt,
                    isEvent: items[existingIndex].isEvent
                )
            }
            return
        }

        // Eviction if at capacity
        if items.count >= maxCapacity {
            evictOldest()
        }

        // Write to journal first (write-ahead)
        writeToJournal(item)

        items.append(item)
        saveToStorage()

        // Trigger flush for critical items
        if item.priority == .critical {
            onFlushRequested?()
        }
    }

    // MARK: - Dequeue / Processing

    public func dequeueReady() -> [QueueItem] {
        let now = Date()
        return items.filter { item in
            if let nextRetry = item.nextRetryAt, nextRetry > now {
                return false
            }
            return item.attempts < maxAttempts
        }
    }

    public func markSuccess(_ id: String) {
        items.removeAll { $0.id == id }
        removeFromJournal(id)
        saveToStorage()
    }

    public func markFailure(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }

        items[index].attempts += 1

        if items[index].attempts >= maxAttempts {
            // Move to DLQ
            dlq.append(items[index])
            items.remove(at: index)
            saveDlqToStorage()
        } else {
            // Calculate backoff
            let delay = min(
                baseRetryDelay * pow(2.0, Double(items[index].attempts - 1)),
                maxRetryDelay
            )
            items[index].nextRetryAt = Date().addingTimeInterval(delay)
        }

        saveToStorage()
    }

    // MARK: - Query

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    public func getAll() -> [QueueItem] { items }

    // MARK: - Cleanup

    public func clearItemsWithInvalidAppKey(_ currentAppKey: String) {
        let before = items.count
        items.removeAll { $0.appKey != currentAppKey }
        if items.count != before {
            saveToStorage()
        }
    }

    public func clear() {
        items.removeAll()
        dlq.removeAll()
        saveToStorage()
        saveDlqToStorage()
        clearJournal()
    }

    public func dispose() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        initialized = false
    }

    // MARK: - Storage

    private func loadFromStorage() {
        if let raw = storage.get(PaywalloConstants.offlineQueueKey),
           let data = raw.data(using: .utf8)
        {
            items = (try? JSONDecoder().decode([QueueItem].self, from: data)) ?? []
        }

        if let raw = storage.get(PaywalloConstants.queueDlqKey),
           let data = raw.data(using: .utf8)
        {
            dlq = (try? JSONDecoder().decode([QueueItem].self, from: data)) ?? []
        }
    }

    private func saveToStorage() {
        if let data = try? JSONEncoder().encode(items),
           let json = String(data: data, encoding: .utf8)
        {
            storage.set(PaywalloConstants.offlineQueueKey, value: json)
        }
    }

    private func saveDlqToStorage() {
        if let data = try? JSONEncoder().encode(dlq),
           let json = String(data: data, encoding: .utf8)
        {
            storage.set(PaywalloConstants.queueDlqKey, value: json)
        }
    }

    // MARK: - Journal (write-ahead log)

    private func writeToJournal(_ item: QueueItem) {
        var journal = loadJournal()
        journal.append(item)
        if let data = try? JSONEncoder().encode(journal),
           let json = String(data: data, encoding: .utf8)
        {
            storage.set(PaywalloConstants.offlineQueueJournalKey, value: json)
        }
    }

    private func removeFromJournal(_ id: String) {
        var journal = loadJournal()
        journal.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(journal),
           let json = String(data: data, encoding: .utf8)
        {
            storage.set(PaywalloConstants.offlineQueueJournalKey, value: json)
        }
    }

    private func loadJournal() -> [QueueItem] {
        guard let raw = storage.get(PaywalloConstants.offlineQueueJournalKey),
              let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([QueueItem].self, from: data)) ?? []
    }

    private func mergeJournal() {
        let journal = loadJournal()
        guard !journal.isEmpty else { return }

        let existingIds = Set(items.map(\.id))
        let newItems = journal.filter { !existingIds.contains($0.id) }
        items.append(contentsOf: newItems)

        clearJournal()
        saveToStorage()
    }

    private func clearJournal() {
        storage.remove(PaywalloConstants.offlineQueueJournalKey)
    }

    // MARK: - Eviction

    private func evictOldest() {
        guard let oldest = items.min(by: { $0.createdAt < $1.createdAt }) else { return }
        dlq.append(oldest)
        items.removeAll { $0.id == oldest.id }
        saveDlqToStorage()
    }

    // MARK: - Cleanup Timer

    private func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.cleanupExpired()
        }
    }

    private func cleanupExpired() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        let before = items.count
        items.removeAll { $0.createdAt < cutoff }
        dlq.removeAll { $0.createdAt < cutoff }

        if items.count != before {
            saveToStorage()
            saveDlqToStorage()
        }
    }
}
