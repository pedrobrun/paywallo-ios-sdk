import Foundation
#if canImport(UIKit)
import UIKit
#endif

public final class DeepLinkAttributionCapture {
    private let attributionTracker: AttributionTracker
    private var started = false

    public init(attributionTracker: AttributionTracker) {
        self.attributionTracker = attributionTracker
    }

    /// Start listening for deep links. Call once on SDK init.
    public func start() {
        guard !started else { return }
        started = true

        // Note: On iOS, deep link handling is typically done via
        // UIApplicationDelegate or SceneDelegate methods.
        // The SDK consumer should call handleUrl(_:) from those callbacks.
    }

    /// Handle an incoming URL (deep link). Call from AppDelegate/SceneDelegate.
    public func handleUrl(_ url: URL) async {
        guard let attribution = parseAttributionFromUrl(url) else { return }
        await attributionTracker.capture(attribution)
    }

    /// Parse attribution data from URL query parameters.
    public func parseAttributionFromUrl(_ url: URL) -> AttributionInput? {
        guard let components = url.query, !components.isEmpty else { return nil }

        let params = parseQueryParams(components)
        guard !params.isEmpty else { return nil }

        let input = AttributionInput(
            utmSource: params["utm_source"],
            utmMedium: params["utm_medium"],
            utmCampaign: params["utm_campaign"],
            utmContent: params["utm_content"],
            utmTerm: params["utm_term"],
            fbclid: params["fbclid"],
            gclid: params["gclid"],
            ttclid: params["ttclid"],
            tiktokCampaignId: params["campaign_id"],
            tiktokAdgroupId: params["adgroup_id"],
            tiktokAdId: params["ad_id"]
            // referrer is intentionally omitted — RN SDK does not set it from
            // the deep link URL either. referrer is populated only by the
            // Play Store Install Referrer API (Android, via InstallReferrerManager).
        )

        // Return nil if no attribution fields present
        guard input.hasAnyField else { return nil }
        return input
    }

    /// Manual query parameter parser that handles + → space correctly
    private func parseQueryParams(_ query: String) -> [String: String] {
        var params: [String: String] = [:]

        let pairs = query.split(separator: "&", omittingEmptySubsequences: true)
        for pair in pairs {
            let keyValue = pair.split(separator: "=", maxSplits: 1)
            guard keyValue.count == 2 else { continue }

            let key = String(keyValue[0])
            // Handle + → space, then percent-decode
            let rawValue = String(keyValue[1]).replacingOccurrences(of: "+", with: " ")
            let value = rawValue.removingPercentEncoding ?? rawValue

            params[key] = value
        }

        return params
    }
}
