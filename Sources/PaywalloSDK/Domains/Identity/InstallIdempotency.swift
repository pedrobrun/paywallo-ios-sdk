import Foundation

/// In-memory guard for the current process launch.
///
/// The first `checkAndArmInstallGuard` call flips this synchronously, before any
/// `await`, so a second concurrent call — two cold-start paths, a Linking race plus the
/// network — sees it already armed and bails before reaching the storage reads. Without
/// it both callers read INSTALL_TRACKED as absent and both dispatch `$app_installed`.
///
/// Reset only on a fresh process launch, which is exactly when the persistent check
/// should run again.
private final class InstallLaunchGuard: @unchecked Sendable {
    static let shared = InstallLaunchGuard()

    private let lock = NSLock()
    private var armed = false

    /// Reads and arms inside one critical section — a plain read-then-write would
    /// reopen the very race this exists to close.
    func armAndReadPrevious() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let previous = armed
        armed = true
        return previous
    }

    func reset() {
        lock.lock()
        armed = false
        lock.unlock()
    }
}

public struct ClassifyInstallAttemptParams: Sendable {
    /// Result of `checkAndArmInstallGuard` — true when a residue flag was found on this device.
    public let hasResidue: Bool
    /// Android Play Install Referrer click time, seconds since epoch. Always nil on iOS.
    public let referrerClickTimestampSeconds: Double?
    /// ISO `capturedAt` from `AttributionTracker.get()` — the iOS click/deep-link proxy signal.
    public let attributionCapturedAtIso: String?
    public let currentAppVersion: String?
    public let now: Double
    /// PackageManager timestamps are Android-only; nil on iOS keeps the freshness gate inert.
    public let packageFirstInstallAtMs: Double?
    public let sdkFirstRunAtMs: Double?
    public let packageLastUpdateAtMs: Double?

    public init(
        hasResidue: Bool,
        referrerClickTimestampSeconds: Double? = nil,
        attributionCapturedAtIso: String? = nil,
        currentAppVersion: String?,
        now: Double = Date().timeIntervalSince1970 * 1000,
        packageFirstInstallAtMs: Double? = nil,
        sdkFirstRunAtMs: Double? = nil,
        packageLastUpdateAtMs: Double? = nil
    ) {
        self.hasResidue = hasResidue
        self.referrerClickTimestampSeconds = referrerClickTimestampSeconds
        self.attributionCapturedAtIso = attributionCapturedAtIso
        self.currentAppVersion = currentAppVersion
        self.now = now
        self.packageFirstInstallAtMs = packageFirstInstallAtMs
        self.sdkFirstRunAtMs = sdkFirstRunAtMs
        self.packageLastUpdateAtMs = packageLastUpdateAtMs
    }
}

public enum InstallIdempotency {

    // MARK: - Guard

    /// Whether the caller should bail out early (`true` = already tracked or in flight).
    ///
    /// Side effect when returning `false`: the pre-send guard
    /// (`@paywallo:app_installed_sent`) is written so concurrent cold-starts in the same
    /// launch cannot both slip past. Cross-boot durability does NOT depend on it — it is
    /// written but never read as a retry guard; `$app_installed` posts directly with
    /// `critical` priority and only a failed attempt lands in `PendingRetry`.
    public static func checkAndArmInstallGuard(storage: SecureStorage) async -> Bool {
        // Synchronous — nothing above this line may await.
        if InstallLaunchGuard.shared.armAndReadPrevious() { return true }

        if await storage.get(PaywalloConstants.installTrackedKey) != nil { return true }

        // Residue written by SDK versions that used the `@panel:` prefix, through the
        // regular storage layer.
        if storage.nativeStorage.get(PaywalloConstants.legacyInstallTrackedKey) != nil { return true }

        storage.nativeStorage.set(PaywalloConstants.appInstalledSentKey, value: "1")
        return false
    }

    /// Test-only — resets the in-memory launch guard between cases.
    public static func resetInstallGuardForTests() {
        InstallLaunchGuard.shared.reset()
    }

    /// Persists the install-tracked flag in both layers after a successful dispatch.
    /// The value is the install timestamp: `classifyInstallAttempt` reads it back as
    /// `lastInstallAtMs` to decide whether a later campaign signal is genuinely newer.
    public static func markInstallTracked(storage: SecureStorage, installedAt: Double) async {
        let stamp = String(Int64(installedAt))
        await storage.set(PaywalloConstants.installTrackedKey, value: stamp)
        storage.nativeStorage.set(PaywalloConstants.legacyInstallTrackedKey, value: stamp)
    }

    // MARK: - Event id

    /// A deterministic UUID whenever a stable device key exists, so a reinstall produces
    /// the SAME `event_id` and the backend deduplicates it automatically.
    ///
    /// `androidId` survives a GAID reset, so it outranks `deviceKey` when present —
    /// otherwise a user resetting their ad id would look like a new install and defeat
    /// dedup. Always nil on iOS, where `deviceKey` is the IDFV.
    public static func resolveInstallEventId(
        deviceKey: String?,
        appKey: String,
        androidId: String? = nil,
        storage: SecureStorage
    ) async -> String {
        let androidIdTrimmed = androidId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stableKey = (androidIdTrimmed?.isEmpty == false) ? androidId : deviceKey

        if let stableKey = stableKey,
           !stableKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Only present after a devResetInstallState. It keeps the id deterministic
            // within one round (a retry reuses it) and rotates it on every reset —
            // without it the id comes from hardware, never changes, and the server drops
            // the "new" install on event_id dedup.
            let epoch = storage.nativeStorage.get(PaywalloConstants.devResetEpochKey)
            let seed = epoch.map { "\(appKey):\(stableKey):\($0)" } ?? "\(appKey):\(stableKey)"
            return deterministicUUID(seed)
        }

