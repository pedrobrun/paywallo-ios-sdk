import Foundation

#if os(iOS)
import StoreKit
#endif

/// Bridge to SKAdNetwork. The advertised app MUST call update at least once
/// (ideally on the first launch, even with fine 0) — without it Apple never opens
/// the conversion window and no postback is generated at all, not even for the ad network.
///
/// Three APIs, by iOS version:
///   16.1+  updatePostbackConversionValue(_:coarseValue:lockWindow:)  — fine + coarse + lock
///   15.4+  updatePostbackConversionValue(_:)                          — fine only
///   <15.4  updateConversionValue(_:)                                  — fine only, no callback
public enum NativeSkan {

    /// SKAdNetwork only exists on iOS; anywhere else `SkanManager` becomes a no-op.
    public static func isAvailable() -> Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    /// Updates the conversion value.
    ///
    /// - Parameters:
    ///   - fine: 0-63. A value lower than the previous one is ignored by Apple.
    ///   - coarse: only value revealed on a low-volume campaign.
    ///   - lock: locks the postback (terminal state) and brings the signal delivery forward.
    /// - Returns: `true` when Apple accepted the update. An error from Apple is expected
    ///   and benign (non-increasing value, or an already locked postback) and never escapes.
    public static func updateConversionValue(
        _ fine: Int,
        coarse: CoarseConversionValue,
        lock: Bool
    ) async -> Bool {
        #if os(iOS)
        if #available(iOS 16.1, *) {
            return await withCheckedContinuation { continuation in
                SKAdNetwork.updatePostbackConversionValue(
                    fine,
                    coarseValue: coarseValue(from: coarse),
                    lockWindow: lock
                ) { error in
                    continuation.resume(returning: error == nil)
                }
            }
        }

        // iOS 16.0 exactly: coarse value and lock window are unavailable, so only the fine
        // value goes up. The pre-15.4 `updateConversionValue` path the RN native module also
        // carries is intentionally absent — this package's deployment target is iOS 16, so it
        // would be unreachable code that only produced a deprecation warning.
        return await withCheckedContinuation { continuation in
            SKAdNetwork.updatePostbackConversionValue(fine) { error in
                continuation.resume(returning: error == nil)
            }
        }
        #else
        return false
        #endif
    }

    #if os(iOS)
    @available(iOS 16.1, *)
    private static func coarseValue(from value: CoarseConversionValue) -> SKAdNetwork.CoarseConversionValue {
        switch value {
        case .high: return .high
        case .medium: return .medium
        // `low` is also the fallback the RN bridge applies to any unrecognised string.
        case .low: return .low
        }
    }

    #endif
}
