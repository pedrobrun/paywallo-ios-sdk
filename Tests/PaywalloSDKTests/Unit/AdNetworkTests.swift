import XCTest
@testable import PaywalloSDK

// MARK: - AdNetworkTests
//
// `utm_source` é texto livre e chega de três lugares que nunca combinam: o que o
// anunciante digitou, a macro que o Ads Manager expande (`ig`) e o carimbo do Meta
// Install Referrer (`apps.facebook.com`). Cada linha da tabela aqui é uma variação
// que apareceu em campo e que fazia `pw_ad_network is meta` não casar.

final class AdNetworkTests: XCTestCase {

    // MARK: - Meta

    func testNormalize_everyMetaAlias() {
        let sources = [
            "meta", "meta_ads", "meta-ads",
            "facebook", "facebook_ads", "facebook-ads",
            "fb", "fb4a", "fbig", "ig", "instagram",
            "apps.facebook.com", "m.facebook.com", "l.facebook.com",
            "audience_network", "audience-network", "audiencenetwork",
        ]
        for source in sources {
            XCTAssertEqual(normalizeAdNetwork(source), "meta", "\(source) deve virar meta")
        }
    }

    // MARK: - TikTok

    func testNormalize_everyTiktokAlias() {
        for source in ["tiktok", "tiktok_ads", "tiktok-ads", "tt", "tiktokglobal", "pangle"] {
            XCTAssertEqual(normalizeAdNetwork(source), "tiktok", "\(source) deve virar tiktok")
        }
    }

    // MARK: - Google

    func testNormalize_everyGoogleAlias() {
        for source in ["google", "google_ads", "google-ads", "googleads", "adwords", "uac", "youtube", "gdn"] {
            XCTAssertEqual(normalizeAdNetwork(source), "google", "\(source) deve virar google")
        }
    }

    // MARK: - Apple Search Ads

    func testNormalize_everyAppleAlias() {
        for source in ["apple", "apple_search_ads", "apple-search-ads", "asa", "apple_ads", "apple-ads"] {
            XCTAssertEqual(normalizeAdNetwork(source), "apple_search_ads", "\(source) deve virar apple_search_ads")
        }
    }

    // MARK: - Case-insensitive e trim

    func testNormalize_isCaseInsensitive() {
        XCTAssertEqual(normalizeAdNetwork("Facebook"), "meta")
        XCTAssertEqual(normalizeAdNetwork("TikTok"), "tiktok")
        XCTAssertEqual(normalizeAdNetwork("ADWORDS"), "google")
    }

    func testNormalize_trimsSurroundingWhitespace() {
        XCTAssertEqual(normalizeAdNetwork("  facebook  "), "meta")
    }

    // MARK: - Ancoragem

    func testNormalize_isAnchored_substringDoesNotMatch() {
        // "notfacebook" contém "facebook" mas não é a rede — sem âncora, uma fonte
        // qualquer com o nome dentro seria rotulada como Meta.
        XCTAssertEqual(normalizeAdNetwork("notfacebook"), "notfacebook")
        XCTAssertEqual(normalizeAdNetwork("google_partner"), "google_partner")
    }

    // MARK: - Carimbo de loja não é rede

    func testNormalize_storeStampsAreNotNetworks() {
        let stamps = [
            "google-play", "googleplay", "play.google.com",
            "app_store", "app-store", "appstore",
            "apple_app_store", "apple-app-store",
            "organic", "direct", "(not set)", "not set", "none",
        ]
        for stamp in stamps {
            XCTAssertNil(normalizeAdNetwork(stamp), "\(stamp) é carimbo de loja, não rede")
        }
    }

    func testNormalize_storeStampWinsOverNetworkTable() {
        // `google-play` casaria com a tabela do Google se a checagem de carimbo não
        // viesse primeiro — e a audiência de Google Ads engoliria todo install
        // orgânico do Android.
        XCTAssertNil(normalizeAdNetwork("google-play"))
        XCTAssertNil(matchKnownAdNetwork("google-play"))
    }

    // MARK: - Vazio / ausente

    func testNormalize_emptyAndNil() {
        XCTAssertNil(normalizeAdNetwork(""))
        XCTAssertNil(normalizeAdNetwork("   "))
        XCTAssertNil(normalizeAdNetwork(nil))
    }

    // MARK: - Fonte desconhecida

    func testNormalize_unknownSourcePassesThroughTrimmed() {
        // Uma audience rule `pw_ad_network is minha_fonte` já publicada continua valendo.
        XCTAssertEqual(normalizeAdNetwork("newsletter"), "newsletter")
        XCTAssertEqual(normalizeAdNetwork("  bio_link  "), "bio_link")
    }

    // MARK: - matchKnownAdNetwork ≠ normalizeAdNetwork

    func testMatchKnown_returnsNilForUnknownSource() {
        // Quem decide "isto é rede reconhecida" precisa de certeza, não de um rótulo.
        XCTAssertNil(matchKnownAdNetwork("newsletter"))
        XCTAssertEqual(matchKnownAdNetwork("facebook"), "meta")
    }
}
