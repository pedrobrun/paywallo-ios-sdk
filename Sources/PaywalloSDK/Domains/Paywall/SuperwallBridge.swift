/**
 * SuperwallBridge — integração bidirecional com SuperwallKit (dependência fraca/opcional).
 *
 * Dois componentes:
 *
 * 1. **Attribute Bridge** — espelha `SuperwallAttributeBridge.ts` do RN.
 *    Lê `AttributionTracker` e empurra campos `pw_*` para o SDK do Superwall.
 *    Aguarda o SDK estar configurado (polling + backoff). Idempotente por
 *    assinatura dos atributos.
 *
 * 2. **Auto Bridge** — espelha `SuperwallAutoBridge.ts` do RN.
 *    Implementa `SuperwallDelegate` para escutar eventos do Superwall e mapear
 *    para `PaywalloClient.shared.track(...)`.
 *
 * A máquina do push fala com o SDK através de `SuperwallAttributeSink`, não com
 * `Superwall.shared` direto: a implementação real vive dentro do
 * `#if canImport(SuperwallKit)`, e o resto (gate de configuração, backoff,
 * assinatura, orçamento do sync) é código normal — testável sem o SDK linkado,
 * que é onde mora toda a regra da 2.9.0.
 *
 * NOTA DE INTEGRAÇÃO — não testável em unit (requer SuperwallKit real):
 * - `Superwall.shared.setUserAttributes(_:)` exige configuração prévia do SDK.
 * - `Superwall.shared.delegate` é um `weak` var — o `SwBridgeDelegate` é mantido
 *   com referência forte interna (`bridgeDelegate`).
 * - Chamar `startSuperwallBridge()` APÓS `PaywalloClient.shared.initialize()`.
 */

import Foundation

// MARK: - Testable pure logic (sem dependência de SuperwallKit)

/// Regex que detecta aquisição paga pelo utm_medium.
/// Cobre cpc/ppc/cpm/cpa, "paid"/"paid_social"/"paidsocial", "display".
/// NÃO é ancorada de propósito: `utm_medium=paid_social` precisa casar por substring.
private let paidMediumRegex: NSRegularExpression = {
    // swiftlint:disable:next force_try
    try! NSRegularExpression(pattern: "cpc|ppc|cpm|cpa|paid|display", options: .caseInsensitive)
}()

/// Truthiness do JS para os campos de atribuição: string vazia não é sinal.
/// O servidor devolve `""` em clid ausente, e tratar isso como clique real
/// marcaria install orgânico como determinístico.
private func swPresent(_ value: String?) -> Bool {
    guard let value = value else { return false }
    return !value.isEmpty
}

/// Click ID capturado no PRÓPRIO device (deep link, Install Referrer) — prova direta
/// do clique, sem inferência. Usado só para rotular `pw_match_type` quando o servidor
/// ainda não respondeu; o rótulo do servidor sempre vence.
private func swHasDeviceSideClickId(_ a: AttributionCapture) -> Bool {
    swPresent(a.fbclid) || swPresent(a.gclid) || swPresent(a.ttclid) || swPresent(a.tiktokCampaignId)
}

/// O domínio de `matchType` que o servidor emite cresce com o tempo (4 valores novos
/// em 4 meses); a audience rule do Superwall precisa de um contrato estável. Colapsa
/// as famílias conhecidas e deixa o resto (ex. `geo_exclusive`) passar cru.
func swCollapseMatchType(_ raw: String) -> String {
    if raw.hasPrefix("probabilistic") { return "probabilistic" }
    if raw.hasPrefix("deterministic") { return "deterministic" }
    return raw
}

