import Foundation

public final class InstallTracker {
    private let storage: SecureStorage
    private let attributionTracker: AttributionTracker
    private let retryScheduler: InstallRetryScheduler
    private let debug: Bool
    private var trackingInProgress = false

    public init(
        storage: SecureStorage = .shared,
        debug: Bool = false,
        attributionTracker: AttributionTracker = .shared,
        deepLinkStore: DeferredDeepLinkStore = .shared
    ) {
        self.storage = storage
        self.debug = debug
        self.attributionTracker = attributionTracker
        self.retryScheduler = InstallRetryScheduler(
            debug: debug,
            storage: storage,
            attributionTracker: attributionTracker,
            deepLinkStore: deepLinkStore
        )
    }

    /// Returns `true` ONLY when `$app_installed` was actually dispatched.
    ///
    /// The caller logs on this: the old signature resolved the same way on every early
    /// exit (already tracked, no distinctId), which sent people investigating the loss of
    /// a critical event where none had happened.
    @discardableResult
    public func trackIfNeeded(
        apiClient: ApiClient,
        distinctIdProvider: @escaping () -> String,
        sessionId: String?,
        deviceData: DeviceData?,
        advertisingIds: AdvertisingIdResult?,
        fbAnonymousId: String?,
        referrer: MetaDeferredLinkParams? = nil,
        idfvChanged: Bool = false,
        syncedIdentityEnabled: Bool = true,
        trackEvent: @escaping (String, [String: AnyCodable], EventPriority) async -> Void
    ) async -> Bool {
        guard !trackingInProgress else { return false }
        trackingInProgress = true
        defer { trackingInProgress = false }

        return await doTrack(
            apiClient: apiClient,
            distinctIdProvider: distinctIdProvider,
            sessionId: sessionId,
            deviceData: deviceData,
            advertisingIds: advertisingIds,
            fbAnonymousId: fbAnonymousId,
            referrer: referrer,
            idfvChanged: idfvChanged,
            syncedIdentityEnabled: syncedIdentityEnabled,
            trackEvent: trackEvent
        )
    }

