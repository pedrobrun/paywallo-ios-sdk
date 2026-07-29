import Foundation
@testable import PaywalloSDK

public final class MockKeychain {
    private var store: [String: Data] = [:]
    public var setCalls: [(key: String, data: Data)] = []
    public var getCalls: [String] = []
    public var removeCalls: [String] = []

    public init() {}

    public func set(_ data: Data, forKey key: String) -> Bool {
        setCalls.append((key: key, data: data))
        store[key] = data
        return true
    }

    public func set(_ string: String, forKey key: String) -> Bool {
        return set(Data(string.utf8), forKey: key)
    }

    public func get(forKey key: String) -> Data? {
        getCalls.append(key)
        return store[key]
    }

    public func getString(forKey key: String) -> String? {
        guard let data = get(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func remove(forKey key: String) -> Bool {
        removeCalls.append(key)
        store.removeValue(forKey: key)
        return true
    }

    public func removeAll() {
        store.removeAll()
    }

    public var allKeys: [String] {
        Array(store.keys)
    }
}
