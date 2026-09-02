import XCTest
@testable import PaywalloSDK

// MARK: - SuperwallBridgeTests
//
// Testa a lógica pura do SuperwallBridge:
//   - swBuildSuperwallAttributes  (mapeamento de campos pw_*)
//   - swDeriveIsPaid              (link rastreado, não "mídia paga")
//   - swDeriveAdNetwork           (rede canônica, do sinal mais forte pro mais fraco)
//   - swMapDismissToCloseReason   (PaywallResult do dismiss → close_reason)
//   - SuperwallAttributePush      (gate de configuração, assinatura, backoff)
//   - swRunSync                   (orçamento por deadline + os 3 outcomes)
//
// A ponte com SuperwallKit real não é testável em unit (requer SDK configurado +
// runtime iOS com SuperwallKit linkado); a máquina do push fala com
// `SuperwallAttributeSink`, que aqui é um dublê.

final class SuperwallBridgeTests: XCTestCase {

    // MARK: - buildSuperwallAttributes — nil attribution

    func testBuildAttributes_nilAttribution_returnsPaidFalse() {
        let attrs = swBuildSuperwallAttributes(nil)
        XCTAssertEqual(attrs["pw_is_paid"] as? Bool, false)
        XCTAssertEqual(attrs.count, 1)
    }

    func testBuildAttributes_organicPath_carriesOnlyIdAndPaidFalse() {
        let attrs = swBuildSuperwallAttributes(nil, distinctId: "dist_abc")
        XCTAssertEqual(attrs["pw_paywallo_id"] as? String, "dist_abc")
        XCTAssertEqual(attrs["pw_is_paid"] as? Bool, false)
        XCTAssertEqual(attrs.count, 2)
        XCTAssertNil(attrs["pw_match_type"])
        XCTAssertNil(attrs["pw_match_type_raw"])
    }

    // MARK: - pw_paywallo_id

    func testBuildAttributes_distinctIdIsWritten() {
        let a = makeAttribution(fbclid: "x")
        let attrs = swBuildSuperwallAttributes(a, distinctId: "dist_xyz789")
        XCTAssertEqual(attrs["pw_paywallo_id"] as? String, "dist_xyz789")
    }

    func testBuildAttributes_emptyDistinctIdIsOmitted() {
        // Um `pw_paywallo_id` vazio é casável-mas-errado — pior que atributo nenhum.
        let a = makeAttribution(fbclid: "x")
        XCTAssertNil(swBuildSuperwallAttributes(a, distinctId: "")["pw_paywallo_id"])
        XCTAssertNil(swBuildSuperwallAttributes(a)["pw_paywallo_id"])
    }

    // MARK: - buildSuperwallAttributes — link rastreado

    func testBuildAttributes_trackedSource_isPaidTrue() {
        // 2.9.0: qualquer utm_source que não seja carimbo de loja conta como rastreado,
        // inclusive bio link do Growth Hub (utm_source=other) e fonte digitada à mão.
        let a = makeAttribution(utmSource: "newsletter", utmMedium: "email")
        let attrs = swBuildSuperwallAttributes(a)
        XCTAssertEqual(attrs["pw_is_paid"] as? Bool, true)
        XCTAssertEqual(attrs["pw_utm_source"] as? String, "newsletter")
        XCTAssertEqual(attrs["pw_utm_medium"] as? String, "email")
    }

