import Foundation

public final class PaywalloClient {
    public static let shared = PaywalloClient()

    // Subsystems
    private var config: PaywalloInitConfig?
    private var apiClient: ApiClient?
    private var apiClientQueue: ApiClientQueue?
    private var identityManager = IdentityManager()
    private var sessionManager = SessionManager()
    private var sessionTracking: SessionTracking?
    private var sessionLifecycle: SessionLifecycle?
    private var eventBatcher = EventBatcher()
    private var offlineQueue = OfflineQueue()
    private var queueProcessor: QueueProcessor?
    private var subscriptionManager = SubscriptionManager()
    private var subscriptionCache = SubscriptionCache()
    private var onboardingManager = OnboardingManager()
    private var notificationsManager: NotificationsManager?
    private var networkMonitor = NetworkMonitor.shared
    private var advertisingIdManager = AdvertisingIdManager.shared
    private var attributionTracker = AttributionTracker()
    private var deepLinkCapture: DeepLinkAttributionCapture?
    private var installTracker = InstallTracker()
    private var metaBridge = MetaBridge.shared
    private var autoEvents = AutoEvents()
    private var localization = Localization.shared
    private var campaignGateService: CampaignGateService?
    private var flagService: FlagService?
    private var planService: PlanService?
    private var offeringService: OfferingService?
    private var autoPreloadPlacement: String?

    // State
    private var initTask: Task<Void, Error>?
    private var isReadyFlag = false
    private var pendingIdentifies: [IdentifyOptions] = []
    private var debug = false
    private var networkRecoveryCleanup: (() -> Void)?
    // Pre-resolved session flag values (keyed by flag key).
    // Populated during init if config.sessionFlags is set; nil means not resolved.
    private var sessionFlagsMap: [String: String?] = [:]

    // Presenter handlers
    public typealias PaywallPresenterHandler = (PaywallConfig, [Product]) async -> PaywallResult
    public typealias CampaignPresenterHandler = (CampaignResponse, [Product]) async -> CampaignResult
    public typealias SubscriptionGetterHandler = () async -> SubscriptionStatusResponse
    public typealias ActiveCheckerHandler = () async -> Bool
    public typealias RestoreHandler = () async throws -> RestoreResult
    public typealias EmergencyPaywallHandler = (EmergencyPaywallResponse) -> Void

    private var paywallPresenter: PaywallPresenterHandler?
    private var campaignPresenter: CampaignPresenterHandler?
    private var subscriptionGetter: SubscriptionGetterHandler?
    private var activeChecker: ActiveCheckerHandler?
    private var restoreHandler: RestoreHandler?
    private var emergencyPaywallHandler: EmergencyPaywallHandler?

    // Init retry config
    private let retryDelays: [TimeInterval] = [2, 5, 10]
    private let maxInitRetries = 3

    private init() {}

    // MARK: - Init

    public func initialize(_ config: PaywalloInitConfig) async throws {
        guard !config.appKey.isEmpty else {
            throw ClientError(code: ClientErrorCode.missingAppKey, message: "appKey is required")
        }

        if isReadyFlag { return }

        if let existing = initTask {
            try await existing.value
            return
        }

        self.config = config
        self.debug = config.debug ?? false

        let task = Task<Void, Error> {
            try await self.initWithRetry(config)
        }
        initTask = task
        do {
            try await task.value
        } catch {
            initTask = nil
            setupNetworkRecovery(config)
            throw error
        }
        initTask = nil
    }