/// Retorna `true` se a atribuição indica que o usuário veio de um link rastreado
/// nosso. Exportado para testes unitários.
///
/// Desde a 2.9.0 isto não é mais "veio de mídia paga": qualquer `utm_source` que não
/// seja carimbo de loja conta, incluindo bio link do Growth Hub e fonte digitada à
/// mão — dois bio links do mesmo painel davam resultado oposto conforme a plataforma.
/// Também cobre o caminho determinístico do Meta no Android (Meta Install Referrer),
/// que chega sem clid nenhum e com `utm_medium=UAC_App_Ads`.
public func swDeriveIsPaid(_ a: AttributionCapture) -> Bool {
    if swHasDeviceSideClickId(a) { return true }
    if let network = a.adNetwork, !network.isEmpty, network != "organic" { return true }
    // normalizeAdNetwork, não matchKnownAdNetwork: fonte desconhecida também é
    // tráfego rastreado — só o carimbo de loja/organic/direct fica de fora.
    if normalizeAdNetwork(a.utmSource) != nil { return true }
    guard let medium = a.utmMedium, !medium.isEmpty else { return false }
    let range = NSRange(medium.startIndex..., in: medium)
    return paidMediumRegex.firstMatch(in: medium, range: range) != nil
}

/// Rótulo da rede, do sinal mais forte para o mais fraco. Exportado para testes.
///
/// Precedência: rede resolvida pelo servidor no deferred-match (deriva do `ad_source`
/// do link, a mesma fonte que o painel usa) > click ID do próprio clique >
/// `utm_source` normalizado. Cru nunca sai daqui: `facebook`/`ig`/`fb4a` viram `meta`.
public func swDeriveAdNetwork(_ a: AttributionCapture) -> String? {
    if let network = a.adNetwork, !network.isEmpty { return network }
    if swPresent(a.fbclid) { return "meta" }
    if swPresent(a.ttclid) || swPresent(a.tiktokCampaignId) { return "tiktok" }
    if swPresent(a.gclid) { return "google" }
    return normalizeAdNetwork(a.utmSource)
}

