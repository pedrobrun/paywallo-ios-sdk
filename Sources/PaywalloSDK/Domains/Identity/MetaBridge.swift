import Foundation

public final class MetaBridge {
    public static let shared = MetaBridge()

    private var cachedAnonymousId: String?
    private var hasCachedAnonymousId = false

    private var cachedDeferredLink: [String: String]??  // outer Optional = whether fetched; inner = result
    private var hasFetchedDeferredLink = false

    private init() {}

    /// Synchronous read of the cached anonymous ID. Returns nil if `getAnonymousID()` hasn't
    /// completed yet. Safe to call from any thread / non-async context.
    public func getCachedAnonymousId() -> String? {
        guard hasCachedAnonymousId else { return nil }
        return cachedAnonymousId
    }

    /// Get Facebook anonymous ID with 2s timeout. Cached after first call.
    /// Returns nil if FBSDK not available or timeout.
    public func getAnonymousID() async -> String? {
        if hasCachedAnonymousId {
            return cachedAnonymousId
        }

        #if canImport(FBSDKCoreKit)
        do {
            let result = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    // Import dynamically to avoid crash if not linked
                    return FBSDKCoreKit.AppEvents.shared.anonymousID
                }

                group.addTask {
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2s timeout
                    throw CancellationError()
                }

                // Return whichever finishes first
                let result = try await group.next()
                group.cancelAll()
                return result ?? nil
            }

