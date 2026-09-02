import Foundation

/// In-memory preload entry for a campaign placement. Só existe entrada para resposta
/// de verdade — erro nunca vira cache.
private struct PreloadEntry {
    let response: CampaignResponse
    let storedAt: Date
    let ttl: TimeInterval

    var isExpired: Bool {
        Date().timeIntervalSince(storedAt) >= ttl
    }

    /// Returns true when 80% of TTL has elapsed (stale-while-revalidate threshold).
    var isStale: Bool {
        Date().timeIntervalSince(storedAt) >= ttl * 0.8
    }
}

/// Resultado da resolução de uma campanha para apresentação.
///
/// "Não existe campanha nesse placement" e "o usuário já é assinante" são coisas
/// diferentes: colapsar as duas em `nil` fazia o client rotular toda falha de
/// configuração como `skippedReason: "subscriber"`, e o app nunca ficava sabendo que
/// o placement estava errado.
public enum CampaignGateOutcome {
    case campaign(CampaignResponse)
    case notFound(CampaignError)
    case subscriber
}

public final class CampaignGateService: @unchecked Sendable {
    // MARK: - Configuration

    private let preloadTTL: TimeInterval
    private let staleThreshold: TimeInterval    // 80% of TTL = 4 min by default
    private let waitPollInterval: TimeInterval  // 100ms
    private let waitMaxDuration: TimeInterval   // 2000ms
    private let activePreloadDelay: TimeInterval // 500ms between placements

    // MARK: - Dependencies

    private let apiClient: ApiClient
    private let subscriptionManager: SubscriptionManager

    // MARK: - State

    private let lock = NSLock()
    private var preloadCache: [String: PreloadEntry] = [:]
    private var activePreloadPromises: [String: Task<CampaignResponse?, Never>] = [:]

    // MARK: - Init

    public init(
        apiClient: ApiClient,
        subscriptionManager: SubscriptionManager,
        preloadTTL: TimeInterval = 5 * 60,
        waitPollInterval: TimeInterval = 0.1,
        waitMaxDuration: TimeInterval = 2.0,
        activePreloadDelay: TimeInterval = 0.5
    ) {
        self.apiClient = apiClient
        self.subscriptionManager = subscriptionManager
        self.preloadTTL = preloadTTL
        self.staleThreshold = preloadTTL * 0.8
        self.waitPollInterval = waitPollInterval
        self.waitMaxDuration = waitMaxDuration
        self.activePreloadDelay = activePreloadDelay
    }

    // MARK: - Preload

    /// Preload a campaign placement into memory cache. Deduplicates concurrent calls.
    @discardableResult
    public func preloadCampaign(
        _ placement: String,
        distinctId: String?,
        context: [String: AnyCodable]? = nil
    ) async -> CampaignResponse? {
        // Return cached if still fresh
        if let cached = getCached(placement), !cached.isExpired {
            // Background revalidate if stale
            if cached.isStale {
                Task { await self.fetchAndCache(placement, distinctId: distinctId, context: context) }
            }
            return cached.response
        }

        // Dedup: reuse existing in-flight task
        if let existing = getActivePromise(placement) {
            return await existing.value
        }

        let task = Task<CampaignResponse?, Never> {
            defer { self.removeActivePromise(placement) }
            return await self.fetchAndCache(placement, distinctId: distinctId, context: context)
        }

        setActivePromise(placement, task: task)
        return await task.value
    }