/// Mapeia `AttributionCapture` (+ `distinctId` resolvido) → dicionário de atributos
/// Superwall com prefixo `pw_`. Retorna `["pw_is_paid": false]` (mais o
/// `pw_paywallo_id`, quando houver) para usuários orgânicos, para uma audience rule
/// conseguir separar orgânico de pago sem ambiguidade. Exportado para testes.
///
/// `distinctId` vazio é omitido: um `pw_paywallo_id` casável-mas-errado é pior para
/// segmentação do que atributo nenhum.
public func swBuildSuperwallAttributes(
    _ a: AttributionCapture?,
    distinctId: String? = nil
) -> [String: Any] {
    var out: [String: Any] = [:]
    func set(_ key: String, _ value: String?) {
        if let v = value, !v.isEmpty { out[key] = v }
    }
    set("pw_paywallo_id", distinctId)
    guard let a = a else {
        out["pw_is_paid"] = false
        return out
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
    set("pw_ad_network", swDeriveAdNetwork(a))
    // Confiança do rótulo acima. `pw_match_type` é o contrato estável das audience
    // rules; `pw_match_type_raw` carrega o veredito granular do servidor (ex.
    // probabilistic_high) só quando ele de fato respondeu — nunca no palpite local.
    let serverMatchType = a.matchType.flatMap { $0.isEmpty ? nil : $0 }
    if let raw = serverMatchType {
        set("pw_match_type", swCollapseMatchType(raw))
        set("pw_match_type_raw", raw)
    } else if swHasDeviceSideClickId(a) {
        set("pw_match_type", "deterministic")
    }
    out["pw_is_paid"] = swDeriveIsPaid(a)
    out["pw_attributed_at"] = a.capturedAt
    return out
}

/// Mapeia o `PaywallResult` do dismiss do Superwall para `close_reason` do Paywallo.
/// Exportado para testes unitários.
///
/// `PaywallHandler.handleClose` no servidor faz `resulted_in_purchase = (reason == "purchased")`,
/// então uma compra PRECISA sair como `purchased` — e um restore NÃO pode: restore não
/// é conversão nova e inflava a taxa de conversão do paywall.
public func swMapDismissToCloseReason(_ type: String) -> String? {
    switch type {
    case "purchased": return "purchased"
    case "restored": return "restored"
    case "declined": return "dismissed"
    default: return nil
    }
}

// MARK: - Attribute push — contrato com o SDK nativo

/// Estado de configuração do SDK do Superwall, reduzido ao que o gate precisa saber.
public enum SuperwallConfigStatus: Sendable {
    case configured
    case failed
    case pending
}

/// Resultado da espera pela configuração. `failed` não é retentável (o SDK avisou que
/// não vai configurar nesta sessão); `timeout` é.
public enum SuperwallConfigWaitResult: String, Sendable {
    case configured
    case failed
    case timeout
}

/// Resultado de UMA tentativa de push. `written`/`unchanged` significam que o Superwall
/// reflete o snapshot atual; `noModule`/`configFailed` que não vai refletir nesta
/// chamada; `configTimeout` que a gate de configuração não resolveu a tempo.
public enum SuperwallPushOutcome: String, Sendable {
    case written
    case unchanged
    case noModule = "no_module"
    case configFailed = "config_failed"
    case configTimeout = "config_timeout"
}

/// Resultado de `syncSuperwallAttributes`.
public enum SuperwallSyncOutcome: String, Sendable {
    case synced
    case timeout
    case skipped
}

/// Superfície mínima do SDK do Superwall que o attribute bridge usa. A implementação
/// real (`SuperwallKitSink`) vive dentro do `#if canImport(SuperwallKit)`; os testes
/// injetam a sua.
protocol SuperwallAttributeSink: AnyObject {
    /// Lança quando o status não pôde ser lido — tratado como `failed` pelo gate,
    /// porque não há o que retentar contra um SDK que não responde.
    func configurationStatus() throws -> SuperwallConfigStatus
    func setUserAttributes(_ attributes: [String: Any]) async throws
}

/// Assinatura determinística do conjunto de atributos — o guard de idempotência.
/// Dicionário do Swift não tem ordem, então as chaves são ordenadas antes.
func swAttributeSignature(_ attributes: [String: Any]) -> String {
    attributes.keys.sorted()
        .map { "\($0)=\(String(describing: attributes[$0] ?? ""))" }
        .joined(separator: "&")
}

// MARK: - Attribute push engine

/// Máquina do push: gate de configuração, guard de idempotência e backoff.
/// Sem estado global — o módulo guarda uma instância em `swPusher`.
final class SuperwallAttributePush: @unchecked Sendable {

    /// Lido SEMPRE depois da gate de configuração, nunca na entrada: atribuição que
    /// chega durante a espera (deep link morno, Install Referrer) não pode se perder
    /// para um snapshot velho.
    typealias SnapshotProvider = () -> (attribution: AttributionCapture?, distinctId: String?)

    private let sink: SuperwallAttributeSink
    private let snapshot: SnapshotProvider
    private let pollIntervalMs: Int
    private let pollMaxAttempts: Int
    private let retryDelaysMs: [Int]
    private let debug: Bool

    private let lock = NSLock()
    private var lastSignature: String?
    private var retryTask: Task<Void, Never>?

    init(
        sink: SuperwallAttributeSink,
        snapshot: @escaping SnapshotProvider,
        debug: Bool = false,
        pollIntervalMs: Int = PaywalloConstants.configPollIntervalMs,
        pollMaxAttempts: Int = PaywalloConstants.configPollMaxAttempts,
        retryDelaysMs: [Int] = PaywalloConstants.configRetryDelaysMs
    ) {
        self.sink = sink
        self.snapshot = snapshot
        self.debug = debug
        self.pollIntervalMs = pollIntervalMs
        self.pollMaxAttempts = pollMaxAttempts
        self.retryDelaysMs = retryDelaysMs
    }

    // MARK: Config gate

    /// Aguarda o SDK chegar em CONFIGURED. Nunca escreve num SDK não configurado —
    /// os atributos seriam descartados em silêncio.
    func waitForConfigured(maxAttempts: Int) async -> SuperwallConfigWaitResult {
        for _ in 0..<maxAttempts {
            let status: SuperwallConfigStatus
            do {
                status = try sink.configurationStatus()
            } catch {
                swLog(debug, "configurationStatus error: \(error)")
                return .failed
            }
            switch status {
            case .configured:
                return .configured
            case .failed:
                swLog(debug, "Superwall configuration FAILED — attribute push skipped")
                return .failed
            case .pending:
                try? await Task.sleep(nanoseconds: UInt64(pollIntervalMs) * 1_000_000)
            }
        }
        swLog(debug, "Superwall not configured within timeout — attribute push skipped")
        return .timeout
    }

    // MARK: Push

    func attempt(
        retryIndex: Int = 0,
        maxConfigAttempts: Int? = nil,
        scheduleRetryOnTimeout: Bool = true
    ) async -> SuperwallPushOutcome {
        let waited = await waitForConfigured(maxAttempts: maxConfigAttempts ?? pollMaxAttempts)
        if waited == .timeout {
            if scheduleRetryOnTimeout { scheduleRetry(retryIndex: retryIndex) }
            return .configTimeout
        }
        guard waited == .configured else { return .configFailed }

        let current = snapshot()
        let attrs = swBuildSuperwallAttributes(current.attribution, distinctId: current.distinctId)
        let signature = swAttributeSignature(attrs)
        if signature == readLastSignature() {
            swLog(debug, "attributes unchanged — skipping push")
            return .unchanged
        }
        do {
            try await sink.setUserAttributes(attrs)
            // A assinatura só persiste DEPOIS do write resolver: gravar antes faria
            // uma falha marcar o snapshot como enviado, e a próxima chamada idêntica
            // viraria no-op — o atributo nunca chegaria.
            writeLastSignature(signature)
            swLog(debug, "attributes pushed to Superwall")
        } catch {
            // Não fatal: push de atributo nunca pode derrubar o app do cliente.
            swLog(debug, "setUserAttributes error: \(error)")
        }
        return .written
    }

    // MARK: Backoff

    private func scheduleRetry(retryIndex: Int) {
        guard retryIndex < retryDelaysMs.count else {
            swLog(debug, "Superwall never configured — giving up attribute push")
            return
        }
        let delayMs = retryDelaysMs[retryIndex]
        cancelRetry()
        swLog(debug, "scheduling attribute push retry #\(retryIndex) in \(delayMs)ms")
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard !Task.isCancelled, let self = self else { return }
            _ = await self.attempt(retryIndex: retryIndex + 1)
        }
        lock.lock()
        retryTask = task
        lock.unlock()
    }

    /// Cancela só o backoff pendente, preservando `lastSignature` — teardown de
    /// Provider não pode forçar um re-push redundante no próximo mount.
    func cancelRetry() {
        lock.lock()
        let task = retryTask
        retryTask = nil
        lock.unlock()
        task?.cancel()
    }

    /// Zera o guard de idempotência (logout / testes): o próximo push escreve de novo.
    func reset() {
        cancelRetry()
        lock.lock()
        lastSignature = nil
        lock.unlock()
    }

    private func readLastSignature() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastSignature
    }

    private func writeLastSignature(_ signature: String) {
        lock.lock()
        lastSignature = signature
        lock.unlock()
    }
}

