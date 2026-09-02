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

    // MARK: field extraction

    func testParse_extractsFbclid() {
        XCTAssertEqual(MetaBridge.parseDeferredAppLink("https://example.com?fbclid=abc123")?.fbclid, "abc123")
    }

    func testParse_extractsTtclid() {
        XCTAssertEqual(MetaBridge.parseDeferredAppLink("https://example.com?ttclid=tiktok_id")?.ttclid, "tiktok_id")
    }

    func testParse_extractsTrackingId() {
        XCTAssertEqual(
            MetaBridge.parseDeferredAppLink("https://example.com?tracking_id=track_abc")?.trackingId,
            "track_abc"
        )
    }

    func testParse_extractsUtmParams() {
        let url = "https://example.com?utm_source=facebook&utm_medium=cpc&utm_campaign=summer"
        let result = MetaBridge.parseDeferredAppLink(url)
        XCTAssertEqual(result?.utmSource, "facebook")
        XCTAssertEqual(result?.utmMedium, "cpc")
        XCTAssertEqual(result?.utmCampaign, "summer")
    }

    func testParse_plusDecodedAsSpace() {
        let url = "https://example.com?utm_campaign=summer+sale&fbclid=fb1"
        XCTAssertEqual(MetaBridge.parseDeferredAppLink(url)?.utmCampaign, "summer sale")
    }

    func testParse_fragmentStrippedBeforeParsing() {
        XCTAssertEqual(MetaBridge.parseDeferredAppLink("https://example.com?fbclid=abc#section")?.fbclid, "abc")
    }

    // MARK: empty/whitespace normalised BEFORE the fallbacks

    func testParse_emptyFieldValue_treatedAsMissing() {
        let result = MetaBridge.parseDeferredAppLink("https://example.com?fbclid=&utm_source=facebook")
        XCTAssertNil(result?.fbclid)
        XCTAssertEqual(result?.utmSource, "facebook")
    }

    func testParse_whitespaceFieldValue_treatedAsMissing() {
        let result = MetaBridge.parseDeferredAppLink("https://example.com?fbclid=+++&utm_source=facebook")
        XCTAssertNil(result?.fbclid)
    }

    /// An empty top-level `fbclid=` must not block the real value nested in target_url.
    func testParse_emptyTopLevelDoesNotBlockInnerValue() {
        let inner = "https://myapp.com/open?fbclid=inner_fb"
        let encoded = inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? inner
        let url = "https://example.com?fbclid=&target_url=\(encoded)"
        XCTAssertEqual(MetaBridge.parseDeferredAppLink(url)?.fbclid, "inner_fb")
    }

    // MARK: target_url nested fallback

    func testParse_fbclidInTargetUrl_extracted() {
        let inner = "https://myapp.com/open?fbclid=inner_fb&utm_source=facebook"
        // Encode with .alphanumerics so `&`/`=`/`:` are percent-escaped (a real deferred
        // app link has the target_url fully encoded); .urlQueryAllowed leaves `&` literal.
        let encoded = inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? inner
        let result = MetaBridge.parseDeferredAppLink("https://example.com?target_url=\(encoded)")
        XCTAssertEqual(result?.fbclid, "inner_fb")
        XCTAssertEqual(result?.utmSource, "facebook")
        XCTAssertEqual(result?.targetUrl, inner)
    }

    func testParse_topLevelFbclidWinsOverInner() {
        let inner = "https://myapp.com/open?fbclid=inner_fb"
        let encoded = inner.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? inner
        let url = "https://example.com?fbclid=top_fb&target_url=\(encoded)"
        XCTAssertEqual(MetaBridge.parseDeferredAppLink(url)?.fbclid, "top_fb")
    }

    /// The inner fallback is GATED on the wrapper having no fbclid: when the wrapper
    /// carries the click ID, the wrapper IS the click and its params are authoritative.
    /// Merging unconditionally let a stale target_url — Meta reuses the destination
    /// across creatives — fill in utm_* that never belonged to this click.
    func testParse_topLevelFbclid_blocksInnerUtmMerge() {
        let inner = "https://myapp.com/open?utm_campaign=stale_campaign"
        let encoded = inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? inner
        let url = "https://example.com?fbclid=top_fb&target_url=\(encoded)"
        let result = MetaBridge.parseDeferredAppLink(url)
        XCTAssertEqual(result?.fbclid, "top_fb")
        XCTAssertNil(result?.utmCampaign, "inner params must not merge once the wrapper carries the click ID")
    }

    func testParse_targetUrlFragmentStrippedBeforeInnerParse() {
        let inner = "https://myapp.com/open?fbclid=abc#section"
        let encoded = inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? inner
        XCTAssertEqual(MetaBridge.parseDeferredAppLink("https://example.com?target_url=\(encoded)")?.fbclid, "abc")
    }

    func testParse_emptyTargetUrl_isIgnored() {
        let result = MetaBridge.parseDeferredAppLink("https://example.com?fbclid=fb1&target_url=")
        XCTAssertNil(result?.targetUrl)
    }

    // MARK: raw / rawReferrer

    func testParse_rawFieldContainsOriginalUrl() {
        let url = "https://example.com?fbclid=abc123"
        XCTAssertEqual(MetaBridge.parseDeferredAppLink(url)?.raw, url)
    }

    func testParse_rawTruncatedAt2048() {
        let url = "https://example.com?fbclid=\(String(repeating: "x", count: 3000))"
        XCTAssertEqual(MetaBridge.parseDeferredAppLink(url)?.raw.count, PaywalloConstants.deferredAppLinkMaxLength)
    }

    /// The wrapper URL is Meta's plumbing; the target is the advertiser's destination,
    /// and that is what the server matches on.
    func testRawReferrerPrefersTheTargetUrl() {
        let inner = "https://myapp.com/open?fbclid=inner_fb"
        let encoded = inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? inner
        let result = MetaBridge.parseDeferredAppLink("https://example.com?target_url=\(encoded)")
        XCTAssertEqual(result?.rawReferrer, inner)
    }

    func testRawReferrerFallsBackToRaw() {
        let url = "https://example.com?fbclid=abc123"
        XCTAssertEqual(MetaBridge.parseDeferredAppLink(url)?.rawReferrer, url)
    }

    func testParse_multipleSignals_allExtracted() {
        let url = "https://example.com?fbclid=fb1&ttclid=tt1&utm_source=facebook&utm_medium=paid"
        let result = MetaBridge.parseDeferredAppLink(url)
        XCTAssertEqual(result?.fbclid, "fb1")
        XCTAssertEqual(result?.ttclid, "tt1")
        XCTAssertEqual(result?.utmSource, "facebook")
        XCTAssertEqual(result?.utmMedium, "paid")
    }

    // MARK: attribution mapping

    /// On iOS the deferred app link IS the install referrer — it must fill the same
    /// `installReferrer*` slots the Play Install Referrer fills on Android.
    func testAttributionInputCarriesTheInstallReferrerSlots() {
        let inner = "https://myapp.com/open?fbclid=inner_fb"
        let encoded = inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? inner
        let raw = "https://example.com?target_url=\(encoded)"
        let input = MetaBridge.parseDeferredAppLink(raw)!.attributionInput()

        XCTAssertEqual(input.fbclid, "inner_fb")
        XCTAssertEqual(input.installReferrerRaw, raw)
        XCTAssertEqual(input.installReferrerSource, "meta_deferred")
        XCTAssertEqual(input.referrer, inner)
    }

    // MARK: fetchDeferredAppLink without FBSDK

    func testFetchDeferredAppLink_withoutFBSDK_returnsNil() async {
        // FBSDK is not linked in the test target — always hits the #else branch → nil
        let result = await MetaBridge.shared.fetchDeferredAppLink()
        XCTAssertNil(result)
    }

    func testFetchDeferredAppLink_cachedAfterFirstCall() async {
        let bridge = MetaBridge.shared
        let first = await bridge.fetchDeferredAppLink()
        let second = await bridge.fetchDeferredAppLink()
        XCTAssertEqual(first, second)
        XCTAssertEqual(bridge.getCachedDeferredAppLink(), first)
    }
}
