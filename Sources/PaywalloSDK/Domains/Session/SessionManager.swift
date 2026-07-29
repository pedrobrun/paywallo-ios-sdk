import Foundation

public final class SessionManager {

    // MARK: - State

    private var sessionId: String?
    private var sessionStartMs: Int64?

    private let secureStorage: SecureStorage
    private var debug: Bool

    // Storage keys — must match PaywalloConstants so any other code reading those
    // constants finds the same data.
    private let sessionIdKey = PaywalloConstants.currentSessionIdKey
    private let sessionStartKey = PaywalloConstants.sessionStartKey
    private let emergencyPaywallShownKey = PaywalloConstants.emergencyPaywallShownKey

    private let timeoutMs: Int = PaywalloConstants.sessionTimeoutMs  // 30 min

    // MARK: - Init

    public init(secureStorage: SecureStorage = .shared, debug: Bool = false) {
        self.secureStorage = secureStorage
        self.debug = debug
    }

    // MARK: - Restore

    /// Call on SDK init to restore a still-valid session from storage.
    public func restoreIfValid() async {
        let storedId = await secureStorage.get(sessionIdKey)
        let storedStart = await secureStorage.get(sessionStartKey)

        guard let id = storedId, let startStr = storedStart, let startMs = Int64(startStr) else {
            await clearStorage()
            return
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let elapsed = nowMs - startMs

        if elapsed < Int64(timeoutMs) {
            sessionId = id
            sessionStartMs = startMs
            log("Session restored: \(id), elapsed \(elapsed)ms")
        } else {
            log("Session expired (elapsed \(elapsed)ms), clearing")
            await clearStorage()
        }
    }

    // MARK: - Start

    /// Starts a new session. Waits up to 1s for a distinctId to be available.
    /// Throws SessionError if no distinctId is available. If a session is already
    /// active it is ended first.
    public func startSession(distinctIdProvider: @escaping () -> String) async throws {
        // Wait up to 10x100ms for a non-empty distinctId
        var resolved = distinctIdProvider()
        if resolved.isEmpty {
            for _ in 0..<10 {
                try await Task.sleep(nanoseconds: 100_000_000)
                resolved = distinctIdProvider()
                if !resolved.isEmpty { break }
            }
        }

        if resolved.isEmpty {
            throw SessionError(
                code: SessionErrorCode.startFailed,
                message: "No distinctId available — identity not initialized"
            )
        }

        // End previous session if active
        if sessionId != nil {
            await endSessionInternal()
        }

        let newId = UUID().uuidString
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        sessionId = newId
        sessionStartMs = nowMs

        await secureStorage.set(sessionIdKey, value: newId)
        await secureStorage.set(sessionStartKey, value: String(nowMs))

        log("Session started: \(newId)")
    }

    // MARK: - End

    /// Ends the current session, emits nothing — tracking is done by SessionTracking.
    /// Returns duration_s for the caller to use when emitting events.
    @discardableResult
    public func endSession() async -> Double {
        return await endSessionInternal()
    }

    @discardableResult
    private func endSessionInternal() async -> Double {
        guard let startMs = sessionStartMs else { return 0 }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let durationS = Double(nowMs - startMs) / 1000.0

        sessionId = nil
        sessionStartMs = nil

        await clearStorage()

        log("Session ended, duration: \(durationS)s")
        return durationS
    }

    // MARK: - Getters

    public func getSessionId() -> String? { sessionId }

    public func getSessionStartMs() -> Int64? { sessionStartMs }

    public func isSessionActive() -> Bool { sessionId != nil }

    // MARK: - Emergency Paywall Flag

    /// Returns true if emergency paywall has already been shown this session.
    public func hasEmergencyPaywallBeenShown() async -> Bool {
        guard sessionId != nil else { return false }
        let val = await secureStorage.get(emergencyPaywallShownKey)
        return val == "1"
    }

    /// Mark emergency paywall as shown for this session.
    public func markEmergencyPaywallShown() async {
        guard sessionId != nil else { return }
        await secureStorage.set(emergencyPaywallShownKey, value: "1")
    }

    // MARK: - Lifecycle

    /// Resets in-memory state. Called on fullReset — does not clear storage
    /// (endSession should be called first for a clean shutdown).
    public func destroy() {
        sessionId = nil
        sessionStartMs = nil
    }

    // MARK: - Private

    private func clearStorage() async {
        await secureStorage.remove(sessionIdKey)
        await secureStorage.remove(sessionStartKey)
        await secureStorage.remove(emergencyPaywallShownKey)
    }

    private func log(_ message: String) {
        guard debug else { return }
        print("[Paywallo:Session] \(message)")
    }
}
