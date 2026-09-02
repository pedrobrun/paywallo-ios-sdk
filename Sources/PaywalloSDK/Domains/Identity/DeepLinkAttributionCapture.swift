import Foundation
#if canImport(UIKit)
import UIKit
#endif

public final class DeepLinkAttributionCapture {
    private let attributionTracker: AttributionTracker
    private let debug: Bool
    private var started = false
    private var launchObserver: NSObjectProtocol?

    public init(attributionTracker: AttributionTracker, debug: Bool = false) {
        self.attributionTracker = attributionTracker
        self.debug = debug
    }

    deinit {
        if let observer = launchObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Start capturing deep-link attribution. Call once on SDK init.
    ///
    /// Cold start: observes `didFinishLaunching`, whose userInfo carries the URL the app
    /// was opened with. That is the only cold-start URL a library can see without the
    /// host wiring anything, and it is the one that matters — the click that produced
    /// the install arrives exactly there.
    ///
    /// Warm start: the host forwards `handleUrl(_:)` from its
    /// `AppDelegate`/`SceneDelegate` URL callbacks.
    ///
    /// Every failure is swallowed: attribution is best-effort and must never break init.
    public func start() {
        guard !started else { return }
        started = true

        #if canImport(UIKit)
        launchObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let url = notification.userInfo?[UIApplication.LaunchOptionsKey.url] as? URL
            else { return }
            Task { await self.handleUrl(url) }
        }
        #endif
    }

    public func stop() {
        if let observer = launchObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        launchObserver = nil
        started = false
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
            gclid: sanitizeGclid(params["gclid"]),
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

    /// Google Ads ValueTrack macros are sometimes left unsubstituted by the ad network,
    /// so the literal `{gclid}` arrives as the value. Storing it poisons the capture:
    /// it is a strong signal by shape, so first-write-wins would then reject the real
    /// click ID that shows up later.
    private func sanitizeGclid(_ value: String?) -> String? {
        guard let value = value else { return nil }
        if value.hasPrefix("{") && value.hasSuffix("}") { return nil }
        return value
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