// MARK: - Just-in-time sync (chamado pelo app antes do register)

/// Corrida entre `operation` e um prazo. NÃO cancela `operation` — o refresh do
/// deferred-match tem o próprio timeout de rede; aqui só paramos de esperar por ele.
/// `nil` significa que o prazo venceu primeiro.
func swWithTimeout<T: Sendable>(
    ms: Int,
    _ operation: @escaping @Sendable () async -> T
) async -> T? {
    let box = SwRaceBox<T>()
    Task { let value = await operation(); box.settle(value) }
    Task {
        try? await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
        box.settle(nil)
    }
    return await box.wait()
}

/// Caixa de corrida de resolução única — o primeiro a chegar define o resultado.
private final class SwRaceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var value: T?
    private var continuation: CheckedContinuation<T?, Never>?

    func settle(_ newValue: T?) {
        lock.lock()
        if settled { lock.unlock(); return }
        settled = true
        value = newValue
        let waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume(returning: newValue)
    }

    func wait() async -> T? {
        await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            lock.lock()
            if settled {
                let resolved = value
                lock.unlock()
                c.resume(returning: resolved)
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }
}

/// Mapeia o resultado do push para o retorno público do sync. `nil` = o prazo estourou.
func swSyncOutcome(for pushOutcome: SuperwallPushOutcome?) -> SuperwallSyncOutcome {
    guard let outcome = pushOutcome else { return .timeout }
    switch outcome {
    case .written, .unchanged:
        return .synced
    // `configFailed`: o Superwall relatou que não vai configurar nesta sessão — mesmo
    // balde de "não dá pra tentar" que módulo ausente, não é questão de tempo.
    case .noModule, .configFailed:
        return .skipped
    case .configTimeout:
        return .timeout
    }
}

