import XCTest
@testable import PaywalloSDK

// MARK: - PaywallMessageParser Tests

final class PaywallMessageParserTests: XCTestCase {

    // MARK: - Allowed types parse successfully

    func testParse_purchase_returnsMessage() {
        let json = #"{"type":"purchase","payload":{"productId":"com.app.monthly"}}"#
        let msg = PaywallMessageParser.parse(json)
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.type, "purchase")
        XCTAssertEqual(msg?.productId, "com.app.monthly")
    }

    func testParse_close_returnsMessage() {
        let json = #"{"type":"close"}"#
        let msg = PaywallMessageParser.parse(json)
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.type, "close")
    }

    func testParse_restore_returnsMessage() {
        let json = #"{"type":"restore"}"#
        let msg = PaywallMessageParser.parse(json)
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.type, "restore")
    }

    func testParse_selectProduct_returnsMessage() {
        let json = #"{"type":"select-product","payload":{"productId":"com.app.annual"}}"#
        let msg = PaywallMessageParser.parse(json)
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.type, "select-product")
        XCTAssertEqual(msg?.productId, "com.app.annual")
    }

    func testParse_openURL_returnsMessage() {
        let json = #"{"type":"open-url","payload":{"url":"https://example.com/terms"}}"#
        let msg = PaywallMessageParser.parse(json)
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.type, "open-url")
        XCTAssertEqual(msg?.url, "https://example.com/terms")
    }

    func testParse_ready_returnsMessage() {
        let json = #"{"type":"ready"}"#
        let msg = PaywallMessageParser.parse(json)
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.type, "ready")
    }

    // MARK: - Invalid type → nil

    func testParse_unknownType_returnsNil() {
        let json = #"{"type":"hack"}"#
        XCTAssertNil(PaywallMessageParser.parse(json))
    }

    func testParse_emptyType_returnsNil() {
        let json = #"{"type":""}"#
        XCTAssertNil(PaywallMessageParser.parse(json))
    }

    func testParse_missingType_returnsNil() {
        let json = #"{"productId":"com.app.monthly"}"#
        XCTAssertNil(PaywallMessageParser.parse(json))
    }

    func testParse_invalidJSON_returnsNil() {
        XCTAssertNil(PaywallMessageParser.parse("not json"))
    }

    func testParse_emptyString_returnsNil() {
        XCTAssertNil(PaywallMessageParser.parse(""))
    }

    // MARK: - Field validation

    func testParse_withTimestamp_parsesTimestamp() {
        let json = #"{"type":"ready","payload":{"timestamp":1234567890.5}}"#
        let msg = PaywallMessageParser.parse(json)
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.timestamp, 1234567890.5)
    }

    func testParse_withoutProductId_productIdNil() {
        let json = #"{"type":"close"}"#
        let msg = PaywallMessageParser.parse(json)
        XCTAssertNil(msg?.productId)
    }

    func testParse_withoutURL_urlNil() {
        let json = #"{"type":"close"}"#
        let msg = PaywallMessageParser.parse(json)
        XCTAssertNil(msg?.url)
    }

    // MARK: - messageId derivation

    func testMessageId_withProductId_usesTypeProductId() {
        let json = #"{"type":"purchase","payload":{"productId":"com.app.pro"}}"#
        let msg = PaywallMessageParser.parse(json)!
        XCTAssertEqual(msg.messageId, "purchase:com.app.pro")
    }

    func testMessageId_withURL_usesTypeURL() {
        let json = #"{"type":"open-url","payload":{"url":"https://example.com"}}"#
        let msg = PaywallMessageParser.parse(json)!
        XCTAssertEqual(msg.messageId, "open-url:https://example.com")
    }

    func testMessageId_withTimestamp_usesTypeTimestamp() {
        let json = #"{"type":"ready","payload":{"timestamp":1000.0}}"#
        let msg = PaywallMessageParser.parse(json)!
        XCTAssertEqual(msg.messageId, "ready:1000.0")
    }

    func testMessageId_noPayload_usesTypeColon() {
        let json = #"{"type":"close"}"#
        let msg = PaywallMessageParser.parse(json)!
        XCTAssertEqual(msg.messageId, "close:")
    }

    func testMessageId_productIdTakesPrecedenceOverURL() {
        let json = #"{"type":"purchase","payload":{"productId":"com.app.x","url":"https://x.com"}}"#
        let msg = PaywallMessageParser.parse(json)!
        XCTAssertEqual(msg.messageId, "purchase:com.app.x")
    }
}

// MARK: - PaywallVariableResolver Tests