    func testBuildAttributes_storeStamp_isPaidFalseAndNoNetwork() {
        let a = makeAttribution(utmSource: "google-play", utmMedium: "organic")
        let attrs = swBuildSuperwallAttributes(a)
        XCTAssertEqual(attrs["pw_is_paid"] as? Bool, false)
        XCTAssertNil(attrs["pw_ad_network"])
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

    func testBuildAttributes_utmMediumPaidSocial_isPaidTrue() {
        let a = makeAttribution(utmMedium: "paid_social")
        let attrs = swBuildSuperwallAttributes(a)
        XCTAssertEqual(attrs["pw_is_paid"] as? Bool, true)
    }

    // MARK: - Meta Install Referrer (caminho determinístico do Meta no Android)

    func testBuildAttributes_metaInstallReferrer_labelsMetaAndPaid() {
        // Shape real: utm_source=apps.facebook.com&utm_campaign=fb4a&utm_medium=UAC_App_Ads.
        // Chega SEM fbclid (só o servidor decifra o blob) e o medium não casa com
        // PAID_MEDIUM — esse usuário era marcado como orgânico.
        let a = makeAttribution(
            utmSource: "apps.facebook.com",
            utmMedium: "UAC_App_Ads",
            utmCampaign: "fb4a",
            installReferrerSource: "play_store"
        )
        let attrs = swBuildSuperwallAttributes(a)
        XCTAssertEqual(attrs["pw_ad_network"] as? String, "meta")
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

    func testBuildAttributes_capturedAtAlwaysPresent() {
        let a = makeAttribution(fbclid: "x")
        let attrs = swBuildSuperwallAttributes(a)
        XCTAssertNotNil(attrs["pw_attributed_at"])
    }

    func testBuildAttributes_nilFields_notIncluded() {
        let a = makeAttribution(fbclid: "x")
        let attrs = swBuildSuperwallAttributes(a)
        XCTAssertNil(attrs["pw_utm_source"])
        XCTAssertNil(attrs["pw_utm_campaign"])
        XCTAssertNil(attrs["pw_gclid"])
        XCTAssertNil(attrs["pw_ttclid"])
    }

    // MARK: - pw_match_type / pw_match_type_raw

    func testMatchType_collapsesKnownFamilies() {
        // Domínio real da engine: deterministic, deterministic_referrer, geo_exclusive,
        // probabilistic_high/low/ambiguous. "probabilistic" puro nunca sai do servidor.
        let cases: [(raw: String, collapsed: String)] = [
            ("probabilistic_high", "probabilistic"),
            ("probabilistic_low", "probabilistic"),
            ("probabilistic_ambiguous", "probabilistic"),
            ("deterministic", "deterministic"),
            ("deterministic_referrer", "deterministic"),
        ]
        for c in cases {
            let attrs = swBuildSuperwallAttributes(makeAttribution(adNetwork: "meta", matchType: c.raw))
            XCTAssertEqual(attrs["pw_match_type"] as? String, c.collapsed, "raw=\(c.raw)")
            XCTAssertEqual(attrs["pw_match_type_raw"] as? String, c.raw)
        }
    }

    func testMatchType_unknownFamilyPassesThroughRaw() {
        let attrs = swBuildSuperwallAttributes(makeAttribution(adNetwork: "meta", matchType: "geo_exclusive"))
        XCTAssertEqual(attrs["pw_match_type"] as? String, "geo_exclusive")
        XCTAssertEqual(attrs["pw_match_type_raw"] as? String, "geo_exclusive")
    }

    func testMatchType_deviceSideClickIdIsDeterministicWithoutRaw() {
        let attrs = swBuildSuperwallAttributes(makeAttribution(fbclid: "fb_deeplink"))
        XCTAssertEqual(attrs["pw_match_type"] as? String, "deterministic")
        XCTAssertNil(attrs["pw_match_type_raw"], "o palpite local nunca preenche o valor cru")
    }

    func testMatchType_serverVerdictBeatsLocalGuess() {
        let attrs = swBuildSuperwallAttributes(
            makeAttribution(fbclid: "fb_x", matchType: "probabilistic_low")
        )
        XCTAssertEqual(attrs["pw_match_type"] as? String, "probabilistic")
        XCTAssertEqual(attrs["pw_match_type_raw"] as? String, "probabilistic_low")
    }

    func testMatchType_omittedWithoutClickIdAndWithoutServer() {
        let attrs = swBuildSuperwallAttributes(makeAttribution(utmSource: "facebook"))
        XCTAssertNil(attrs["pw_match_type"])
        XCTAssertNil(attrs["pw_match_type_raw"])
        XCTAssertEqual(attrs["pw_ad_network"] as? String, "meta")
    }

    // MARK: - deriveIsPaid

    func testDeriveIsPaid_noFields_false() {
        XCTAssertFalse(swDeriveIsPaid(makeAttribution()))
    }

    func testDeriveIsPaid_referrerOnly_false() {
        XCTAssertFalse(swDeriveIsPaid(makeAttribution(referrer: "https://blog.exemplo.com")))
    }

    func testDeriveIsPaid_tiktokCampaignId_true() {
        XCTAssertTrue(swDeriveIsPaid(makeAttribution(tiktokCampaignId: "camp1")))
    }

    func testDeriveIsPaid_utmMediumDisplay_true() {
        XCTAssertTrue(swDeriveIsPaid(makeAttribution(utmMedium: "display")))
    }

    func testDeriveIsPaid_utmMediumSocialWithoutSource_false() {
        XCTAssertFalse(swDeriveIsPaid(makeAttribution(utmMedium: "social")))
    }

    func testDeriveIsPaid_utmMediumOrganicWithoutSource_false() {
        XCTAssertFalse(swDeriveIsPaid(makeAttribution(utmMedium: "organic")))
    }

    func testDeriveIsPaid_utmMediumCPM_caseInsensitive_true() {
        XCTAssertTrue(swDeriveIsPaid(makeAttribution(utmMedium: "CPM")))
    }

    func testDeriveIsPaid_growthHubBioLinkFallbackSource_true() {
        // `other` é o fallback do bio link quando a plataforma não bate com as 4
        // conhecidas: dois links do mesmo painel davam resultado oposto.
        XCTAssertTrue(swDeriveIsPaid(makeAttribution(utmSource: "other")))
        XCTAssertTrue(swDeriveIsPaid(makeAttribution(utmSource: "newsletter", utmMedium: "email")))
    }

    func testDeriveIsPaid_storeStamp_false() {
        XCTAssertFalse(swDeriveIsPaid(makeAttribution(utmSource: "google-play", utmMedium: "organic")))
        XCTAssertFalse(swDeriveIsPaid(makeAttribution(utmSource: "(not set)")))
    }

    func testDeriveIsPaid_serverNetwork_true() {
        XCTAssertTrue(swDeriveIsPaid(makeAttribution(adNetwork: "meta")))
    }

    func testDeriveIsPaid_serverNetworkOrganic_false() {
        XCTAssertFalse(swDeriveIsPaid(makeAttribution(adNetwork: "organic")))
    }

    // MARK: - deriveAdNetwork priority

    func testDeriveAdNetwork_serverNetworkBeatsClickId() {
        XCTAssertEqual(swDeriveAdNetwork(makeAttribution(fbclid: "fb", adNetwork: "tiktok")), "tiktok")
    }

    func testDeriveAdNetwork_clickIdBeatsUtmSource() {
        XCTAssertEqual(swDeriveAdNetwork(makeAttribution(utmSource: "tiktok", fbclid: "fb")), "meta")
    }

    func testDeriveAdNetwork_fbclidBeatsGclid() {
        XCTAssertEqual(swDeriveAdNetwork(makeAttribution(fbclid: "fb", gclid: "gc")), "meta")
    }

    func testDeriveAdNetwork_ttclidOverGclid() {
        XCTAssertEqual(swDeriveAdNetwork(makeAttribution(gclid: "gc", ttclid: "tt")), "tiktok")
    }

    func testDeriveAdNetwork_utmSourceIsNormalizedNotRaw() {
        // Antes o atributo carregava o utm_source cru e `pw_ad_network is meta` não
        // casava com a maioria dos usuários de Meta Ads.
        XCTAssertEqual(swDeriveAdNetwork(makeAttribution(utmSource: "ig")), "meta")
        XCTAssertEqual(swDeriveAdNetwork(makeAttribution(utmSource: "apps.facebook.com")), "meta")
    }

    func testDeriveAdNetwork_unknownSourcePassesThrough() {
        XCTAssertEqual(swDeriveAdNetwork(makeAttribution(utmSource: "newsletter")), "newsletter")
    }

    func testDeriveAdNetwork_storeStamp_nil() {
        XCTAssertNil(swDeriveAdNetwork(makeAttribution(utmSource: "google-play")))
    }

    func testDeriveAdNetwork_nothing_nil() {
        XCTAssertNil(swDeriveAdNetwork(makeAttribution()))
    }

    // MARK: - mapDismissToCloseReason

    func testMapDismiss_purchased_returnsPurchased() {
        XCTAssertEqual(swMapDismissToCloseReason("purchased"), "purchased")
    }

    func testMapDismiss_restored_returnsRestored() {
        // Restore não é conversão nova — mapeá-lo para "purchased" inflava a taxa.
        XCTAssertEqual(swMapDismissToCloseReason("restored"), "restored")
    }

    func testMapDismiss_declined_returnsDismissed() {
        XCTAssertEqual(swMapDismissToCloseReason("declined"), "dismissed")
    }

    func testMapDismiss_unknownType_returnsNil() {
        // O domínio de `paywallInfo.closeReason` (systemLogic/manualClose/...) não é
        // este — nenhum dos seus valores pode ser aceito por engano.
        XCTAssertNil(swMapDismissToCloseReason("manualClose"))
        XCTAssertNil(swMapDismissToCloseReason("systemLogic"))
        XCTAssertNil(swMapDismissToCloseReason("backgrounded"))
        XCTAssertNil(swMapDismissToCloseReason(""))
    }

    // MARK: - Assinatura dos atributos

    func testAttributeSignature_isOrderIndependent() {
        let a: [String: Any] = ["pw_is_paid": true, "pw_ad_network": "meta"]
        let b: [String: Any] = ["pw_ad_network": "meta", "pw_is_paid": true]
        XCTAssertEqual(swAttributeSignature(a), swAttributeSignature(b))
    }

    func testAttributeSignature_changesWithValue() {
        let a: [String: Any] = ["pw_ad_network": "meta"]
        let b: [String: Any] = ["pw_ad_network": "tiktok"]
        XCTAssertNotEqual(swAttributeSignature(a), swAttributeSignature(b))
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
        installReferrerSource: String? = nil,
        adNetwork: String? = nil,
        matchType: String? = nil
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
            adNetwork: adNetwork,
            matchType: matchType,
            capturedAt: "2026-07-20T00:00:00Z"
        )
    }
}

// MARK: - Dublê do SDK nativo

private final class MockSuperwallSink: SuperwallAttributeSink, @unchecked Sendable {
    private let lock = NSLock()
    private var statusQueue: [SuperwallConfigStatus]
    private var steadyStatus: SuperwallConfigStatus
    var statusError: Error?
    var writeError: Error?
    private(set) var writes: [[String: Any]] = []
    private(set) var statusReads = 0

