import Foundation

/// Classifies an install attempt against on-device residue — a persisted
/// INSTALL_TRACKED flag from a previous launch. On iOS this can survive an
/// uninstall (Keychain). Residue is final for firing purposes: reinstall never
/// fires `$app_installed` again, campaign click or not (decision 12/08 —
/// reinstall never counts, in any data, and is never sent).
public enum InstallClassification: String, Codable, Sendable {
    case newInstall = "new_install"
    case reinstallAttributed = "reinstall_attributed"
    case appUpdate = "app_update"
    case relaunch
    case unknownResidue = "unknown_residue"
    case staleRestore = "stale_restore"
}

// PREMISSA NAO VERIFICADA: assume-se que o Play Install Referrer repete o mesmo
// referrerClickTimestamp (nao um novo) quando o reinstall nao teve clique novo.
// Se cair, o ajuste e so na comparacao de timestamp abaixo, nao um redesenho.
private let iosClickSignalWindowMs: Double = 24 * 60 * 60 * 1000
private let clockFreshnessWindowMs: Double = 24 * 60 * 60 * 1000

public struct CampaignSignalInput: Sendable {
    public let lastInstallAtMs: Double?
    public let referrerClickTimestampSeconds: Double?
    public let attributionCapturedAtMs: Double?
    public let now: Double

    public init(
        lastInstallAtMs: Double?,
        referrerClickTimestampSeconds: Double?,
        attributionCapturedAtMs: Double?,
        now: Double
    ) {
        self.lastInstallAtMs = lastInstallAtMs
        self.referrerClickTimestampSeconds = referrerClickTimestampSeconds
        self.attributionCapturedAtMs = attributionCapturedAtMs
        self.now = now
    }
}

/// True when a campaign signal newer than the last known install exists —
/// Android's Play Install Referrer click timestamp, or (iOS) a recent
/// attribution capture. Only matters when there is no residue (genuinely new
/// install): it can override the clock-freshness gate below. It does not
/// override residue itself — a reinstall never fires.
public func hasNewCampaignSignal(_ input: CampaignSignalInput) -> Bool {
    if let clickSeconds = input.referrerClickTimestampSeconds {
        let clickAtMs = clickSeconds * 1000
        if input.lastInstallAtMs == nil || clickAtMs > input.lastInstallAtMs! { return true }
    }

    if let capturedAt = input.attributionCapturedAtMs,
       input.now - capturedAt <= iosClickSignalWindowMs,
       input.lastInstallAtMs == nil || capturedAt > input.lastInstallAtMs! {
        return true
    }

    return false
}

public struct InstallClassificationInput: Sendable {
    public let hasResidue: Bool
    public let hasNewSignal: Bool
    public let storedAppVersion: String?
    public let currentAppVersion: String?
    /// `nil` (field not supplied) or `true` = no gate applied — retrocompat default.
    public let isClockFresh: Bool?

    public init(
        hasResidue: Bool,
        hasNewSignal: Bool,
        storedAppVersion: String?,
        currentAppVersion: String?,
        isClockFresh: Bool? = nil
    ) {
        self.hasResidue = hasResidue
        self.hasNewSignal = hasNewSignal
        self.storedAppVersion = storedAppVersion
        self.currentAppVersion = currentAppVersion
        self.isClockFresh = isClockFresh
    }
}

public func classifyInstall(_ input: InstallClassificationInput) -> InstallClassification {
    if !input.hasResidue {
        // Clock gate only ever suppresses the no-signal path — a campaign signal
        // is stronger evidence than a restored device clock and always wins.
        if !input.hasNewSignal && input.isClockFresh == false { return .staleRestore }
        return .newInstall
    }
    // Residue present: a new campaign signal does not override it — reinstall
    // never fires, click or not (decision 12/08).
    if input.storedAppVersion == nil || input.currentAppVersion == nil { return .unknownResidue }
    if input.storedAppVersion != input.currentAppVersion { return .appUpdate }
    return .relaunch
}

public struct InstallClockFreshnessInput: Sendable {
    /// PackageManager firstInstallTime for this app on this device, ms since epoch. Android-only; `nil` on iOS.
    public let packageFirstInstallAtMs: Double?
    /// SDK's own persisted first-run marker, ms since epoch.
    public let sdkFirstRunAtMs: Double?
    /// PackageManager lastUpdateTime — corroborates a side-load-then-update install. Android-only; `nil` on iOS.
    public let packageLastUpdateAtMs: Double?

    public init(packageFirstInstallAtMs: Double?, sdkFirstRunAtMs: Double?, packageLastUpdateAtMs: Double?) {
        self.packageFirstInstallAtMs = packageFirstInstallAtMs
        self.sdkFirstRunAtMs = sdkFirstRunAtMs
        self.packageLastUpdateAtMs = packageLastUpdateAtMs
    }
}

/// True when the OS-reported install clock agrees with the SDK's own first-run
/// marker within 24h, or with lastUpdateTime for the side-load-then-update case
/// where firstInstallTime predates SDK integration. Missing data never gates —
/// only an explicit mismatch does. On iOS both package timestamps are `nil`, so
/// this always returns `true` and the gate stays inert by design.
public func isInstallClockFresh(_ input: InstallClockFreshnessInput) -> Bool {
    guard let firstInstall = input.packageFirstInstallAtMs,
          let sdkFirstRun = input.sdkFirstRunAtMs else { return true }

    if abs(sdkFirstRun - firstInstall) <= clockFreshnessWindowMs { return true }
    if let lastUpdate = input.packageLastUpdateAtMs,
       abs(sdkFirstRun - lastUpdate) <= clockFreshnessWindowMs {
        return true
    }
    return false
}

