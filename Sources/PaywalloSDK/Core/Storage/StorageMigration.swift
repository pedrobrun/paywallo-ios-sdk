import Foundation

public final class StorageMigration {

    private static let keychainKeyPrefix = "com.paywallo.sdk."

    private static let legacySecureKeys = [
        "device_id",
        "device_id_fallback",
        "anon_id",
        "user_email",
        "user_properties",
    ]

    /// Run migration if not already done. Idempotent — guarded by flag.
    public static func runIfNeeded(using storage: NativeStorage = .shared) async {
        let flag = storage.get(PaywalloConstants.migrationV152DoneKey)
        if flag == "1" { return }

        // Migrate legacy Keychain entries (sequential to avoid concurrency)
        await migrateKeychainLegacy(using: storage)

        storage.set(PaywalloConstants.migrationV152DoneKey, value: "1")
    }

    /// Migrate from legacy react-native-keychain layout to new layout.
    /// Legacy: service="com.paywallo.sdk.{key}", account="panel"
    /// New:    service="com.paywallo.sdk", account="com.paywallo.sdk.{key}"
    private static func migrateKeychainLegacy(using storage: NativeStorage) async {
        for key in legacySecureKeys {
            let legacyService = "\(keychainKeyPrefix)\(key)"

            guard let legacyValue = await storage.legacySecureGet(legacyService) else {
                continue
            }

            // Only migrate if new slot is empty
            let newKey = "\(keychainKeyPrefix)\(key)"
            let existing = await storage.secureGet(newKey)
            if existing == nil {
                await storage.secureSet(newKey, value: legacyValue)
            }
        }
    }
}
