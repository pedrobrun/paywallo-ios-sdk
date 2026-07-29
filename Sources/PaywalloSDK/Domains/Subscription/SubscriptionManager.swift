import Foundation

#if canImport(StoreKit)
import StoreKit
#endif

public struct SubscriptionManagerConfig {
    public let serverUrl: String
    public let appKey: String
    public var cacheTTL: TimeInterval?
    public var debug: Bool

    public init(serverUrl: String, appKey: String, cacheTTL: TimeInterval? = nil, debug: Bool = false) {
        self.serverUrl = serverUrl
        self.appKey = appKey
        self.cacheTTL = cacheTTL
        self.debug = debug
    }
}

public typealias SubscriptionListener = (SubscriptionStatusResponse) -> Void

public final class SubscriptionManager: @unchecked Sendable {
    private var config: SubscriptionManagerConfig?
    private var apiClient: ApiClient?
    private var cache: SubscriptionCache
    private var listeners: [UUID: SubscriptionListener] = [:]
    private var userId: String?

    public init(cache: SubscriptionCache = SubscriptionCache()) {
        self.cache = cache
    }

    /// Inject the shared ApiClient so `fetchSubscriptionStatus` uses the global
    /// headers (x-sdk-version, x-sdk-platform, x-sdk-environment) instead of
    /// building its own URLRequest.
    public func setApiClient(_ client: ApiClient) {
        self.apiClient = client
    }

    private var cacheKey: String {
        userId ?? "__anonymous__"
    }

    public func initialize(_ config: SubscriptionManagerConfig) {
        self.config = config
        if let ttl = config.cacheTTL {
            Task { await self.cache.setTTL(ttl) }
        }
    }

    public func setUserId(_ userId: String?) {
        if self.userId != userId {
            self.userId = userId
            Task { await cache.invalidateAll() }
        }
    }

    public func hasActiveSubscription(forceRefresh: Bool = false) async -> Bool {
        let status = await getSubscriptionStatus(forceRefresh: forceRefresh)
        return status.hasActiveSubscription
    }

    public func getSubscription(forceRefresh: Bool = false) async -> Subscription? {
        let status = await getSubscriptionStatus(forceRefresh: forceRefresh)
        return status.subscription
    }

    public func getSubscriptionStatus(forceRefresh: Bool = false) async -> SubscriptionStatusResponse {
        guard config != nil else {
            return emptyStatus()
        }

        if !forceRefresh {
            if let cached = await cache.get(cacheKey), !cached.isStale {
                return cached.data
            }
        }

        do {
            let status = try await fetchSubscriptionStatus()
            await cache.set(cacheKey, data: status)
            notifyListeners(status)
            return status
        } catch {
            log("Failed to fetch subscription status", error)

            if let cached = await cache.get(cacheKey) {
                return cached.data
            }

            return emptyStatus()
        }
    }

    public func restorePurchases() async throws -> SubscriptionStatusResponse {
        guard config != nil else {
            throw SessionError(code: SessionErrorCode.notInitialized, message: "SubscriptionManager not initialized")
        }

        // Step 1: native StoreKit 2 sync — forces App Store to re-verify entitlements
        // and pushes any missing transactions to Transaction.currentEntitlements.
        #if canImport(StoreKit)
        if #available(iOS 15.0, macOS 12.0, *) {
            do {
                try await AppStore.sync()
                log("AppStore.sync() completed")
            } catch {
                log("AppStore.sync() failed (non-fatal): \(error.localizedDescription)")
            }

            // Step 2: iterate current entitlements so the local StoreKit state is
            // up-to-date before we hit the server for subscription status.
            var restoredCount = 0
            for await result in Transaction.currentEntitlements {
                switch result {
                case .verified(let transaction):
                    log("Entitlement restored: \(transaction.productID) txn=\(transaction.id)")
                    restoredCount += 1
                case .unverified(let transaction, let error):
                    log("Entitlement unverified: \(transaction.productID) — \(error.localizedDescription)")
                }
            }
            log("Native restore found \(restoredCount) entitlements")
        }
        #endif

        // Step 3: invalidate cache and refresh subscription status from server
        // (combines native restore result with server source-of-truth).
        await cache.invalidate(cacheKey)
        return await getSubscriptionStatus(forceRefresh: true)
    }

    private func log(_ message: String) {
        guard config?.debug == true else { return }
        print("[Paywallo:Subscription] \(message)")
    }

    public func onPurchaseComplete() async {
        await cache.invalidate(cacheKey)
        _ = await getSubscriptionStatus(forceRefresh: true)
    }

    @discardableResult
    public func addListener(_ listener: @escaping SubscriptionListener) -> () -> Void {
        let id = UUID()
        listeners[id] = listener
        return { [weak self] in
            self?.listeners.removeValue(forKey: id)
        }
    }

    // MARK: - Private

    private func fetchSubscriptionStatus() async throws -> SubscriptionStatusResponse {
        guard config != nil else {
            return emptyStatus()
        }

        // Prefer ApiClient so the global SDK headers (x-sdk-version, x-sdk-platform,
        // x-sdk-environment) are always included in the request.
        if let client = apiClient {
            let encoded = userId.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) }
            return try await client.getSubscriptionStatus(distinctId: encoded)
        }

        // Fallback: build request manually when ApiClient is not yet injected.
        guard let config = config else { return emptyStatus() }
        var urlString = "\(config.serverUrl)/sdk/purchases/status"
        if let userId = userId {
            let encoded = userId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? userId
            urlString += "?distinctId=\(encoded)"
        }
        guard let url = URL(string: urlString) else {
            throw SessionError(code: SessionErrorCode.restoreFailed, message: "Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.appKey, forHTTPHeaderField: "X-App-Key")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SessionError(
                code: SessionErrorCode.restoreFailed,
                message: "Failed to fetch subscription status: \(statusCode)"
            )
        }
        let envelope = try JSONDecoder().decode(V2Envelope<SubscriptionStatusResponse>.self, from: data)
        return envelope.data
    }

    private func emptyStatus() -> SubscriptionStatusResponse {
        SubscriptionStatusResponse(hasActiveSubscription: false, subscription: nil)
    }

    private func notifyListeners(_ status: SubscriptionStatusResponse) {
        for listener in listeners.values {
            listener(status)
        }
    }

    private func log(_ message: String, _ error: Error? = nil) {
        guard config?.debug == true else { return }
        if let error = error {
            print("[Paywallo:Subscription] \(message): \(error)")
        } else {
            print("[Paywallo:Subscription] \(message)")
        }
    }
}