/// Only a genuine new install is worth a network dispatch — reinstall never counts, in any data.
public func shouldFireInstall(_ classification: InstallClassification) -> Bool {
    classification == .newInstall
}

/// Raw signals behind a classification decision, meant to travel on the
/// `$app_installed` payload as ONE nested object (not flattened) — the
/// top-level boundedProperties key budget is only 50 and `$app_installed`
/// already uses ~23, so a nested object costs 1 key regardless of how many
/// fields it holds. Never fed back into `classifyInstall` live; this is
/// diagnostic + retroactive-reclassification material only.
public struct InstallClassificationSignals: Codable, Sendable, Equatable {
    public let hasInstallTrackedKey: Bool
    public let hasLegacyInstallTrackedKey: Bool
    public let hasAppVersionKey: Bool
    public let previousAppVersion: String?
    public let packageFirstInstallAtMs: Double?
    public let packageLastUpdateAtMs: Double?
    public let idfvChanged: Bool
    public let syncedIdentityKeyExists: Bool

    public init(
        hasInstallTrackedKey: Bool,
        hasLegacyInstallTrackedKey: Bool,
        hasAppVersionKey: Bool,
        previousAppVersion: String?,
        packageFirstInstallAtMs: Double?,
        packageLastUpdateAtMs: Double?,
        idfvChanged: Bool,
        syncedIdentityKeyExists: Bool
    ) {
        self.hasInstallTrackedKey = hasInstallTrackedKey
        self.hasLegacyInstallTrackedKey = hasLegacyInstallTrackedKey
        self.hasAppVersionKey = hasAppVersionKey
        self.previousAppVersion = previousAppVersion
        self.packageFirstInstallAtMs = packageFirstInstallAtMs
        self.packageLastUpdateAtMs = packageLastUpdateAtMs
        self.idfvChanged = idfvChanged
        self.syncedIdentityKeyExists = syncedIdentityKeyExists
    }

    /// Serializes to the nested object shape the server stores in `classification_signals` (jsonb).
    ///
    /// Returns `[String: Any]`, not `[String: AnyCodable]`, because the caller nests the
    /// result inside one `AnyCodable`: that wrapper re-wraps each value, and an
    /// `AnyCodable` holding an `AnyCodable` matches none of its encode cases and THROWS —
    /// which fails the encode of the whole `$app_installed` body, not just this field.
    /// For the same reason absent values become `NSNull` (an `Optional.none` boxed as
    /// `Any` also matches no case) so they encode as JSON null.
    public func toPayload() -> [String: Any] {
        [
            "hasInstallTrackedKey": hasInstallTrackedKey,
            "hasLegacyInstallTrackedKey": hasLegacyInstallTrackedKey,
            "hasAppVersionKey": hasAppVersionKey,
            "previousAppVersion": previousAppVersion ?? NSNull(),
            "packageFirstInstallAtMs": packageFirstInstallAtMs ?? NSNull(),
            "packageLastUpdateAtMs": packageLastUpdateAtMs ?? NSNull(),
            "idfvChanged": idfvChanged,
            "syncedIdentityKeyExists": syncedIdentityKeyExists,
        ]
    }
}

/// Pure assembly, no I/O — caller sources each field however it already reads it.
/// `hasAppVersionKey` is derived, never passed in.
public func buildInstallClassificationSignals(
    hasInstallTrackedKey: Bool,
    hasLegacyInstallTrackedKey: Bool,
    previousAppVersion: String?,
    packageFirstInstallAtMs: Double? = nil,
    packageLastUpdateAtMs: Double? = nil,
    idfvChanged: Bool,
    syncedIdentityKeyExists: Bool
) -> InstallClassificationSignals {
    InstallClassificationSignals(
        hasInstallTrackedKey: hasInstallTrackedKey,
        hasLegacyInstallTrackedKey: hasLegacyInstallTrackedKey,
        hasAppVersionKey: previousAppVersion != nil,
        previousAppVersion: previousAppVersion,
        packageFirstInstallAtMs: packageFirstInstallAtMs,
        packageLastUpdateAtMs: packageLastUpdateAtMs,
        idfvChanged: idfvChanged,
        syncedIdentityKeyExists: syncedIdentityKeyExists
    )
}

/// Recomputes the classification from a persisted signals snapshot alone —
/// the proof that the snapshot is enough for retroactive reclassification
/// without live storage/device access.
public func classifyInstallFromSignals(
    signals: InstallClassificationSignals,
    hasNewSignal: Bool,
    currentAppVersion: String?,
    sdkFirstRunAtMs: Double? = nil
) -> InstallClassification {
    classifyInstall(
        InstallClassificationInput(
            hasResidue: signals.hasInstallTrackedKey || signals.hasLegacyInstallTrackedKey,
            hasNewSignal: hasNewSignal,
            storedAppVersion: signals.previousAppVersion,
            currentAppVersion: currentAppVersion,
            isClockFresh: isInstallClockFresh(
                InstallClockFreshnessInput(
                    packageFirstInstallAtMs: signals.packageFirstInstallAtMs,
                    sdkFirstRunAtMs: sdkFirstRunAtMs,
                    packageLastUpdateAtMs: signals.packageLastUpdateAtMs
                )
            )
        )
    )
}
