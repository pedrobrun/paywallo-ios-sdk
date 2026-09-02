import Foundation

/// The two synced-identity bits that ride on the `$app_installed` payload.
public struct InstallSyncSignals: Sendable, Equatable {
    public let syncedIdentityKeyExists: Bool
    public let syncedIdentityDivergence: Bool

    public init(syncedIdentityKeyExists: Bool, syncedIdentityDivergence: Bool) {
        self.syncedIdentityKeyExists = syncedIdentityKeyExists
        self.syncedIdentityDivergence = syncedIdentityDivergence
    }
}

public enum SyncedIdentitySignal {
    /// Publishes the synced-Keychain identity signal for the install event.
    ///
    /// PURE TELEMETRY. It is never fed back into install classification — the
    /// campaign-signal precedence in `InstallClassifier` must keep deciding fire/no-fire
    /// on its own, and a synced key surviving an uninstall would otherwise silently
    /// suppress legitimate paid reinstalls.
    ///
    /// `enabled` is a server-side kill switch that ships ON. It must be read from the
    /// flag CACHE only: a cache miss means "no answer yet", not "off", hence the `true`
    /// default — and `$app_installed` must never wait on a network round-trip to be sent.
    public static func collect(
        storage: SecureStorage = .shared,
        enabled: Bool = true,
        createValue: () -> String = { UUID().uuidString }
    ) async -> InstallSyncSignals {
        let result = await storage.resolveSyncedIdentity(
            PaywalloConstants.syncedIdentityKey,
            enabled: enabled,
            createValue: createValue
        )
        return InstallSyncSignals(
            syncedIdentityKeyExists: result.syncedKeyExists,
            syncedIdentityDivergence: result.divergence
        )
    }
}