    private func initWithRetry(_ config: PaywalloInitConfig) async throws {
        var lastError: Error?

        for attempt in 0...maxInitRetries {
            do {
                try await doInit(config)
                return
            } catch {
                lastError = error
                if attempt < maxInitRetries {
                    let delay = retryDelays[min(attempt, retryDelays.count - 1)]
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        // Report failure
        await reportInitFailure(config: config, error: lastError)
        throw lastError ?? ClientError(code: ClientErrorCode.unknown, message: "Init failed after retries")
    }

    private func reportInitFailure(config: PaywalloInitConfig, error: Error?) async {
        let serverUrl = config.apiUrl ?? PaywalloConstants.defaultApiUrl
        let tempApi = ApiClient(serverUrl: serverUrl, appKey: config.appKey, debug: debug)
        let paywError = PaywalloError(domain: "client", code: "INIT_FAILED", message: error?.localizedDescription ?? "Unknown init error")
        await tempApi.reportError(paywError)
    }

    private func resolveSessionFlags(api: ApiClient, keys: [String]) async {
        do {
            let results = try await api.evaluateFlags(keys: keys, distinctId: identityManager.getDistinctId())
            sessionFlagsMap.removeAll()
            for key in keys {
                sessionFlagsMap[key] = results[key]?.variant
            }
        } catch {
            for key in keys {
                sessionFlagsMap[key] = nil
            }
        }
    }

    private func setupNetworkRecovery(_ config: PaywalloInitConfig) {
        networkRecoveryCleanup?()
        let cleanup = networkMonitor.addListener { [weak self] online in
            guard let self = self, online, !self.isReadyFlag, self.initTask == nil else { return }
            Task {
                try? await self.initialize(config)
            }
        }
        networkRecoveryCleanup = cleanup
    }

    private func doInit(_ config: PaywalloInitConfig) async throws {
        let environment = config.environment ?? (debug ? .sandbox : .production)

        // 1. Network + OfflineQueue
        networkMonitor.initialize()
        networkMonitor.setDebug(debug)
        offlineQueue.initialize()
        offlineQueue.clearItemsWithInvalidAppKey(config.appKey)

        // 2. ApiClient
        let serverUrl = config.apiUrl ?? PaywalloConstants.defaultApiUrl
        let api = ApiClient(serverUrl: serverUrl, appKey: config.appKey, debug: debug, environment: environment)
        if let onError = config.onError {
            api.onError = onError
        }
        self.apiClient = api

        let queue = ApiClientQueue(
            apiClient: api,
            offlineQueue: offlineQueue,
            networkMonitor: networkMonitor,
            debug: debug
        )
        self.apiClientQueue = queue

        // 3. QueueProcessor
        let processor = QueueProcessor(queue: offlineQueue, networkMonitor: networkMonitor)
        processor.initialize(httpClient: api.httpClient, getFreshHeaders: { [weak self] in
            guard let self = self else { return [:] }
            return [
                "X-App-Key": config.appKey,
                "x-sdk-version": PaywalloConstants.sdkVersion
            ]
        })
        self.queueProcessor = processor

        // 4. SubscriptionManager
        subscriptionManager.initialize(SubscriptionManagerConfig(
            serverUrl: serverUrl,
            appKey: config.appKey,
            cacheTTL: config.subscriptionCacheTTL,
            debug: debug
        ))
        subscriptionManager.setApiClient(api)

        // 4b. Domain services
        campaignGateService = CampaignGateService(
            apiClient: api,
            subscriptionManager: subscriptionManager
        )
        flagService = FlagService(
            apiClient: api,
            distinctIdProvider: { [weak self] in self?.identityManager.getDistinctId() ?? "" }
        )
        planService = PlanService(apiClient: api)
        offeringService = OfferingService(apiClient: api)

        // 5. Identity
        let _ = try await identityManager.initialize(debug: debug)

        // 6. Replay pending identifies
        for pending in pendingIdentifies {
            await identityManager.identify(pending)
        }
        pendingIdentifies.removeAll()

        // 7. Attribution (best-effort)
        await attributionTracker.loadFromStorage()
        deepLinkCapture = DeepLinkAttributionCapture(attributionTracker: attributionTracker)
        deepLinkCapture?.start()

        // 8. Pre-warm DeviceInfo (BEFORE context provider so events have device data)
        let _ = await DeviceInfo.shared.getDeviceInfo()

        // 8b. Pre-warm ad IDs + Meta (fire-and-forget)
        Task { await self.advertisingIdManager.collect(requestATT: config.requestATT ?? false) }
        Task { let _ = await self.metaBridge.getAnonymousID() }
        Task { let _ = await self.metaBridge.fetchDeferredAppLink(attributionTracker: self.attributionTracker) }

        // 9. Event context provider
        api.setEventContextProvider { [weak self] in
            guard let self = self else { return IngestContext() }
            var ctx = IngestContext()

            // Identity
            ctx.distinctId = self.identityManager.getDistinctId()
            ctx.deviceId = self.identityManager.getDeviceId()

            // Session
            ctx.sessionId = self.sessionManager.getSessionId()

            // SDK metadata
            ctx.sdkVersion = PaywalloConstants.sdkVersion
            ctx.platform = PaywalloConstants.sdkPlatform

            // Device info (cached, non-blocking)
            if let device = DeviceInfo.shared.getCached() {
                ctx.appVersion = device.appVersion
                ctx.osVersion = device.systemVersion
                ctx.deviceModel = device.modelId.isEmpty ? device.model : device.modelId
                ctx.timezone = device.timezone
                ctx.locale = device.locale
            }

            // Attribution
            if let attr = self.attributionTracker.get() {
                var attrDict: [String: AnyCodable] = [:]
                if let v = attr.fbclid { attrDict["fbclid"] = AnyCodable(v) }
                if let v = attr.gclid { attrDict["gclid"] = AnyCodable(v) }
                if let v = attr.ttclid { attrDict["ttclid"] = AnyCodable(v) }
                if let v = attr.utmSource { attrDict["utm_source"] = AnyCodable(v) }
                if let v = attr.utmMedium { attrDict["utm_medium"] = AnyCodable(v) }
                if let v = attr.utmCampaign { attrDict["utm_campaign"] = AnyCodable(v) }
                if let v = attr.utmContent { attrDict["utm_content"] = AnyCodable(v) }
                if let v = attr.utmTerm { attrDict["utm_term"] = AnyCodable(v) }
                if let v = attr.referrer { attrDict["referrer"] = AnyCodable(v) }
                if let v = attr.tiktokCampaignId { attrDict["tiktok_campaign_id"] = AnyCodable(v) }
                if let v = attr.tiktokAdgroupId { attrDict["tiktok_adgroup_id"] = AnyCodable(v) }
                if let v = attr.tiktokAdId { attrDict["tiktok_ad_id"] = AnyCodable(v) }
                if let v = attr.installReferrerRaw { attrDict["install_referrer_raw"] = AnyCodable(v) }
                if let v = attr.installReferrerSource { attrDict["install_referrer_source"] = AnyCodable(v) }
                if !attrDict.isEmpty { ctx.attribution = attrDict }
            }

            // Advertising IDs (cached, non-blocking)
            let adIds = self.advertisingIdManager.getCached()
            let fbAnonId = self.metaBridge.getCachedAnonymousId()
            var idsDict: [String: AnyCodable] = [:]
            if let v = adIds?.idfa { idsDict["idfa"] = AnyCodable(v) }
            if let v = adIds?.idfv { idsDict["idfv"] = AnyCodable(v) }
            if let v = fbAnonId { idsDict["fb_anon_id"] = AnyCodable(v) }
            if !idsDict.isEmpty { ctx.ids = idsDict }

            return ctx
        }

        // 10. Session (restore existing, then optionally start)
        await sessionManager.restoreIfValid()

        // 11. Event pipeline
        eventBatcher.initialize(
            httpClient: api.httpClient,
            contextProvider: { api.getEventContext() },
            offlineQueue: offlineQueue,
            appKey: config.appKey,
            debug: debug
        )

        // 11b. Session tracking + lifecycle
        let tracking = SessionTracking(
            batcher: eventBatcher,
            distinctIdProvider: { [weak self] in self?.identityManager.getDistinctId() ?? "" },
            debug: debug
        )
        sessionTracking = tracking

        let lifecycle = SessionLifecycle(
            sessionManager: sessionManager,
            sessionTracking: tracking,
            batcher: eventBatcher,
            distinctIdProvider: { [weak self] in self?.identityManager.getDistinctId() ?? "" },
            emergencyPaywallCheck: { [weak self] in
                await self?.checkAndHandleEmergencyPaywall()
            },
            debug: debug
        )
        sessionLifecycle = lifecycle
        lifecycle.setup()

        // 12. Onboarding
        onboardingManager.injectDeps(
            trackEvent: { [weak self] name, props, priority in
                self?.eventBatcher.enqueue(name: name, properties: props, priority: priority)
            },
            distinctIdProvider: { [weak self] in self?.identityManager.getDistinctId() ?? "" },
            debug: debug
        )

        // 13. Notifications (skip if disabled)
        if config.notifications != false {
            let nm = NotificationsManager(
                apiClient: api,
                distinctIdProvider: { [weak self] in self?.identityManager.getDistinctId() ?? "" }
            )
            notificationsManager = nm
            await nm.initialize()
        }

        // 14. Auto start session
        if config.autoStartSession != false {
            try? await sessionManager.startSession(
                distinctIdProvider: { [weak self] in self?.identityManager.getDistinctId() ?? "" }
            )
            if let sid = sessionManager.getSessionId() {
                await tracking.trackSessionStart(sessionId: sid)
            }
        }

        // 14b. Warm device info so context provider + install tracker have cached data
        let deviceData = await DeviceInfo.shared.getDeviceInfo()

        // 15. Install tracking + deferred match (fire-and-forget)
        Task {
            await self.installTracker.trackIfNeeded(
                distinctIdProvider: { [weak self] in self?.identityManager.getDistinctId() ?? "" },
                sessionId: self.sessionManager.getSessionId(),
                deviceData: deviceData,
                advertisingIds: self.advertisingIdManager.getCached(),
                attribution: self.attributionTracker.get(),
                fbAnonymousId: self.metaBridge.getCachedAnonymousId(),
                trackEvent: { [weak self] name, props, priority in
                    self?.eventBatcher.enqueue(name: name, properties: props, priority: priority)
                },
                appKey: config.appKey
            )

            // Deferred match — direct attribution match endpoint (best-effort)
            await self.installTracker.performDeferredMatch(
                appKey: config.appKey,
                httpClient: api.httpClient,
                deviceData: deviceData,
                advertisingIds: self.advertisingIdManager.getCached(),
                fbAnonymousId: self.metaBridge.getCachedAnonymousId(),
                attributionTracker: self.attributionTracker
            )
        }

        // 16. Auto events (fire-and-forget)
        Task {
            await self.autoEvents.fireIfNeeded { [weak self] name, props, priority in
                self?.eventBatcher.enqueue(name: name, properties: props, priority: priority)
            }
        }

        // 17. Session flags — awaited before marking ready (matches RN step 19)
        if let sessionFlagConfig = config.sessionFlags, !sessionFlagConfig.keys.isEmpty {
            await resolveSessionFlags(api: api, keys: sessionFlagConfig.keys)
        }

        // 18. Mark ready
        isReadyFlag = true

        // 19. Preload subscription status (fire-and-forget)
        Task {
            self.subscriptionManager.setUserId(self.identityManager.getDistinctId())
            _ = await self.subscriptionManager.hasActiveSubscription()
        }

        // 20. Heartbeat crash recovery (fire-and-forget)
        Task { [weak self] in
            guard let self = self else { return }
            let sessionId = self.sessionManager.getSessionId()
            let heartbeat = PaywallHeartbeat(onCrashRecovery: { [weak self] snapshot, durationS in
                guard let self = self else { return }
                let closedAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: snapshot.lastSeen / 1000))
                var props: [String: AnyCodable] = [
                    "type": AnyCodable("closed"),
                    "close_reason": AnyCodable("error"),
                    "paywall_id": AnyCodable(snapshot.paywallId),
                    "placement": AnyCodable(snapshot.placement),
                    "closed_at": AnyCodable(closedAt),
                    "duration_s": AnyCodable(durationS),
                ]
                if let v = snapshot.variantKey  { props["variant_key"]  = AnyCodable(v) }
                if let v = snapshot.variantId   { props["variant_id"]   = AnyCodable(v) }
                if let v = snapshot.campaignId  { props["campaign_id"]  = AnyCodable(v) }
                if let v = sessionId            { props["sessionId"]    = AnyCodable(v) }
                self.eventBatcher.enqueue(name: "paywall", properties: props, priority: .critical)
            })
            _ = heartbeat  // Crash recovery fires in init; keep alive until done
        }

        // 21. Auto preload campaign (fire-and-forget)
        if let autoPreload = config.autoPreloadCampaign {
            autoPreloadPlacement = autoPreload
            Task { [weak self] in
                guard let self = self else { return }
                await self.campaignGateService?.preloadCampaign(autoPreload, distinctId: self.identityManager.getDistinctId())
            }
        } else {
            Task { [weak self] in
                guard let self = self, let api = self.apiClient else { return }
                do {
                    guard let primary = try await api.getPrimaryCampaign(distinctId: self.identityManager.getDistinctId()) else { return }
                    self.autoPreloadPlacement = primary.placement
                    await self.campaignGateService?.preloadCampaign(primary.placement, distinctId: self.identityManager.getDistinctId())
                } catch { /* best effort */ }
            }
        }

        // 22. Batch preload all active campaign placements (fire-and-forget)
        // Mirrors RN startBatchPreload() called after setupAutoPreload.
        Task { [weak self] in
            guard let self = self else { return }
            await self.campaignGateService?.preloadAllActive(distinctId: self.identityManager.getDistinctId())
        }
    }

    // MARK: - Ready

    public func isReady() -> Bool { isReadyFlag }

    public func waitUntilReady() async {
        if isReadyFlag { return }
        if let task = initTask {
            try? await task.value
        }
    }

    // MARK: - Identity

    /// Shorthand overload — accepts raw properties dict directly (mirrors RN `identify(UserProperties)`).
    public func identify(_ properties: [String: AnyCodable]) async throws {
        let options = IdentifyOptions(properties: properties)
        try await identify(options)
    }

    /// Enqueues the identify call if init is in-flight (matching RN behaviour).
    /// Throws `ClientError.notInitialized` if no init has ever been attempted.
    public func identify(_ options: IdentifyOptions) async throws {
        if !identityManager.isInitialized {
            if initTask != nil || config != nil {
                // Init is in-flight or was started: queue for replay inside doInit.
                pendingIdentifies.append(options)
                return
            }
            // No init attempted at all — throw, same as RN SDK.
            throw ClientError(code: ClientErrorCode.notInitialized, message: "SDK not initialized. Call initialize() first")
        }
        await identityManager.identify(options)

        // Send to server via queue (durable — survives offline)
        if let queue = apiClientQueue {
            let distinctId = identityManager.getDistinctId()
            let properties = options.properties
            let email = options.email
            let deviceId = identityManager.getDeviceId()
            let pii: [String: String?] = [
                "phone": options.phone,
                "firstName": options.firstName,
                "lastName": options.lastName,
                "dateOfBirth": options.dateOfBirth,
                "gender": options.gender?.rawValue,
            ]

            // Build body identical to ApiClient.identify()
            var traits: [String: Any] = ["platform": "ios"]
            if let email = email { traits["email"] = email }

            let traitKeys: Set<String> = ["name", "country", "locale", "app_version"]
            let attributionKeys: Set<String> = [
                "utm_source", "utm_medium", "utm_campaign", "utm_content", "utm_term",
                "fbclid", "gclid", "ttclid", "referrer",
            ]
            var attribution: [String: Any] = [:]
            if let props = properties {
                for (k, v) in props {
                    if traitKeys.contains(k) { traits[k] = v.value }
                    else if attributionKeys.contains(k) { attribution[k] = v.value }
                }
            }
            for (k, v) in pii {
                guard let v = v else { continue }
                if k == "email" { traits["email"] = v }
                else if traitKeys.contains(k) { traits[k] = v }
            }

            var body: [String: Any] = ["distinct_id": distinctId, "traits": traits]
            if !attribution.isEmpty { body["attribution"] = attribution }
            if let deviceId = deviceId, !deviceId.isEmpty { body["deviceId"] = deviceId }

            if let phone = pii["phone"] as? String, !phone.isEmpty {
                body["phone"] = phone
            }
            if let firstName = pii["firstName"] as? String, !firstName.isEmpty {
                body["firstName"] = firstName
            }
            if let lastName = pii["lastName"] as? String, !lastName.isEmpty {
                body["lastName"] = lastName
            }
            if let dob = pii["dateOfBirth"] as? String, ApiClient.isValidDateOfBirth(dob) {
                body["dateOfBirth"] = dob
            }
            if let rawGender = pii["gender"] as? String, let g = ApiClient.normalizeGender(rawGender) {
                body["gender"] = g
            }

            let jsonData = try? JSONSerialization.data(withJSONObject: body)
            Task {
                await queue.execute(method: "POST", path: "/sdk/identity/identify", body: jsonData, priority: .normal)
            }
        }
    }

    public func getDistinctId() -> String { identityManager.getDistinctId() }
    public func getDeviceId() -> String? { identityManager.getDeviceId() }
    public func getEmail() -> String? { identityManager.getEmail() }
    public func getIdentityState() -> IdentityState { identityManager.getState() }

    // MARK: - Events

    public func track(
        _ eventName: String,
        properties: [String: AnyCodable]? = nil,
        priority: EventPriority = .normal
    ) {
        var merged = identityManager.getProperties()
        if let sid = sessionManager.getSessionId() {
            merged["sessionId"] = AnyCodable(sid)
        }
        // User-provided properties win on conflict
        for (key, value) in (properties ?? [:]) {
            merged[key] = value
        }
        eventBatcher.enqueue(name: eventName, properties: merged, priority: priority)
    }

    // MARK: - Session

    public func getSessionId() -> String? { sessionManager.getSessionId() }

    @discardableResult
    public func startSession() async throws -> String {
        try await sessionManager.startSession(
            distinctIdProvider: { [weak self] in self?.identityManager.getDistinctId() ?? "" }
        )
        let sid = sessionManager.getSessionId() ?? UUID().uuidString
        await sessionTracking?.trackSessionStart(sessionId: sid)
        return sid
    }

    public func endSession() async {
        _ = await sessionManager.endSession()
    }

    // MARK: - Subscription

    public func hasActiveSubscription(forceRefresh: Bool = false) async -> Bool {
        await subscriptionManager.hasActiveSubscription(forceRefresh: forceRefresh)
    }

    public func getSubscription(forceRefresh: Bool = false) async -> Subscription? {
        await subscriptionManager.getSubscription(forceRefresh: forceRefresh)
    }

    /// Restores purchases and returns a `RestoreResult` — mirrors RN `restorePurchases() → RestoreResult`.
    public func restorePurchases() async throws -> RestoreResult {
        let status = try await subscriptionManager.restorePurchases()
        let productId = status.subscription?.productId
        let restoredProducts: [String] = productId.map { [$0] } ?? []
        return RestoreResult(
            success: status.hasActiveSubscription,
            restoredProducts: restoredProducts
        )
    }

    // MARK: - Onboarding

    public func onboardingStep(stepName: String, order: Double, variantKey: String? = nil, timeOnPrevS: Double? = nil) async throws {
        try await onboardingManager.step(stepName: stepName, order: order, variantKey: variantKey, timeOnPrevS: timeOnPrevS)
    }

    /// Fires an onboarding_complete event — mirrors RN `onboardingComplete()`.
    public func onboardingComplete(variantKey: String? = nil) async throws {
        try await onboardingManager.complete(variantKey: variantKey)
    }

    // MARK: - Offerings

    /// Returns offerings from cache (stale-while-revalidate) or fetches fresh.
    /// Mirrors RN `getOfferings(ids?) → Offering[]`.
    public func getOfferings(ids: [String]? = nil) async throws -> [Offering] {
        guard let offeringService = offeringService else {
            throw ClientError(code: ClientErrorCode.notInitialized, message: "Not initialized")
        }
        return try await offeringService.getOfferings(ids: ids)
    }

    // MARK: - Flags

    public func getVariant(key: String, distinctId: String? = nil) async throws -> FlagVariant {
        guard let api = apiClient else {
            throw ClientError(code: ClientErrorCode.notInitialized, message: "Not initialized")
        }
        return try await api.getVariant(key: key, distinctId: distinctId ?? identityManager.getDistinctId())
    }

    public func getVariantCached(key: String, defaultValue: String? = nil) async -> FlagVariant {
        guard let flagService = flagService else { return FlagVariant(variant: defaultValue) }
        let result = await flagService.getVariantCached(key: key, distinctId: identityManager.getDistinctId())
        if let resolved = result { return resolved }
        return FlagVariant(variant: defaultValue)
    }

    public func evaluateFlags(keys: [String]) async throws -> [String: FlagVariant] {
        guard let api = apiClient else {
            throw ClientError(code: ClientErrorCode.notInitialized, message: "Not initialized")
        }
        return try await api.evaluateFlags(keys: keys, distinctId: identityManager.getDistinctId())
    }

    public func getConditionalFlag(key: String, context: ConditionalFlagContext? = nil) async throws -> ConditionalFlagResult {
        guard let api = apiClient else {
            throw ClientError(code: ClientErrorCode.notInitialized, message: "Not initialized")
        }
        return try await api.getConditionalFlag(key: key, context: context)
    }

    // MARK: - Paywall

    public func getPaywall(placement: String) async -> PaywallConfig? {
        guard let api = apiClient else { return nil }
        return try? await api.getPaywall(placement)
    }

    public func presentPaywall(placement: String) async -> PaywallResult {
        guard let presenter = paywallPresenter,
              let config = await getPaywall(placement: placement) else {
            return PaywallResult(presented: false, purchased: false, cancelled: false, restored: false)
        }
        return await presenter(config, [])
    }

    public func getEmergencyPaywall() async throws -> EmergencyPaywallResponse {
        guard let api = apiClient else {
            throw ClientError(code: ClientErrorCode.notInitialized, message: "Not initialized")
        }
        return try await api.getEmergencyPaywall()
    }

    // MARK: - Campaign

    public func getCampaign(
        placement: String,
        context: [String: AnyCodable]? = nil
    ) async throws -> CampaignResponse {
        guard let api = apiClient else {
            throw ClientError(code: ClientErrorCode.notInitialized, message: "Not initialized")
        }
        return try await api.getCampaign(placement, distinctId: identityManager.getDistinctId(), context: context)
    }

    public func presentCampaign(
        placement: String,
        context: [String: AnyCodable]? = nil,
        forceShow: Bool = false
    ) async -> CampaignResult {
        guard let gate = campaignGateService else {
            return CampaignResult(presented: false, purchased: false, cancelled: false, restored: false)
        }
        let response = await gate.presentCampaign(
            placement: placement,
            distinctId: identityManager.getDistinctId(),
            context: context,
            forceShow: forceShow
        )
        guard let response = response else {
            return CampaignResult(
                presented: false,
                purchased: false,
                cancelled: false,
                restored: false,
                skippedReason: "subscriber"
            )
        }
        guard let presenter = campaignPresenter else {
            return CampaignResult(
                presented: true,
                purchased: false,
                cancelled: false,
                restored: false,
                campaignId: response.campaignId,
                variantKey: response.variantKey,
                variantId: response.variantId
            )
        }
        return await presenter(response, [])
    }

    public func preloadCampaign(placement: String, context: [String: AnyCodable]? = nil) async {
        await campaignGateService?.preloadCampaign(placement, distinctId: identityManager.getDistinctId(), context: context)
    }

    public func getPreloadedCampaign(placement: String) async -> CampaignResponse? {
        return await campaignGateService?.waitForPreload(placement)
    }

    public func isPreloaded(placement: String) async -> Bool {
        return await campaignGateService?.waitForPreload(placement) != nil
    }

    // MARK: - Content Gating

    /// Returns `true` if user is already subscribed.
    /// If `paywallPlacement` is nil and user is not subscribed, returns `false` without showing any paywall.
    /// Matches RN `requireSubscription(paywallPlacement?)` → `Bool`.
    public func requireSubscription(paywallPlacement: String? = nil) async -> Bool {
        let active = await hasActiveSubscription()
        if active { return true }
        guard let placement = paywallPlacement else { return false }
        let result = await presentPaywall(placement: placement)
        return result.purchased || result.restored
    }

    public func requireSubscriptionWithCampaign(
        placement: String,
        context: [String: AnyCodable]? = nil
    ) async -> Bool {
        let active = await hasActiveSubscription()
        if active { return true }
        let result = await presentCampaign(placement: placement, context: context)
        return result.purchased || result.restored
    }

    /// Returns `true`/`false` (simple gate). For the generic `T?` version use the overload below.
    public func gateContent(paywallPlacement: String? = nil) async -> Bool {
        return await requireSubscription(paywallPlacement: paywallPlacement)
    }

    /// Generic overload — mirrors RN `gateContent<T>(content: () => T | Promise<T>, paywallPlacement?) → T | null`.
    /// Returns the content closure result if the user is subscribed, `nil` otherwise.
    public func gateContent<T: Sendable>(
        _ content: @Sendable () async -> T,
        paywallPlacement: String? = nil
    ) async -> T? {
        guard await requireSubscription(paywallPlacement: paywallPlacement) else { return nil }
        return await content()
    }

    /// Returns `true`/`false` (simple gate). For the generic `T?` version use the overload below.
    public func gateContentWithCampaign(
        placement: String,
        context: [String: AnyCodable]? = nil
    ) async -> Bool {
        return await requireSubscriptionWithCampaign(placement: placement, context: context)
    }

    /// Generic overload — mirrors RN `gateContentWithCampaign<T>(content, placement, context?) → T | null`.
    public func gateContentWithCampaign<T: Sendable>(
        _ content: @Sendable () async -> T,
        placement: String,
        context: [String: AnyCodable]? = nil
    ) async -> T? {
        guard await requireSubscriptionWithCampaign(placement: placement, context: context) else { return nil }
        return await content()
    }

    // MARK: - Auto Preload

    public func getAutoPreloadedPlacement() -> String? { autoPreloadPlacement }

    public func waitForAutoPreloadedPlacement() async -> String? {
        if let placement = autoPreloadPlacement { return placement }
        await waitUntilReady()
        return autoPreloadPlacement
    }

    // MARK: - Queue Management

    public func getOfflineQueueSize() -> Int { offlineQueue.count }
    public func clearOfflineQueue() async { offlineQueue.clear() }

    /// Processes the offline queue and returns the count of processed and failed items.
    /// Mirrors RN `processOfflineQueue() → { processed: number; failed: number }`.
    @discardableResult
    public func processOfflineQueue() async -> OfflineQueueResult {
        return await queueProcessor?.processQueue() ?? OfflineQueueResult(processed: 0, failed: 0)
    }

    // MARK: - Plans

    /// Returns all plans together with the `currentIdentifier` — mirrors RN `getPlans() → AllPlansResponse`.
    public func getPlans() async throws -> AllPlansResponse {
        guard let planService = planService else {
            throw ClientError(code: ClientErrorCode.notInitialized, message: "Not initialized")
        }
        return try await planService.getAllPlansResponse()
    }

    public func getCurrentPlan() async throws -> Plan? {
        guard let planService = planService else {
            throw ClientError(code: ClientErrorCode.notInitialized, message: "Not initialized")
        }
        return try await planService.getCurrentPlan()
    }

    // MARK: - Session Extended

    /// Returns the current session state — mirrors RN `getSessionState() → SessionState`.
    public func getSessionState() -> SessionState {
        let sid = sessionManager.getSessionId()
        let startMs = sessionManager.getSessionStartMs()
        let startedAt: Date? = startMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
        let duration: TimeInterval
        if let ms = startMs {
            duration = Double(Int64(Date().timeIntervalSince1970 * 1000) - ms) / 1000.0
        } else {
            duration = 0
        }
        return SessionState(sessionId: sid, startedAt: startedAt, isActive: sid != nil, duration: duration)
    }

    /// Returns the pre-resolved session flag value (populated during init from
    /// `config.sessionFlags`). Returns `nil` if not set or SDK not initialized.
    /// Matches RN `getSessionFlag()` which reads from `sessionFlagsMap`.
    public func getSessionFlag(key: String) -> String? {
        guard isReadyFlag else { return nil }
        if let entry = sessionFlagsMap[key] {
            return entry
        }
        return nil
    }

    // MARK: - Presenter Registration

    public func registerPaywallPresenter(_ handler: PaywallPresenterHandler?) {
        paywallPresenter = handler
    }

    public func registerCampaignPresenter(_ handler: CampaignPresenterHandler?) {
        campaignPresenter = handler
    }

    public func registerSubscriptionGetter(_ handler: SubscriptionGetterHandler?) {
        subscriptionGetter = handler
    }

    public func registerActiveChecker(_ handler: ActiveCheckerHandler?) {
        activeChecker = handler
    }

    public func registerRestoreHandler(_ handler: RestoreHandler?) {
        restoreHandler = handler
    }

    public func registerEmergencyPaywallHandler(_ handler: EmergencyPaywallHandler?) {
        emergencyPaywallHandler = handler
    }

    // MARK: - Misc

    public func getWebUrl() -> String? { apiClient?.getWebUrl() }

    public func coreAction(_ actionName: String) throws { try CoreAction.execute(actionName) }

    // MARK: - Config

    public func getConfig() -> PaywalloInitConfig? { config }
    public func getEnvironment() -> Environment? { apiClient?.getEnvironment() }

    public func setEnvironment(_ env: Environment) {
        apiClient?.setEnvironment(env)
    }

    // MARK: - Network

    public func isOnline() -> Bool { networkMonitor.isOnline() }

    // MARK: - Push

    /// Requests OS push permission and registers the APNS token with the backend.
    /// Returns the final `PushPermissionStatus` — safe to call before init (returns `.notDetermined`).
    /// Mirrors RN `requestPushPermission(options?) → PushPermissionStatus`.
    /// - Parameter provisional: If true, requests provisional (quiet) authorization — iOS 12+.
    public func requestPushPermission(provisional: Bool = false) async -> PushPermissionStatus {
        guard isReadyFlag, let nm = notificationsManager else { return .notDetermined }
        let granted = await nm.requestPermission(provisional: provisional)
        return granted ? .granted : .denied
    }

    /// Forwards the APNS device token to the notifications subsystem.
    /// Call from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    /// If the token differs from the last registered one, re-registers automatically with the backend.
    /// Safe to call before init — the token will be applied once the manager is initialized.
    public func setApnsToken(_ token: String) async {
        await notificationsManager?.setApnsToken(token)
    }

    // MARK: - Deep Links

    public func handleDeepLink(_ url: URL) async {
        await deepLinkCapture?.handleUrl(url)
    }

    // MARK: - Emergency Paywall (internal)

    private func checkAndHandleEmergencyPaywall() async {
        guard let api = apiClient else { return }
        let shown = await sessionManager.hasEmergencyPaywallBeenShown()
        guard !shown else { return }
        guard let response = try? await api.getEmergencyPaywall(),
              response.enabled,
              response.paywallId != nil else { return }
        await sessionManager.markEmergencyPaywallShown()
        emergencyPaywallHandler?(response)
    }

    // MARK: - Reset

    /// Soft reset: clears identity (new anonId) and subscription cache.
    /// SDK stays ready — matches RN `doReset()`.
    public func reset() async {
        await identityManager.reset()
        await subscriptionCache.invalidateAll()
        // Invalidate local push token (previous user's mapping). No server call — that's opt-out.
        await notificationsManager?.invalidateLocalToken()
        // Update subscription manager to new distinct ID.
        subscriptionManager.setUserId(identityManager.getDistinctId())
    }

    /// Hard reset: tears down every subsystem and resets to pre-init state.
    /// Matches RN `doFullReset()`.
    public func fullReset() async {
        _ = await sessionManager.endSession()
        sessionManager.destroy()
        sessionLifecycle?.teardown()
        sessionLifecycle = nil
        sessionTracking = nil
        await identityManager.reset()
        await subscriptionCache.invalidateAll()
        queueProcessor?.dispose()
        queueProcessor = nil
        offlineQueue.dispose()
        networkMonitor.dispose()
        campaignGateService?.invalidateAllCache()
        campaignGateService = nil
        // Invalidate local token before destroying the manager.
        await notificationsManager?.invalidateLocalToken()
        notificationsManager?.destroy()
        notificationsManager = nil
        deepLinkCapture = nil

        networkRecoveryCleanup?()
        networkRecoveryCleanup = nil

        sessionFlagsMap.removeAll()
        pendingIdentifies.removeAll()

        flagService = nil
        planService = nil
        offeringService = nil
        autoPreloadPlacement = nil

        paywallPresenter = nil
        campaignPresenter = nil
        subscriptionGetter = nil
        activeChecker = nil
        restoreHandler = nil
        emergencyPaywallHandler = nil

        eventBatcher.dispose()
        apiClient = nil
        apiClientQueue = nil
        config = nil
        isReadyFlag = false
        initTask = nil
    }
}

// MARK: - Convenience

public typealias Paywallo = PaywalloClient