    /// Roda a cada leitura de status — usado para simular atribuição que chega
    /// DURANTE a gate de configuração.
    var onStatusRead: (() -> Void)?

    init(statusQueue: [SuperwallConfigStatus] = [], steadyStatus: SuperwallConfigStatus = .configured) {
        self.statusQueue = statusQueue
        self.steadyStatus = steadyStatus
    }

    func configurationStatus() throws -> SuperwallConfigStatus {
        lock.lock()
        statusReads += 1
        let error = statusError
        let next = statusQueue.isEmpty ? steadyStatus : statusQueue.removeFirst()
        let hook = onStatusRead
        lock.unlock()
        hook?()
        if let error = error { throw error }
        return next
    }

    func setUserAttributes(_ attributes: [String: Any]) async throws {
        lock.lock()
        writes.append(attributes)
        let error = writeError
        lock.unlock()
        if let error = error { throw error }
    }

    var writeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return writes.count
    }
}

private struct MockSinkError: Error {}

/// Caixa thread-safe para o snapshot de atribuição usado pelos dublês.
private final class CaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: AttributionCapture?

    var value: AttributionCapture? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

// MARK: - SuperwallAttributePushTests

final class SuperwallAttributePushTests: XCTestCase {

    private func makeCapture(campaign: String? = nil) -> AttributionCapture {
        AttributionCapture(
            utmSource: "facebook",
            utmMedium: "cpc",
            utmCampaign: campaign,
            fbclid: "fbABC",
            capturedAt: "2026-06-09T00:00:00.000Z"
        )
    }

