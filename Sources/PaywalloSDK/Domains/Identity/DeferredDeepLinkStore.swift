import Foundation

/// Deferred deep link resolved by the server during the deferred match (Links
/// Personalizados with an external destination) — lets the app open the OFFER the user
/// clicked instead of the home screen on first open. Purely additive: an older server
/// never sends `deepLink`, `get()` simply stays nil, and nothing else in the flow
/// depends on it.
public struct DeferredDeepLink: Codable, Sendable, Equatable {
    public struct Campaign: Codable, Sendable, Equatable {
        public let name: String?
        public let adsetName: String?
        public let adName: String?

        public init(name: String? = nil, adsetName: String? = nil, adName: String? = nil) {
            self.name = name
            self.adsetName = adsetName
            self.adName = adName
        }
    }

    public let deeplinkId: String
    public let installId: String
    public let redirectionUrl: String
    public let expiresAt: String
    public let queryParams: [String: String]?
    public let campaign: Campaign?

    public init(
        deeplinkId: String,
        installId: String,
        redirectionUrl: String,
        expiresAt: String,
        queryParams: [String: String]? = nil,
        campaign: Campaign? = nil
    ) {
        self.deeplinkId = deeplinkId
        self.installId = installId
        self.redirectionUrl = redirectionUrl
        self.expiresAt = expiresAt
        self.queryParams = queryParams
        self.campaign = campaign
    }
}

public typealias DeferredDeepLinkListener = (DeferredDeepLink) -> Void

/// Kept apart from `AttributionTracker` on purpose: this is screen-personalisation data.
/// It must never enter the event envelope nor the CAPI dispatch pipeline.
public final class DeferredDeepLinkStore {
    public static let shared = DeferredDeepLinkStore()

    private var cache: DeferredDeepLink?
    private var listeners: [UUID: DeferredDeepLinkListener] = [:]
    private let storage: SecureStorage

    public init(storage: SecureStorage = .shared) {
        self.storage = storage
    }

    public func loadFromStorage() async {
        guard let raw = await storage.get(PaywalloConstants.deferredDeepLinkKey),
              let data = raw.data(using: .utf8) else { return }
        // Malformed — treat as empty rather than propagating a decode failure to init.
        cache = try? JSONDecoder().decode(DeferredDeepLink.self, from: data)
    }

    public func capture(_ deepLink: DeferredDeepLink) async {
        if let encoded = try? JSONEncoder().encode(deepLink),
           let json = String(data: encoded, encoding: .utf8) {
            await storage.set(PaywalloConstants.deferredDeepLinkKey, value: json)
        }
        cache = deepLink
        notifyListeners(deepLink)
    }

    /// Notifies whoever already built the UI before the deferred match answered — the
    /// common case, since the response lands in background after the cold start.
    /// Returns an unsubscribe closure.
    @discardableResult
    public func onCapture(_ listener: @escaping DeferredDeepLinkListener) -> () -> Void {
        let token = UUID()
        listeners[token] = listener
        return { [weak self] in self?.listeners.removeValue(forKey: token) }
    }

    public func get() -> DeferredDeepLink? {
        cache
    }

    public func clear() async {
        cache = nil
        await storage.remove(PaywalloConstants.deferredDeepLinkKey)
    }

    private func notifyListeners(_ deepLink: DeferredDeepLink) {
        for listener in listeners.values {
            listener(deepLink)
        }
    }
}

/// Validates the raw server object before it is persisted. Only non-empty strings
/// survive, and `redirectionUrl` must be https (the same rule as the server's
/// `DestinationUrlValidator`) — anything else is dropped instead of handed to the app.
public func parseDeferredDeepLink(_ raw: Any?) -> DeferredDeepLink? {
    guard let source = raw as? [String: Any] else { return nil }

    guard let deeplinkId = nonEmptyString(source["deeplinkId"]),
          let installId = nonEmptyString(source["installId"]),
          let redirectionUrl = nonEmptyString(source["redirectionUrl"]),
          let expiresAt = nonEmptyString(source["expiresAt"]),
          redirectionUrl.hasPrefix("https://")
    else { return nil }

    return DeferredDeepLink(
        deeplinkId: deeplinkId,
        installId: installId,
        redirectionUrl: redirectionUrl,
        expiresAt: expiresAt,
        queryParams: parseDeepLinkQueryParams(source["queryParams"]),
        campaign: parseDeepLinkCampaign(source["campaign"])
    )
}

private func nonEmptyString(_ value: Any?) -> String? {
    guard let string = value as? String,
          !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return string
}

private func parseDeepLinkQueryParams(_ raw: Any?) -> [String: String]? {
    guard let source = raw as? [String: Any] else { return nil }
    var out: [String: String] = [:]
    for (key, value) in source {
        if let string = value as? String, !string.isEmpty { out[key] = string }
    }
    return out.isEmpty ? nil : out
}

private func parseDeepLinkCampaign(_ raw: Any?) -> DeferredDeepLink.Campaign? {
    guard let source = raw as? [String: Any] else { return nil }
    let name = (source["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let adsetName = (source["adsetName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let adName = (source["adName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    if name == nil && adsetName == nil && adName == nil { return nil }
    return DeferredDeepLink.Campaign(name: name, adsetName: adsetName, adName: adName)
}
