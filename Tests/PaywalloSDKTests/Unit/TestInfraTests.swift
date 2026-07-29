import XCTest
@testable import PaywalloSDK

final class TestInfraTests: XCTestCase {

    // MARK: - MockURLSession

    func testMockURLSessionDefaultResponse() async throws {
        let mock = MockURLSession()
        let request = URLRequest(url: URL(string: "https://api.paywallo.com/test")!)
        let (_, response) = try await mock.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(mock.requestsReceived.count, 1)
    }

    func testMockURLSessionEnqueueResponse() async throws {
        let mock = MockURLSession()
        mock.enqueueResponse(statusCode: 404)
        let request = URLRequest(url: URL(string: "https://api.paywallo.com/test")!)
        let (_, response) = try await mock.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        XCTAssertEqual(httpResponse.statusCode, 404)
    }

    func testMockURLSessionEnqueueJSON() async throws {
        let mock = MockURLSession()
        mock.enqueueJSON(["success": true])
        let request = URLRequest(url: URL(string: "https://api.paywallo.com/test")!)
        let (data, _) = try await mock.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["success"] as? Bool, true)
    }

    func testMockURLSessionEnqueueError() async {
        let mock = MockURLSession()
        mock.enqueueError(URLError(.notConnectedToInternet))
        let request = URLRequest(url: URL(string: "https://api.paywallo.com/test")!)
        do {
            _ = try await mock.data(for: request)
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is URLError)
        }
    }

    func testMockURLSessionTracksRequests() async throws {
        let mock = MockURLSession()
        let request1 = URLRequest(url: URL(string: "https://api.paywallo.com/a")!)
        let request2 = URLRequest(url: URL(string: "https://api.paywallo.com/b")!)
        _ = try await mock.data(for: request1)
        _ = try await mock.data(for: request2)
        XCTAssertEqual(mock.requestsReceived.count, 2)
        XCTAssertEqual(mock.requestsReceived[0].url?.path, "/a")
        XCTAssertEqual(mock.requestsReceived[1].url?.path, "/b")
    }

    // MARK: - MockKeychain

    func testMockKeychainSetGet() {
        let keychain = MockKeychain()
        _ = keychain.set("secret", forKey: "token")
        XCTAssertEqual(keychain.getString(forKey: "token"), "secret")
    }

    func testMockKeychainGetNonExistent() {
        let keychain = MockKeychain()
        XCTAssertNil(keychain.get(forKey: "nonexistent"))
    }

    func testMockKeychainRemove() {
        let keychain = MockKeychain()
        _ = keychain.set("value", forKey: "key")
        _ = keychain.remove(forKey: "key")
        XCTAssertNil(keychain.getString(forKey: "key"))
    }

    func testMockKeychainOverwrite() {
        let keychain = MockKeychain()
        _ = keychain.set("old", forKey: "key")
        _ = keychain.set("new", forKey: "key")
        XCTAssertEqual(keychain.getString(forKey: "key"), "new")
    }

    func testMockKeychainTracksCalls() {
        let keychain = MockKeychain()
        _ = keychain.set("v", forKey: "k")
        _ = keychain.get(forKey: "k")
        _ = keychain.remove(forKey: "k")
        XCTAssertEqual(keychain.setCalls.count, 1)
        XCTAssertEqual(keychain.getCalls.count, 1)
        XCTAssertEqual(keychain.removeCalls.count, 1)
    }

    // MARK: - MockUserDefaults

    func testMockUserDefaultsSetGet() {
        let defaults = MockUserDefaults()
        defaults.set("value", forKey: "key")
        XCTAssertEqual(defaults.string(forKey: "key"), "value")
    }

    func testMockUserDefaultsGetNonExistent() {
        let defaults = MockUserDefaults()
        XCTAssertNil(defaults.string(forKey: "nonexistent"))
    }

    func testMockUserDefaultsRemove() {
        let defaults = MockUserDefaults()
        defaults.set("value", forKey: "key")
        defaults.removeObject(forKey: "key")
        XCTAssertNil(defaults.string(forKey: "key"))
    }

    func testMockUserDefaultsBool() {
        let defaults = MockUserDefaults()
        defaults.set(true, forKey: "flag")
        XCTAssertTrue(defaults.bool(forKey: "flag"))
    }

    func testMockUserDefaultsBoolDefaultFalse() {
        let defaults = MockUserDefaults()
        XCTAssertFalse(defaults.bool(forKey: "nonexistent"))
    }

    func testMockUserDefaultsSetNilRemoves() {
        let defaults = MockUserDefaults()
        defaults.set("value", forKey: "key")
        defaults.set(nil, forKey: "key")
        XCTAssertNil(defaults.string(forKey: "key"))
    }

    func testMockUserDefaultsTracksCalls() {
        let defaults = MockUserDefaults()
        defaults.set("v", forKey: "k")
        _ = defaults.string(forKey: "k")
        defaults.removeObject(forKey: "k")
        XCTAssertEqual(defaults.setCalls.count, 1)
        XCTAssertEqual(defaults.getCalls.count, 1)
        XCTAssertEqual(defaults.removeCalls.count, 1)
    }

    // MARK: - TestFactories

    func testMakeConfigDefaults() {
        let config = TestFactories.makeConfig()
        XCTAssertEqual(config.appKey, "pk_test_key_123")
        XCTAssertEqual(config.debug, true)
        XCTAssertEqual(config.environment, .sandbox)
    }

    func testMakeConfigCustom() {
        let config = TestFactories.makeConfig(appKey: "pk_custom", debug: false, environment: .production)
        XCTAssertEqual(config.appKey, "pk_custom")
        XCTAssertEqual(config.debug, false)
        XCTAssertEqual(config.environment, .production)
    }

    func testMakeProductDefaults() {
        let product = TestFactories.makeProduct()
        XCTAssertEqual(product.productId, "com.test.monthly")
        XCTAssertEqual(product.priceValue, 9.99)
        XCTAssertEqual(product.type, .subscription)
    }

    func testMakeSubscriptionDefaults() {
        let sub = TestFactories.makeSubscription()
        XCTAssertEqual(sub.productId, "com.test.monthly")
        XCTAssertEqual(sub.status, .active)
        XCTAssertNotNil(sub.expiresAt)
        XCTAssertEqual(sub.platform, .ios)
    }

    func testMakePurchaseDefaults() {
        let purchase = TestFactories.makePurchase()
        XCTAssertEqual(purchase.productId, "com.test.monthly")
        XCTAssertFalse(purchase.transactionId.isEmpty)
        XCTAssertEqual(purchase.platform, .ios)
    }

    func testMakeIdentifyOptionsDefaults() {
        let options = TestFactories.makeIdentifyOptions()
        XCTAssertEqual(options.email, "test@example.com")
    }
}