    private func makePush(
        sink: MockSuperwallSink,
        capture: @escaping () -> AttributionCapture?,
        distinctId: @escaping () -> String? = { nil },
        pollMaxAttempts: Int = 2,
        retryDelaysMs: [Int] = []
    ) -> SuperwallAttributePush {
        SuperwallAttributePush(
            sink: sink,
            snapshot: { (capture(), distinctId()) },
            debug: false,
            pollIntervalMs: 1,
            pollMaxAttempts: pollMaxAttempts,
            retryDelaysMs: retryDelaysMs
        )
    }

    func testAttempt_writesAttributes() async {
        let sink = MockSuperwallSink()
        let push = makePush(sink: sink, capture: { self.makeCapture() })

        let outcome = await push.attempt()

        XCTAssertEqual(outcome, .written)
        XCTAssertEqual(sink.writeCount, 1)
        XCTAssertEqual(sink.writes.first?["pw_ad_network"] as? String, "meta")
        XCTAssertEqual(sink.writes.first?["pw_is_paid"] as? Bool, true)
    }

    func testAttempt_isIdempotentBySignature() async {
        let sink = MockSuperwallSink()
        let push = makePush(sink: sink, capture: { self.makeCapture() })

        _ = await push.attempt()
        let second = await push.attempt()

        XCTAssertEqual(second, .unchanged)
        XCTAssertEqual(sink.writeCount, 1)
    }

