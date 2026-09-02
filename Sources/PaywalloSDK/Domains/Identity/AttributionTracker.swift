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
    /// Canonical ad network resolved by the SERVER (derived from the link's `ad_source`).
    /// Nothing on-device ever invents this — it covers the Meta-link-without-fbclid case
    /// the device has no way to label. Takes precedence over any on-device heuristic.
    public var adNetwork: String?
    /// Raw, granular match verdict from the server. Open domain — never validate against a list.
    /// Observed: deterministic_referrer, probabilistic_high/low/ambiguous, geo_exclusive.
    public var matchType: String?
    public let capturedAt: String

    public init(
        utmSource: String? = nil, utmMedium: String? = nil, utmCampaign: String? = nil,
        utmContent: String? = nil, utmTerm: String? = nil,
        fbclid: String? = nil, gclid: String? = nil, ttclid: String? = nil,
        tiktokCampaignId: String? = nil, tiktokAdgroupId: String? = nil, tiktokAdId: String? = nil,
        installReferrerRaw: String? = nil, installReferrerSource: String? = nil,
        referrer: String? = nil, adNetwork: String? = nil, matchType: String? = nil,
        capturedAt: String
    ) {
        self.utmSource = utmSource; self.utmMedium = utmMedium; self.utmCampaign = utmCampaign
        self.utmContent = utmContent; self.utmTerm = utmTerm
        self.fbclid = fbclid; self.gclid = gclid; self.ttclid = ttclid
        self.tiktokCampaignId = tiktokCampaignId; self.tiktokAdgroupId = tiktokAdgroupId; self.tiktokAdId = tiktokAdId
        self.installReferrerRaw = installReferrerRaw; self.installReferrerSource = installReferrerSource
        self.referrer = referrer; self.adNetwork = adNetwork; self.matchType = matchType
        self.capturedAt = capturedAt
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
    public var adNetwork: String?
    public var matchType: String?

    public init(
        utmSource: String? = nil, utmMedium: String? = nil, utmCampaign: String? = nil,
        utmContent: String? = nil, utmTerm: String? = nil,
        fbclid: String? = nil, gclid: String? = nil, ttclid: String? = nil,
        tiktokCampaignId: String? = nil, tiktokAdgroupId: String? = nil, tiktokAdId: String? = nil,
        installReferrerRaw: String? = nil, installReferrerSource: String? = nil,
        referrer: String? = nil, adNetwork: String? = nil, matchType: String? = nil
    ) {
        self.utmSource = utmSource; self.utmMedium = utmMedium; self.utmCampaign = utmCampaign
        self.utmContent = utmContent; self.utmTerm = utmTerm
        self.fbclid = fbclid; self.gclid = gclid; self.ttclid = ttclid
        self.tiktokCampaignId = tiktokCampaignId; self.tiktokAdgroupId = tiktokAdgroupId; self.tiktokAdId = tiktokAdId
        self.installReferrerRaw = installReferrerRaw; self.installReferrerSource = installReferrerSource
        self.referrer = referrer; self.adNetwork = adNetwork; self.matchType = matchType
    }

    var hasAnyField: Bool {
        [utmSource, utmMedium, utmCampaign, utmContent, utmTerm,
         fbclid, gclid, ttclid, tiktokCampaignId, tiktokAdgroupId, tiktokAdId,
         installReferrerRaw, installReferrerSource, referrer, adNetwork, matchType]
            .contains(where: { $0 != nil && !($0?.isEmpty ?? true) })
    }
}

/// Notified when `capture()` performs its first real write, or when a server match is
/// promoted over a weak one.
public typealias AttributionCaptureListener = (AttributionCapture) -> Void

/// A STRONG signal identifies the advertiser unambiguously: a click ID from the click
/// itself, or the network resolved by the server. `utm_*` alone does not count — the
/// store stamps `utm_source=google-play&utm_medium=organic` on organic installs, and a
/// utm typed into a link is free text written by the advertiser.
///
/// Uses `!isEmpty` rather than a plain nil check: a malformed payload can arrive with
/// `fbclid: ""`, and treating that as present would label a weak capture strong.
private func isStrongAttribution(
    fbclid: String?, gclid: String?, ttclid: String?, tiktokCampaignId: String?, adNetwork: String?
) -> Bool {
    [fbclid, gclid, ttclid, tiktokCampaignId, adNetwork]
        .contains(where: { $0 != nil && !($0?.isEmpty ?? true) })
}

/// First-write-wins attribution tracker with secure persistence.
///
/// Usage:
/// 1. Call `loadFromStorage()` once on SDK init before any `get()` calls.
/// 2. Call `capture(_:)` whenever attribution data is available — no-op after first capture.
/// 3. Call `get()` synchronously to read the cached attribution.
public final class AttributionTracker: @unchecked Sendable {
    // Must match the key used in the RN SDK (IdentityStorage constants pass the
    // full "@paywallo:"-prefixed key to SecureStorage, which then prepends
    // "com.paywallo.sdk." for Keychain and "@paywallo:" for the UserDefaults
    // fallback). Using the same full key here keeps both SDKs' Keychain slots
    // aligned: "com.paywallo.sdk.@paywallo:attribution_v2".
    private static let storageKey = PaywalloConstants.attributionV2Key

