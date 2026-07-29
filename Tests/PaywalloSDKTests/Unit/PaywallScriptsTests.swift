import XCTest
@testable import PaywalloSDK

// MARK: - PaywallScriptsTests

final class PaywallScriptsTests: XCTestCase {

    // MARK: - buildPaywallInjectionScript

    func testBuildPaywallInjectionScript_containsReactNativeWebViewBridge() {
        let script = PaywallScripts.buildPaywallInjectionScript()
        XCTAssertTrue(script.contains("window.ReactNativeWebView"), "Must install the ReactNativeWebView shim")
    }

    func testBuildPaywallInjectionScript_bridgePostMessageDelegatesToWebKit() {
        let script = PaywallScripts.buildPaywallInjectionScript()
        XCTAssertTrue(script.contains("window.webkit.messageHandlers.paywallo.postMessage(data)"))
    }

    func testBuildPaywallInjectionScript_pollsForReceiveNativeMessage() {
        let script = PaywallScripts.buildPaywallInjectionScript()
        XCTAssertTrue(script.contains("window.receiveNativeMessage"))
        XCTAssertTrue(script.contains("pollForReceiver"))
    }

    func testBuildPaywallInjectionScript_maxAttemptsIs50() {
        let script = PaywallScripts.buildPaywallInjectionScript()
        XCTAssertTrue(script.contains("maxAttempts = 50"))
    }

    func testBuildPaywallInjectionScript_pollIntervalIs100ms() {
        let script = PaywallScripts.buildPaywallInjectionScript()
        XCTAssertTrue(script.contains("pollInterval = 100"))
    }

    func testBuildPaywallInjectionScript_isIIFE() {
        let script = PaywallScripts.buildPaywallInjectionScript()
        XCTAssertTrue(script.contains("(function()"), "Must be wrapped in an IIFE")
    }

    // MARK: - buildPaywallDataScript

    func testBuildPaywallDataScript_containsReceiveNativeMessageCall() {
        let product = makeProduct()
        let script = PaywallScripts.buildPaywallDataScript(
            craftData: "{}",
            products: [product],
            primaryProductId: nil,
            secondaryProductId: nil
        )
        XCTAssertTrue(script.contains("window.receiveNativeMessage(d)"))
    }

    func testBuildPaywallDataScript_messageTypeIsPaywall() {
        let script = PaywallScripts.buildPaywallDataScript(
            craftData: "{}",
            products: [],
            primaryProductId: nil,
            secondaryProductId: nil
        )
        XCTAssertTrue(script.contains("type:\"paywall\""))
    }

    func testBuildPaywallDataScript_includesCraftData() {
        let craftData = #"{"layout":"v2"}"#
        let script = PaywallScripts.buildPaywallDataScript(
            craftData: craftData,
            products: [],
            primaryProductId: nil,
            secondaryProductId: nil
        )
        // craftData is JS-escaped and injected as a string
        XCTAssertTrue(script.contains("{\\\"layout\\\":\\\"v2\\\"}"))
    }

    func testBuildPaywallDataScript_primaryProductIdIsNull_whenNil() {
        let script = PaywallScripts.buildPaywallDataScript(
            craftData: "{}",
            products: [],
            primaryProductId: nil,
            secondaryProductId: nil
        )
        XCTAssertTrue(script.contains("primaryProductId:null"))
    }

    func testBuildPaywallDataScript_primaryProductIdIsQuoted_whenProvided() {
        let script = PaywallScripts.buildPaywallDataScript(
            craftData: "{}",
            products: [],
            primaryProductId: "com.app.monthly",
            secondaryProductId: nil
        )
        XCTAssertTrue(script.contains("primaryProductId:\"com.app.monthly\""))
    }

    func testBuildPaywallDataScript_secondaryProductIdIsNull_whenNil() {
        let script = PaywallScripts.buildPaywallDataScript(
            craftData: "{}",
            products: [],
            primaryProductId: nil,
            secondaryProductId: nil
        )
        XCTAssertTrue(script.contains("secondaryProductId:null"))
    }

    func testBuildPaywallDataScript_secondaryProductIdIsQuoted_whenProvided() {
        let script = PaywallScripts.buildPaywallDataScript(
            craftData: "{}",
            products: [],
            primaryProductId: nil,
            secondaryProductId: "com.app.annual"
        )
        XCTAssertTrue(script.contains("secondaryProductId:\"com.app.annual\""))
    }

