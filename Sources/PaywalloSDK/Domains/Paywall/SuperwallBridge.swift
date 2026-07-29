/**
 * SuperwallBridge — integração bidirecional com SuperwallKit (dependência fraca/opcional).
 *
 * O arquivo inteiro está dentro de `#if canImport(SuperwallKit)`. Quando SuperwallKit
 * não estiver linkado, todas as funções públicas existem como stubs no-op (abaixo do #else).
 *
 * Dois componentes:
 *
 * 1. **Attribute Bridge** — espelha `SuperwallAttributeBridge.ts` do RN.
 *    Lê `AttributionTracker` e empurra campos `pw_*` para
 *    `Superwall.shared.setUserAttributes(...)`. Aguarda o SDK estar configurado
 *    (polling com backoff). Idempotente por assinatura dos atributos.
 *
 * 2. **Auto Bridge** — espelha `SuperwallAutoBridge.ts` do RN.
 *    Implementa `SuperwallDelegate` para escutar eventos do Superwall e mapear
 *    para `PaywalloClient.shared.track(...)`. Cobre: `paywallDidAppear` → viewed,
 *    `paywallDidDisappear` → closed, `transactionDidSucceed` → transaction.
 *    Dedup por transactionId via Set em memória.
 *
 * NOTA DE INTEGRAÇÃO — não testável em unit (requer SuperwallKit real):
 * - `Superwall.shared.setUserAttributes(_:)` exige configuração prévia do SDK.
 * - `Superwall.shared.delegate` é um `weak` var — o `SwBridgeDelegate` deve ser
 *   mantido com referência forte externa (ex: `PaywalloClient` guarda a instância).
 * - Chamar `startSuperwallBridge()` APÓS `PaywalloClient.shared.initialize()`.
 */

import Foundation

// MARK: - Testable pure logic (sem dependência de SuperwallKit)

/// Regex que detecta aquisição paga pelo utm_medium.
/// Cobre cpc/ppc/cpm/cpa, "paid"/"paid_social"/"paidsocial", "display".
private let paidMediumRegex: NSRegularExpression = {
    // swiftlint:disable:next force_try
    try! NSRegularExpression(pattern: "cpc|ppc|cpm|cpa|paid|display", options: .caseInsensitive)
}()

/// Retorna `true` se a atribuição indica aquisição paga (click ID ou utm_medium pago).
/// Exportado para testes unitários.
public func swDeriveIsPaid(_ a: AttributionCapture) -> Bool {
    if a.fbclid != nil || a.gclid != nil || a.ttclid != nil || a.tiktokCampaignId != nil {
        return true
    }
    guard let medium = a.utmMedium, !medium.isEmpty else { return false }
    let range = NSRange(medium.startIndex..., in: medium)
    return paidMediumRegex.firstMatch(in: medium, range: range) != nil
}

/// Retorna a rede de anúncios mais forte disponível. Exportado para testes unitários.
public func swDeriveAdNetwork(_ a: AttributionCapture) -> String? {
    if a.fbclid != nil { return "meta" }
    if a.ttclid != nil || a.tiktokCampaignId != nil { return "tiktok" }
    if a.gclid != nil { return "google" }
    return a.utmSource
}

/// Mapeia `AttributionCapture` → dicionário de atributos Superwall com prefixo `pw_`.
/// Retorna `["pw_is_paid": false]` para usuários orgânicos (sem atribuição).
/// Exportado para testes unitários.
public func swBuildSuperwallAttributes(_ a: AttributionCapture?) -> [String: Any] {
    guard let a = a else {
        return ["pw_is_paid": false]
    }
    var out: [String: Any] = [:]
    func set(_ key: String, _ value: String?) {
        if let v = value, !v.isEmpty { out[key] = v }
    }
    set("pw_utm_source", a.utmSource)
    set("pw_utm_medium", a.utmMedium)
    set("pw_utm_campaign", a.utmCampaign)
    set("pw_utm_content", a.utmContent)
    set("pw_utm_term", a.utmTerm)
    set("pw_fbclid", a.fbclid)
    set("pw_gclid", a.gclid)
    set("pw_ttclid", a.ttclid)
    set("pw_tiktok_campaign_id", a.tiktokCampaignId)
    set("pw_tiktok_adgroup_id", a.tiktokAdgroupId)
    set("pw_tiktok_ad_id", a.tiktokAdId)
    set("pw_referrer", a.referrer)
    set("pw_install_referrer_source", a.installReferrerSource)
    if let network = swDeriveAdNetwork(a) { out["pw_ad_network"] = network }
    out["pw_is_paid"] = swDeriveIsPaid(a)
    out["pw_attributed_at"] = a.capturedAt
    return out
}