    func testAttempt_rePushesWhenAttributionChanges() async {
        let sink = MockSuperwallSink()
        var campaign: String?
        let push = makePush(sink: sink, capture: { self.makeCapture(campaign: campaign) })

        _ = await push.attempt()
        campaign = "promo_v2"
        let second = await push.attempt()

        XCTAssertEqual(second, .written)
        XCTAssertEqual(sink.writeCount, 2)
    }

    func testAttempt_failedWriteDoesNotPersistSignature() async {
        // Persistir a assinatura antes do write resolver fazia a próxima chamada
        // idêntica virar no-op — o atributo nunca chegava.
        let sink = MockSuperwallSink()
        sink.writeError = MockSinkError()
        let push = makePush(sink: sink, capture: { self.makeCapture() })

        _ = await push.attempt()
        sink.writeError = nil
        _ = await push.attempt()

        XCTAssertEqual(sink.writeCount, 2, "Falha não pode marcar o snapshot como enviado")
    }

    func testAttempt_readsSnapshotAfterConfigGate() async {
        // Ler na entrada capturava a atribuição pré-espera; um deep link morno que
        // chegasse durante a gate se perdia. O snapshot começa orgânico e só ganha
        // valor quando a gate roda.
        let sink = MockSuperwallSink(statusQueue: [.pending], steadyStatus: .configured)
        let box = CaptureBox()
        let push = makePush(sink: sink, capture: { box.value })
        sink.onStatusRead = { box.value = self.makeCapture() }

        let outcome = await push.attempt()

        XCTAssertEqual(outcome, .written)
        XCTAssertEqual(sink.writes.first?["pw_fbclid"] as? String, "fbABC")
        XCTAssertEqual(sink.writes.first?["pw_is_paid"] as? Bool, true)
    }

    func testAttempt_configurationFailed_doesNotWrite() async {
        let sink = MockSuperwallSink(steadyStatus: .failed)
        let push = makePush(sink: sink, capture: { self.makeCapture() })

        let outcome = await push.attempt()

        XCTAssertEqual(outcome, .configFailed)
        XCTAssertEqual(sink.writeCount, 0)
    }

