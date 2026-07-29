import Foundation

public final class SecureStorage {
    public static let shared = SecureStorage()

    private let keychainKeyPrefix = "com.paywallo.sdk."
    private let regularKeyPrefix = PaywalloConstants.storagePrefix  // "@paywallo:"
    private let nativeStorage: NativeStorage

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
}