final class PaywallVariableResolverTests: XCTestCase {

    private func makeProduct(
        id: String = "com.app.pro",
        title: String = "Pro Monthly",
        price: String = "$9.99",
        priceValue: Double = 9.99,
        pricePerMonth: String? = "$9.99",
        trialDays: Int? = nil,
        savings: String? = nil
    ) -> Product {
        Product(
            productId: id,
            title: title,
            description: "Full access",
            price: price,
            priceValue: priceValue,
            currency: "USD",
            localizedPrice: price,
            type: .subscription,
            subscriptionPeriod: nil,
            introductoryPrice: nil,
            introductoryPriceValue: nil,
            freeTrialPeriod: nil,
            trialDays: trialDays,
            pricePerMonth: pricePerMonth,
            savings: savings
        )
    }

    // MARK: - Device namespace

    func testResolve_deviceNamespace() {
        let context = PaywallVariableResolver.Context(
            deviceInfo: ["model": "iPhone 15", "os": "17.0"]
        )
        let result = PaywallVariableResolver.resolve("Device: {{device.model}}", context: context)
        XCTAssertEqual(result, "Device: iPhone 15")
    }

    func testResolve_deviceUnknownKey_emptyString() {
        let context = PaywallVariableResolver.Context(deviceInfo: [:])
        let result = PaywallVariableResolver.resolve("{{device.unknown}}", context: context)
        XCTAssertEqual(result, "")
    }

    // MARK: - User namespace

    func testResolve_userNamespace() {
        let context = PaywallVariableResolver.Context(
            userInfo: ["name": "Lucas", "email": "lucas@example.com"]
        )
        let result = PaywallVariableResolver.resolve("Hello {{user.name}}!", context: context)
        XCTAssertEqual(result, "Hello Lucas!")
    }

    func testResolve_userUnknownKey_emptyString() {
        let context = PaywallVariableResolver.Context(userInfo: [:])
        let result = PaywallVariableResolver.resolve("{{user.phone}}", context: context)
        XCTAssertEqual(result, "")
    }

    // MARK: - Products namespace

    func testResolve_productsSelected_id() {
        let product = makeProduct(id: "com.app.pro")
        let context = PaywallVariableResolver.Context(selectedProduct: product)
        let result = PaywallVariableResolver.resolve("{{products.selected.id}}", context: context)
        XCTAssertEqual(result, "com.app.pro")
    }

    func testResolve_productsPrimary_name() {
        let product = makeProduct(title: "Annual Plan")
        let context = PaywallVariableResolver.Context(primaryProduct: product)
        let result = PaywallVariableResolver.resolve("{{products.primary.name}}", context: context)
        XCTAssertEqual(result, "Annual Plan")
    }

    func testResolve_productsSecondary_price() {
        let product = makeProduct(price: "$4.99")
        let context = PaywallVariableResolver.Context(secondaryProduct: product)
        let result = PaywallVariableResolver.resolve("{{products.secondary.price}}", context: context)
        XCTAssertEqual(result, "$4.99")
    }

    func testResolve_productsPrimary_pricePerMonth() {
        let product = makeProduct(pricePerMonth: "$3.33")
        let context = PaywallVariableResolver.Context(primaryProduct: product)
        let result = PaywallVariableResolver.resolve("{{products.primary.pricePerMonth}}", context: context)
        XCTAssertEqual(result, "$3.33")
    }

    func testResolve_productsSelected_noProduct_emptyString() {
        let context = PaywallVariableResolver.Context()
        let result = PaywallVariableResolver.resolve("{{products.selected.price}}", context: context)
        XCTAssertEqual(result, "")
    }

    // MARK: - Legacy aliases

    func testResolve_selectedProductAlias_id() {
        let product = makeProduct(id: "legacy.id")
        let context = PaywallVariableResolver.Context(selectedProduct: product)
        let result = PaywallVariableResolver.resolve("{{selectedProduct.id}}", context: context)
        XCTAssertEqual(result, "legacy.id")
    }

    func testResolve_primaryProductAlias_price() {
        let product = makeProduct(price: "$12.99")
        let context = PaywallVariableResolver.Context(primaryProduct: product)
        let result = PaywallVariableResolver.resolve("{{primaryProduct.price}}", context: context)
        XCTAssertEqual(result, "$12.99")
    }

    func testResolve_secondaryProductAlias_name() {
        let product = makeProduct(title: "Basic")
        let context = PaywallVariableResolver.Context(secondaryProduct: product)
        let result = PaywallVariableResolver.resolve("{{secondaryProduct.name}}", context: context)
        XCTAssertEqual(result, "Basic")
    }

