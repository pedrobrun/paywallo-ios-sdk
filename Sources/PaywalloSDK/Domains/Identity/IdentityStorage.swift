import Foundation

public struct PersistedIdentityState {
    public var deviceId: String?
    public var anonId: String?
    public var email: String?
    public var propertiesJson: String?
    public var distinctId: String?
    public var name: String?
    public var country: String?
    public var locale: String?
}

public enum IdentityStorage {

    /// Read value from new @paywallo: key, fallback to legacy key if not found.
    /// Promotes legacy value to new key on migration.
    static func readWithMigration(
        storage: SecureStorage,
        newKey: String,
        legacyKey: String
    ) async -> String? {
        if let value = await storage.get(newKey) {
            return value
        }

        if let legacyValue = await storage.get(legacyKey) {
            await storage.set(newKey, value: legacyValue)
            return legacyValue
        }

        return nil
    }

    /// Load all persisted identity fields, migrating from legacy keys when needed.
    public static func loadPersistedIdentity(storage: SecureStorage) async -> PersistedIdentityState {
        // All these run concurrently via async let
        async let deviceId = readWithMigration(storage: storage, newKey: PaywalloConstants.deviceIdKey, legacyKey: PaywalloConstants.legacyDeviceIdKey)
        async let anonId = readWithMigration(storage: storage, newKey: PaywalloConstants.anonIdKey, legacyKey: PaywalloConstants.legacyAnonIdKey)
        async let email = readWithMigration(storage: storage, newKey: PaywalloConstants.userEmailKey, legacyKey: PaywalloConstants.legacyEmailKey)
        async let propertiesJson = readWithMigration(storage: storage, newKey: PaywalloConstants.userPropertiesKey, legacyKey: PaywalloConstants.legacyPropertiesKey)
        async let distinctId = readWithMigration(storage: storage, newKey: PaywalloConstants.distinctIdKey, legacyKey: PaywalloConstants.legacyDistinctIdKey)
        async let name = readWithMigration(storage: storage, newKey: PaywalloConstants.userNameKey, legacyKey: PaywalloConstants.legacyNameKey)
        async let country = readWithMigration(storage: storage, newKey: PaywalloConstants.userCountryKey, legacyKey: PaywalloConstants.legacyCountryKey)
        async let locale = readWithMigration(storage: storage, newKey: PaywalloConstants.userLocaleKey, legacyKey: PaywalloConstants.legacyLocaleKey)

        return PersistedIdentityState(
            deviceId: await deviceId,
            anonId: await anonId,
            email: await email,
            propertiesJson: await propertiesJson,
            distinctId: await distinctId,
            name: await name,
            country: await country,
            locale: await locale
        )
    }

    /// Read device ID with fallback to device_id_fallback key.
    public static func readDeviceIdWithFallback(storage: SecureStorage) async -> String? {
        if let value = await readWithMigration(storage: storage, newKey: PaywalloConstants.deviceIdKey, legacyKey: PaywalloConstants.legacyDeviceIdKey) {
            return value
        }
        return await storage.get(PaywalloConstants.deviceIdFallbackKey)
    }

    /// Parse user properties from JSON string. Returns empty dict on failure.
    public static func parseProperties(_ json: String?) -> [String: AnyCodable] {
        guard let json = json, let data = json.data(using: .utf8) else { return [:] }
        do {
            return try JSONDecoder().decode([String: AnyCodable].self, from: data)
        } catch {
            return [:]
        }
    }

    /// Read PII with migration from legacy @panel: key to new @paywallo: key.
    public static func readWithPiiMigration(
        storage: SecureStorage,
        newKey: String,
        legacyKey: String
    ) async -> String? {
        if let value = await storage.get(newKey) {
            return value
        }
        if let legacyValue = await storage.get(legacyKey) {
            await storage.set(newKey, value: legacyValue)
            return legacyValue
        }
        return nil
    }
}
