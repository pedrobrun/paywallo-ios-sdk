import Foundation
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif
#if canImport(AdSupport)
import AdSupport
#endif
#if canImport(UIKit)
import UIKit
#endif

public enum AttStatus: String, Codable, Sendable {
    case granted
    case denied
    case restricted
    case undetermined
    case unavailable
}

public struct AdvertisingIdResult: Sendable {
    public let idfv: String?
    public let idfa: String?
    public let attStatus: AttStatus

    public init(idfv: String?, idfa: String?, attStatus: AttStatus) {
        self.idfv = idfv
        self.idfa = idfa
        self.attStatus = attStatus
    }
}

/// Notified once per undetermined→granted ATT transition detected by `refresh()`.
public typealias AdvertisingIdEnrichmentListener = (AdvertisingIdResult) -> Void

public final class AdvertisingIdManager {
    public static let shared = AdvertisingIdManager()

    private var cached: AdvertisingIdResult?
    private var listeners: [UUID: AdvertisingIdEnrichmentListener] = [:]
    /// One-shot guard: ATT decisions are monotonic (Apple never reverts granted back to
    /// undetermined), so a single flag covers "per transition" — without it, a caller
    /// polling `refresh()` after the OS decision would re-notify on every call.
    private var grantedTransitionNotified = false
    private var foregroundObserver: NSObjectProtocol?

    private let zeroIdfa = "00000000-0000-0000-0000-000000000000"

    public init() {
        setupForegroundRefreshListener()
    }

    deinit {
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Synchronous accessor for the cached `collect()` result. Returns nil until
    /// `collect()` resolves at least once. Used by the V2 envelope context provider —
    /// which is sync — to populate `context.ids` without awaiting.
    public func getCached() -> AdvertisingIdResult? {
        cached
    }

    /// `requestATT` is IGNORED — the SDK never shows the ATT prompt, that is the host
    /// app's call alone. The parameter survives only for source compatibility with
    /// existing call sites.
    @MainActor
    public func collect(requestATT: Bool = false) async -> AdvertisingIdResult {
        _ = requestATT
        if let cached = cached { return cached }

        let idfv = await collectIdfv()

        #if canImport(AppTrackingTransparency)
        if #available(iOS 14, *) {
            let status = ATTrackingManager.trackingAuthorizationStatus
            var idfa: String?

            // Only READS the status the app already resolved — never prompts here. The
            // install cannot hang waiting for an answer: the app may die before it
            // arrives, and losing the install costs more than losing the IDFA.
            if status == .authorized {
                #if canImport(AdSupport)
                idfa = sanitizeId(ASIdentifierManager.shared().advertisingIdentifier.uuidString)
                #endif
            }

            let result = AdvertisingIdResult(idfv: idfv, idfa: idfa, attStatus: mapAttStatus(status))
            // Only cache once the IDFV is present — UIDevice can still answer nil while
            // the app is early in launch, and caching that nil freezes it until next boot.
            if idfv != nil { cached = result }
            return result
        }
        #endif

        let result = AdvertisingIdResult(idfv: idfv, idfa: nil, attStatus: .unavailable)
        if idfv != nil { cached = result }
        return result
    }

    /// Invalidates the cache and re-collects (still without prompting). Use after the
    /// user answers an ATT prompt raised outside `collect()`'s own call — `getCached()`
    /// would otherwise keep serving the pre-answer snapshot until the next cold boot,
    /// since `collect()`'s call sites all run at init.
    ///
    /// Nulling the cache is required: `collect()` skips writing it when the IDFV is nil,
    /// so a stale cache would survive a bare re-invocation.
    @discardableResult
    @MainActor
    public func refresh() async -> AdvertisingIdResult {
        let previousStatus = cached?.attStatus
        cached = nil

        let result = await collect(requestATT: false)

        if previousStatus == .undetermined && result.attStatus == .granted {
            notifyGrantedTransition(result)
        }

        return result
    }

    /// Subscribes to the undetermined→granted ATT transition detected by `refresh()`.
    /// Fires at most once per manager instance, so polling `refresh()` does not re-notify.
    /// Returns an unsubscribe closure.
    @discardableResult
    public func onGrantedTransition(_ listener: @escaping AdvertisingIdEnrichmentListener) -> () -> Void {
        let token = UUID()
        listeners[token] = listener
        return { [weak self] in self?.listeners.removeValue(forKey: token) }
    }

    // MARK: - Private

    /// Re-checks ATT on foreground ONLY while it is still undetermined — Apple's decision
    /// is monotonic, so a decided status never needs re-collecting on every
    /// background/foreground cycle.
    private func setupForegroundRefreshListener() {
        #if canImport(UIKit)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.cached?.attStatus == .undetermined else { return }
            Task { @MainActor in await self.refresh() }
        }
        #endif
    }

    private func notifyGrantedTransition(_ result: AdvertisingIdResult) {
        if grantedTransitionNotified { return }
        grantedTransitionNotified = true
        for listener in listeners.values {
            listener(result)
        }
    }

    /// UIDevice can answer nil for a short window during launch (and right after a
    /// restore), and a nil IDFV costs the deterministic match. Retry a few times before
    /// giving up.
    @MainActor
    private func collectIdfv() async -> String? {
        for attempt in 0..<PaywalloConstants.idfvCollectMaxAttempts {
            #if canImport(UIKit)
            if let idfv = sanitizeId(UIDevice.current.identifierForVendor?.uuidString) {
                return idfv
            }
            #endif
            if attempt < PaywalloConstants.idfvCollectMaxAttempts - 1 {
                try? await Task.sleep(nanoseconds: UInt64(PaywalloConstants.idfvCollectRetryDelayMs) * 1_000_000)
            }
        }
        return nil
    }

    private func sanitizeId(_ id: String?) -> String? {
        guard let id = id, !id.isEmpty, id != zeroIdfa else { return nil }
        return id
    }

    #if canImport(AppTrackingTransparency)
    @available(iOS 14, *)
    private func mapAttStatus(_ status: ATTrackingManager.AuthorizationStatus) -> AttStatus {
        switch status {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .undetermined
        @unknown default: return .unavailable
        }
    }
    #endif
}