    func testAttempt_statusReadError_isTreatedAsFailed() async {
        // Não há o que retentar contra um SDK que não responde o próprio status.
        let sink = MockSuperwallSink()
        sink.statusError = MockSinkError()
        let push = makePush(sink: sink, capture: { self.makeCapture() })

        let outcome = await push.attempt()
        XCTAssertEqual(outcome, .configFailed)
    }

    func testAttempt_neverConfigured_reportsTimeout() async {
        let sink = MockSuperwallSink(steadyStatus: .pending)
        let push = makePush(sink: sink, capture: { self.makeCapture() })

        let outcome = await push.attempt(scheduleRetryOnTimeout: false)

        XCTAssertEqual(outcome, .configTimeout)
        XCTAssertEqual(sink.writeCount, 0)
    }

    func testAttempt_maxConfigAttemptsCapsPolling() async {
        let sink = MockSuperwallSink(steadyStatus: .pending)
        let push = makePush(sink: sink, capture: { self.makeCapture() }, pollMaxAttempts: 40)

        _ = await push.attempt(maxConfigAttempts: 2, scheduleRetryOnTimeout: false)

        XCTAssertEqual(sink.statusReads, 2, "O sync JIT usa uma gate curta, não a janela de ~10s")
    }

    func testAttempt_backoffRetryEventuallyWrites() async throws {
        let sink = MockSuperwallSink(statusQueue: [.pending, .pending], steadyStatus: .configured)
        let push = makePush(
            sink: sink,
            capture: { self.makeCapture() },
            retryDelaysMs: [10]
        )

        let outcome = await push.attempt()
        XCTAssertEqual(outcome, .configTimeout)

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(sink.writeCount, 1, "O retry agendado escreve quando a configuração chega")
    }

    func testCancelRetry_preservesSignature() async {
        let sink = MockSuperwallSink()
        let push = makePush(sink: sink, capture: { self.makeCapture() })

        _ = await push.attempt()
        push.cancelRetry()   // teardown: não pode forçar re-push
        let second = await push.attempt()

        XCTAssertEqual(second, .unchanged)
        XCTAssertEqual(sink.writeCount, 1)
    }

    func testArmedBridge_rePushesWhenAttributionLandsLate() async throws {
        // A atribuição costuma resolver depois do primeiro open; sem a inscrição em
        // onCapture o Superwall ficava com o snapshot orgânico da inicialização.
        let sink = MockSuperwallSink()
        let suite = UserDefaults(suiteName: "com.paywallo.sdk.tests.swbridge.\(UUID().uuidString)")!
        let native = NativeStorage(service: "com.paywallo.sdk.tests.swbridge.\(UUID().uuidString)", defaults: suite)
        let tracker = AttributionTracker(storage: SecureStorage(nativeStorage: native), nativeStorage: native)

        swArmAttributeBridge(
            sink: sink,
            attribution: tracker,
            distinctIdProvider: nil,
            apiClient: nil,
            debug: false
        )
        defer { swDisarmAttributeBridge() }

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(sink.writeCount, 1, "O primeiro push sai no arm, com o snapshot orgânico")
        XCTAssertEqual(sink.writes.first?["pw_is_paid"] as? Bool, false)

        await tracker.capture(AttributionInput(utmSource: "facebook", fbclid: "fb_late"))
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(sink.writeCount, 2, "O capture tardio tem que gerar re-push")
        XCTAssertEqual(sink.writes.last?["pw_ad_network"] as? String, "meta")
        XCTAssertEqual(sink.writes.last?["pw_is_paid"] as? Bool, true)
    }

    func testReset_forcesRePush() async {
        let sink = MockSuperwallSink()
        let push = makePush(sink: sink, capture: { self.makeCapture() })

        _ = await push.attempt()
        push.reset()
        _ = await push.attempt()

        XCTAssertEqual(sink.writeCount, 2)
    }
}

// MARK: - syncSuperwallAttributes

final class SuperwallSyncTests: XCTestCase {

    // MARK: Mapeamento de outcome

    func testSyncOutcome_writtenAndUnchangedAreSynced() {
        XCTAssertEqual(swSyncOutcome(for: .written), .synced)
        XCTAssertEqual(swSyncOutcome(for: .unchanged), .synced)
    }