    /// Shared instance. `promoteFromServerMatch` is fed by the deferred-match scheduler,
    /// which is built ad-hoc on every just-in-time refresh — both paths must land in the
    /// same cache the event context provider reads.
    public static let shared = AttributionTracker()

    /// Guards every mutable field below. `cache` is written from background work (the
    /// deferred-match scheduler calling `promoteFromServerMatch`) and read SYNCHRONOUSLY from
    /// the event hot path (`get()` inside the envelope context provider, on the flush task).
    /// `AttributionCapture` is a 17-field struct of `String?`, so an unsynchronised
    /// concurrent read is a torn read or an ARC over-release, not just a stale value —
    /// and `listeners` mutated while being iterated can corrupt the dictionary outright.
    private let lock = NSLock()
    private var cache: AttributionCapture?
    private var captureInProgress = false
    private var hydrated = false
    private var hydratingTask: Task<Void, Never>?
    private var listeners: [UUID: AttributionCaptureListener] = [:]
    private let storage: SecureStorage
    private let nativeStorage: NativeStorage

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public init(storage: SecureStorage = .shared, nativeStorage: NativeStorage = .shared) {
        self.storage = storage
        self.nativeStorage = nativeStorage
    }

    // MARK: - Public API

    /// Load persisted attribution into memory. Must be called once on SDK init before `get()`.
    ///
    /// Idempotent and shareable: concurrent or repeated calls (`promoteFromServerMatch`
    /// hydrates defensively) await the same in-flight read instead of hitting storage twice.
    public func loadFromStorage() async {
        let task: Task<Void, Never>? = withLock {
            if hydrated { return nil }
            if hydratingTask == nil {
                hydratingTask = Task { await self.hydrate() }
            }
            return hydratingTask
        }
        await task?.value
    }

    private func hydrate() async {
        defer { withLock { hydratingTask = nil } }

        // 1. Try current key via SecureStorage (Keychain → UserDefaults @paywallo:)
        if let raw = await storage.get(Self.storageKey) {
            withLock {
                // Only adopt if nobody wrote while the read was in flight (a concurrent
                // capture()) — otherwise the older disk value would stomp the newer one.
                if cache == nil { cache = decode(raw) }
                hydrated = true
            }
            return
        }

        // 2. Legacy migration: @panel:attribution_v2 stored in UserDefaults
        // NativeStorage.get reads UserDefaults with the exact key passed (no prefix added).
        if let raw = nativeStorage.get(PaywalloConstants.legacyAttributionV2Key) {
            withLock { if cache == nil { cache = decode(raw) } }
            // Promote to current secure storage and remove legacy plaintext
            await storage.set(Self.storageKey, value: raw)
            nativeStorage.remove(PaywalloConstants.legacyAttributionV2Key)
        }
        withLock { hydrated = true }
    }

    /// Subscribes to the first real attribution write (first-write-wins — no-op captures
    /// never fire) and to server-match promotions. Useful for late enrichment consumers,
    /// e.g. re-pushing Superwall attributes when a warm deep link or a deferred match
    /// lands after init. Returns an unsubscribe closure.
    @discardableResult
    public func onCapture(_ listener: @escaping AttributionCaptureListener) -> () -> Void {
        let token = UUID()
        withLock { listeners[token] = listener }
        return { [weak self] in
            guard let self = self else { return }
            self.withLock { _ = self.listeners.removeValue(forKey: token) }
        }
    }

    private func notifyListeners(_ capture: AttributionCapture) {
        // Snapshot under the lock, then call OUTSIDE it: a listener re-entering the tracker
        // (onCapture → pushAttributionToSuperwall → get()) would otherwise deadlock.
        let current = withLock { Array(listeners.values) }
        for listener in current {
            // A listener that throws must never break the capture path.
            listener(capture)
        }
    }

    /// First-write-wins capture. No-op if attribution already captured or input has no fields.
    public func capture(_ data: AttributionInput) async {
        guard data.hasAnyField else { return }
        // Test-and-set atomically: two concurrent captures must not both pass the guard.
        let claimed: Bool = withLock {
            if cache != nil || captureInProgress { return false }
            captureInProgress = true
            return true
        }
        guard claimed else { return }
        defer { withLock { captureInProgress = false } }

        var input = data
        // Server ceiling for `install_referrer_raw`. Meta's encrypted blob in utm_content
        // exceeds 2048; truncating below that cuts the JSON mid-way and kills the
        // deterministic match (raised from 2048 in 2.7.1).
        if let raw = input.installReferrerRaw, raw.count > PaywalloConstants.installReferrerMaxLength {
            input.installReferrerRaw = String(raw.prefix(PaywalloConstants.installReferrerMaxLength))
        }

        let capture = AttributionCapture(
            utmSource: input.utmSource, utmMedium: input.utmMedium, utmCampaign: input.utmCampaign,
            utmContent: input.utmContent, utmTerm: input.utmTerm,
            fbclid: input.fbclid, gclid: input.gclid, ttclid: input.ttclid,
            tiktokCampaignId: input.tiktokCampaignId, tiktokAdgroupId: input.tiktokAdgroupId, tiktokAdId: input.tiktokAdId,
            installReferrerRaw: input.installReferrerRaw, installReferrerSource: input.installReferrerSource,
            referrer: input.referrer, adNetwork: input.adNetwork, matchType: input.matchType,
            capturedAt: ISO8601DateFormatter().string(from: Date())
        )

        if let json = encode(capture) {
            await storage.set(Self.storageKey, value: json)
        }

        withLock { cache = capture }
        notifyListeners(capture)
    }