        return await getOrCreateInstallEventId(storage: storage)
    }

    /// Random-UUID fallback for devices with no stable key. This one IS persisted — it
    /// cannot be re-derived, so losing it would break dedup across retries.
    public static func getOrCreateInstallEventId(storage: SecureStorage) async -> String {
        let native = storage.nativeStorage
        if let existing = native.get(PaywalloConstants.installEventIdKey) { return existing }

        // Silent migration from the legacy `@panel:` key.
        if let legacy = native.get(PaywalloConstants.legacyInstallEventIdKey) {
            native.set(PaywalloConstants.installEventIdKey, value: legacy)
            return legacy
        }

        let id = UUID().uuidString
        native.set(PaywalloConstants.installEventIdKey, value: id)
        return id
    }

    // MARK: - Classification

    /// Reads the residue's last known install time plus the stored app version, runs the
    /// pure classifier, and keeps the stored app version in sync regardless of outcome —
    /// otherwise a real version bump would mislabel every relaunch after it as
    /// `app_update` forever.
    public static func classifyInstallAttempt(
        storage: SecureStorage,
        params: ClassifyInstallAttemptParams
    ) async -> InstallClassification {
        let installedAtRaw = await storage.get(PaywalloConstants.installTrackedKey)
        let storedAppVersion = await storage.get(PaywalloConstants.installAppVersionKey)

        let lastInstallAtMs = installedAtRaw.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }

        let hasNewSignal = hasNewCampaignSignal(
            CampaignSignalInput(
                lastInstallAtMs: lastInstallAtMs,
                referrerClickTimestampSeconds: params.referrerClickTimestampSeconds,
                attributionCapturedAtMs: parseIsoMs(params.attributionCapturedAtIso),
                now: params.now
            )
        )

        let isClockFresh = isInstallClockFresh(
            InstallClockFreshnessInput(
                packageFirstInstallAtMs: params.packageFirstInstallAtMs,
                sdkFirstRunAtMs: params.sdkFirstRunAtMs,
                packageLastUpdateAtMs: params.packageLastUpdateAtMs
            )
        )

        let classification = classifyInstall(
            InstallClassificationInput(
                hasResidue: params.hasResidue,
                hasNewSignal: hasNewSignal,
                storedAppVersion: storedAppVersion,
                currentAppVersion: params.currentAppVersion,
                isClockFresh: isClockFresh
            )
        )

        if let current = params.currentAppVersion, current != storedAppVersion {
            await storage.set(PaywalloConstants.installAppVersionKey, value: current)
        }

        return classification
    }

    // MARK: - Dev reset

    /// Erases the install markers so the next cold start classifies as `new_install`.
    ///
    /// Exists because these keys live in the Keychain: they survive uninstalling the app
    /// and can even come back from an iCloud restore, so there is no way to test the
    /// acquisition flow on a device that already ran the app — clearing the server
    /// database does not help, the decision happens here.
    ///
    /// `reset()`/`fullReset()` do NOT serve: both clear identity and PII, never these
    /// keys. The caller gates this on DEV (see PaywalloClient).
    public static func clearInstallState(storage: SecureStorage) async {
        InstallLaunchGuard.shared.reset()

        // Each key leaves through the SAME layer that wrote it. `SecureStorage.remove`
        // re-prefixes with "@paywallo:", and the install keys already start with it — so
        // using it on a key written by `NativeStorage.set` looks for
        // "@paywallo:@paywallo:..." and deletes nothing. The reset used to stop half-way:
        // INSTALL_EVENT_ID survived and the "new" `$app_installed` reused the previous
        // round's event id on devices without an IDFV.
        let viaSecureStorage = [
            PaywalloConstants.installTrackedKey,
            PaywalloConstants.deferredMatchDoneKey,
            PaywalloConstants.deferredMatchStateKey,
            PaywalloConstants.installAppVersionKey,
            // Written by IdentityStorage — without erasing it the "new install" comes
            // back carrying the previous round's anonymous identity.
            PaywalloConstants.anonIdKey,
        ]
        let viaNativeStorage = [
            PaywalloConstants.appInstalledSentKey,
            PaywalloConstants.installEventIdKey,
            PaywalloConstants.legacyInstallTrackedKey,
            PaywalloConstants.legacyInstallEventIdKey,
            PaywalloConstants.legacyDeferredMatchDoneKey,
            PaywalloConstants.legacyAnonIdCurrentKey,
        ]

        for key in viaSecureStorage {
            await storage.remove(key)
        }
        for key in viaNativeStorage {
            storage.nativeStorage.remove(key)
        }

        // Written AFTER the removals: with a stable IDFV the installEventId does not
        // change just because a key was erased, and the server would drop the "new"
        // install on event_id dedup.
        storage.nativeStorage.set(
            PaywalloConstants.devResetEpochKey,
            value: String(Int64(Date().timeIntervalSince1970 * 1000))
        )
    }
}

/// `Date.parse` equivalent for the ISO strings `AttributionTracker` writes. Accepts the
/// fractional-seconds variant too, since a capture persisted by another SDK version may
/// carry it.
func parseIsoMs(_ iso: String?) -> Double? {
    guard let iso = iso else { return nil }

    let plain = ISO8601DateFormatter()
    if let date = plain.date(from: iso) { return date.timeIntervalSince1970 * 1000 }

    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: iso) { return date.timeIntervalSince1970 * 1000 }

    return nil
}
