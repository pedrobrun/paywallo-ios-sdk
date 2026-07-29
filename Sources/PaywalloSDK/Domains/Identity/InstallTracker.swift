import CommonCrypto
import Foundation

public final class InstallTracker {
    private let storage: SecureStorage
    private var debug = false
    private var trackingInProgress = false

    public init(storage: SecureStorage = .shared) {
        self.storage = storage
    }

    /// Track install if not already tracked. Fire-and-forget.
    public func trackIfNeeded(
        distinctIdProvider: () -> String,
        sessionId: String?,
        deviceData: DeviceData?,
        advertisingIds: AdvertisingIdResult?,
        attribution: AttributionCapture?,
        fbAnonymousId: String?,
        trackEvent: @escaping (String, [String: AnyCodable], EventPriority) async -> Void,
        appKey: String? = nil
    ) async {
        // Check two-stage idempotency
        let installTracked = await storage.get(PaywalloConstants.installTrackedKey)
        if installTracked != nil {
            return  // Already tracked successfully
        }

        guard !trackingInProgress else { return }
        trackingInProgress = true
        defer { trackingInProgress = false }

        let installSent = await storage.get(PaywalloConstants.appInstalledSentKey)
        if installSent != nil {
            // Pre-flight was set but post-success wasn't → clear and retry
            await storage.remove(PaywalloConstants.appInstalledSentKey)
        }

        // Wait for distinct ID
        var distinctId = distinctIdProvider()
        var retries = 0
        while distinctId.isEmpty && retries < 10 {
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            distinctId = distinctIdProvider()
            retries += 1
        }

        guard !distinctId.isEmpty else {
            // Don't set INSTALL_SENT — next boot will retry
            return
        }

        // Set pre-flight guard
        await storage.set(PaywalloConstants.appInstalledSentKey, value: "1")

        // Get or create stable install event ID
        let installEventId = await getOrCreateInstallEventId(
            idfv: advertisingIds?.idfv,
            appKey: appKey
        )

        // Build payload — shape matches RN SDK InstallTracker._doTrack()
        var payload: [String: AnyCodable] = [
            "installedAt": AnyCodable(Date().timeIntervalSince1970 * 1000),
            "platform": AnyCodable("ios"),
            "installEventId": AnyCodable(installEventId),
        ]

        if let sessionId = sessionId {
            payload["sessionId"] = AnyCodable(sessionId)
        }

        // Device data
        if let device = deviceData {
            payload["appVersion"] = AnyCodable(device.appVersion)
            payload["osVersion"] = AnyCodable(device.systemVersion)
            payload["deviceModel"] = AnyCodable(device.modelId)
            payload["buildNumber"] = AnyCodable(device.buildNumber)
            payload["screenWidth"] = AnyCodable(device.screenWidth)
            payload["screenHeight"] = AnyCodable(device.screenHeight)
            payload["screenDensity"] = AnyCodable(device.screenDensity)
            payload["locale"] = AnyCodable(device.locale)
            payload["timezone"] = AnyCodable(device.timezone)
            payload["carrier"] = AnyCodable(device.carrier)
            payload["totalDisk"] = AnyCodable(device.totalDisk)
            payload["totalRam"] = AnyCodable(device.totalRam)
            payload["brand"] = AnyCodable(device.brand)
        }

        // Ad IDs
        if let ads = advertisingIds {
            if let idfa = ads.idfa { payload["idfa"] = AnyCodable(idfa) }
            if let idfv = ads.idfv { payload["idfv"] = AnyCodable(idfv) }
            payload["attStatus"] = AnyCodable(ads.attStatus.rawValue)
        }

        // Attribution
        if let attr = attribution {
            if let fbclid = attr.fbclid { payload["fbclid"] = AnyCodable(fbclid) }
            if let gclid = attr.gclid { payload["gclid"] = AnyCodable(gclid) }
            if let ttclid = attr.ttclid { payload["ttclid"] = AnyCodable(ttclid) }
        }

        // FB Anonymous ID
        if let fbAnonId = fbAnonymousId {
            payload["fbAnonId"] = AnyCodable(fbAnonId)
        }

        // Track the event with critical priority.
        // Uses "$app_installed" (custom family) to match the RN SDK's InstallTracker —
        // this is the event the server's attribution pipeline listens for (IDFA/IDFV
        // deferred match, CAPI). The canonical lifecycle install event (type:"install")
        // is emitted separately by AutoEvents using the firstSeen guard.
        await trackEvent("$app_installed", payload, .critical)

        // Mark as tracked
        await storage.set(PaywalloConstants.installTrackedKey, value: "1")
    }