    // MARK: - Unknown paths → empty string

    func testResolve_unknownNamespace_emptyString() {
        let context = PaywallVariableResolver.Context()
        let result = PaywallVariableResolver.resolve("{{foo.bar}}", context: context)
        XCTAssertEqual(result, "")
    }

    func testResolve_unknownProductProperty_emptyString() {
        let product = makeProduct()
        let context = PaywallVariableResolver.Context(selectedProduct: product)
        let result = PaywallVariableResolver.resolve("{{products.selected.unknownProp}}", context: context)
        XCTAssertEqual(result, "")
    }

    // MARK: - Multiple variables

    func testResolve_multipleVariables() {
        let product = makeProduct(title: "Pro", price: "$9.99")
        let context = PaywallVariableResolver.Context(
            userInfo: ["name": "Alice"],
            selectedProduct: product
        )
        let tmpl = "Hi {{user.name}}, get {{products.selected.name}} for {{products.selected.price}}"
        let result = PaywallVariableResolver.resolve(tmpl, context: context)
        XCTAssertEqual(result, "Hi Alice, get Pro for $9.99")
    }

    // MARK: - No variables

    func testResolve_noVariables_returnsOriginal() {
        let context = PaywallVariableResolver.Context()
        let result = PaywallVariableResolver.resolve("Hello World!", context: context)
        XCTAssertEqual(result, "Hello World!")
    }
}

// MARK: - PaywallCloseReason Tests

final class PaywallCloseReasonTests: XCTestCase {

    // MARK: - Legacy → canonical

    func testCanonicalize_dismissed_returnsDismiss() {
        XCTAssertEqual(PaywallCloseReason.canonicalize("dismissed"), "dismiss")
    }

    func testCanonicalize_purchased_returnsPurchase() {
        XCTAssertEqual(PaywallCloseReason.canonicalize("purchased"), "purchase")
    }

    func testCanonicalize_backgrounded_returnsDismiss() {
        XCTAssertEqual(PaywallCloseReason.canonicalize("backgrounded"), "dismiss")
    }

    func testCanonicalize_timeout_returnsTimeout() {
        XCTAssertEqual(PaywallCloseReason.canonicalize("timeout"), "timeout")
    }

    // MARK: - Already canonical → pass-through

    func testCanonicalize_dismiss_returnsDismiss() {
        XCTAssertEqual(PaywallCloseReason.canonicalize("dismiss"), "dismiss")
    }

    func testCanonicalize_cta_returnsCta() {
        XCTAssertEqual(PaywallCloseReason.canonicalize("cta"), "cta")
    }

    func testCanonicalize_purchase_returnsPurchase() {
        XCTAssertEqual(PaywallCloseReason.canonicalize("purchase"), "purchase")
    }

    func testCanonicalize_error_returnsError() {
        XCTAssertEqual(PaywallCloseReason.canonicalize("error"), "error")
    }

    // MARK: - Unknown → default dismiss

    func testCanonicalize_unknown_returnsDismiss() {
        XCTAssertEqual(PaywallCloseReason.canonicalize("whatever"), "dismiss")
    }

    func testCanonicalize_empty_returnsDismiss() {
        XCTAssertEqual(PaywallCloseReason.canonicalize(""), "dismiss")
    }

    // MARK: - isCanonical

    func testIsCanonical_dismiss_true() {
        XCTAssertTrue(PaywallCloseReason.isCanonical("dismiss"))
    }

    func testIsCanonical_cta_true() {
        XCTAssertTrue(PaywallCloseReason.isCanonical("cta"))
    }

    func testIsCanonical_purchase_true() {
        XCTAssertTrue(PaywallCloseReason.isCanonical("purchase"))
    }

    func testIsCanonical_error_true() {
        XCTAssertTrue(PaywallCloseReason.isCanonical("error"))
    }

    func testIsCanonical_timeout_true() {
        XCTAssertTrue(PaywallCloseReason.isCanonical("timeout"))
    }

    func testIsCanonical_legacy_false() {
        XCTAssertFalse(PaywallCloseReason.isCanonical("dismissed"))
        XCTAssertFalse(PaywallCloseReason.isCanonical("backgrounded"))
        XCTAssertFalse(PaywallCloseReason.isCanonical("purchased"))
    }
}

// MARK: - PaywallHeartbeat Duration Tests

final class PaywallHeartbeatTests: XCTestCase {

    // MARK: - duration_s calculation

