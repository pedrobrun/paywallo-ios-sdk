import Foundation

public final class SecureStorage {
    public static let shared = SecureStorage()

    private let keychainKeyPrefix = "com.paywallo.sdk."
    /// Synced items live under their own prefix so a synced slot can never collide with
    /// the local one for the same logical key.
    private let syncedKeychainKeyPrefix = "com.paywallo.sdk.sync."
    private let regularKeyPrefix = PaywalloConstants.storagePrefix  // "@paywallo:"
    /// Exposed so callers that must write through the SAME layer that wrote a key can do
    /// so: `remove()` here re-prefixes with "@paywallo:", which would look for
    /// "@paywallo:@paywallo:..." on a key `NativeStorage.set` wrote directly.
    public let nativeStorage: NativeStorage

    public init(nativeStorage: NativeStorage = .shared) {
        self.nativeStorage = nativeStorage
    }

    /// Read with promotion: Keychain first → UserDefaults fallback → promote to Keychain
    public func get(_ key: String) async -> String? {
        // Try Keychain first
        let keychainKey = "\(keychainKeyPrefix)\(key)"
        if let value = await nativeStorage.secureGet(keychainKey) {
            return value
        }

        // Fallback to UserDefaults
        let regularKey = "\(regularKeyPrefix)\(key)"
        if let value = nativeStorage.get(regularKey) {
            // Promote to Keychain
            await nativeStorage.secureSet(keychainKey, value: value)
            // Remove plaintext copy
            nativeStorage.remove(regularKey)
            return value
        }

        return nil
    }

    /// Write ONLY to Keychain — never plaintext
    @discardableResult
    public func set(_ key: String, value: String) async -> Bool {
        let keychainKey = "\(keychainKeyPrefix)\(key)"
        return await nativeStorage.secureSet(keychainKey, value: value)
    }

    /// Remove from both Keychain and UserDefaults (cleanup legacy)
    @discardableResult
    public func remove(_ key: String) async -> Bool {
        let keychainKey = "\(keychainKeyPrefix)\(key)"
        let regularKey = "\(regularKeyPrefix)\(key)"

        nativeStorage.remove(regularKey)
        return await nativeStorage.secureRemove(keychainKey)
    }

    // MARK: - Synced identity

    /// Outcome of `resolveSyncedIdentity` — the value plus the two telemetry bits the
    /// `$app_installed` payload carries.
    public struct SyncedIdentityResult: Sendable {
        public let value: String?
        /// True when the iCloud-synced slot already held a value on this device. On a
        /// fresh device that means the identity arrived from another one.
        public let syncedKeyExists: Bool
        /// Synced and local disagree — two devices, or a restore that carried the synced
        /// key but not the local one. Telemetry only, never fed back into classification.
        public let divergence: Bool
    }

    /// Reconciles the iCloud-synced identity slot with the device-local one.
    ///
    /// Synced wins when present (it is the cross-device identity); a local-only value is
    /// promoted up; neither present creates one in both. `enabled == false` is the kill
    /// switch: it degrades to the local value and never touches the synced Keychain.
    public func resolveSyncedIdentity(
        _ key: String,
        enabled: Bool,
        createValue: () -> String
    ) async -> SyncedIdentityResult {
        let localKey = "\(key):local"

        if !enabled {
            let localOnly = await get(localKey)
            return SyncedIdentityResult(value: localOnly, syncedKeyExists: false, divergence: false)
        }

        let syncedValue = await nativeStorage.secureGetSynced("\(syncedKeychainKeyPrefix)\(key)")
        let localValue = await get(localKey)

        let syncedKeyExists = syncedValue != nil
        let divergence = syncedKeyExists && localValue != nil && syncedValue != localValue

        if let syncedValue = syncedValue {
            if localValue == nil { await set(localKey, value: syncedValue) }
            return SyncedIdentityResult(value: syncedValue, syncedKeyExists: true, divergence: divergence)
        }

        if let localValue = localValue {
            await nativeStorage.secureSetSynced("\(syncedKeychainKeyPrefix)\(key)", value: localValue)
            return SyncedIdentityResult(value: localValue, syncedKeyExists: false, divergence: false)
        }

        let created = createValue()
        await set(localKey, value: created)
        await nativeStorage.secureSetSynced("\(syncedKeychainKeyPrefix)\(key)", value: created)
        return SyncedIdentityResult(value: created, syncedKeyExists: false, divergence: false)
    }
}