/// Mapeia o tipo de dismiss do Superwall para `close_reason` do Paywallo.
/// Exportado para testes unitários.
public func swMapDismissToCloseReason(_ type: String) -> String? {
    switch type {
    case "purchased": return "purchased"
    case "restored": return "restored"
    case "declined": return "dismissed"
    default: return nil
    }
}

// MARK: - Stubs no-op (sem SuperwallKit)

#if canImport(SuperwallKit)

import SuperwallKit

// MARK: - Config gate

private let configPollIntervalNs: UInt64 = 250_000_000  // 250ms
private let configPollMaxAttempts = 40                   // ~10s

private let configRetryDelaysS: [TimeInterval] = [30, 60, 120]

// MARK: - Attribute Bridge state

private var attrLastSignature: String? = nil
private var attrRetryTask: Task<Void, Never>? = nil

// MARK: - Auto Bridge state

private var bridgeStarted = false
private var seenTransactionIds: Set<String> = []
private var bridgeDelegate: SwBridgeDelegate? = nil
private var bridgeDebug = false

// MARK: - Internal helpers

private func swLog(_ debug: Bool, _ msg: String) {
    guard debug else { return }
    // console.log permitido no SDK sob flag debug (ver CLAUDE.md SDK)
    print("[Paywallo:SuperwallBridge] \(msg)")
}

// MARK: - Attribute Bridge

private func waitForConfigured(debug: Bool) async -> Bool {
    for _ in 0..<configPollMaxAttempts {
        let status = Superwall.shared.configurationStatus
        if case .configured = status { return true }
        if case .failed = status {
            swLog(debug, "Superwall configuration FAILED — attribute push skipped")
            return false
        }
        try? await Task.sleep(nanoseconds: configPollIntervalNs)
    }
    swLog(debug, "Superwall not configured within timeout")
    return false
}

private func attemptAttributePush(debug: Bool, retryIndex: Int, attribution: AttributionTracker) async {
    let configured = await waitForConfigured(debug: debug)
    guard configured else {
        scheduleAttrRetry(debug: debug, retryIndex: retryIndex, attribution: attribution)
        return
    }

    // Snapshot APÓS a gate de configuração (igual ao RN)
    let attrs = swBuildSuperwallAttributes(attribution.get())
    let signature = "\(attrs.sorted(by: { $0.key < $1.key }))"
    if signature == attrLastSignature {
        swLog(debug, "attributes unchanged — skipping push")
        return
    }
    Superwall.shared.setUserAttributes(attrs)
    attrLastSignature = signature
    swLog(debug, "attributes pushed to Superwall")
}

private func scheduleAttrRetry(debug: Bool, retryIndex: Int, attribution: AttributionTracker) {
    guard retryIndex < configRetryDelaysS.count else {
        swLog(debug, "Superwall never configured — giving up attribute push")
        return
    }
    let delayS = configRetryDelaysS[retryIndex]
    attrRetryTask?.cancel()
    attrRetryTask = Task {
        try? await Task.sleep(nanoseconds: UInt64(delayS * 1_000_000_000))
        guard !Task.isCancelled else { return }
        await attemptAttributePush(debug: debug, retryIndex: retryIndex + 1, attribution: attribution)
    }
}

// MARK: - Auto Bridge delegate

/// Delegate concreto do Superwall que mapeia eventos → `PaywalloClient.track`.
/// A instância deve ser mantida com referência forte (guardada em `bridgeDelegate`).
final class SwBridgeDelegate: SuperwallDelegate {

    private let debug: Bool

    init(debug: Bool) {
        self.debug = debug
    }

    // MARK: Paywall viewed

    func paywallDidAppear(withInfo paywallInfo: PaywallInfo) {
        let id = paywallInfo.identifier
        swLog(debug, "paywallDidAppear: \(id)")
        PaywalloClient.shared.track(
            "paywall",
            properties: buildViewedProps(info: paywallInfo),
            priority: .critical
        )
    }

    // MARK: Paywall closed

    func paywallDidDisappear(withInfo paywallInfo: PaywallInfo) {
        let id = paywallInfo.identifier
        let closeReason = paywallInfo.closeReason?.description ?? "dismissed"
        let mappedReason = swMapDismissToCloseReason(closeReason) ?? "dismissed"
        swLog(debug, "paywallDidDisappear: \(id) reason=\(mappedReason)")
        var props = buildViewedProps(info: paywallInfo)
        props["type"] = AnyCodable("closed")
        props["close_reason"] = AnyCodable(mappedReason)
        props["closed_at"] = AnyCodable(ISO8601DateFormatter().string(from: Date()))
        PaywalloClient.shared.track("paywall", properties: props, priority: .critical)
    }

    // MARK: Transaction

