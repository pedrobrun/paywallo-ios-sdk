import Foundation

public struct AttributionCapture: Codable, Sendable {
    public var utmSource: String?
    public var utmMedium: String?
    public var utmCampaign: String?
    public var utmContent: String?
    public var utmTerm: String?
    public var fbclid: String?
    public var gclid: String?
    public var ttclid: String?
    public var tiktokCampaignId: String?
    public var tiktokAdgroupId: String?
    public var tiktokAdId: String?
    public var installReferrerRaw: String?
    public var installReferrerSource: String?
    public var referrer: String?
    public let capturedAt: String

    public init(
        utmSource: String? = nil, utmMedium: String? = nil, utmCampaign: String? = nil,
        utmContent: String? = nil, utmTerm: String? = nil,
        fbclid: String? = nil, gclid: String? = nil, ttclid: String? = nil,
        tiktokCampaignId: String? = nil, tiktokAdgroupId: String? = nil, tiktokAdId: String? = nil,
        installReferrerRaw: String? = nil, installReferrerSource: String? = nil,
        referrer: String? = nil, capturedAt: String
    ) {
        self.utmSource = utmSource; self.utmMedium = utmMedium; self.utmCampaign = utmCampaign
        self.utmContent = utmContent; self.utmTerm = utmTerm
        self.fbclid = fbclid; self.gclid = gclid; self.ttclid = ttclid
        self.tiktokCampaignId = tiktokCampaignId; self.tiktokAdgroupId = tiktokAdgroupId; self.tiktokAdId = tiktokAdId
        self.installReferrerRaw = installReferrerRaw; self.installReferrerSource = installReferrerSource
        self.referrer = referrer; self.capturedAt = capturedAt
    }
}

public struct AttributionInput {
    public var utmSource: String?
    public var utmMedium: String?
    public var utmCampaign: String?
    public var utmContent: String?
    public var utmTerm: String?
    public var fbclid: String?
    public var gclid: String?
    public var ttclid: String?
    public var tiktokCampaignId: String?
    public var tiktokAdgroupId: String?
    public var tiktokAdId: String?
    public var installReferrerRaw: String?
    public var installReferrerSource: String?
    public var referrer: String?

    public init(
        utmSource: String? = nil, utmMedium: String? = nil, utmCampaign: String? = nil,
        utmContent: String? = nil, utmTerm: String? = nil,
        fbclid: String? = nil, gclid: String? = nil, ttclid: String? = nil,
        tiktokCampaignId: String? = nil, tiktokAdgroupId: String? = nil, tiktokAdId: String? = nil,
        installReferrerRaw: String? = nil, installReferrerSource: String? = nil,
        referrer: String? = nil
    ) {
        self.utmSource = utmSource; self.utmMedium = utmMedium; self.utmCampaign = utmCampaign
        self.utmContent = utmContent; self.utmTerm = utmTerm
        self.fbclid = fbclid; self.gclid = gclid; self.ttclid = ttclid
        self.tiktokCampaignId = tiktokCampaignId; self.tiktokAdgroupId = tiktokAdgroupId; self.tiktokAdId = tiktokAdId
        self.installReferrerRaw = installReferrerRaw; self.installReferrerSource = installReferrerSource
        self.referrer = referrer
    }

    var hasAnyField: Bool {
        [utmSource, utmMedium, utmCampaign, utmContent, utmTerm,
         fbclid, gclid, ttclid, tiktokCampaignId, tiktokAdgroupId, tiktokAdId,
         installReferrerRaw, installReferrerSource, referrer]
            .contains(where: { $0 != nil && !($0?.isEmpty ?? true) })
    }
}

/// First-write-wins attribution tracker with secure persistence.
///
/// Usage:
/// 1. Call `loadFromStorage()` once on SDK init before any `get()` calls.
/// 2. Call `capture(_:)` whenever attribution data is available — no-op after first capture.
/// 3. Call `get()` synchronously to read the cached attribution.
public final class AttributionTracker {
    // Must match the key used in the RN SDK (IdentityStorage constants pass the
    // full "@paywallo:"-prefixed key to SecureStorage, which then prepends
    // "com.paywallo.sdk." for Keychain and "@paywallo:" for the UserDefaults
    // fallback). Using the same full key here keeps both SDKs' Keychain slots
    // aligned: "com.paywallo.sdk.@paywallo:attribution_v2".
    private static let storageKey = PaywalloConstants.attributionV2Key

    private var cache: AttributionCapture?
    private var captureInProgress = false
    private let storage: SecureStorage
    private let nativeStorage: NativeStorage

    public init(storage: SecureStorage = .shared, nativeStorage: NativeStorage = .shared) {
        self.storage = storage
        self.nativeStorage = nativeStorage
    }

    // MARK: - Public API

    /// Load persisted attribution into memory. Must be called once on SDK init before `get()`.
    public func loadFromStorage() async {
        // 1. Try current key via SecureStorage (Keychain → UserDefaults @paywallo:)
        if let raw = await storage.get(Self.storageKey) {
            cache = decode(raw)
            return
        }

        // 2. Legacy migration: @panel:attribution_v2 stored in UserDefaults
        // NativeStorage.get reads UserDefaults with the exact key passed (no prefix added).
        if let raw = nativeStorage.get(PaywalloConstants.legacyAttributionV2Key) {
            cache = decode(raw)
            // Promote to current secure storage and remove legacy plaintext
            await storage.set(Self.storageKey, value: raw)
            nativeStorage.remove(PaywalloConstants.legacyAttributionV2Key)
        }
    }

    /// First-write-wins capture. No-op if attribution already captured or input has no fields.
    public func capture(_ data: AttributionInput) async {
        guard cache == nil else { return }
        guard data.hasAnyField else { return }
        guard !captureInProgress else { return }

        captureInProgress = true
        defer { captureInProgress = false }

        var input = data
        // Truncate rawReferrer to 2048 chars
        if let raw = input.installReferrerRaw, raw.count > 2048 {
            input.installReferrerRaw = String(raw.prefix(2048))
        }

        let capture = AttributionCapture(
            utmSource: input.utmSource, utmMedium: input.utmMedium, utmCampaign: input.utmCampaign,
            utmContent: input.utmContent, utmTerm: input.utmTerm,
            fbclid: input.fbclid, gclid: input.gclid, ttclid: input.ttclid,
            tiktokCampaignId: input.tiktokCampaignId, tiktokAdgroupId: input.tiktokAdgroupId, tiktokAdId: input.tiktokAdId,
            installReferrerRaw: input.installReferrerRaw, installReferrerSource: input.installReferrerSource,
            referrer: input.referrer, capturedAt: ISO8601DateFormatter().string(from: Date())
        )

        if let json = encode(capture) {
            await storage.set(Self.storageKey, value: json)
        }

        cache = capture
    }

    /// Synchronous read from in-memory cache. Call `loadFromStorage()` first.
    public func get() -> AttributionCapture? {
        cache
    }

    /// Clear attribution from both storage and memory.
    public func clear() async {
        cache = nil
        await storage.remove(Self.storageKey)
    }

    // MARK: - Private Helpers

    private func decode(_ raw: String) -> AttributionCapture? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AttributionCapture.self, from: data)
    }

    private func encode(_ capture: AttributionCapture) -> String? {
        guard let data = try? JSONEncoder().encode(capture) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