    // swiftlint:disable:next function_body_length
    private func doTrack(
        apiClient: ApiClient,
        distinctIdProvider: @escaping () -> String,
        sessionId: String?,
        deviceData: DeviceData?,
        advertisingIds: AdvertisingIdResult?,
        fbAnonymousId: String?,
        referrer: MetaDeferredLinkParams?,
        idfvChanged: Bool,
        syncedIdentityEnabled: Bool,
        trackEvent: @escaping (String, [String: AnyCodable], EventPriority) async -> Void
    ) async -> Bool {
        // Arms the pre-send flag BEFORE dispatching so concurrent cold-starts cannot both
        // fire `$app_installed`. `hasResidue` alone no longer decides the outcome — the
        // classifier below weighs it against a fresh campaign signal.
        let hasResidue = await InstallIdempotency.checkAndArmInstallGuard(storage: storage)

        // Read BEFORE classifyInstallAttempt, which overwrites APP_VERSION as a side
        // effect when the version changes — after that the "previous" value is gone.
        // Raw signals for diagnosis and retroactive reclassification, never fed back into
        // the classification itself.
        let hasInstallTrackedKey = await storage.get(PaywalloConstants.installTrackedKey) != nil
        let hasLegacyInstallTrackedKey =
            storage.nativeStorage.get(PaywalloConstants.legacyInstallTrackedKey) != nil
        let previousAppVersion = await storage.get(PaywalloConstants.installAppVersionKey)

        let classification = await InstallIdempotency.classifyInstallAttempt(
            storage: storage,
            params: ClassifyInstallAttemptParams(
                hasResidue: hasResidue,
                // Play Install Referrer is Android-only; on iOS the recent click/deep-link
                // capture is the proxy signal.
                referrerClickTimestampSeconds: nil,
                attributionCapturedAtIso: attributionTracker.get()?.capturedAt,
                currentAppVersion: deviceData?.appVersion
            )
        )

        guard shouldFireInstall(classification) else {
            // `$app_installed` already fired on a past launch (or this is an
            // update/relaunch with no new signal) — which says NOTHING about the
            // deferred match having a confirmed answer. Retry that on its own, without
            // re-lighting the install event.
            await retryScheduler.retryIfDue(apiClient: apiClient)
            return false
        }

        // Race guard: if identity init is still in flight, distinctId comes back empty.
        // Wait for it explicitly — on timeout we do NOT mark anything, so the next boot retries.
        guard let distinctId = await waitForDistinctId(distinctIdProvider) else {
            if debug {
                print("[Paywallo:Install] trackIfNeeded skipped — distinctId unavailable after retry; will retry next boot")
            }
            return false
        }

        let installedAt = Date().timeIntervalSince1970 * 1000

        let installEventId = await InstallIdempotency.resolveInstallEventId(
            deviceKey: advertisingIds?.idfv,
            appKey: apiClient.appKey,
            storage: storage
        )

        let effectiveAnonId = await resolveAnonId(fbAnonymousId)

        // Telemetry only — never fed back into classification.
        let syncSignals = await SyncedIdentitySignal.collect(
            storage: storage,
            enabled: syncedIdentityEnabled
        )

        // Raw signals behind the classification above, nested under ONE key (not
        // flattened) to spend a single slot of the server's 50-key boundedProperties
        // budget. Never reprocessed here.
        let installSignals = buildInstallClassificationSignals(
            hasInstallTrackedKey: hasInstallTrackedKey,
            hasLegacyInstallTrackedKey: hasLegacyInstallTrackedKey,
            previousAppVersion: previousAppVersion,
            idfvChanged: idfvChanged,
            syncedIdentityKeyExists: syncSignals.syncedIdentityKeyExists
        )

        let country = installRegionCode()

        var payload: [String: AnyCodable] = [
            "installedAt": AnyCodable(installedAt),
            "platform": AnyCodable(PaywalloConstants.sdkPlatform),
            "installEventId": AnyCodable(installEventId),
            "installClassification": AnyCodable(classification.rawValue),
            "installSignals": AnyCodable(installSignals.toPayload()),
            "syncedIdentityKeyExists": AnyCodable(syncSignals.syncedIdentityKeyExists),
            "syncedIdentityDivergence": AnyCodable(syncSignals.syncedIdentityDivergence),
            // Always present: "the app never asked" and "the user said no" are different
            // answers, and only the status tells them apart downstream.
            "attStatus": AnyCodable((advertisingIds?.attStatus ?? .unavailable).rawValue),
        ]

        if let sessionId = sessionId { payload["sessionId"] = AnyCodable(sessionId) }
        if let country = country { payload["country"] = AnyCodable(country) }

        if let device = deviceData {
            payload["deviceModel"] = AnyCodable(device.modelId.isEmpty ? device.model : device.modelId)
            payload["osVersion"] = AnyCodable(device.systemVersion)
            payload["appVersion"] = AnyCodable(device.appVersion)
            payload["buildNumber"] = AnyCodable(device.buildNumber)
            payload["screenWidth"] = AnyCodable(device.screenWidth)
            payload["screenHeight"] = AnyCodable(device.screenHeight)
            payload["screenDensity"] = AnyCodable(device.screenDensity)
            payload["locale"] = AnyCodable(device.locale)
            payload["timezone"] = AnyCodable(device.timezone)
            payload["brand"] = AnyCodable(device.brand)
            payload["carrier"] = AnyCodable(device.carrier)
            // Int, not the source UInt64: AnyCodable encodes Bool/Int/Double/String and
            // throws on anything else, and a throw here fails the encode of the WHOLE
            // event body. Byte counts fit Int64 with room to spare.
            payload["totalRam"] = AnyCodable(Int(device.totalRam))
            payload["totalDisk"] = AnyCodable(Int(device.totalDisk))
            payload["freeDisk"] = AnyCodable(Int(device.freeDisk))
        }

        if let anonId = effectiveAnonId { payload["fbAnonId"] = AnyCodable(anonId) }

        if let referrer = referrer {
            payload["installReferrer"] = AnyCodable(referrer.rawReferrer)
            payload["install_referrer_raw"] = AnyCodable(referrer.raw)
            payload["install_referrer_source"] = AnyCodable("meta_deferred")
            if let v = referrer.trackingId { payload["referrerTrackingId"] = AnyCodable(v) }
            if let v = referrer.fbclid { payload["referrerFbclid"] = AnyCodable(v) }
            if let v = referrer.utmSource { payload["referrerUtmSource"] = AnyCodable(v) }
            if let v = referrer.utmMedium { payload["referrerUtmMedium"] = AnyCodable(v) }
            if let v = referrer.utmCampaign { payload["referrerUtmCampaign"] = AnyCodable(v) }
            if let v = referrer.ttclid { payload["ttclid"] = AnyCodable(v) }
        }

        if let idfa = advertisingIds?.idfa { payload["idfa"] = AnyCodable(idfa) }
        if let idfv = advertisingIds?.idfv { payload["idfv"] = AnyCodable(idfv) }

        // Install is a one-shot, non-recoverable event — dispatched as `critical` so it
        // posts directly and, on failure, lands in PendingRetry instead of queueing
        // behind normal events. `installEventId` is stable across retries so the backend
        // deduplicates repeated dispatches.
        await trackEvent("$app_installed", payload, .critical)

        // Fire-and-forget: the deferred match must never delay the install dispatch.
        let scheduler = retryScheduler
        Task {
            await scheduler.start(
                apiClient: apiClient,
                distinctId: distinctId,
                deviceData: deviceData,
                country: country,
                idfv: advertisingIds?.idfv,
                anonId: effectiveAnonId,
                installedAt: installedAt,
                rawReferrer: referrer?.rawReferrer
            )
        }

        await InstallIdempotency.markInstallTracked(storage: storage, installedAt: installedAt)
        return true
    }

