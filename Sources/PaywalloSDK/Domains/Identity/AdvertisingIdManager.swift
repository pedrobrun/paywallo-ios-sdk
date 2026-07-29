import Foundation
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif
#if canImport(AdSupport)
import AdSupport
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

public final class AdvertisingIdManager {
    public static let shared = AdvertisingIdManager()

    private var cached: AdvertisingIdResult?
    private let zeroIdfa = "00000000-0000-0000-0000-000000000000"

    public init() {}

    public func getCached() -> AdvertisingIdResult? {
        cached
    }

    @MainActor
    public func collect(requestATT: Bool = false) async -> AdvertisingIdResult {
        if let cached = cached { return cached }

        let idfv = collectIdfv()

        #if canImport(AppTrackingTransparency)
        if #available(iOS 14, *) {
            var status = ATTrackingManager.trackingAuthorizationStatus

            if status == .notDetermined && requestATT {
                status = await ATTrackingManager.requestTrackingAuthorization()
            }

            let attStatus = mapAttStatus(status)
            var idfa: String? = nil

            if status == .authorized {
                #if canImport(AdSupport)
                let rawIdfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
                idfa = sanitizeId(rawIdfa)
                #endif
            }

            let result = AdvertisingIdResult(idfv: idfv, idfa: idfa, attStatus: attStatus)
            cached = result
            return result
        }
        #endif

        let result = AdvertisingIdResult(idfv: idfv, idfa: nil, attStatus: .unavailable)
        cached = result
        return result
    }

    private func collectIdfv() -> String? {
        #if canImport(UIKit)
        let idfv = UIDevice.current.identifierForVendor?.uuidString
        return sanitizeId(idfv)
        #else
        return nil
        #endif
    }

    private func sanitizeId(_ id: String?) -> String? {
        guard let id = id, id != zeroIdfa else { return nil }
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
