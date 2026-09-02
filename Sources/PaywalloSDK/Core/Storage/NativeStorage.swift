import Foundation
import Security

/// Thread-safe by construction: every stored property is an immutable `let`, Keychain access
/// is funnelled through a serial queue, and `UserDefaults` is itself thread-safe. The
/// `@unchecked` is therefore an assertion about those invariants, not a suppression.
public class NativeStorage: @unchecked Sendable {
    public static let shared = NativeStorage()

    private let service: String
    private let keychainQueue = DispatchQueue(label: "com.paywallo.sdk.keychain", qos: .userInitiated)
    private let defaults: UserDefaults

    public init(service: String = PaywalloConstants.keychainServiceName, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }

    // MARK: - Secure Storage (Keychain)

    public func secureGet(_ key: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            keychainQueue.async {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: self.service,
                    kSecAttrAccount as String: key,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                ]

                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)

                if status == errSecSuccess,
                   let data = item as? Data,
                   let value = String(data: data, encoding: .utf8)
                {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    @discardableResult
    public func secureSet(_ key: String, value: String) async -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            keychainQueue.async {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: self.service,
                    kSecAttrAccount as String: key,
                ]

                let attributes: [String: Any] = [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                ]

                let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

                if updateStatus == errSecItemNotFound {
                    var addQuery = query
                    addQuery[kSecValueData as String] = data
                    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
                    continuation.resume(returning: addStatus == errSecSuccess)
                } else {
                    continuation.resume(returning: updateStatus == errSecSuccess)
                }
            }
        }
    }

    @discardableResult
    public func secureRemove(_ key: String) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            keychainQueue.async {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: self.service,
                    kSecAttrAccount as String: key,
                ]
                SecItemDelete(query as CFDictionary)
                continuation.resume(returning: true)
            }
        }
    }

    // MARK: - Synced Keychain (iCloud Keychain)
    // Same service, but `kSecAttrSynchronizable` makes the item a DIFFERENT Keychain
    // slot from the local one with the same account — a synced read never sees a local
    // write and vice-versa. Accessibility must be `AfterFirstUnlock` (not
    // `...ThisDeviceOnly`): the OS refuses to sync a device-only item, and `secureSet`'s
    // attributes would make every write fail silently.

    public func secureGetSynced(_ key: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            keychainQueue.async {
                var query = self.syncedQuery(key)
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne

                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)

                if status == errSecSuccess,
                   let data = item as? Data,
                   let value = String(data: data, encoding: .utf8)
                {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    @discardableResult
    public func secureSetSynced(_ key: String, value: String) async -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.keychainQueue.async {
                let query = self.syncedQuery(key)
                let attributes: [String: Any] = [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                ]

                let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

                if updateStatus == errSecItemNotFound {
                    var addQuery = query
                    addQuery[kSecValueData as String] = data
                    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
                    continuation.resume(returning: addStatus == errSecSuccess)
                } else {
                    continuation.resume(returning: updateStatus == errSecSuccess)
                }
            }
        }
    }

    @discardableResult
    public func secureRemoveSynced(_ key: String) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            keychainQueue.async {
                SecItemDelete(self.syncedQuery(key) as CFDictionary)
                continuation.resume(returning: true)
            }
        }
    }

    private func syncedQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: true,
        ]
    }

    // MARK: - Legacy Keychain (SDK ≤1.5.0 migration)
    // react-native-keychain stored: service="com.paywallo.sdk.{key}", account="panel"

    public func legacySecureGet(_ legacyService: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            keychainQueue.async {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: legacyService,
                    kSecAttrAccount as String: "panel",
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                ]

                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)

                if status == errSecSuccess,
                   let data = item as? Data,
                   let value = String(data: data, encoding: .utf8)
                {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Regular Storage (UserDefaults)

    public func get(_ key: String) -> String? {
        defaults.string(forKey: key)
    }

    @discardableResult
    public func set(_ key: String, value: String) -> Bool {
        defaults.set(value, forKey: key)
        return true
    }

    @discardableResult
    public func remove(_ key: String) -> Bool {
        defaults.removeObject(forKey: key)
        return true
    }
}