            cachedAnonymousId = result
            hasCachedAnonymousId = true
            return result
        } catch {
            cachedAnonymousId = nil
            hasCachedAnonymousId = true
            return nil
        }
        #else
        cachedAnonymousId = nil
        hasCachedAnonymousId = true
        return nil
        #endif
    }

    /// Log event to Facebook. No-op if FBSDK not available.
    public func logEvent(_ name: String, parameters: [String: Any]? = nil) {
        #if canImport(FBSDKCoreKit)
        FBSDKCoreKit.AppEvents.shared.logEvent(FBSDKCoreKit.AppEvents.Name(name), parameters: parameters ?? [:])
        #endif
    }

    /// Log purchase to Facebook. No-op if FBSDK not available.
    public func logPurchase(amount: Double, currency: String, parameters: [String: Any]? = nil) {
        #if canImport(FBSDKCoreKit)
        FBSDKCoreKit.AppEvents.shared.logPurchase(amount: amount, currency: currency, parameters: parameters ?? [:])
        #endif
    }

    /// Set Facebook user ID. No-op if FBSDK not available.
    public func setUserID(_ userId: String?) {
        #if canImport(FBSDKCoreKit)
        FBSDKCoreKit.AppEvents.shared.userID = userId
        #endif
    }

    /// Fetch deferred app link from Facebook on first install launch.
    /// Cached after first call (FB recommends calling once per activation).
    /// If `attributionTracker` is provided, the parsed result is applied via `capture(_:)`.
    /// Returns nil if FBSDK not available, no deferred link exists, or timeout.
    /// - Note: `fetchDeferredAppLink` requires a real FBSDK integration and
    ///   cannot be unit-tested without the framework linked. Test `parseDeferredAppLink(_:)` instead.
    public func fetchDeferredAppLink(attributionTracker: AttributionTracker? = nil) async -> [String: String]? {
        if hasFetchedDeferredLink {
            return cachedDeferredLink ?? nil
        }

        #if canImport(FBSDKCoreKit)
        do {
            let urlString = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    return try await withCheckedThrowingContinuation { continuation in
                        FBSDKCoreKit.AppLinkUtility.fetchDeferredAppLink { url, error in
                            if let error = error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume(returning: url?.absoluteString)
                            }
                        }
                    }
                }

                group.addTask {
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2s timeout
                    throw CancellationError()
                }

                let result = try await group.next()
                group.cancelAll()
                return result ?? nil
            }

            let parsed = MetaBridge.parseDeferredAppLink(urlString)
            hasFetchedDeferredLink = true
            cachedDeferredLink = parsed

            // Wire result into AttributionTracker (first-write-wins)
            if let dict = parsed, let tracker = attributionTracker {
                let input = AttributionInput(
                    utmSource: dict["utm_source"],
                    utmMedium: dict["utm_medium"],
                    utmCampaign: dict["utm_campaign"],
                    fbclid: dict["fbclid"],
                    ttclid: dict["ttclid"]
                )
                await tracker.capture(input)
            }

            return parsed
        } catch {
            hasFetchedDeferredLink = true
            cachedDeferredLink = nil
            return nil
        }
        #else
        hasFetchedDeferredLink = true
        cachedDeferredLink = nil
        return nil
        #endif
    }

    /// Parse a deferred app link URL string into an attribution dictionary.
    /// Extracts: fbclid, ttclid, tracking_id, utm_source, utm_medium, utm_campaign
    /// from both the top-level query string and the nested `target_url` param (fallback).
    /// Returns nil if no attribution signals are found.
    /// This is a pure function — safe to unit-test without FBSDK.
    public static func parseDeferredAppLink(_ urlString: String?) -> [String: String]? {
        guard let urlString = urlString, !urlString.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }

        let raw = String(urlString.prefix(2048))
        // Strip fragment before parsing
        let cleanRaw = raw.components(separatedBy: "#").first ?? raw
        guard let qIndex = cleanRaw.firstIndex(of: "?") else { return nil }

        let queryString = String(cleanRaw[cleanRaw.index(after: qIndex)...])
        var top = parseQueryString(queryString)

        // Decode nested target_url
        var targetUrl: String? = nil
        if let rawTarget = top["target_url"] {
            targetUrl = rawTarget.removingPercentEncoding ?? rawTarget
        }

        // Merge inner params (top-level wins, inner fills gaps)
        if let target = targetUrl {
            let cleanTarget = target.components(separatedBy: "#").first ?? target
            if let innerQ = cleanTarget.firstIndex(of: "?") {
                let innerQuery = String(cleanTarget[cleanTarget.index(after: innerQ)...])
                let inner = parseQueryString(innerQuery)
                for (key, value) in inner {
                    if top[key] == nil {
                        top[key] = value
                    }
                }
            }
        }

        // Normalize empty strings to nil via filter
        func nz(_ v: String?) -> String? {
            guard let v = v, !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return v
        }

        let fbclid     = nz(top["fbclid"])
        let ttclid     = nz(top["ttclid"])
        let trackingId = nz(top["tracking_id"])
        let utmSource  = nz(top["utm_source"])
        let utmMedium  = nz(top["utm_medium"])
        let utmCampaign = nz(top["utm_campaign"])

        // Return nil if no attribution signals
        guard fbclid != nil || ttclid != nil || trackingId != nil
                || utmSource != nil || utmMedium != nil || utmCampaign != nil else {
            return nil
        }

        var result: [String: String] = [:]
        if let v = fbclid      { result["fbclid"]       = v }
        if let v = ttclid      { result["ttclid"]       = v }
        if let v = trackingId  { result["tracking_id"]  = v }
        if let v = utmSource   { result["utm_source"]   = v }
        if let v = utmMedium   { result["utm_medium"]   = v }
        if let v = utmCampaign { result["utm_campaign"] = v }
        if let v = targetUrl   { result["target_url"]   = v }
        result["raw"] = String(urlString.prefix(2048))

        return result
    }

    // MARK: - Private Helpers

    private static func parseQueryString(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.components(separatedBy: "&") {
            guard let eqRange = pair.range(of: "=") else { continue }
            let rawKey   = String(pair[pair.startIndex..<eqRange.lowerBound])
                .replacingOccurrences(of: "+", with: " ")
            let rawValue = String(pair[eqRange.upperBound...])
                .replacingOccurrences(of: "+", with: " ")
            guard let key   = rawKey.removingPercentEncoding, !key.isEmpty,
                  let value = rawValue.removingPercentEncoding else { continue }
            result[key] = value
        }
        return result
    }

    /// Flush Facebook events. No-op if FBSDK not available.
    public func flush() {
        #if canImport(FBSDKCoreKit)
        FBSDKCoreKit.AppEvents.shared.flush()
        #endif
    }
}
