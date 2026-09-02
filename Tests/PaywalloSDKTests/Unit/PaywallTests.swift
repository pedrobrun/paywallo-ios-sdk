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
        XCTAssertEqual(msg.messageId, "ready:1000")
    }

    func testMessageId_epochTimestamp_hasNoDecimalPoint() {
        // O RN interpola o número JS sem casa decimal; um "1735689600000.0" aqui daria
        // chave de dedup diferente da do RN para a MESMA mensagem.
        let json = #"{"type":"ready","payload":{"timestamp":1735689600000}}"#
        let msg = PaywallMessageParser.parse(json)!
        XCTAssertEqual(msg.messageId, "ready:1735689600000")
    }

    func testMessageId_fractionalTimestamp_keepsFraction() {
        let json = #"{"type":"ready","payload":{"timestamp":1000.5}}"#
        let msg = PaywallMessageParser.parse(json)!
        XCTAssertEqual(msg.messageId, "ready:1000.5")
    }

    // MARK: - haptic style

    func testParse_hapticStyleMedium_isPreserved() {
        let json = #"{"type":"haptic","payload":{"style":"medium"}}"#
        XCTAssertEqual(PaywallMessageParser.parse(json)?.style, "medium")
    }

    func testParse_hapticStyleHeavy_isPreserved() {
        let json = #"{"type":"haptic","payload":{"style":"heavy"}}"#
        XCTAssertEqual(PaywallMessageParser.parse(json)?.style, "heavy")
    }

    func testParse_hapticStyleInvalid_fallsBackToLight() {
        // O webview pediu vibração: um valor novo/errado não pode virar silêncio.
        let json = #"{"type":"haptic","payload":{"style":"nuclear"}}"#
        XCTAssertEqual(PaywallMessageParser.parse(json)?.style, "light")
    }

    func testParse_hapticStyleNull_fallsBackToLight() {
        let json = #"{"type":"haptic","payload":{"style":null}}"#
        XCTAssertEqual(PaywallMessageParser.parse(json)?.style, "light")
    }

    func testParse_hapticWithoutStyle_isNil() {
        let json = #"{"type":"haptic","payload":{}}"#
        XCTAssertNil(PaywallMessageParser.parse(json)?.style)
    }

    func testParse_noPayload_styleIsNil() {
        let json = #"{"type":"close"}"#
        XCTAssertNil(PaywallMessageParser.parse(json)?.style)
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

    // MARK: - device / user namespaces têm chaves fixas

    func testResolve_deviceUnknownKeyPresentInDict_stillEmpty() {
        // O namespace é contrato com o editor do painel, não um dump do dicionário.
        let context = PaywallVariableResolver.Context(deviceInfo: ["secretToken": "abc"])
        XCTAssertEqual(PaywallVariableResolver.resolve("{{device.secretToken}}", context: context), "")
    }

    func testResolve_deviceFixedKeys() {
        let context = PaywallVariableResolver.Context(
            deviceInfo: ["name": "iPhone do Lucas", "model": "iPhone15,2", "os": "iOS",
                         "osVersion": "17.4", "locale": "pt-BR"]
        )
        let tmpl = "{{device.name}}|{{device.model}}|{{device.os}}|{{device.osVersion}}|{{device.locale}}"
        XCTAssertEqual(
            PaywallVariableResolver.resolve(tmpl, context: context),
            "iPhone do Lucas|iPhone15,2|iOS|17.4|pt-BR"
        )
    }

    func testResolve_userFixedKeys() {
        let context = PaywallVariableResolver.Context(
            userInfo: ["id": "u_1", "name": "Lucas", "email": "l@x.com", "cpf": "000"]
        )
        XCTAssertEqual(PaywallVariableResolver.resolve("{{user.id}}", context: context), "u_1")
        XCTAssertEqual(PaywallVariableResolver.resolve("{{user.email}}", context: context), "l@x.com")
        XCTAssertEqual(PaywallVariableResolver.resolve("{{user.cpf}}", context: context), "")
    }

    // MARK: - customVariables (último fallback antes de "")

    func testResolve_customVariable_isUsedAsFinalFallback() {
        let context = PaywallVariableResolver.Context(customVariables: ["cupom": "BLACK50"])
        XCTAssertEqual(PaywallVariableResolver.resolve("{{cupom}}", context: context), "BLACK50")
    }

    func testResolve_customVariableAbsent_emptyString() {
        let context = PaywallVariableResolver.Context(customVariables: ["cupom": "BLACK50"])
        XCTAssertEqual(PaywallVariableResolver.resolve("{{outro}}", context: context), "")
    }

    func testResolve_knownNamespaceNeverFallsBackToCustom() {
        let context = PaywallVariableResolver.Context(customVariables: ["device.model": "hack"])
        XCTAssertEqual(PaywallVariableResolver.resolve("{{device.model}}", context: context), "")
    }

    // MARK: - Variáveis legadas sem namespace

    func testResolve_legacyDeviceName() {
        let context = PaywallVariableResolver.Context(deviceInfo: ["name": "iPhone do Lucas"])
        XCTAssertEqual(PaywallVariableResolver.resolve("{{device_name}}", context: context), "iPhone do Lucas")
    }

    func testResolve_legacyProductPrice_usesLocalizedPrice() {
        let product = makeFullProduct(price: "9.99", localizedPrice: "R$ 9,99")
        let context = PaywallVariableResolver.Context(selectedProduct: product)
        XCTAssertEqual(PaywallVariableResolver.resolve("{{product_price}}", context: context), "R$ 9,99")
    }

    func testResolve_legacyTrialPeriod() {
        let product = makeFullProduct(freeTrialPeriod: "P7D")
        let context = PaywallVariableResolver.Context(selectedProduct: product)
        XCTAssertEqual(PaywallVariableResolver.resolve("{{trial_period}}", context: context), "P7D")
    }

    func testResolve_legacyProductPrice_noSelected_fallsBackToCustom() {
        let context = PaywallVariableResolver.Context(customVariables: ["product_price": "grátis"])
        XCTAssertEqual(PaywallVariableResolver.resolve("{{product_price}}", context: context), "grátis")
    }

    // MARK: - products.tertiary

    func testResolve_productsTertiary() {
        let product = makeFullProduct(productId: "com.app.lifetime", title: "Lifetime")
        let context = PaywallVariableResolver.Context(tertiaryProduct: product)
        XCTAssertEqual(PaywallVariableResolver.resolve("{{products.tertiary.name}}", context: context), "Lifetime")
        XCTAssertEqual(PaywallVariableResolver.resolve("{{products.tertiary.id}}", context: context), "com.app.lifetime")
    }

    // MARK: - products.hasIntroductoryOffer

    func testResolve_hasIntroductoryOffer_trueWhenAnyProductHasIt() {
        let plain = makeFullProduct(productId: "a")
        let intro = makeFullProduct(productId: "b", introductoryPrice: "R$ 1,99")
        let context = PaywallVariableResolver.Context(primaryProduct: plain, secondaryProduct: intro)
        XCTAssertEqual(
            PaywallVariableResolver.resolve("{{products.hasIntroductoryOffer}}", context: context),
            "true"
        )
    }

    func testResolve_hasIntroductoryOffer_falseWhenNoneHasIt() {
        let context = PaywallVariableResolver.Context(primaryProduct: makeFullProduct())
        XCTAssertEqual(
            PaywallVariableResolver.resolve("{{products.hasIntroductoryOffer}}", context: context),
            "false"
        )
    }

    func testResolve_hasIntroductoryOffer_falseWithNoProducts() {
        XCTAssertEqual(
            PaywallVariableResolver.resolve("{{products.hasIntroductoryOffer}}", context: PaywallVariableResolver.Context()),
            "false"
        )
    }

    // MARK: - Propriedades de produto

    func testResolve_price_usesLocalizedPriceNotRawPrice() {
        // `price` cru é "9.99" — sem símbolo nem moeda; era isso que ia pra tela.
        let product = makeFullProduct(price: "9.99", localizedPrice: "R$ 9,99")
        let context = PaywallVariableResolver.Context(selectedProduct: product)
        XCTAssertEqual(PaywallVariableResolver.resolve("{{products.selected.price}}", context: context), "R$ 9,99")
    }

    func testResolve_pricePerMonth_fallsBackToLocalizedPrice() {
        let product = makeFullProduct(localizedPrice: "R$ 99,00", pricePerMonth: nil)
        let context = PaywallVariableResolver.Context(selectedProduct: product)
        XCTAssertEqual(
            PaywallVariableResolver.resolve("{{products.selected.pricePerMonth}}", context: context),
            "R$ 99,00"
        )
    }

    func testResolve_periodAndRenewalPeriod() {
        let product = makeFullProduct(subscriptionPeriod: "P1M")
        let context = PaywallVariableResolver.Context(selectedProduct: product)
        XCTAssertEqual(PaywallVariableResolver.resolve("{{products.selected.period}}", context: context), "P1M")
        XCTAssertEqual(PaywallVariableResolver.resolve("{{products.selected.renewalPeriod}}", context: context), "P1M")
    }

    func testResolve_trialPeriodAndIntroPrice() {
        let product = makeFullProduct(introductoryPrice: "R$ 1,99", freeTrialPeriod: "P3D")
        let context = PaywallVariableResolver.Context(selectedProduct: product)
        XCTAssertEqual(PaywallVariableResolver.resolve("{{products.selected.trialPeriod}}", context: context), "P3D")
        XCTAssertEqual(PaywallVariableResolver.resolve("{{products.selected.introPrice}}", context: context), "R$ 1,99")
    }

    func testResolve_hasFreeTrialAndHasIntroOffer() {
        let withOffers = makeFullProduct(introductoryPrice: "R$ 1,99", freeTrialPeriod: "P3D")
        let without = makeFullProduct()
        let ctxWith = PaywallVariableResolver.Context(selectedProduct: withOffers)
        let ctxWithout = PaywallVariableResolver.Context(selectedProduct: without)
        XCTAssertEqual(PaywallVariableResolver.resolve("{{products.selected.hasFreeTrial}}", context: ctxWith), "true")
        XCTAssertEqual(PaywallVariableResolver.resolve("{{products.selected.hasIntroOffer}}", context: ctxWith), "true")
        XCTAssertEqual(PaywallVariableResolver.resolve("{{products.selected.hasFreeTrial}}", context: ctxWithout), "false")
        XCTAssertEqual(PaywallVariableResolver.resolve("{{products.selected.hasIntroOffer}}", context: ctxWithout), "false")
    }

    // MARK: - Helper com todos os campos opcionais

    private func makeFullProduct(
        productId: String = "com.app.pro",
        title: String = "Pro",
        price: String = "9.99",
        localizedPrice: String = "$9.99",
        subscriptionPeriod: String? = nil,
        introductoryPrice: String? = nil,
        freeTrialPeriod: String? = nil,
        pricePerMonth: String? = nil
    ) -> Product {
        Product(
            productId: productId,
            title: title,
            description: "Full access",
            price: price,
            priceValue: 9.99,
            currency: "BRL",
            localizedPrice: localizedPrice,
            type: .subscription,
            subscriptionPeriod: subscriptionPeriod,
            introductoryPrice: introductoryPrice,
            introductoryPriceValue: nil,
            freeTrialPeriod: freeTrialPeriod,
            trialDays: nil,
            pricePerMonth: pricePerMonth
        )
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

    // MARK: - Unknown → passa cru (não pode mascarar valor novo)

    func testCanonicalize_unknown_returnsInput() {
        XCTAssertEqual(PaywallCloseReason.canonicalize("whatever"), "whatever")
    }

    func testCanonicalize_empty_returnsInput() {
        XCTAssertEqual(PaywallCloseReason.canonicalize(""), "")
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