    /// Promotes the attribution the SERVER resolved (deferred match) over a weak
    /// on-device capture. The only exception to first-write-wins, and it exists for a
    /// concrete failure: the store stamps an organic referrer on every install that did
    /// not come from a tracked click, the install path writes it, and the deferred
    /// match — carrying the fbclid of the real click — was discarded in silence. The
    /// device stayed labelled organic forever, including for users who came from Meta Ads.
    ///
    /// Promotes only when the current capture is WEAK (no click ID, no resolved network)
    /// and the incoming one is STRONG. A deep link or install referrer with a real click
    /// ID is never overwritten.
    public func promoteFromServerMatch(_ data: AttributionInput) async {
        guard data.hasAnyField else { return }
        guard withLock({ !captureInProgress }) else { return }

        // `cache == nil` is ambiguous (empty storage vs. not hydrated yet). A forced
        // match can land before init's `loadFromStorage()` finishes — hydrate here so a
        // strong capture already on disk is never mistaken for "empty" and overwritten.
        await loadFromStorage()

        guard let current = withLock({ captureInProgress ? nil : cache }) else {
            // Either a capture is in flight (leave it alone) or there is nothing stored yet,
            // in which case the normal first-write path applies.
            if withLock({ cache == nil && !captureInProgress }) { await capture(data) }
            return
        }

        if isStrongAttribution(
            fbclid: current.fbclid, gclid: current.gclid, ttclid: current.ttclid,
            tiktokCampaignId: current.tiktokCampaignId, adNetwork: current.adNetwork
        ) { return }

        guard isStrongAttribution(
            fbclid: data.fbclid, gclid: data.gclid, ttclid: data.ttclid,
            tiktokCampaignId: data.tiktokCampaignId, adNetwork: data.adNetwork
        ) else { return }

        let claimed: Bool = withLock {
            if captureInProgress { return false }
            captureInProgress = true
            return true
        }
        guard claimed else { return }
        defer { withLock { captureInProgress = false } }

        // MERGE, not replacement: what the server brought wins field by field, what it
        // did not bring is inherited. Replacing the whole object erased real data — a
        // Meta deferred app link carrying `utm_campaign` lost the campaign when the
        // server answered with the network alone.
        //
        // Two fields are deliberately preserved from the original capture:
        // - `capturedAt` feeds `hasNewCampaignSignal` in install classification; moving
        //   it would rewrite new-install/reinstall.
        // - `installReferrerRaw` is the local evidence of what the store actually handed over.
        let promoted = AttributionCapture(
            utmSource: data.utmSource ?? current.utmSource,
            utmMedium: data.utmMedium ?? current.utmMedium,
            utmCampaign: data.utmCampaign ?? current.utmCampaign,
            utmContent: data.utmContent ?? current.utmContent,
            utmTerm: data.utmTerm ?? current.utmTerm,
            fbclid: data.fbclid ?? current.fbclid,
            gclid: data.gclid ?? current.gclid,
            ttclid: data.ttclid ?? current.ttclid,
            tiktokCampaignId: data.tiktokCampaignId ?? current.tiktokCampaignId,
            tiktokAdgroupId: data.tiktokAdgroupId ?? current.tiktokAdgroupId,
            tiktokAdId: data.tiktokAdId ?? current.tiktokAdId,
            installReferrerRaw: current.installReferrerRaw ?? data.installReferrerRaw,
            installReferrerSource: data.installReferrerSource ?? current.installReferrerSource,
            referrer: data.referrer ?? current.referrer,
            adNetwork: data.adNetwork ?? current.adNetwork,
            matchType: data.matchType ?? current.matchType,
            capturedAt: current.capturedAt
        )

        if let json = encode(promoted) {
            await storage.set(Self.storageKey, value: json)
        }

        withLock { cache = promoted }
        notifyListeners(promoted)
    }

    /// Synchronous read from in-memory cache. Call `loadFromStorage()` first.
    public func get() -> AttributionCapture? {
        withLock { cache }
    }

    /// Clear attribution from both storage and memory.
    public func clear() async {
        withLock {
            cache = nil
            hydrated = false
        }
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