    func testDurationS_zeroElapsed_returnsZero() {
        let ts = 1000000.0
        let result = PaywallHeartbeat.calculateDurationS(presentedAt: ts, lastSeen: ts)
        XCTAssertEqual(result, 0.0)
    }

    func testDurationS_exactlyOneSecond_returnsOne() {
        let result = PaywallHeartbeat.calculateDurationS(presentedAt: 0, lastSeen: 1000)
        XCTAssertEqual(result, 1.0)
    }

    func testDurationS_1500ms_roundsToTwo() {
        // 1500ms / 1000 = 1.5 → rounds to 2
        let result = PaywallHeartbeat.calculateDurationS(presentedAt: 0, lastSeen: 1500)
        XCTAssertEqual(result, 2.0)
    }

    func testDurationS_1499ms_roundsToOne() {
        // 1499ms / 1000 = 1.499 → rounds to 1
        let result = PaywallHeartbeat.calculateDurationS(presentedAt: 0, lastSeen: 1499)
        XCTAssertEqual(result, 1.0)
    }

    func testDurationS_negative_returnsZero() {
        // lastSeen < presentedAt → negative raw → clamped to 0
        let result = PaywallHeartbeat.calculateDurationS(presentedAt: 5000, lastSeen: 1000)
        XCTAssertEqual(result, 0.0)
    }

    func testDurationS_largeValue_roundsCorrectly() {
        // 30 minutes = 1800000ms → 1800s exactly
        let result = PaywallHeartbeat.calculateDurationS(presentedAt: 0, lastSeen: 1_800_000)
        XCTAssertEqual(result, 1800.0)
    }

    func testDurationS_750ms_roundsToOne() {
        // 750ms → 0.75 → rounds to 1
        let result = PaywallHeartbeat.calculateDurationS(presentedAt: 0, lastSeen: 750)
        XCTAssertEqual(result, 1.0)
    }

    func testDurationS_250ms_roundsToZero() {
        // 250ms → 0.25 → rounds to 0
        let result = PaywallHeartbeat.calculateDurationS(presentedAt: 0, lastSeen: 250)
        XCTAssertEqual(result, 0.0)
    }

    // MARK: - Crash recovery via storage

    func testCrashRecovery_noSnapshot_noCallback() {
        let suiteName = "com.paywallo.sdk.heartbeat.test.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        let storage = NativeStorage(defaults: suite)

        var callbackInvoked = false
        _ = PaywallHeartbeat(storage: storage) { _, _ in
            callbackInvoked = true
        }

        XCTAssertFalse(callbackInvoked)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    func testCrashRecovery_withSnapshot_invokesCallback() {
        let suiteName = "com.paywallo.sdk.heartbeat.test.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        let storage = NativeStorage(defaults: suite)

        // Plant a heartbeat snapshot simulating a crash
        let snapshot = HeartbeatSnapshot(
            paywallId: "pw_crash_test",
            placement: "main",
            presentedAt: 0,
            lastSeen: 5000,
            variantKey: nil,
            variantId: nil,
            campaignId: nil
        )
        if let data = try? JSONEncoder().encode(snapshot),
           let raw = String(data: data, encoding: .utf8) {
            storage.set(PaywalloConstants.paywallHeartbeatKey, value: raw)
        }

        var recoveredSnapshot: HeartbeatSnapshot?
        var recoveredDuration: Double?

        _ = PaywallHeartbeat(storage: storage) { snapshot, duration in
            recoveredSnapshot = snapshot
            recoveredDuration = duration
        }

        XCTAssertEqual(recoveredSnapshot?.paywallId, "pw_crash_test")
        XCTAssertEqual(recoveredDuration, 5.0)  // 5000ms → 5s

        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    func testCrashRecovery_snapshotCleared() {
        let suiteName = "com.paywallo.sdk.heartbeat.test.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        let storage = NativeStorage(defaults: suite)

        let snapshot = HeartbeatSnapshot(paywallId: "pw_x", placement: "test", presentedAt: 0, lastSeen: 1000, variantKey: nil, variantId: nil, campaignId: nil)
        if let data = try? JSONEncoder().encode(snapshot),
           let raw = String(data: data, encoding: .utf8) {
            storage.set(PaywalloConstants.paywallHeartbeatKey, value: raw)
        }

        _ = PaywallHeartbeat(storage: storage, onCrashRecovery: nil)

        // After init, snapshot should be cleared
        let remaining = storage.get(PaywalloConstants.paywallHeartbeatKey)
        XCTAssertNil(remaining)

        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}