    /// Preload all active campaign placements one at a time with 500ms delay between them.
    public func preloadAllActive(distinctId: String?) async {
        do {
            let placements = try await apiClient.getCampaignPlacements()
            for (index, placement) in placements.enumerated() {
                if index > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(activePreloadDelay * 1_000_000_000))
                }
                await preloadCampaign(placement, distinctId: distinctId, context: nil)
            }
        } catch {
            // Non-critical — best effort
        }
    }

    // MARK: - Wait for preload

    /// Espera um preload EM VOO para o placement terminar (teto de 2s) e devolve o que
    /// ficou em cache.
    ///
    /// Sem preload em voo, retorna na hora: o loop dormia os 2s inteiros em todo
    /// caminho frio, e como `presentCampaign` e `isPreloaded` chamam isto antes do
    /// fetch, cada apresentação fria pagava 2s de latência para não descobrir nada.
    public func waitForPreload(_ placement: String) async -> CampaignResponse? {
        guard getActivePromise(placement) != nil else {
            return getCached(placement)?.response
        }

        let deadline = Date().addingTimeInterval(waitMaxDuration)
        while Date() < deadline {
            if getActivePromise(placement) == nil { break }
            try? await Task.sleep(nanoseconds: UInt64(waitPollInterval * 1_000_000_000))
        }

        // Devolve o que ficou em cache — inclusive stale — mesmo se estourou o teto.
        return getCached(placement)?.response
    }

    // MARK: - Present campaign

    /// Resolve a campanha para apresentação, distinguindo "não existe" de "assinante".
    /// - forceShow: pula a checagem de assinatura, apresenta independente do status.
    ///
    /// A campanha é resolvida ANTES da checagem de assinatura: invertido, um placement
    /// inexistente respondia "subscriber" para todo assinante e o erro de configuração
    /// só aparecia para quem não assinava.
    public func resolveCampaign(
        placement: String,
        distinctId: String?,
        context: [String: AnyCodable]? = nil,
        forceShow: Bool = false
    ) async -> CampaignGateOutcome {
        // Espera um preload em voo (retorna na hora se não houver) antes de olhar o cache.
        _ = await waitForPreload(placement)

        var resolved: CampaignResponse?
        if let cached = getCached(placement), !cached.isExpired {
            if cached.isStale {
                Task { await self.fetchAndCache(placement, distinctId: distinctId, context: context) }
            }
            resolved = cached.response
        } else {
            resolved = await fetchAndCache(placement, distinctId: distinctId, context: context)
        }

        guard let campaign = resolved else {
            return .notFound(CampaignError(
                code: CampaignErrorCode.notFound,
                message: "No campaign found for placement: \(placement)"
            ))
        }

        if !forceShow {
            let hasActive = await subscriptionManager.hasActiveSubscription()
            if hasActive { return .subscriber }
        }

        return .campaign(campaign)
    }

    /// Atalho legado: descarta a distinção entre "não encontrada" e "assinante".
    /// Prefira `resolveCampaign` — é ela que carrega o motivo.
    public func presentCampaign(
        placement: String,
        distinctId: String?,
        context: [String: AnyCodable]? = nil,
        forceShow: Bool = false
    ) async -> CampaignResponse? {
        let outcome = await resolveCampaign(
            placement: placement,
            distinctId: distinctId,
            context: context,
            forceShow: forceShow
        )
        guard case .campaign(let campaign) = outcome else { return nil }
        return campaign
    }

    // MARK: - Cache invalidation

    public func invalidateCache(for placement: String) {
        lock.lock()
        defer { lock.unlock() }
        preloadCache.removeValue(forKey: placement)
    }

    public func invalidateAllCache() {
        lock.lock()
        defer { lock.unlock() }
        preloadCache.removeAll()
    }

    // MARK: - Private helpers

    @discardableResult
    private func fetchAndCache(
        _ placement: String,
        distinctId: String?,
        context: [String: AnyCodable]? = nil
    ) async -> CampaignResponse? {
        do {
            let response = try await apiClient.getCampaign(placement, distinctId: distinctId, context: context)
            let entry = PreloadEntry(response: response, storedAt: Date(), ttl: preloadTTL)
            setCache(placement, entry: entry)
            return response
        } catch {
            // Falha de rede não é resultado: gravar um tombstone com o TTL cheio fazia
            // um erro transitório bloquear a campanha pelos 5 minutos seguintes.
            return nil
        }
    }

    private func getCached(_ placement: String) -> PreloadEntry? {
        lock.lock()
        defer { lock.unlock() }
        return preloadCache[placement]
    }

    private func setCache(_ placement: String, entry: PreloadEntry) {
        lock.lock()
        defer { lock.unlock() }
        preloadCache[placement] = entry
    }

    private func getActivePromise(_ placement: String) -> Task<CampaignResponse?, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return activePreloadPromises[placement]
    }

    private func setActivePromise(_ placement: String, task: Task<CampaignResponse?, Never>) {
        lock.lock()
        defer { lock.unlock() }
        activePreloadPromises[placement] = task
    }

    private func removeActivePromise(_ placement: String) {
        lock.lock()
        defer { lock.unlock() }
        activePreloadPromises.removeValue(forKey: placement)
    }
}