    func testSyncOutcome_noModuleAndConfigFailedAreSkipped() {
        // configFailed é "não dá pra tentar", não questão de tempo — mesmo balde de
        // módulo ausente.
        XCTAssertEqual(swSyncOutcome(for: .noModule), .skipped)
        XCTAssertEqual(swSyncOutcome(for: .configFailed), .skipped)
    }

    func testSyncOutcome_configTimeoutAndDeadlineAreTimeout() {
        XCTAssertEqual(swSyncOutcome(for: .configTimeout), .timeout)
        XCTAssertEqual(swSyncOutcome(for: nil), .timeout)
    }

    // MARK: Fluxo completo

    func testRunSync_asksServerBeforePushing() async {
        let order = OrderRecorder()
        let outcome = await swRunSync(
            timeoutMs: 500,
            refresh: { order.record("refresh") },
            push: { order.record("push"); return .written }
        )

        XCTAssertEqual(order.entries, ["refresh", "push"])
        XCTAssertEqual(outcome, .synced)
    }

    func testRunSync_hangingRefreshStillPushesWithinBudget() async {
        // O orçamento é teto, não alvo: não pode segurar o paywall.
        let started = Date()
        let outcome = await swRunSync(
            timeoutMs: 400,
            refresh: { try? await Task.sleep(nanoseconds: 5_000_000_000) },
            push: { .written }
        )

        XCTAssertEqual(outcome, .synced)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
    }

    func testRunSync_hangingPushReportsTimeout() async {
        let outcome = await swRunSync(
            timeoutMs: 400,
            refresh: {},
            push: {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return .written
            }
        )

        XCTAssertEqual(outcome, .timeout)
    }

    func testRunSync_noModuleIsSkipped() async {
        let outcome = await swRunSync(timeoutMs: 300, refresh: {}, push: { .noModule })
        XCTAssertEqual(outcome, .skipped)
    }

    func testRunSync_configTimeoutIsTimeout() async {
        let outcome = await swRunSync(timeoutMs: 300, refresh: {}, push: { .configTimeout })
        XCTAssertEqual(outcome, .timeout)
    }

    func testRunSync_budgetIsADeadlineNotAFixedSlice() async {
        // Fatia fixa (0.6 × 800ms = 480ms) cortaria o refresh de 600ms fora e o push
        // leria o snapshot velho; o orçamento por deadline dá 800-300 = 500ms... e o
        // refresh de 300ms cabe com folga, devolvendo o resto pro push.
        let flag = OrderRecorder()
        let outcome = await swRunSync(
            timeoutMs: 800,
            refresh: {
                try? await Task.sleep(nanoseconds: 300_000_000)
                flag.record("server_matched")
            },
            push: {
                XCTAssertEqual(flag.entries, ["server_matched"], "O push tem que ler o snapshot já atualizado")
                return .written
            }
        )

        XCTAssertEqual(outcome, .synced)
    }

    func testRunSync_zeroBudgetStillGivesThePushItsFloor() async {
        // Piso reservado pro push mesmo com o orçamento inteiro consumido.
        let outcome = await swRunSync(timeoutMs: 0, refresh: {}, push: { .written })
        XCTAssertEqual(outcome, .synced)
    }

    func testRunSync_negativeBudgetIsClamped() async {
        let outcome = await swRunSync(timeoutMs: -100, refresh: {}, push: { .unchanged })
        XCTAssertEqual(outcome, .synced)
    }

    // MARK: withTimeout

    func testWithTimeout_returnsNilWhenDeadlineWins() async {
        let value = await swWithTimeout(ms: 50) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return 42
        }
        XCTAssertNil(value)
    }

    func testWithTimeout_returnsValueWhenOperationWins() async {
        let value = await swWithTimeout(ms: 2_000) { 42 }
        XCTAssertEqual(value, 42)
    }
}

/// Registrador thread-safe de ordem de execução.
private final class OrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ entry: String) {
        lock.lock(); storage.append(entry); lock.unlock()
    }

    var entries: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