/// Orquestra o sync JIT dentro de um orçamento. Separado da API pública para ser
/// testável sem SuperwallKit — é aqui que mora a regra do prazo.
///
/// O orçamento é um DEADLINE, não uma fatia fixa: o refresh ganha tudo que sobrar até
/// o piso do push, e um servidor que responde rápido devolve o resto pro push em vez
/// de desperdiçar orçamento concedido.
func swRunSync(
    timeoutMs: Int,
    refresh: @escaping @Sendable () async -> Void,
    push: @escaping @Sendable () async -> SuperwallPushOutcome
) async -> SuperwallSyncOutcome {
    let budgetMs = max(0, timeoutMs)
    let deadline = Date().addingTimeInterval(TimeInterval(budgetMs) / 1000.0)

    let refreshBudgetMs = max(0, budgetMs - PaywalloConstants.minPushBudgetMs)
    _ = await swWithTimeout(ms: refreshBudgetMs) { await refresh(); return true }

    // Piso reservado pro push mesmo se o refresh consumir o orçamento inteiro: cobre
    // 1 poll de configuração + a chamada nativa. É piso best-effort, não garantia —
    // com o SDK ainda configurando o push volta `configTimeout` e o sync diz "timeout".
    let remainingMs = Int(deadline.timeIntervalSinceNow * 1000)
    let pushBudgetMs = max(PaywalloConstants.minPushBudgetMs, remainingMs)
    let outcome = await swWithTimeout(ms: pushBudgetMs) { await push() }
    return swSyncOutcome(for: outcome)
}

// MARK: - Module state

/// Instância viva do push. `nil` enquanto `startSuperwallBridge` não rodou (ou quando
/// SuperwallKit não está linkado) — é o equivalente ao "módulo nativo ausente" do RN.
private var swPusher: SuperwallAttributePush?

/// `ApiClient` para o refresh do deferred-match no sync JIT. `PaywalloClient` guarda o
/// dele privado, então o bridge recebe a referência no start.
private var swApiClient: ApiClient?

/// Guard de in-flight do refresh: `refreshDeferredAttributionNow` monta um scheduler
/// próprio por chamada. Sem isto, um caller sequencial que dispara dois syncs
/// concorrentes gera dois POSTs para o mesmo device — `swWithTimeout` só abandona a
/// espera, não cancela o request em voo.
private var swInFlightRefresh: Task<Void, Never>?

/// Cancela a inscrição em `attributionTracker.onCapture`.
private var swAttributionUnsubscribe: (() -> Void)?

private var swBridgeDebug = false

func swLog(_ debug: Bool, _ msg: String) {
    guard debug else { return }
    // print permitido no SDK sob flag debug (ver CLAUDE.md SDK)
    print("[Paywallo:SuperwallBridge] \(msg)")
}

