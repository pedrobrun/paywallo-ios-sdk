import Foundation

// MARK: - Snapshot

/// Snapshot returned to callers — contains paywall config + StoreKit products.
public struct PreloadedPaywallSnapshot: Sendable {
    public let config: PaywallConfig
    public let products: [String: Product]
}

// MARK: - Preload result

/// Resultado de um `preload`. O caller precisa distinguir "esse placement não existe"
/// de "a rede caiu" — engolir os dois num log deixava o app sem como reagir.
public struct PreloadPaywallResult: @unchecked Sendable {
    public let success: Bool
    public let error: Error?

    public init(success: Bool, error: Error? = nil) {
        self.success = success
        self.error = error
    }
}

// MARK: - PreloadEntry (private)

private struct PaywallPreloadEntry {
    let config: PaywallConfig
    let products: [String: Product]
    let storedAt: Date
    let ttl: TimeInterval

    var isExpired: Bool {
        Date().timeIntervalSince(storedAt) >= ttl
    }

    /// Returns true when 75% of TTL has elapsed (stale-while-revalidate threshold).
    var isStale: Bool {
        Date().timeIntervalSince(storedAt) >= ttl * 0.75
    }

    var snapshot: PreloadedPaywallSnapshot {
        PreloadedPaywallSnapshot(config: config, products: products)
    }
}

// MARK: - PaywallPreloadService

/// Caches paywall config + StoreKit products so `presentPaywall` skips the
/// round-trip to the backend and store.
///
/// Thread-safety: NSLock guards the in-memory maps. Concurrent preloads for
/// the same placement are deduplicated via an in-flight Task dictionary.
///
/// Stale-while-revalidate (75% threshold): a read returns the cached snapshot
/// immediately and triggers a background refresh when the entry is near expiry.
///
/// HTTP prewarm: `prewarmHTTP(for:)` fires a HEAD request to
/// `<webUrl>/paywall/preheat` to warm Next.js edge caches before the user
/// opens the paywall. Full WebView prewarm is deferred to presentation time.
public final class PaywallPreloadService: @unchecked Sendable {

    // MARK: - Configuration

    private let preloadTTL: TimeInterval   // default: 5 min
    private let staggerDelay: TimeInterval // default: 200ms between placements

    // MARK: - Dependencies

    private let apiClient: ApiClient
    private let iapService: IAPService
    private let debug: Bool

    // MARK: - State

    private let lock = NSLock()
    private var cache: [String: PaywallPreloadEntry] = [:]
    private var inFlight: [String: Task<PreloadPaywallResult, Never>] = [:]

    // MARK: - Init

    public init(
        apiClient: ApiClient,
        iapService: IAPService,
        debug: Bool = false,
        preloadTTL: TimeInterval = 5 * 60,
        staggerDelay: TimeInterval = 0.2
    ) {
        self.apiClient = apiClient
        self.iapService = iapService
        self.debug = debug
        self.preloadTTL = preloadTTL
        self.staggerDelay = staggerDelay
    }

    // MARK: - Public API

    /// Preloads a single paywall placement into the cache.
    /// Returns immediately if the placement is already cached and fresh.
    /// Deduplicates concurrent calls for the same placement.
    @discardableResult
    public func preload(_ placement: String) async -> PreloadPaywallResult {
        // Return immediately if cache is fresh
        if let cached = getCached(placement), !cached.isExpired {
            if cached.isStale {
                triggerBackgroundRevalidate(placement)
            }
            return PreloadPaywallResult(success: true)
        }

        // Dedup: await existing in-flight task
        if let existing = getInFlight(placement) {
            return await existing.value
        }

        let task = Task<PreloadPaywallResult, Never> {
            defer { self.removeInFlight(placement) }
            return await self.fetchAndCache(placement)
        }
        setInFlight(placement, task: task)
        return await task.value
    }

    /// Preloads multiple placements, disparando cada um com 200ms de intervalo mas
    /// SEM esperar o anterior terminar: serializado, cada placement pagava rede +
    /// StoreKit do anterior e a fila inteira levava segundos. Erros individuais são
    /// engolidos — uma falha não pode abortar as outras, e `presentPaywall` cai no
    /// fetch direto quando o cache erra.
    public func preloadMany(_ placements: [String]) async {
        guard !placements.isEmpty else { return }
        log("preloading \(placements.count) placements")
        await withTaskGroup(of: Void.self) { group in
            for (index, placement) in placements.enumerated() {
                if index > 0 {
                    // Stagger para não martelar a API na inicialização.
                    try? await Task.sleep(nanoseconds: UInt64(staggerDelay * 1_000_000_000))
                }
                group.addTask { _ = await self.preload(placement) }
            }
        }
    }

