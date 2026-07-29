import Foundation

public final class AutoEvents {
    private var didRun = false
    private let storage: SecureStorage

    public init(storage: SecureStorage = .shared) {
        self.storage = storage
    }

    public func fireIfNeeded(
        trackEvent: @escaping (String, [String: AnyCodable], EventPriority) async -> Void
    ) async {
        guard !didRun else { return }
        didRun = true

        // Debounce 1s
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        // Install event (once per device)
        let firstSeen = await storage.get(PaywalloConstants.firstSeenKey)
        if firstSeen == nil {
            await storage.set(PaywalloConstants.firstSeenKey, value: ISO8601DateFormatter().string(from: Date()))

            let payload: [String: AnyCodable] = [
                "type": AnyCodable("install"),
                "platform": AnyCodable("ios"),
                "device_type": AnyCodable("ios"),
                "app_version": AnyCodable(appVersion),
                "os_version": AnyCodable(ProcessInfo.processInfo.operatingSystemVersionString),
            ]
            await trackEvent("lifecycle", payload, .critical)
        }

        // Cold start (every launch)
        let coldStartPayload: [String: AnyCodable] = [
            "type": AnyCodable("cold_start"),
            "platform": AnyCodable("ios"),
            "device_type": AnyCodable("ios"),
            "app_version": AnyCodable(appVersion),
            "os_version": AnyCodable(ProcessInfo.processInfo.operatingSystemVersionString),
        ]
        await trackEvent("lifecycle", coldStartPayload, .normal)
    }
}
