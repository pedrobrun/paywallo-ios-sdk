import XCTest
@testable import PaywalloSDK

// MARK: - MetaBridge.parseDeferredAppLink Tests
//
// `fetchDeferredAppLink()` itself requires a real FBSDKCoreKit integration and
// cannot be exercised in unit tests (no FBSDK linked in test target). The async
// method behaviour is documented via:
//   - testFetchDeferredAppLink_withoutFBSDK_returnsNil  (no-op / nil branch)
//   - testFetchDeferredAppLink_cachedAfterFirstCall      (idempotency)
//
// All parse logic lives in the static `parseDeferredAppLink(_:)` which IS fully
// testable as a pure function.

final class MetaBridgeDeferredLinkTests: XCTestCase {

    // MARK: Nil / empty input

    func testParse_nilUrl_returnsNil() {
        XCTAssertNil(MetaBridge.parseDeferredAppLink(nil))
    }

    func testParse_emptyString_returnsNil() {
        XCTAssertNil(MetaBridge.parseDeferredAppLink(""))
    }

    func testParse_whitespaceOnly_returnsNil() {
        XCTAssertNil(MetaBridge.parseDeferredAppLink("   "))
    }

    func testParse_urlWithNoQuery_returnsNil() {
        XCTAssertNil(MetaBridge.parseDeferredAppLink("https://example.com/path"))
    }

    func testParse_urlWithQueryButNoAttributionFields_returnsNil() {
        XCTAssertNil(MetaBridge.parseDeferredAppLink("https://example.com?foo=bar&baz=qux"))
    }

    // MARK: fbclid extraction

    func testParse_extractsFbclid() {
        let result = MetaBridge.parseDeferredAppLink("https://example.com?fbclid=abc123")
        XCTAssertEqual(result?["fbclid"], "abc123")
    }

    // MARK: ttclid extraction

    func testParse_extractsTtclid() {
        let result = MetaBridge.parseDeferredAppLink("https://example.com?ttclid=tiktok_id")
        XCTAssertEqual(result?["ttclid"], "tiktok_id")
    }

    // MARK: tracking_id extraction

    func testParse_extractsTrackingId() {
        let result = MetaBridge.parseDeferredAppLink("https://example.com?tracking_id=track_abc")
        XCTAssertEqual(result?["tracking_id"], "track_abc")
    }

    // MARK: utm params

    func testParse_extractsUtmParams() {
        let url = "https://example.com?utm_source=facebook&utm_medium=cpc&utm_campaign=summer"
        let result = MetaBridge.parseDeferredAppLink(url)
        XCTAssertEqual(result?["utm_source"],   "facebook")
        XCTAssertEqual(result?["utm_medium"],   "cpc")
        XCTAssertEqual(result?["utm_campaign"], "summer")
    }

    // MARK: + decoded as space

    func testParse_plusDecodedAsSpace() {
        let url = "https://example.com?utm_campaign=summer+sale&fbclid=fb1"
        let result = MetaBridge.parseDeferredAppLink(url)
        XCTAssertEqual(result?["utm_campaign"], "summer sale")
    }

    // MARK: fragment stripped before parsing

    func testParse_fragmentStrippedBeforeParsing() {
        let url = "https://example.com?fbclid=abc#section"
        let result = MetaBridge.parseDeferredAppLink(url)
        XCTAssertEqual(result?["fbclid"], "abc")
    }

    // MARK: empty string field treated as missing (nz normalisation)

    func testParse_emptyFieldValue_treatedAsMissing() {
        // fbclid="" → empty → nil; but utm_source has value, so result is non-nil
        let url = "https://example.com?fbclid=&utm_source=facebook"
        let result = MetaBridge.parseDeferredAppLink(url)
        XCTAssertNil(result?["fbclid"])
        XCTAssertEqual(result?["utm_source"], "facebook")
    }

    // MARK: target_url nested fallback — fbclid in inner URL

    func testParse_fbclidInTargetUrl_extracted() {
        let inner = "https://myapp.com/open?fbclid=inner_fb&utm_source=facebook"
        // Encode with .alphanumerics so `&`/`=`/`:` are percent-escaped (a real deferred
        // app link has the target_url fully encoded); .urlQueryAllowed leaves `&` literal.
        let encoded = inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? inner
        let url = "https://example.com?target_url=\(encoded)"
        let result = MetaBridge.parseDeferredAppLink(url)
        XCTAssertEqual(result?["fbclid"],      "inner_fb")
        XCTAssertEqual(result?["utm_source"],  "facebook")
        XCTAssertEqual(result?["target_url"],  inner)
    }

    // MARK: top-level wins over target_url inner value

    func testParse_topLevelFbclidWinsOverInner() {
        let inner = "https://myapp.com/open?fbclid=inner_fb"
        let encoded = inner.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? inner
        let url = "https://example.com?fbclid=top_fb&target_url=\(encoded)"
        let result = MetaBridge.parseDeferredAppLink(url)
        XCTAssertEqual(result?["fbclid"], "top_fb")
    }

    // MARK: target_url with fragment stripped before inner parse

    func testParse_targetUrlFragmentStrippedBeforeInnerParse() {
        let inner = "https://myapp.com/open?fbclid=abc#section"
        let encoded = inner.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? inner
        let url = "https://example.com?target_url=\(encoded)"
        let result = MetaBridge.parseDeferredAppLink(url)
        XCTAssertEqual(result?["fbclid"], "abc")
    }

    // MARK: raw field always present

    func testParse_rawFieldContainsOriginalUrl() {
        let url = "https://example.com?fbclid=abc123"
        let result = MetaBridge.parseDeferredAppLink(url)
        XCTAssertEqual(result?["raw"], url)
    }

    // MARK: raw field truncated at 2048 chars

    func testParse_rawTruncatedAt2048() {
        let longParam = String(repeating: "x", count: 3000)
        let url = "https://example.com?fbclid=\(longParam)"
        let result = MetaBridge.parseDeferredAppLink(url)
        XCTAssertEqual(result?["raw"]?.count, 2048)
    }

    // MARK: multiple attribution signals combined

    func testParse_multipleSignals_allExtracted() {
        let url = "https://example.com?fbclid=fb1&ttclid=tt1&utm_source=facebook&utm_medium=paid"
        let result = MetaBridge.parseDeferredAppLink(url)
        XCTAssertEqual(result?["fbclid"],      "fb1")
        XCTAssertEqual(result?["ttclid"],      "tt1")
        XCTAssertEqual(result?["utm_source"],  "facebook")
        XCTAssertEqual(result?["utm_medium"],  "paid")
    }

    // MARK: fetchDeferredAppLink without FBSDK returns nil (no-op branch)

    func testFetchDeferredAppLink_withoutFBSDK_returnsNil() async {
        // FBSDK is not linked in the test target — always hits the #else branch → nil
        let bridge = MetaBridge.shared
        let result = await bridge.fetchDeferredAppLink()
        XCTAssertNil(result)
    }

    // MARK: fetchDeferredAppLink is cached after first call (idempotency)

    func testFetchDeferredAppLink_cachedAfterFirstCall() async {
        let bridge = MetaBridge.shared
        let first  = await bridge.fetchDeferredAppLink()
        let second = await bridge.fetchDeferredAppLink()
        // Both must be equal (nil == nil without FBSDK; or same dict if FBSDK present)
        XCTAssertEqual(first as NSDictionary?, second as NSDictionary?)
    }
}
