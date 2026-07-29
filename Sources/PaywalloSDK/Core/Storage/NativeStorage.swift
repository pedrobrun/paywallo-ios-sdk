import Foundation
import Security

public class NativeStorage {
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