    /// Get or create stable install event ID
    private func getOrCreateInstallEventId(idfv: String? = nil, appKey: String? = nil) async -> String {
        if let existing = await storage.get(PaywalloConstants.installEventIdKey) {
            return existing
        }
        let id: String
        if let idfv = idfv, !idfv.isEmpty, let appKey = appKey, !appKey.isEmpty {
            id = deterministicUUID(from: "\(idfv):\(appKey)")
        } else {
            id = UUID().uuidString
        }
        await storage.set(PaywalloConstants.installEventIdKey, value: id)
        return id
    }

    /// Derives a stable UUID-like string from a seed string using SHA256.
    private func deterministicUUID(from seed: String) -> String {
        let data = Data(seed.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        let hex = hash.prefix(16).map { String(format: "%02x", $0) }.joined()
        let p1 = String(hex.prefix(8))
        let p2 = String(hex.dropFirst(8).prefix(4))
        let p3 = String(hex.dropFirst(12).prefix(4))
        let p4 = String(hex.dropFirst(16).prefix(4))
        let p5 = String(hex.dropFirst(20).prefix(12))
        return "\(p1)-\(p2)-\(p3)-\(p4)-\(p5)".uppercased()
    }

    /// Deferred match — POST /sdk/attribution/deferred-match/{appKey}
    /// Best-effort, doesn't block init.
    ///
    /// NOTE: The server route param is named `:appId` (UUID) in some controller versions,
    /// but `PaywalloConfig` only exposes `appKey` (string). If the server looks up by appId
    /// (UUID), this call will fail with 404. Update this path to use the appId UUID once
    /// it is available in the SDK config.
    public func performDeferredMatch(
        appKey: String,
        httpClient: HttpClient,
        deviceData: DeviceData?,
        advertisingIds: AdvertisingIdResult?,
        fbAnonymousId: String? = nil,
        attributionTracker: AttributionTracker? = nil
    ) async {
        // Idempotency check
        let done = await storage.get(PaywalloConstants.deferredMatchDoneKey)
        if done != nil { return }

        let installTimestamp = ISO8601DateFormatter().string(from: Date())
        var body: [String: AnyCodable] = [
            "platform": AnyCodable("ios"),
            "installTimestamp": AnyCodable(installTimestamp),
        ]

        if let device = deviceData {
            body["deviceModel"] = AnyCodable(device.modelId)
            body["osVersion"] = AnyCodable(device.systemVersion)
            body["language"] = AnyCodable(device.locale)
            body["timezone"] = AnyCodable(device.timezone)
            body["screenWidth"] = AnyCodable(Int(device.screenWidth))
            body["screenHeight"] = AnyCodable(Int(device.screenHeight))
            // country is used by the server for probabilistic matching
            if !device.locale.isEmpty {
                // locale is e.g. "en_BR" — extract country code after underscore
                let parts = device.locale.components(separatedBy: "_")
                if parts.count >= 2 { body["country"] = AnyCodable(parts.last!) }
            }
        }

        if let ads = advertisingIds {
            if let idfa = ads.idfa { body["idfa"] = AnyCodable(idfa) }
            if let idfv = ads.idfv { body["idfv"] = AnyCodable(idfv) }
        }

        if let fbAnonId = fbAnonymousId { body["fbAnonId"] = AnyCodable(fbAnonId) }

        do {
            let jsonData = try JSONEncoder().encode(body)
            let options = RequestOptions(
                method: "POST",
                body: jsonData,
                skipRetry: true,
                timeout: 5
            )

            struct DeferredMatchResponse: Decodable {
                let fbclid: String?
                let gclid: String?
                let ttclid: String?
                let utmSource: String?
                let utmMedium: String?
                let utmCampaign: String?
                let utmContent: String?
                let utmTerm: String?
                let referrer: String?
            }

            let response: HttpResponse<DeferredMatchResponse> = try await httpClient.request(
                path: "/sdk/attribution/deferred-match/\(appKey)",
                options: options
            )

            // Apply server match result to attributionTracker (first-write-wins)
            if let tracker = attributionTracker {
                let r = response.data
                let input = AttributionInput(
                    utmSource: r.utmSource,
                    utmMedium: r.utmMedium,
                    utmCampaign: r.utmCampaign,
                    utmContent: r.utmContent,
                    utmTerm: r.utmTerm,
                    fbclid: r.fbclid,
                    gclid: r.gclid,
                    ttclid: r.ttclid,
                    referrer: r.referrer
                )
                await tracker.capture(input)
            }
        } catch {
            // Best-effort — don't block
        }

        // Mark as done regardless of success
        await storage.set(PaywalloConstants.deferredMatchDoneKey, value: "1")
    }
}
