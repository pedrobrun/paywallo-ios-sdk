import Foundation

public final class PaywalloClient {
    public static let shared = PaywalloClient()

    // Subsystems
    private var config: PaywalloInitConfig?
    private var apiClient: ApiClient?
    private var identityManager = IdentityManager()
    private var sessionManager = SessionManager()
    private var sessionTracking: SessionTracking?
    private var sessionLifecycle: SessionLifecycle?
    private var eventBatcher = EventBatcher()
    private var subscriptionManager = SubscriptionManager()
    private var subscriptionCache = SubscriptionCache()
    private var onboardingManager = OnboardingManager()
    private var notificationsManager: NotificationsManager?
    private var networkMonitor = NetworkMonitor.shared
    private var advertisingIdManager = AdvertisingIdManager.shared
    private var attributionTracker = AttributionTracker.shared
    private var deepLinkCapture: DeepLinkAttributionCapture?
    private var installTracker = InstallTracker()
    private var metaBridge = MetaBridge.shared
    private var autoEvents = AutoEvents()
    private var localization = Localization.shared
    private var iapService: IAPService?
    private var transactionEmitter: TransactionEmitter?
    private let skanManager = SkanManager()
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
    private var attEnrichCleanup: (() -> Void)?
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

    /// Single-owner rule: if another SDK in the same binary also writes the conversion value,
    /// the two overwrite each other — it is a single, monotonic value per app. `skan: false`
    /// hands ownership over.
    private func setupSkan(_ config: PaywalloInitConfig) async {
        if config.skan == false { return }
        guard NativeSkan.isAvailable() else {
            if debug { print("[Paywallo][SKAN] auto-detect: disabled — SKAdNetwork unavailable") }
            return
        }
        await skanManager.injectDeps(debug: debug)
        eventBatcher.setEventObserver { [weak self] name, props in
            self?.skanManager.observe(name, properties: props)
        }
        skanManager.openConversionWindow()
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

        // 1. Network. The durable offline queue was REMOVED in 2.7.0 (incident 03/08/2026);
        // all that is left is a one-shot wipe of its three orphaned storage keys.
        networkMonitor.initialize()
        networkMonitor.setDebug(debug)
        LegacyOfflineQueueCleanup.run()

        // 2. ApiClient. resolveApiUrl THROWS on a malformed or non-https override —
        // silently falling back to production would point a local test build at real data.
        let serverUrl = try ApiClient.resolveApiUrl(config.apiUrl)
        let api = ApiClient(
            serverUrl: serverUrl,
            appKey: config.appKey,
            debug: debug,
            environment: environment,
            timeout: config.timeout ?? PaywalloConstants.defaultTimeout
        )
        if let onError = config.onError {
            api.onError = onError
        }
        self.apiClient = api

        // 3. PendingRetry — durable retry for CRITICAL requests only. Re-posts each saved
        // body byte-for-byte; it never merges, re-wraps or batches items (that re-wrap is
        // exactly what lost 100% of $app_installed on 03/08/2026).
        await PendingRetry.shared.setDebug(debug)
        await PendingRetry.shared.initialize { url, body, headers in
            do {
                let options = RequestOptions(method: "POST", headers: headers, body: body, skipRetry: true)
                let response = try await api.httpClient.requestRaw(path: url, options: options)
                return (ok: response.ok, status: response.status)
            } catch {
                return (ok: false, status: 0)
            }
        }

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
        // Deferred deep link resolved on a previous launch (screen personalisation only —
        // it never enters an event envelope or the CAPI pipeline).
        await DeferredDeepLinkStore.shared.loadFromStorage()
        // Warms the attribution kill-switch cache. Deliberately NOT awaited: the read below
        // is cache-only, and $app_installed must never wait on a round trip.
        Task { await api.refreshAttributionFlags() }

        // 8. Pre-warm identity caches and AWAIT them, with a 350ms ceiling, so the first
        // events of the session (cold_start, session_start) already carry idfv / idfa /
        // fb_anon_id when the (synchronous) context provider runs. If a native call is slow
        // the deadline wins and init continues — later events still pick the values up.
        //
        // The SDK NEVER shows the ATT prompt; the app does, before init. The timing of that
        // prompt decides the opt-in rate and only the app knows the right moment — and the
        // install must not block waiting for the answer (2.8.0).
        await withDeadline(timeoutMs: 350) { [weak self] in
            guard let self = self else { return }
            async let device: Void = { _ = await DeviceInfo.shared.getDeviceInfo() }()
            async let adIds: Void = { _ = await self.advertisingIdManager.collect() }()
            async let anonId: Void = { _ = await self.metaBridge.getAnonymousID() }()
            _ = await (device, adIds, anonId)
        }
        // The deferred app link is the iOS equivalent of the install referrer; it feeds the
        // $app_installed payload, so it is fetched but never gates init.
        Task { _ = await self.metaBridge.fetchDeferredAppLink(attributionTracker: self.attributionTracker) }

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
            post: { url, body, label, priority in
                await api.postWithQueue(url: url, payload: body, label: label, priority: priority)
            },
            contextProvider: { api.getEventContext() },
            distinctIdProvider: { [weak self] in self?.identityManager.getDistinctId() ?? "" },
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
                distinctIdProvider: { [weak self] in self?.identityManager.getDistinctId() ?? "" },
                eventBatcher: eventBatcher,
                deviceIdProvider: { [weak self] in self?.identityManager.getDeviceId() ?? "" }
            )
            notificationsManager = nm
            await nm.initialize(config: NotificationsConfig(debug: debug))
        }

        // 13b. IAP — the Transaction.updates listener starts with the emitter. Without it
        // `transaction {renewed}` never fires, which also makes the SKAN `Retained` milestone
        // unreachable, and refunds/cancellations never reach the server.
        let iap = IAPService(apiClient: api, debug: debug)
        let emitter = TransactionEmitter(
            batcher: eventBatcher,
            productProvider: { [weak iap] id in iap?.getProduct(id) },
            distinctIdProvider: { [weak self] in self?.identityManager.getDistinctId() },
            debug: debug
        )
        iap.setTransactionEmitter(emitter)
        self.iapService = iap
        self.transactionEmitter = emitter

        // 13c. SKAN — BEFORE the install tracker on purpose: opening the conversion window is
        // a prerequisite for Apple to generate any postback for the installation at all.
        await setupSkan(config)

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

        // 14c. Post-ATT enrichment producer. The install fires immediately without waiting
        // for the prompt, so the IDFA only exists once the APP asks and the user accepts.
        // Unsubscribe first: an init retry would otherwise register a second listener and
        // post the enrichment twice.
        attEnrichCleanup?()
        attEnrichCleanup = advertisingIdManager.onGrantedTransition { [weak self] result in
            guard let self = self, let idfa = result.idfa else { return }
            let distinctId = self.identityManager.getDistinctId()
            guard !distinctId.isEmpty else { return }
            Task {
                await api.enrichInstall(distinctId: distinctId, idfa: idfa, attStatus: result.attStatus.rawValue)
            }
        }

        // 15. Install tracking (fire-and-forget). The deferred match now lives inside the
        // tracker's InstallRetryScheduler: the old performDeferredMatch stamped
        // `deferred_match_done` regardless of the outcome, so a device that did not match on
        // the first try — common on iOS, where the click may not be processed yet or the IP
        // changed between click and install — was sealed with no attribution forever.
        Task {
            let referrer = await self.metaBridge.fetchDeferredAppLink(attributionTracker: self.attributionTracker)
            let sent = await self.installTracker.trackIfNeeded(
                apiClient: api,
                distinctIdProvider: { [weak self] in self?.identityManager.getDistinctId() ?? "" },
                sessionId: self.sessionManager.getSessionId(),
                deviceData: deviceData,
                advertisingIds: self.advertisingIdManager.getCached(),
                fbAnonymousId: self.metaBridge.getCachedAnonymousId(),
                referrer: referrer,
                idfvChanged: self.identityManager.hasIdfvChanged(),
                // Cache miss means "no answer yet", not "disabled" — hence the true default.
                syncedIdentityEnabled: api.getAttributionFlagsFromCache()?.syncedIdentityEnabled ?? true,
                trackEvent: { [weak self] name, props, priority in
                    self?.eventBatcher.enqueue(name: name, properties: props, priority: priority)
                }
            )
            if self.debug {
                print(sent
                    ? "[Paywallo INSTALL] $app_installed sent"
                    : "[Paywallo INSTALL] $app_installed skipped — aparelho já rastreado ou sem distinctId")
            }
        }

        // 15b. Superwall bridge. Arms the pw_* attribute push and subscribes to
        // attributionTracker.onCapture, so a deep link / deferred match that resolves after
        // boot re-pushes (idempotent by signature).
        startSuperwallBridge(
            attribution: attributionTracker,
            distinctIdProvider: { [weak self] in self?.identityManager.getDistinctId() ?? "" },
            apiClient: api,
            debug: debug
        )

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

        // Body is built in ONE place (ApiClient.identify) — this used to be a duplicated
        // copy that had already drifted from it. identify is `critical`: it carries the PII
        // and the attribution signals (fbclid/utm/gclid) used for matching, so a network
        // blip must not drop it — a failure lands in PendingRetry.
        guard let api = apiClient else { return }
        await api.identify(
            identityManager.getDistinctId(),
            properties: options.properties,
            email: options.email,
            deviceId: identityManager.getDeviceId(),
            pii: [
                "phone": options.phone,
                "firstName": options.firstName,
                "lastName": options.lastName,
                "dateOfBirth": options.dateOfBirth,
                "gender": options.gender?.rawValue,
                "zipCode": options.zipCode,
            ]
        )
    }

    public func getDistinctId() -> String { identityManager.getDistinctId() }
    public func getDeviceId() -> String? { identityManager.getDeviceId() }
    public func getEmail() -> String? { identityManager.getEmail() }
    public func getIdentityState() -> IdentityState { identityManager.getState() }

    /// Pushes the `pw_*` attributes to Superwall and waits, up to `timeoutMs`, for them to land.
    ///
    /// Call this immediately before every `register()`. Superwall evaluates audience rules
    /// on-device inside `register()`, and the variant chosen there sticks to the user until the
    /// assignment is reset — an attribute that arrives afterwards reclassifies nobody. Since
    /// Paywallo's attribution resolves seconds after first open (deferred match), skipping this
    /// leaves ad-sourced users permanently evaluated as organic.
    ///
    /// `timeoutMs` is a total deadline, not a fixed split: whatever the server lookup does not
    /// use is handed to the push.
    @discardableResult
    public func syncSuperwallAttributes(
        timeoutMs: Int = PaywalloConstants.defaultSyncTimeoutMs
    ) async -> SuperwallSyncOutcome {
        await PaywalloSDK.syncSuperwallAttributes(timeoutMs: timeoutMs, debug: debug)
    }

    /// Public stable identifier — wraps `getDistinctId()`. Established automatically on boot.
    public func getId() -> String { identityManager.getDistinctId() }

    /// Merges into the stored user properties and re-sends `identify` with the accumulated set.
    public func updateProperties(_ properties: [String: AnyCodable]) async {
        await identityManager.updateProperties(properties)
    }

    /// LGPD/GDPR erase. Signals the server, then wipes local PII and any pending retries
    /// (they can carry PII) and issues a fresh anonymous id **immediately** — a running app
    /// must never be left tracking with a nil distinctId. `deviceId` is deliberately kept:
    /// it feeds install idempotency, so clearing it would let the device re-register as new.
    public func deleteUserData() async {
        let distinctId = identityManager.getDistinctId()
        let deviceId = identityManager.getDeviceId()
        if let api = apiClient, !distinctId.isEmpty {
            await api.deleteUserData(distinctId: distinctId, deviceId: deviceId)
        }
        await identityManager.deleteUserData()
    }

    /// The deferred deep link resolved by the attribution match, when the user came from an
    /// ad for a specific offer. Personalisation data only — it never enters an event.
    public func getDeferredDeepLink() -> DeferredDeepLink? {
        DeferredDeepLinkStore.shared.get()
    }

    /// Observes the deferred deep link, which usually resolves in the background *after* the
    /// UI has already mounted. Returns an unsubscribe closure.
    @discardableResult
    public func onDeferredDeepLink(_ listener: @escaping (DeferredDeepLink) -> Void) -> () -> Void {
        DeferredDeepLinkStore.shared.onCapture(listener)
    }

    /// DEV ONLY. Wipes the install markers so the next cold start looks like a new user.
    ///
    /// Needed because these keys live in the Keychain: they survive deleting the app and come
    /// back from an iCloud restore, so a device that ran the app once can never test the
    /// acquisition flow again. Requires a restart — the next cold start is what emits
    /// `$app_installed`.
    ///
    /// Two guards: it does not exist in a release build (`#if DEBUG`, so the call cannot even
    /// be compiled into a shipped binary), and it throws unless `debug: true`. Never call it in
    /// production: besides inflating install counts it resets the anonymous identity and
    /// erases local PII.
    public func devResetInstallState() async throws {
        #if DEBUG
        guard config?.debug == true else {
            throw ClientError(
                code: ClientErrorCode.notInitialized,
                message: "devResetInstallState exige debug: true"
            )
        }
        await identityManager.clearInstallStateForDev()
        print("[Paywallo DEV] estado de install limpo — reinicie o app para disparar $app_installed")
        #else
        throw ClientError(
            code: ClientErrorCode.notInitialized,
            message: "devResetInstallState não existe em build de produção"
        )
        #endif
    }

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
        // "No campaign for this placement" and "active subscriber" are DIFFERENT outcomes.
        // Both used to collapse into nil here and get reported as skippedReason "subscriber",
        // which made a missing campaign look like a paying user in the caller's analytics.
        let outcome = await gate.resolveCampaign(
            placement: placement,
            distinctId: identityManager.getDistinctId(),
            context: context,
            forceShow: forceShow
        )
        let response: CampaignResponse
        switch outcome {
        case .campaign(let value):
            response = value
        case .subscriber:
            return CampaignResult(
                presented: false,
                purchased: false,
                cancelled: false,
                restored: false,
                skippedReason: "subscriber"
            )
        case .notFound(let error):
            return CampaignResult(
                presented: false,
                purchased: false,
                cancelled: false,
                restored: false,
                error: error
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

    // MARK: - Queue Management (removed in 2.9.0 — kept as no-ops for source compatibility)

    /// - Warning: The durable offline queue was removed (incident 03/08/2026). Always 0.
    @available(*, deprecated, message: "Fila offline removida em 2.9.0; no-op, sai na 3.0.0.")
    public func getOfflineQueueSize() -> Int { 0 }

    /// - Warning: No-op. Clears the durable critical-retry store instead.
    @available(*, deprecated, message: "Fila offline removida em 2.9.0; limpa o PendingRetry, sai na 3.0.0.")
    public func clearOfflineQueue() async { await PendingRetry.shared.clear() }

    /// - Warning: No-op. `PendingRetry` drains itself on a 30s timer and on network recovery.
    @available(*, deprecated, message: "Fila offline removida em 2.9.0; no-op, sai na 3.0.0.")
    @discardableResult
    public func processOfflineQueue() async -> OfflineQueueResult {
        OfflineQueueResult(processed: 0, failed: 0)
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
        return await nm.requestPushPermission(provisional: provisional)
    }

    /// Current OS push permission, without prompting.
    public func getPushPermissionStatus() async -> PushPermissionStatus {
        guard let nm = notificationsManager else { return .notDetermined }
        return await nm.getPermissionStatus()
    }

    /// Soft prompt: the SDK never renders UI — it hands back the copy plus `accept()` /
    /// `reject()`, so the app owns the presentation and the SDK owns the funnel events.
    public func requestPushPermissionWithPrePrompt(_ options: PrePromptOptions) -> PrePromptHandle? {
        notificationsManager?.requestPermissionWithPrePrompt(options)
    }

    /// Callbacks accumulate — registering a second one does not replace the first.
    public func onNotificationReceived(_ callback: @escaping (NotificationPayload) -> Void) {
        notificationsManager?.onReceived(callback)
    }

    public func onNotificationOpened(_ callback: @escaping (NotificationPayload) -> Void) {
        notificationsManager?.onOpened(callback)
    }

    public func onNotificationDismissed(_ callback: @escaping (NotificationPayload) -> Void) {
        notificationsManager?.onDismissed(callback)
    }

    /// The notification that launched the app, if any.
    public func getInitialNotification() -> NotificationPayload? {
        notificationsManager?.getInitialNotification()
    }

    /// Call from `application(_:didFinishLaunchingWithOptions:)` with the remote-notification
    /// launch option so a cold start from a push is attributed.
    public func setInitialNotification(userInfo: [AnyHashable: Any]) {
        notificationsManager?.setInitialNotification(userInfo: userInfo)
    }

    public func flushNotificationEvents() async {
        await notificationsManager?.flushEvents()
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
        await PendingRetry.shared.dispose()
        stopSuperwallBridge()
        attEnrichCleanup?()
        attEnrichCleanup = nil
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
        config = nil
        isReadyFlag = false
        initTask = nil
    }
}

// MARK: - Convenience

public typealias Paywallo = PaywalloClient