    func testBuildPaywallDataScript_returnsTrue_atEnd() {
        let script = PaywallScripts.buildPaywallDataScript(
            craftData: "{}",
            products: [],
            primaryProductId: nil,
            secondaryProductId: nil
        )
        XCTAssertTrue(script.hasSuffix("true;"), "Script must end with 'true;' for WKWebView eval")
    }

    func testBuildPaywallDataScript_pollsUpTo50Times() {
        let script = PaywallScripts.buildPaywallDataScript(
            craftData: "{}",
            products: [],
            primaryProductId: nil,
            secondaryProductId: nil
        )
        XCTAssertTrue(script.contains("m=50"))
    }

    // MARK: - buildPaywallDataScript products encoding (camelCase)

    func testBuildPaywallDataScript_encodesProductsInCamelCase() {
        let product = makeProduct(productId: "com.test.pro", localizedPrice: "$9.99")
        let script = PaywallScripts.buildPaywallDataScript(
            craftData: "{}",
            products: [product],
            primaryProductId: nil,
            secondaryProductId: nil
        )
        // camelCase key must be present
        XCTAssertTrue(script.contains("\"productId\""), "Products JSON must use camelCase 'productId'")
        XCTAssertTrue(script.contains("\"localizedPrice\""), "Products JSON must use camelCase 'localizedPrice'")
        // snake_case must NOT be present
        XCTAssertFalse(script.contains("\"product_id\""), "Products JSON must NOT use snake_case 'product_id'")
        XCTAssertFalse(script.contains("\"localized_price\""), "Products JSON must NOT use snake_case 'localized_price'")
    }

    func testBuildPaywallDataScript_emptyProducts_encodesEmptyArray() {
        let script = PaywallScripts.buildPaywallDataScript(
            craftData: "{}",
            products: [],
            primaryProductId: nil,
            secondaryProductId: nil
        )
        XCTAssertTrue(script.contains("products:[]"))
    }

    func testBuildPaywallDataScript_multipleProducts_encodedAll() {
        let p1 = makeProduct(productId: "com.test.monthly")
        let p2 = makeProduct(productId: "com.test.annual")
        let script = PaywallScripts.buildPaywallDataScript(
            craftData: "{}",
            products: [p1, p2],
            primaryProductId: nil,
            secondaryProductId: nil
        )
        XCTAssertTrue(script.contains("com.test.monthly"))
        XCTAssertTrue(script.contains("com.test.annual"))
    }

    func testBuildPaywallDataScript_craftDataWithSpecialChars_escaped() {
        // Newlines and quotes in craftData must be JS-escaped
        let craftData = "line1\nline2"
        let script = PaywallScripts.buildPaywallDataScript(
            craftData: craftData,
            products: [],
            primaryProductId: nil,
            secondaryProductId: nil
        )
        XCTAssertTrue(script.contains("\\n"), "Newline must be escaped as \\n in the JS string")
        XCTAssertFalse(script.contains("\nline2"), "Raw newline must not appear inside the JS string literal")
    }

    // MARK: - buildPurchaseStateScript

    func testBuildPurchaseStateScript_isPurchasingTrue_containsTrue() {
        let script = PaywallScripts.buildPurchaseStateScript(isPurchasing: true)
        XCTAssertTrue(script.contains("isPurchasing:true"))
    }

    func testBuildPurchaseStateScript_isPurchasingFalse_containsFalse() {
        let script = PaywallScripts.buildPurchaseStateScript(isPurchasing: false)
        XCTAssertTrue(script.contains("isPurchasing:false"))
    }

    func testBuildPurchaseStateScript_typeIsPurchaseState() {
        let script = PaywallScripts.buildPurchaseStateScript(isPurchasing: true)
        XCTAssertTrue(script.contains("type:\"purchaseState\""))
    }

    func testBuildPurchaseStateScript_callsReceiveNativeMessage() {
        let script = PaywallScripts.buildPurchaseStateScript(isPurchasing: true)
        XCTAssertTrue(script.contains("window.receiveNativeMessage"))
    }

    func testBuildPurchaseStateScript_returnsTrueAtEnd() {
        let script = PaywallScripts.buildPurchaseStateScript(isPurchasing: false)
        XCTAssertTrue(script.hasSuffix("true;"))
    }

    // MARK: - Helpers

    private func makeProduct(
        productId: String = "com.test.monthly",
        localizedPrice: String = "$9.99"
    ) -> Product {
        Product(
            productId: productId,
            title: "Test Plan",
            description: "desc",
            price: "9.99",
            priceValue: 9.99,
            currency: "USD",
            localizedPrice: localizedPrice,
            type: .subscription
        )
    }
}
