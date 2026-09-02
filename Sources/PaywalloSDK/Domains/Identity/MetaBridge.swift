import Foundation

/// Meta's deferred app link, parsed. On iOS this IS the install referrer: there is no
/// Play Install Referrer, so the link Meta hands back on first launch is the only
/// store-side evidence of which click produced the install.
public struct MetaDeferredLinkParams: Sendable, Equatable {
    public let fbclid: String?
    public let utmSource: String?
    public let utmMedium: String?
    public let utmCampaign: String?
    public let ttclid: String?
    /// `tracking_id` minted by the /d/ redirector — travels on the install payload as
    /// `referrerTrackingId`; there is no `AttributionCapture` slot for it.
    public let trackingId: String?
    public let targetUrl: String?
    /// The original link, capped at `deferredAppLinkMaxLength`.
    public let raw: String

    /// What the click actually pointed at. The wrapper URL is Meta's plumbing; the
    /// target is the advertiser's destination, and that is what the server matches on.
    public var rawReferrer: String { targetUrl ?? raw }

    public init(
        fbclid: String?, utmSource: String?, utmMedium: String?, utmCampaign: String?,
        ttclid: String?, trackingId: String?, targetUrl: String?, raw: String
    ) {
        self.fbclid = fbclid
        self.utmSource = utmSource
        self.utmMedium = utmMedium
        self.utmCampaign = utmCampaign
        self.ttclid = ttclid
        self.trackingId = trackingId
        self.targetUrl = targetUrl
        self.raw = raw
    }
}

public final class MetaBridge {
    public static let shared = MetaBridge()

    private var cachedAnonymousId: String?
    private var hasCachedAnonymousId = false

    private var cachedDeferredLink: MetaDeferredLinkParams?
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
    public func fetchDeferredAppLink(attributionTracker: AttributionTracker? = nil) async -> MetaDeferredLinkParams? {
        if hasFetchedDeferredLink {
            return cachedDeferredLink
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
            if let link = parsed, let tracker = attributionTracker {
                await tracker.capture(link.attributionInput())
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

    /// Synchronous read of the last parsed deferred app link. Returns nil until
    /// `fetchDeferredAppLink()` has resolved once.
    public func getCachedDeferredAppLink() -> MetaDeferredLinkParams? {
        cachedDeferredLink
    }

    /// Parse a deferred app link URL into its attribution signals — from the top-level
    /// query string and, as a fallback, from the nested `target_url`.
    /// Returns nil when no signal is found. Pure — safe to unit-test without FBSDK.
    public static func parseDeferredAppLink(_ urlString: String?) -> MetaDeferredLinkParams? {
        guard let urlString = urlString, !urlString.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }

        let raw = String(urlString.prefix(PaywalloConstants.deferredAppLinkMaxLength))
        // Strip the fragment before parsing, so `?fbclid=abc#section` yields "abc".
        let cleanRaw = raw.components(separatedBy: "#").first ?? raw
        guard let qIndex = cleanRaw.firstIndex(of: "?") else { return nil }

        let top = parseQueryString(String(cleanRaw[cleanRaw.index(after: qIndex)...]))

        // Normalise empty/whitespace to nil BEFORE the fallbacks: an empty top-level
        // `fbclid=` must not block the real value nested in `target_url`.
        var fbclid = nz(top["fbclid"])
        var utmSource = nz(top["utm_source"])
        var utmMedium = nz(top["utm_medium"])
        var utmCampaign = nz(top["utm_campaign"])
        var ttclid = nz(top["ttclid"])
        var trackingId = nz(top["tracking_id"])

        var targetUrl: String?
        if let rawTarget = top["target_url"], !rawTarget.isEmpty {
            targetUrl = rawTarget.removingPercentEncoding ?? rawTarget
        }

        // Gated on `fbclid == nil`: when the wrapper already carries the click ID, the
        // wrapper IS the click and its params are authoritative. Merging the inner query
        // unconditionally let a stale `target_url` — Meta reuses the destination across
        // creatives — fill in utm_* that never belonged to this click.
        if fbclid == nil, let target = targetUrl {
            let cleanTarget = target.components(separatedBy: "#").first ?? target
            if let innerQ = cleanTarget.firstIndex(of: "?") {
                let inner = parseQueryString(String(cleanTarget[cleanTarget.index(after: innerQ)...]))
                fbclid = fbclid ?? nz(inner["fbclid"])
                utmSource = utmSource ?? nz(inner["utm_source"])
                utmMedium = utmMedium ?? nz(inner["utm_medium"])
                utmCampaign = utmCampaign ?? nz(inner["utm_campaign"])
                ttclid = ttclid ?? nz(inner["ttclid"])
                trackingId = trackingId ?? nz(inner["tracking_id"])
            }
        }

        guard fbclid != nil || ttclid != nil || trackingId != nil
                || utmSource != nil || utmMedium != nil || utmCampaign != nil else {
            return nil
        }

        return MetaDeferredLinkParams(
            fbclid: fbclid,
            utmSource: utmSource,
            utmMedium: utmMedium,
            utmCampaign: utmCampaign,
            ttclid: ttclid,
            trackingId: trackingId,
            targetUrl: targetUrl,
            raw: raw
        )
    }

    /// Normalize empty/whitespace string → nil so the fallback chains work.
    private static func nz(_ value: String?) -> String? {
        guard let value = value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
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

extension MetaDeferredLinkParams {
    /// Meta's deferred link is the iOS install referrer, so it fills the same
    /// `installReferrer*` slots the Play Install Referrer fills on Android — that pair is
    /// what lets the server tell a Meta-sourced install from an organic one when the
    /// click carried no clid at all.
    func attributionInput() -> AttributionInput {
        AttributionInput(
            utmSource: utmSource,
            utmMedium: utmMedium,
            utmCampaign: utmCampaign,
            fbclid: fbclid,
            ttclid: ttclid,
            installReferrerRaw: raw,
            installReferrerSource: "meta_deferred",
            referrer: rawReferrer
        )
    }
}