    // MARK: - Private helpers

    /// Meta's own anon id when the FB SDK answered; otherwise the persisted local one;
    /// otherwise a fresh `PW_` id. The `PW_` value is NOT a real `_fbp` — Meta does not
    /// recognise it — but a stable per-device id still lets the server stitch the install
    /// to later events, which is what it is for.
    private func resolveAnonId(_ fbAnonymousId: String?) async -> String? {
        if let fbAnonymousId = fbAnonymousId, !fbAnonymousId.isEmpty { return fbAnonymousId }

        if let stored = await storage.get(PaywalloConstants.anonIdKey), !stored.isEmpty {
            return stored
        }

        let generated = "PW_\(UUID().uuidString)"
        if debug {
            print("[Paywallo:Install] fb_anon_id: generated local PW_ (Facebook SDK absent in host? real _fbp unavailable — Meta does not recognise PW_)")
        }
        await storage.set(PaywalloConstants.anonIdKey, value: generated)
        return generated
    }

    /// Same policy as the session guard: poll briefly rather than fail the install on a
    /// cold-start race with identity init. Returns nil on timeout so the caller skips
    /// WITHOUT marking anything — the next boot retries.
    private func waitForDistinctId(_ provider: @escaping () -> String) async -> String? {
        for _ in 0..<10 {
            let id = provider()
            if !id.isEmpty { return id }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let last = provider()
        return last.isEmpty ? nil : last
    }
}

/// Region for the server's probabilistic match. `Locale.region` needs macOS 13 and the
/// package still builds for macOS 12, so the deprecated accessor stays as the fallback.
func installRegionCode() -> String? {
    let code: String?
    if #available(iOS 16.0, macOS 13.0, *) {
        code = Locale.current.region?.identifier
    } else {
        code = Locale.current.regionCode
    }
    guard let code = code, !code.isEmpty else { return nil }
    return code
}