private func swAttemptPush(
    maxConfigAttempts: Int? = nil,
    scheduleRetryOnTimeout: Bool = true
) async -> SuperwallPushOutcome {
    guard let pusher = swPusher else { return .noModule }
    return await pusher.attempt(
        maxConfigAttempts: maxConfigAttempts,
        scheduleRetryOnTimeout: scheduleRetryOnTimeout
    )
}

private func swRefreshAttributionFromServer(debug: Bool) async {
    guard let api = swApiClient else { return }
    if let existing = swInFlightRefresh {
        await existing.value
        return
    }
    let task = Task { await refreshDeferredAttributionNow(apiClient: api, debug: debug) }
    swInFlightRefresh = task
    await task.value
    swInFlightRefresh = nil
}

/// Arma o attribute bridge sobre um sink e dispara o primeiro push.
///
/// Compartilhado entre a implementação real e os testes de propósito: é aqui que mora
/// o re-push por enriquecimento de atribuição, e ele precisa ser compilado mesmo em
/// build sem SuperwallKit.
func swArmAttributeBridge(
    sink: SuperwallAttributeSink,
    attribution: AttributionTracker,
    distinctIdProvider: (() -> String)?,
    apiClient: ApiClient?,
    debug: Bool
) {
    swBridgeDebug = debug
    swApiClient = apiClient

    swPusher?.cancelRetry()
    swPusher = SuperwallAttributePush(
        sink: sink,
        // `distinctId` resolvido no momento do push, não no start: a identidade pode
        // ainda não estar hidratada quando o bridge sobe.
        snapshot: { (attribution.get(), distinctIdProvider?()) },
        debug: debug
    )

    // A atribuição costuma resolver DEPOIS do primeiro open (deferred-match, deep link
    // morno, Install Referrer). Sem re-push, o Superwall ficaria com o snapshot
    // orgânico da inicialização para sempre. Idempotente por assinatura — um capture
    // que não muda nada é no-op local.
    swAttributionUnsubscribe?()
    swAttributionUnsubscribe = attribution.onCapture { _ in
        Task { await pushAttributionToSuperwall() }
    }

    Task { await pushAttributionToSuperwall() }
}

/// Desarma o attribute bridge: cancela a inscrição, o backoff e o guard de assinatura.
func swDisarmAttributeBridge() {
    swAttributionUnsubscribe?()
    swAttributionUnsubscribe = nil
    swPusher?.reset()
    swPusher = nil
    swApiClient = nil
    swInFlightRefresh = nil
}

// MARK: - Public API (attribute bridge)

/**
 Empurra a atribuição atual do device para o Superwall como user attributes.

 Seguro de chamar várias vezes (idempotente por assinatura) e seguro quando o
 SuperwallKit não está presente (no-op silencioso). Nunca lança.

 Chame DEPOIS de `PaywalloClient.shared.initialize()` (a atribuição é hidratada lá) e
 ANTES do primeiro `register()`. Se o SDK ainda não configurou, espera (best-effort)
 antes de escrever; quando a configuração não chega na janela de poll, o push retenta
 com backoff (30s/60s/120s).

 É também o ponto que `AttributionTracker.onCapture` deve chamar quando a atribuição
 enriquece (deep link morno, deferred-match): o re-push é idempotente por assinatura.
 */
public func pushAttributionToSuperwall() async {
    swPusher?.cancelRetry()
    _ = await swAttemptPush()
}

