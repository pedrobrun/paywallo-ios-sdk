import Foundation

public final class SessionTracking {

    private let batcher: EventBatcher
    private let distinctIdProvider: () -> String
    private let debug: Bool

    private let maxRetries = 10
    private let retryDelayNs: UInt64 = 100_000_000  // 100ms

    public init(
        batcher: EventBatcher,
        distinctIdProvider: @escaping () -> String,
        debug: Bool = false
    ) {
        self.batcher = batcher
        self.distinctIdProvider = distinctIdProvider
        self.debug = debug
    }

    // MARK: - Guard

    /// Returns a non-empty distinctId or throws after retries.
    private func waitForDistinctId() async throws -> String {
        var id = distinctIdProvider()
        if !id.isEmpty { return id }

        for _ in 0..<maxRetries {
            try await Task.sleep(nanoseconds: retryDelayNs)
            id = distinctIdProvider()
            if !id.isEmpty { return id }
        }

        throw SessionError(
            code: SessionErrorCode.startFailed,
            message: "distinctId not available after \(maxRetries) retries"
        )
    }

    // MARK: - Events

    /// Tracks $session_start with device/app context.
    /// Property names match RN SDK (camelCase): sessionId, appVersion, deviceModel, osVersion, timestamp.
    public func trackSessionStart(sessionId: String) async {
        let deviceInfo = await MainActor.run { DeviceInfo.shared.getDeviceInfo() }
        let timestamp = ISO8601DateFormatter().string(from: Date())

        let props: [String: AnyCodable] = [
            "sessionId": AnyCodable(sessionId),
            "timestamp": AnyCodable(timestamp),
            "appVersion": AnyCodable(deviceInfo.appVersion),
            "deviceModel": AnyCodable(deviceInfo.modelId.isEmpty ? deviceInfo.model : deviceInfo.modelId),
            "osVersion": AnyCodable(deviceInfo.systemVersion),
        ]

        batcher.enqueue(
            name: "$session_start",
            properties: props,
            priority: .normal
        )
    }

    /// Tracks lifecycle session_end with duration_s, ended_at, and started_at.
    /// Matches RN SDK payload: type, session_id, duration_s, ended_at, started_at.
    public func trackSessionEnd(sessionId: String, durationS: Double, startedAtMs: Int64? = nil) {
        let endedAt = ISO8601DateFormatter().string(from: Date())
        var props: [String: AnyCodable] = [
            "type": AnyCodable(LifecycleType.sessionEnd.rawValue),
            "session_id": AnyCodable(sessionId),
            "duration_s": AnyCodable(durationS),
            "ended_at": AnyCodable(endedAt),
        ]
        if let startMs = startedAtMs {
            let startedAt = ISO8601DateFormatter().string(
                from: Date(timeIntervalSince1970: Double(startMs) / 1000.0)
            )
            props["started_at"] = AnyCodable(startedAt)
        }

        batcher.enqueue(
            name: "lifecycle",
            properties: props,
            priority: .critical
        )
    }

    /// Tracks lifecycle foreground (replaces deprecated $app_open).
    public func trackAppOpen(sessionId: String) {
        let props: [String: AnyCodable] = [
            "type": AnyCodable(LifecycleType.foreground.rawValue),
            "session_id": AnyCodable(sessionId),
        ]

        batcher.enqueue(
            name: "lifecycle",
            properties: props,
            priority: .normal
        )
    }

    /// Tracks lifecycle background with duration_s.
    public func trackAppBackground(sessionId: String, durationS: Double) {
        let props: [String: AnyCodable] = [
            "type": AnyCodable(LifecycleType.background.rawValue),
            "session_id": AnyCodable(sessionId),
            "duration_s": AnyCodable(durationS),
        ]

        batcher.enqueue(
            name: "lifecycle",
            properties: props,
            priority: .critical
        )
    }
}