    func transactionDidSucceed(
        withTransaction transaction: StoreTransaction,
        paywallInfo: PaywallInfo
    ) {
        let transactionId = transaction.id ?? "\(transaction.productIdentifier)_\(Int(Date().timeIntervalSince1970 * 1000))"

        // Dedup por transactionId
        if seenTransactionIds.contains(transactionId) {
            swLog(debug, "transaction already seen — skipping: \(transactionId)")
            return
        }
        seenTransactionIds.insert(transactionId)

        let productId = transaction.productIdentifier
        let product = paywallInfo.products.first(where: { $0.productIdentifier == productId })

        let price = product?.price.doubleValue ?? 0.0
        let currency = product?.currencyCode ?? "USD"
        let hasFreeTrial = product?.hasFreeTrial ?? false
        let introPrice = product?.introductoryPrice?.price.doubleValue ?? 0.0

        // Mesma lógica do RN: free trial só quando introPrice <= 0
        let isTrial = hasFreeTrial && introPrice <= 0
        let isPaidIntro = introPrice > 0

        swLog(debug, "transactionDidSucceed: \(productId) trial=\(isTrial) introPrice=\(introPrice)")

        var props: [String: AnyCodable] = [
            "type": AnyCodable(isTrial ? "trial_started" : "completed"),
            "transaction_id": AnyCodable(transactionId),
            "product_id": AnyCodable(productId),
            "amount": AnyCodable(isTrial ? 0.0 : (isPaidIntro ? introPrice : price)),
            "currency": AnyCodable(currency),
            "paywall_id": AnyCodable(paywallInfo.identifier),
        ]
        if isTrial || isPaidIntro {
            props["full_price"] = AnyCodable(price)
        }
        PaywalloClient.shared.track("transaction", properties: props, priority: .critical)
    }

    // MARK: Helpers

    private func buildViewedProps(info: PaywallInfo) -> [String: AnyCodable] {
        var props: [String: AnyCodable] = [
            "type": AnyCodable("viewed"),
            "paywall_id": AnyCodable(info.identifier),
        ]
        if let placement = info.presentedByEventWithName {
            props["placement"] = AnyCodable(placement)
        }
        if let variantId = info.experiment?.variant.id {
            props["variant_id"] = AnyCodable(variantId)
        }
        if let campaignId = info.experiment?.id {
            props["campaign_id"] = AnyCodable(campaignId)
        }
        return props
    }
}

// MARK: - Public API

/**
 Inicia o Superwall bridge bidirecional. Idempotente — chamadas repetidas são no-op.

 - Parameter attribution: `AttributionTracker` para leitura dos campos `pw_*`.
 - Parameter debug: Quando `true`, habilita logs de diagnóstico.

 Chame APÓS `PaywalloClient.shared.initialize()` e ANTES do primeiro `register()` do Superwall.

 NOTA: mantém referência forte ao `SwBridgeDelegate` internamente. Não é necessário
 guardar referência externa.
 */
public func startSuperwallBridge(attribution: AttributionTracker, debug: Bool = false) {
    // 1. Attribute bridge (fire-and-forget)
    attrRetryTask?.cancel()
    attrRetryTask = nil
    Task {
        await attemptAttributePush(debug: debug, retryIndex: 0, attribution: attribution)
    }

    // 2. Auto bridge (idempotente)
    guard !bridgeStarted else {
        swLog(debug, "already started, skipping")
        return
    }
    bridgeDebug = debug
    let delegate = SwBridgeDelegate(debug: debug)
    bridgeDelegate = delegate
    Superwall.shared.delegate = delegate
    bridgeStarted = true
    swLog(debug, "bridge started")
}

/**
 Para o auto bridge e cancela retries pendentes.
 Primariamente para testes e teardown.
 */
public func stopSuperwallBridge() {
    attrRetryTask?.cancel()
    attrRetryTask = nil
    attrLastSignature = nil

    if bridgeStarted {
        Superwall.shared.delegate = nil
        bridgeDelegate = nil
    }
    bridgeStarted = false
    seenTransactionIds.removeAll()
}

/**
 Cancela apenas o retry pendente do attribute bridge sem limpar a assinatura.
 Para teardown de Provider sem forçar re-push desnecessário.
 */
public func cancelSuperwallAttributeRetry() {
    attrRetryTask?.cancel()
    attrRetryTask = nil
}

/**
 Reseta o guard de idempotência do attribute bridge.
 Para testes e logout (próximo push força re-escrita).
 */
public func resetSuperwallAttributePush() {
    attrLastSignature = nil
    attrRetryTask?.cancel()
    attrRetryTask = nil
}

#else

// MARK: - No-op stubs (SuperwallKit não linkado)

public func startSuperwallBridge(attribution: AttributionTracker, debug: Bool = false) {
    // SuperwallKit não está disponível — no-op intencional
}

public func stopSuperwallBridge() {}
public func cancelSuperwallAttributeRetry() {}
public func resetSuperwallAttributePush() {}

#endif