/**
 Sincroniza os atributos `pw_*` no Superwall AGORA e resolve dentro de `timeoutMs`,
 aconteça o que acontecer.

 Chame imediatamente ANTES de `register()`. O Superwall avalia as audience rules
 on-device no momento do register, e a variante que o usuário receber ali gruda nele
 até o assignment ser resetado — atributo que chega depois não reclassifica ninguém.
 Como a atribuição do Paywallo pode resolver segundos após o primeiro open
 (deferred-match), sem este ponto de sincronia o usuário vindo de ads é avaliado como
 orgânico e fica assim.

 Faz duas coisas dentro do orçamento: pergunta ao servidor se o install casou com
 algum clique (ignorando a espera do backoff) e empurra o resultado pro Superwall.
 Nunca lança, nunca segura o paywall além do timeout.

 - Returns: `.synced` quando o push escreveu (ou já estava sincronizado); `.timeout`
   quando o orçamento acabou antes de escrever; `.skipped` quando o SDK do Superwall
   não está disponível.
 */
@discardableResult
public func syncSuperwallAttributes(
    timeoutMs: Int = PaywalloConstants.defaultSyncTimeoutMs,
    debug: Bool = false
) async -> SuperwallSyncOutcome {
    let logDebug = debug || swBridgeDebug
    let outcome = await swRunSync(
        timeoutMs: timeoutMs,
        refresh: { await swRefreshAttributionFromServer(debug: logDebug) },
        // Gate de configuração curto e sem reagendar backoff: se o Superwall ainda não
        // configurou, não há paywall pra mostrar e o push periódico normal cobre o
        // resto. Cancelar o backoff em voo aqui deixaria o device sem tentativa futura.
        push: { await swAttemptPush(maxConfigAttempts: 2, scheduleRetryOnTimeout: false) }
    )
    swLog(logDebug, "syncSuperwallAttributes → \(outcome.rawValue)")
    return outcome
}

/**
 Cancela apenas o retry pendente do attribute bridge, sem limpar a assinatura.
 Para teardown sem forçar re-push desnecessário no próximo start.
 */
public func cancelSuperwallAttributeRetry() {
    swPusher?.cancelRetry()
}

/**
 Reseta o guard de idempotência do attribute bridge (testes e logout): o próximo push
 escreve de novo mesmo com a atribuição inalterada.
 */
public func resetSuperwallAttributePush() {
    swPusher?.reset()
    swInFlightRefresh = nil
}

// MARK: - SuperwallKit integration

#if canImport(SuperwallKit)

import SuperwallKit

// MARK: - Auto Bridge state

private var bridgeStarted = false
private var seenTransactionIds: Set<String> = []
private var bridgeDelegate: SwBridgeDelegate?

// MARK: - Sink real

/// Implementação de `SuperwallAttributeSink` sobre `Superwall.shared`.
private final class SuperwallKitSink: SuperwallAttributeSink {
    func configurationStatus() throws -> SuperwallConfigStatus {
        switch Superwall.shared.configurationStatus {
        case .configured: return .configured
        case .failed: return .failed
        default: return .pending
        }
    }

    func setUserAttributes(_ attributes: [String: Any]) async throws {
        Superwall.shared.setUserAttributes(attributes)
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
        swLog(debug, "paywallDidAppear: \(paywallInfo.identifier)")
        PaywalloClient.shared.track(
            "paywall",
            properties: buildViewedProps(info: paywallInfo),
            priority: .critical
        )
    }

    // MARK: Paywall closed

