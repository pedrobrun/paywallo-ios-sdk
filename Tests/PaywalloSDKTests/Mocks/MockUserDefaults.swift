import Foundation
@testable import PaywalloSDK

public final class MockUserDefaults {
    private var store: [String: Any] = [:]
    public var setCalls: [(key: String, value: Any)] = []
    public var getCalls: [String] = []
    public var removeCalls: [String] = []

    public init() {}

    public func set(_ value: Any?, forKey key: String) {
        setCalls.append((key: key, value: value ?? NSNull()))
        if let value = value {
            store[key] = value
        } else {
            store.removeValue(forKey: key)
        }
    }

    public func string(forKey key: String) -> String? {
        getCalls.append(key)
        return store[key] as? String
    }

    public func data(forKey key: String) -> Data? {
        getCalls.append(key)
        return store[key] as? Data
    }

    public func object(forKey key: String) -> Any? {
        getCalls.append(key)
        return store[key]
    }

    public func bool(forKey key: String) -> Bool {
        getCalls.append(key)
        return store[key] as? Bool ?? false
    }

    public func removeObject(forKey key: String) {
        removeCalls.append(key)
        store.removeValue(forKey: key)
    }

    public var allKeys: [String] {
        Array(store.keys)
    }

    public func removeAll() {
        store.removeAll()
    }
}
