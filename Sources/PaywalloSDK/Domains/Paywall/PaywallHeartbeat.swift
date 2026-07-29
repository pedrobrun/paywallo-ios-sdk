import Foundation

// MARK: - HeartbeatSnapshot

public struct HeartbeatSnapshot: Codable {
    public let paywallId: String
    public let placement: String
    public let presentedAt: Double   // ms
    public let lastSeen: Double      // ms
    public let variantKey: String?
    public let variantId: String?
    public let campaignId: String?
}

// MARK: - PaywallHeartbeat

/// Maintains a periodic heartbeat snapshot in storage for crash recovery.
/// On init, if a snapshot is found it means the app crashed while a paywall was open.
public final class PaywallHeartbeat {

    // MARK: - Constants

    private static let storageKey = PaywalloConstants.paywallHeartbeatKey  // "@paywallo:paywall_heartbeat"
    private static let heartbeatIntervalMs = PaywalloConstants.heartbeatIntervalMs  // 5000

    // MARK: - Dependencies

    private let storage: NativeStorage
    private let onCrashRecovery: ((HeartbeatSnapshot, Double) -> Void)?  // (snapshot, durationS)

    // MARK: - State

    private var timer: Timer?
    private var snapshot: HeartbeatSnapshot?

    // MARK: - Init

    /// - Parameters:
    ///   - storage: NativeStorage instance (UserDefaults-backed).
    ///   - onCrashRecovery: Called with (snapshot, duration_s) when a previous crash is detected.
    public init(
        storage: NativeStorage = .shared,
        onCrashRecovery: ((HeartbeatSnapshot, Double) -> Void)? = nil
    ) {
        self.storage = storage
        self.onCrashRecovery = onCrashRecovery
        checkForCrashRecovery()
    }

    // MARK: - Crash Recovery

    private func checkForCrashRecovery() {
        guard let raw = storage.get(storageKey),
              let data = raw.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(HeartbeatSnapshot.self, from: data)
        else { return }

        // A snapshot exists → previous session crashed while paywall was open
        let durationS = calculateDurationS(presentedAt: snapshot.presentedAt, lastSeen: snapshot.lastSeen)

        // Clean up the stale snapshot
        storage.remove(storageKey)

        // Notify caller with full snapshot
        onCrashRecovery?(snapshot, durationS)
    }

    private var storageKey: String { PaywallHeartbeat.storageKey }

    // MARK: - Heartbeat Control

    /// Start the heartbeat timer. Call this when the paywall is presented.
    public func startHeartbeat(
        paywallId: String,
        placement: String,
        variantKey: String? = nil,
        variantId: String? = nil,
        campaignId: String? = nil
    ) {
        let nowMs = Date().timeIntervalSince1970 * 1000
        self.snapshot = HeartbeatSnapshot(
            paywallId: paywallId,
            placement: placement,
            presentedAt: nowMs,
            lastSeen: nowMs,
            variantKey: variantKey,
            variantId: variantId,
            campaignId: campaignId
        )

        writeSnapshot()

        let interval = TimeInterval(PaywallHeartbeat.heartbeatIntervalMs) / 1000.0
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tickSnapshot()
        }
    }

    /// Stop the heartbeat timer and remove the snapshot. Call this when paywall closes normally.
    public func stopHeartbeat() {
        timer?.invalidate()
        timer = nil
        storage.remove(storageKey)
        snapshot = nil
    }

    // MARK: - Private Helpers

    private func tickSnapshot() {
        guard let current = snapshot else { return }
        snapshot = HeartbeatSnapshot(
            paywallId: current.paywallId,
            placement: current.placement,
            presentedAt: current.presentedAt,
            lastSeen: Date().timeIntervalSince1970 * 1000,
            variantKey: current.variantKey,
            variantId: current.variantId,
            campaignId: current.campaignId
        )
        writeSnapshot()
    }

    private func writeSnapshot() {
        guard let current = snapshot else { return }

        if let data = try? JSONEncoder().encode(current),
           let raw = String(data: data, encoding: .utf8) {
            storage.set(storageKey, value: raw)
        }
    }

    // MARK: - Duration Calculation

    /// duration_s = max(0, round((lastSeen - presentedAt) / 1000))
    public static func calculateDurationS(presentedAt: Double, lastSeen: Double) -> Double {
        let rawS = (lastSeen - presentedAt) / 1000.0
        return max(0, rawS.rounded())
    }

    private func calculateDurationS(presentedAt: Double, lastSeen: Double) -> Double {
        PaywallHeartbeat.calculateDurationS(presentedAt: presentedAt, lastSeen: lastSeen)
    }
}