    /// O `close_reason` vem do `PaywallResult` do dismiss, não de `paywallInfo.closeReason`:
    /// esse último é outro domínio (`systemLogic`/`manualClose`/...) e nenhum dos seus
    /// valores casa com o mapa, então toda compra pelo paywall do Superwall caía no
    /// default e virava `dismissed` — o servidor nunca marcava `resulted_in_purchase`.
    func paywallDidDisappear(withInfo paywallInfo: PaywallInfo, result: PaywallResult) {
        let mappedReason = swMapDismissToCloseReason(swPaywallResultToken(result)) ?? "dismissed"
        swLog(debug, "paywallDidDisappear: \(paywallInfo.identifier) reason=\(mappedReason)")
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

        // Mesma lógica do RN: free trial só quando introPrice <= 0. Uma oferta intro
        // PAGA é receita real e vai como `completed` pelo valor da intro.
        let isTrial = hasFreeTrial && introPrice <= 0
        let isPaidIntro = introPrice > 0

        swLog(debug, "transactionDidSucceed: \(productId) trial=\(isTrial) introPrice=\(introPrice)")

        // `paywall {type: "purchased"}` — equivalente do `onPurchase` do RN. É o evento
        // que liga a compra ao paywall; o `transaction` abaixo é o que cria a linha de
        // receita no servidor. Emitido depois do dedup para não duplicar a atribuição.
        var purchasedProps = buildViewedProps(info: paywallInfo)
        purchasedProps["type"] = AnyCodable("purchased")
        purchasedProps["product_id"] = AnyCodable(productId)
        PaywalloClient.shared.track("paywall", properties: purchasedProps, priority: .critical)

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

/// Token textual do `PaywallResult`, no mesmo vocabulário que o RN entrega
/// (`result.type`) — mantém `swMapDismissToCloseReason` livre de SuperwallKit.
private func swPaywallResultToken(_ result: PaywallResult) -> String {
    switch result {
    case .purchased: return "purchased"
    case .restored: return "restored"
    case .declined: return "declined"
    @unknown default: return "declined"
    }
}

// MARK: - Public API (bridge lifecycle)

/**
 Inicia o Superwall bridge bidirecional. Idempotente — chamadas repetidas são no-op
 para o auto bridge e um re-push idempotente para os atributos.

 - Parameter attribution: `AttributionTracker` para leitura dos campos `pw_*`.
 - Parameter distinctIdProvider: resolve o `distinctId` no momento do push (não no
   start): a identidade pode ainda não estar hidratada quando o bridge sobe.
 - Parameter apiClient: usado por `syncSuperwallAttributes` para perguntar ao servidor
   se o install casou com algum clique. Sem ele o sync só empurra o que já existe.
 - Parameter debug: Quando `true`, habilita logs de diagnóstico.

 Chame APÓS `PaywalloClient.shared.initialize()` e ANTES do primeiro `register()`.
 */
public func startSuperwallBridge(
    attribution: AttributionTracker = .shared,
    distinctIdProvider: (@Sendable () -> String)? = nil,
    apiClient: ApiClient? = nil,
    debug: Bool = false
) {
    // 1. Attribute bridge (fire-and-forget, com re-push por enriquecimento)
    swArmAttributeBridge(
        sink: SuperwallKitSink(),
        attribution: attribution,
        distinctIdProvider: distinctIdProvider,
        apiClient: apiClient,
        debug: debug
    )

    // 2. Auto bridge (idempotente)
    guard !bridgeStarted else {
        swLog(debug, "already started, skipping")
        return
    }
    let delegate = SwBridgeDelegate(debug: debug)
    bridgeDelegate = delegate
    Superwall.shared.delegate = delegate
    bridgeStarted = true
    swLog(debug, "bridge started")
}

/**
 Para o auto bridge, cancela retries pendentes e descarta o guard de idempotência.
 Primariamente para testes e teardown.
 */
public func stopSuperwallBridge() {
    swDisarmAttributeBridge()

    if bridgeStarted {
        Superwall.shared.delegate = nil
        bridgeDelegate = nil
    }
    bridgeStarted = false
    seenTransactionIds.removeAll()
}

#else

// MARK: - No-op stubs (SuperwallKit não linkado)

/// Sem SuperwallKit não há sink: `swPusher` fica nil, todo push responde `noModule` e
/// `syncSuperwallAttributes` responde `.skipped`.
public func startSuperwallBridge(
    attribution: AttributionTracker = .shared,
    distinctIdProvider: (@Sendable () -> String)? = nil,
    apiClient: ApiClient? = nil,
    debug: Bool = false
) {
    swBridgeDebug = debug
    swApiClient = apiClient
}

public func stopSuperwallBridge() {
    swDisarmAttributeBridge()
}

#endif
