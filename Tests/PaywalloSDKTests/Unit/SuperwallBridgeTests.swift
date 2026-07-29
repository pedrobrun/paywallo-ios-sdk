import XCTest
@testable import PaywalloSDK

// MARK: - SuperwallBridgeTests
//
// Testa a lógica pura do SuperwallBridge:
//   - buildSuperwallAttributes  (mapeamento de campos pw_*)
//   - deriveIsPaid              (detecção de aquisição paga)
//   - deriveAdNetwork           (rede de anúncios mais forte)
//   - mapDismissToCloseReason   (mapeamento de dismiss → close_reason)
//
// A integração com SuperwallKit real não é testável em unit (requer SDK configurado
// + runtime iOS com SuperwallKit linkado). Para validar a integração completa, use
// um app-host de testes com SuperwallKit presente.

final class SuperwallBridgeTests: XCTestCase {

    // MARK: - buildSuperwallAttributes — nil attribution

    func testBuildAttributes_nilAttribution_returnsPaidFalse() {
        let attrs = swBuildSuperwallAttributes(nil)
        XCTAssertEqual(attrs["pw_is_paid"] as? Bool, false)
        XCTAssertEqual(attrs.count, 1)
    }

    // MARK: - buildSuperwallAttributes — organic (sem click IDs)

    func testBuildAttributes_organic_isPaidFalse() {
        let a = makeAttribution(utmSource: "newsletter", utmMedium: "email")
        let attrs = swBuildSuperwallAttributes(a)
        XCTAssertEqual(attrs["pw_is_paid"] as? Bool, false)
        XCTAssertEqual(attrs["pw_utm_source"] as? String, "newsletter")
        XCTAssertEqual(attrs["pw_utm_medium"] as? String, "email")
    }

    // MARK: - buildSuperwallAttributes — paid via fbclid

    func testBuildAttributes_fbclid_isPaidTrue_networkMeta() {
        let a = makeAttribution(utmSource: "fb", fbclid: "abc123")
        let attrs = swBuildSuperwallAttributes(a)
        XCTAssertEqual(attrs["pw_is_paid"] as? Bool, true)
        XCTAssertEqual(attrs["pw_ad_network"] as? String, "meta")
        XCTAssertEqual(attrs["pw_fbclid"] as? String, "abc123")
    }

    // MARK: - buildSuperwallAttributes — paid via ttclid

    func testBuildAttributes_ttclid_isPaidTrue_networkTiktok() {
        let a = makeAttribution(ttclid: "tt999")
        let attrs = swBuildSuperwallAttributes(a)
        XCTAssertEqual(attrs["pw_is_paid"] as? Bool, true)
        XCTAssertEqual(attrs["pw_ad_network"] as? String, "tiktok")
    }

    // MARK: - buildSuperwallAttributes — paid via gclid

    func testBuildAttributes_gclid_isPaidTrue_networkGoogle() {
        let a = makeAttribution(gclid: "ggg456")
        let attrs = swBuildSuperwallAttributes(a)
        XCTAssertEqual(attrs["pw_is_paid"] as? Bool, true)
        XCTAssertEqual(attrs["pw_ad_network"] as? String, "google")
    }

    // MARK: - buildSuperwallAttributes — paid via utm_medium cpc

    func testBuildAttributes_utmMediumCpc_isPaidTrue() {
        let a = makeAttribution(utmSource: "google", utmMedium: "cpc")
        let attrs = swBuildSuperwallAttributes(a)
        XCTAssertEqual(attrs["pw_is_paid"] as? Bool, true)
        XCTAssertEqual(attrs["pw_ad_network"] as? String, "google")
    }

    // MARK: - buildSuperwallAttributes — paid via utm_medium "paid_social"

    func testBuildAttributes_utmMediumPaidSocial_isPaidTrue() {
        let a = makeAttribution(utmMedium: "paid_social")
        let attrs = swBuildSuperwallAttributes(a)
        XCTAssertEqual(attrs["pw_is_paid"] as? Bool, true)
    }

    // MARK: - buildSuperwallAttributes — all UTM fields present

    func testBuildAttributes_fullUTM_allFieldsMapped() {
        let a = makeAttribution(
            utmSource: "meta",
            utmMedium: "cpc",
            utmCampaign: "summer",
            utmContent: "creative_a",
            utmTerm: "keyword",
            referrer: "https://example.com"
        )
        let attrs = swBuildSuperwallAttributes(a)
        XCTAssertEqual(attrs["pw_utm_source"] as? String, "meta")
        XCTAssertEqual(attrs["pw_utm_medium"] as? String, "cpc")
        XCTAssertEqual(attrs["pw_utm_campaign"] as? String, "summer")
        XCTAssertEqual(attrs["pw_utm_content"] as? String, "creative_a")
        XCTAssertEqual(attrs["pw_utm_term"] as? String, "keyword")
        XCTAssertEqual(attrs["pw_referrer"] as? String, "https://example.com")
    }

