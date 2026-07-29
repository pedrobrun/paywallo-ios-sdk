import Foundation
#if canImport(UIKit)
import UIKit
#endif

public final class SessionLifecycle {

    private let sessionManager: SessionManager
    private let sessionTracking: SessionTracking
    private let batcher: EventBatcherProtocol
    private let distinctIdProvider: () -> String
    private let emergencyPaywallCheck: (() async -> Void)?
    private let debug: Bool

    private var isInBackground = false
    private var observations: [NSObjectProtocol] = []

    public init(
        sessionManager: SessionManager,
        sessionTracking: SessionTracking,
        batcher: EventBatcherProtocol,
        distinctIdProvider: @escaping () -> String,
        emergencyPaywallCheck: (() async -> Void)? = nil,
        debug: Bool = false
    ) {
        self.sessionManager = sessionManager
        self.sessionTracking = sessionTracking
        self.batcher = batcher
        self.distinctIdProvider = distinctIdProvider
        self.emergencyPaywallCheck = emergencyPaywallCheck
        self.debug = debug
    }

    // MARK: - Setup

    public func setup() {
        #if canImport(UIKit)
        let center = NotificationCenter.default

        let foregroundObs = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleForeground()
        }

        let backgroundObs = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleBackground()
        }

        observations = [foregroundObs, backgroundObs]
        log("Lifecycle observers registered")
        #endif
    }

    public func teardown() {
        let center = NotificationCenter.default
        observations.forEach { center.removeObserver($0) }
        observations.removeAll()
        log("Lifecycle observers removed")
    }

    // MARK: - Handlers

    private func handleForeground() {
        guard isInBackground else { return }  // Only trigger on active↔background transitions
        isInBackground = false

        log("App foregrounded — starting new session")

        Task {
            do {
                try await sessionManager.startSession(distinctIdProvider: distinctIdProvider)
                if let sid = sessionManager.getSessionId() {
                    await sessionTracking.trackSessionStart(sessionId: sid)
                    sessionTracking.trackAppOpen(sessionId: sid)
                    await emergencyPaywallCheck?()
                }
            } catch {
                log("Failed to start session on foreground: \(error)")
            }
        }
    }

    private func handleBackground() {
        // Background ALWAYS ends session, regardless of previous state
        isInBackground = true

        log("App backgrounded — ending session")

        let currentSessionId = sessionManager.getSessionId()
        let startedAtMs = sessionManager.getSessionStartMs()

        Task {
            // 1. Enqueue background + session_end events FIRST so they are
            //    included in the flush below (mirrors JS: trackAppBackground →
            //    flushEventsWithTimeout → endSession → trackSessionEnd).
            if let sid = currentSessionId,
               let startMs = startedAtMs {
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                let durationS = Double(nowMs - startMs) / 1000.0
                sessionTracking.trackAppBackground(sessionId: sid, durationS: durationS)
            }

            let durationS = await sessionManager.endSession()

            if let sid = currentSessionId {
                sessionTracking.trackSessionEnd(sessionId: sid, durationS: durationS, startedAtMs: startedAtMs)
            }

            // 2. Flush — race against 2s timeout so a slow network cannot hang
            //    the AppState transition. Events remain in the offline queue and
            //    are replayed on next foreground if the flush times out.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.batcher.flush() }
                group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                await group.next()
                group.cancelAll()
            }
        }
    }

    // MARK: - Private

    private func log(_ message: String) {
        guard debug else { return }
        print("[Paywallo:Lifecycle] \(message)")
    }
}