    /// Returns the cached snapshot for a placement, or nil if not cached / expired.
    /// Triggers a background revalidation if the entry is stale (>75% of TTL elapsed).
    public func getPreloaded(_ placement: String) -> PreloadedPaywallSnapshot? {
        guard let entry = getCached(placement) else { return nil }
        if entry.isExpired {
            removeCached(placement)
            return nil
        }
        if entry.isStale {
            triggerBackgroundRevalidate(placement)
        }
        return entry.snapshot
    }

    /// Returns true when a fresh (non-expired) entry is cached for the placement.
    public func isPaywallPreloaded(_ placement: String) -> Bool {
        getPreloaded(placement) != nil
    }

    /// Fires a HEAD request to `<webUrl>/paywall/preheat` to warm the Next.js
    /// HTTP cache (edge/CDN) before the user opens the paywall.
    ///
    /// Note: WebView prewarm (loading the page off-screen) requires UIKit and is
    /// handled at presentation time by the caller. This method only warms the
    /// network layer via URLSession — it is safe to call from any context.
    public func prewarmHTTP(for placement: String) {
        let webUrl = apiClient.getWebUrl()
        let urlString = "\(webUrl)/paywall/preheat"
        guard let url = URL(string: urlString) else { return }

        Task {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.httpMethod = "HEAD"
            do {
                let options = RequestOptions(method: "HEAD", skipRetry: true, timeout: 10)
                let _ = try await apiClient.httpClient.requestRaw(path: url.absoluteString, options: options)
                log("preheat done for placement: \(placement)")
            } catch {
                log("preheat failed for \(placement): \(error.localizedDescription)")
            }
        }
    }

    /// Clears all cached entries and cancels in-flight tasks.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        inFlight.removeAll()
    }

    // MARK: - Private: Fetch & Cache

    private func fetchAndCache(_ placement: String) async -> PreloadPaywallResult {
        do {
            let config = try await apiClient.getPaywall(placement)
            let products = await loadProducts(for: config)
            let entry = PaywallPreloadEntry(
                config: config,
                products: products,
                storedAt: Date(),
                ttl: preloadTTL
            )
            setCache(placement, entry: entry)
            log("cached placement: \(placement)")
            return PreloadPaywallResult(success: true)
        } catch {
            let mapped = mapPreloadError(error, placement: placement)
            log("preload failed for \(placement): \(mapped)")
            return PreloadPaywallResult(success: false, error: mapped)
        }
    }

    /// Erro do domínio (já classificado pela camada de API) passa direto. O transporte
    /// não lança em 404 — um placement inexistente volta com corpo que não decodifica
    /// em `PaywallConfig`, que é o "config nulo" do RN.
    private func mapPreloadError(_ error: Error, placement: String) -> Error {
        if let known = error as? PaywalloError { return known }
        if error is DecodingError {
            return PaywallDomainError(
                code: PaywallErrorCode.notFound,
                message: "Paywall not found for placement: \(placement)"
            )
        }
        return PaywallDomainError(code: PaywallErrorCode.loadFailed, message: String(describing: error))
    }

    private func loadProducts(for config: PaywallConfig) async -> [String: Product] {
        var ids: [String] = []
        if let p = config.primaryProductId { ids.append(p) }
        if let s = config.secondaryProductId { ids.append(s) }
        if let t = config.tertiaryProductId { ids.append(t) }
        guard !ids.isEmpty else { return [:] }

        let loaded = await iapService.loadProducts(productIds: ids)
        var map: [String: Product] = [:]
        for product in loaded { map[product.productId] = product }
        return map
    }

    private func triggerBackgroundRevalidate(_ placement: String) {
        guard getInFlight(placement) == nil else { return }
        let task = Task<PreloadPaywallResult, Never> {
            defer { self.removeInFlight(placement) }
            return await self.fetchAndCache(placement)
        }
        setInFlight(placement, task: task)
    }

    // MARK: - Private: Thread-safe accessors

    private func getCached(_ placement: String) -> PaywallPreloadEntry? {
        lock.lock()
        defer { lock.unlock() }
        return cache[placement]
    }

    private func setCache(_ placement: String, entry: PaywallPreloadEntry) {
        lock.lock()
        defer { lock.unlock() }
        cache[placement] = entry
    }

    private func removeCached(_ placement: String) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: placement)
    }

    private func getInFlight(_ placement: String) -> Task<PreloadPaywallResult, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return inFlight[placement]
    }

    private func setInFlight(_ placement: String, task: Task<PreloadPaywallResult, Never>) {
        lock.lock()
        defer { lock.unlock() }
        inFlight[placement] = task
    }

    private func removeInFlight(_ placement: String) {
        lock.lock()
        defer { lock.unlock() }
        inFlight.removeValue(forKey: placement)
    }

    // MARK: - Logging

    private func log(_ msg: String) {
        guard debug else { return }
        print("[Paywallo:PaywallPreload] \(msg)")
    }
}