    // MARK: - buildSuperwallAttributes — capturedAt sempre presente

    func testBuildAttributes_capturedAtAlwaysPresent() {
        let a = makeAttribution(fbclid: "x")
        let attrs = swBuildSuperwallAttributes(a)
        XCTAssertNotNil(attrs["pw_attributed_at"])
    }

    // MARK: - buildSuperwallAttributes — campos nulos não aparecem no dict

    func testBuildAttributes_nilFields_notIncluded() {
        let a = makeAttribution(fbclid: "x")
        let attrs = swBuildSuperwallAttributes(a)
        XCTAssertNil(attrs["pw_utm_source"])
        XCTAssertNil(attrs["pw_utm_campaign"])
        XCTAssertNil(attrs["pw_gclid"])
        XCTAssertNil(attrs["pw_ttclid"])
    }

    // MARK: - deriveIsPaid

    func testDeriveIsPaid_noFields_false() {
        let a = makeAttribution()
        XCTAssertFalse(swDeriveIsPaid(a))
    }

    func testDeriveIsPaid_tiktokCampaignId_true() {
        let a = makeAttribution(tiktokCampaignId: "camp1")
        XCTAssertTrue(swDeriveIsPaid(a))
    }

    func testDeriveIsPaid_utmMediumDisplay_true() {
        let a = makeAttribution(utmMedium: "display")
        XCTAssertTrue(swDeriveIsPaid(a))
    }

    func testDeriveIsPaid_utmMediumSocial_false() {
        let a = makeAttribution(utmMedium: "social")
        XCTAssertFalse(swDeriveIsPaid(a))
    }

    func testDeriveIsPaid_utmMediumOrganic_false() {
        let a = makeAttribution(utmMedium: "organic")
        XCTAssertFalse(swDeriveIsPaid(a))
    }

    func testDeriveIsPaid_utmMediumCPM_caseInsensitive_true() {
        let a = makeAttribution(utmMedium: "CPM")
        XCTAssertTrue(swDeriveIsPaid(a))
    }

    // MARK: - deriveAdNetwork priority

    func testDeriveAdNetwork_fbclidBeatsGclid() {
        let a = makeAttribution(fbclid: "fb", gclid: "gc")
        XCTAssertEqual(swDeriveAdNetwork(a), "meta")
    }

    func testDeriveAdNetwork_ttclidOverGclid() {
        let a = makeAttribution(gclid: "gc", ttclid: "tt")
        // gclid tem prioridade 3, ttclid prioridade 2 → ttclid ganha
        XCTAssertEqual(swDeriveAdNetwork(a), "tiktok")
    }

    func testDeriveAdNetwork_noClickId_fallbackToUtmSource() {
        let a = makeAttribution(utmSource: "newsletter")
        XCTAssertEqual(swDeriveAdNetwork(a), "newsletter")
    }

    func testDeriveAdNetwork_nothing_nil() {
        let a = makeAttribution()
        XCTAssertNil(swDeriveAdNetwork(a))
    }

    // MARK: - mapDismissToCloseReason

    func testMapDismiss_purchased_returnsPurchased() {
        XCTAssertEqual(swMapDismissToCloseReason("purchased"), "purchased")
    }

    func testMapDismiss_restored_returnsRestored() {
        XCTAssertEqual(swMapDismissToCloseReason("restored"), "restored")
    }

    func testMapDismiss_declined_returnsDismissed() {
        XCTAssertEqual(swMapDismissToCloseReason("declined"), "dismissed")
    }

    func testMapDismiss_unknownType_returnsNil() {
        XCTAssertNil(swMapDismissToCloseReason("backgrounded"))
        XCTAssertNil(swMapDismissToCloseReason("timeout"))
        XCTAssertNil(swMapDismissToCloseReason(""))
    }

    // MARK: - Factory helper

    private func makeAttribution(
        utmSource: String? = nil,
        utmMedium: String? = nil,
        utmCampaign: String? = nil,
        utmContent: String? = nil,
        utmTerm: String? = nil,
        fbclid: String? = nil,
        gclid: String? = nil,
        ttclid: String? = nil,
        tiktokCampaignId: String? = nil,
        tiktokAdgroupId: String? = nil,
        tiktokAdId: String? = nil,
        referrer: String? = nil,
        installReferrerSource: String? = nil
    ) -> AttributionCapture {
        AttributionCapture(
            utmSource: utmSource,
            utmMedium: utmMedium,
            utmCampaign: utmCampaign,
            utmContent: utmContent,
            utmTerm: utmTerm,
            fbclid: fbclid,
            gclid: gclid,
            ttclid: ttclid,
            tiktokCampaignId: tiktokCampaignId,
            tiktokAdgroupId: tiktokAdgroupId,
            tiktokAdId: tiktokAdId,
            installReferrerRaw: nil,
            installReferrerSource: installReferrerSource,
            referrer: referrer,
            capturedAt: "2026-07-20T00:00:00Z"
        )
    }
}
