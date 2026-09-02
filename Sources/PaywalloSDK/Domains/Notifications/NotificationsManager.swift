import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Config

public struct NotificationsConfig {
    public var requestPermissionOnInit: Bool
    public var debug: Bool

    public init(requestPermissionOnInit: Bool = false, debug: Bool = false) {
        self.requestPermissionOnInit = requestPermissionOnInit
        self.debug = debug
    }
}

// MARK: - NotificationsManager

public final class NotificationsManager {

    // MARK: - Dependencies

    private let apiClient: ApiClient
    private let secureStorage: SecureStorage
    private let distinctIdProvider: () -> String
    /// Optional: without it the lifecycle events (delivered/displayed/clicked/dismissed)
    /// have nowhere to go and the tracker is not built.
    private let eventBatcher: EventBatcherProtocol?
    private let deviceIdProvider: (() -> String)?

    // MARK: - State

    private var isInitialized = false
    private var config = NotificationsConfig()
    private var debug = false

    private var currentToken: String?
    private var registeredToken: String?
    private var permissionStatus: PushPermissionStatus = .notDetermined

    // Deferred handler setup
    private var pendingHandlers: (() -> Void)?
    private var handlers: NotificationHandlers?

    private let permissionManager = PermissionManager()
    private var eventTracker: NotificationEventTracker?
#if canImport(UserNotifications)
    /// `UNUserNotificationCenter.delegate` is a weak reference — the SDK has to own it.
    private var notificationDelegate: PaywalloNotificationDelegate?
#endif

    // Subscribers accumulate (matching the RN SDK): a second `onOpened` never replaces
    // the first, so two independent features can both listen.
    private var receivedCallbacks: [(NotificationPayload) -> Void] = []
    private var openedCallbacks: [(NotificationPayload) -> Void] = []
    private var dismissedCallbacks: [(NotificationPayload) -> Void] = []

    private var initialNotification: NotificationPayload?

    // Token refresh subscription (stored so we can cancel on destroy)
    private var tokenRefreshTask: Task<Void, Never>?

    // Storage keys (bare keys — SecureStorage prepends its own prefix)
    private let tokenKey = PaywalloConstants.pushTokenKey

    // MARK: - Init

    public init(
        apiClient: ApiClient,
        secureStorage: SecureStorage = .shared,
        distinctIdProvider: @escaping () -> String,
        eventBatcher: EventBatcherProtocol? = nil,
        deviceIdProvider: (() -> String)? = nil
    ) {
        self.apiClient = apiClient
        self.secureStorage = secureStorage
        self.distinctIdProvider = distinctIdProvider
        self.eventBatcher = eventBatcher
        self.deviceIdProvider = deviceIdProvider
    }

    // MARK: - Initialize

    /// Full init sequence:
    /// applyConfig → apply deferred handlers → build event tracker → install the
    /// UNUserNotificationCenter delegate → refreshPermissionStatus
    ///   → waitForApnsToken (3 retries @ 500ms) → getToken
    ///   → registerAndPersistToken → subscribeTokenRefresh
    public func initialize(config: NotificationsConfig = NotificationsConfig(), apnsToken: String? = nil) async {
        guard !isInitialized else { return }

        applyConfig(config)

        // Apply any handlers that were set before initialize was called
        if let pending = pendingHandlers {
            pending()
            pendingHandlers = nil
        }
        ensureHandlers()

        await setupEventTracker()
        installNotificationDelegate()

        await refreshPermissionStatus()

        // Resolve APNS token (injected or wait for it)
        let token: String?
        if let injected = apnsToken {
            token = injected
        } else {
            token = await waitForApnsToken(retries: 3, delayMs: 500)
        }

        if let t = token {
            currentToken = t
            await registerAndPersistToken(t)
        } else {
            log("APNS token unavailable after retries")
        }

        subscribeTokenRefresh()
        isInitialized = true

        log("Initialized (token: \(currentToken ?? "none"))")
    }

    /// Marks the subsystem ready without running the init sequence — used when the host
    /// drives token acquisition itself.
    public func markInitialized() {
        isInitialized = true
    }

    // MARK: - setupHandlers (deferred pattern)

    /// If called before initialize(), stores handlers for deferred apply.
    public func setupHandlers(_ configure: @escaping (inout NotificationHandlers) -> Void) {
        if isInitialized {
            var h = handlers ?? NotificationHandlers()
            configure(&h)
            handlers = h
        } else {
            pendingHandlers = { [weak self] in
                guard let self = self else { return }
                var h = self.handlers ?? NotificationHandlers()
                configure(&h)
                self.handlers = h
            }
        }
    }

    // MARK: - Subscribers

    public func onReceived(_ callback: @escaping (NotificationPayload) -> Void) {
        receivedCallbacks.append(callback)
        ensureHandlers()
        if receivedCallbacks.count == 1 {
            // The fan-out is installed only for the first subscriber: while
            // `handlers.onReceived` is nil, NotificationHandlers buffers what arrives, and
            // the new subscriber drains that backlog right below.
            handlers?.onReceived = { [weak self] payload in
                self?.receivedCallbacks.forEach { $0(payload) }
            }
        }
        handlers?.drainReceived().forEach(callback)
    }

    public func onOpened(_ callback: @escaping (NotificationPayload) -> Void) {
        openedCallbacks.append(callback)
        ensureHandlers()
        if openedCallbacks.count == 1 {
            handlers?.onOpened = { [weak self] payload in
                self?.openedCallbacks.forEach { $0(payload) }
            }
        }
        handlers?.drainOpened().forEach(callback)
    }

    public func onDismissed(_ callback: @escaping (NotificationPayload) -> Void) {
        dismissedCallbacks.append(callback)
        ensureHandlers()
        if dismissedCallbacks.count == 1 {
            handlers?.onDismissed = { [weak self] payload in
                self?.dismissedCallbacks.forEach { $0(payload) }
            }
        }
        handlers?.drainDismissed().forEach(callback)
    }

    /// The notification that launched the app.
    ///
    /// iOS has no equivalent of FCM's `getInitialNotification()`: the payload arrives
    /// either in `didFinishLaunchingWithOptions[.remoteNotification]` — forward it through
    /// `setInitialNotification(userInfo:)` — or through the delegate's cold-start
    /// `didReceive response`, which lands in the opened buffer. Peeking at that buffer
    /// covers the second case without the host wiring anything, and leaves the payload in
    /// place for the `onOpened` subscribers.
    public func getInitialNotification() -> NotificationPayload? {
        initialNotification ?? handlers?.peekOpened()
    }

    /// Forward `launchOptions[.remoteNotification]` from
    /// `application(_:didFinishLaunchingWithOptions:)`.
    public func setInitialNotification(userInfo: [AnyHashable: Any]) {
        initialNotification = NotificationPayload(userInfo: userInfo)
    }

    /// Ships whatever the event pipeline has buffered — call before app termination.
    public func flushEvents() async {
        await eventBatcher?.flush()
    }

    // MARK: - Permission

    /// Current OS authorization status.
    public func getPermissionStatus() async -> PushPermissionStatus {
        let status = await permissionManager.getStatus()
        permissionStatus = status
        return status
    }

    /// Requests OS authorization. Returns the real status, so a provisional request
    /// resolves to `.provisional` instead of collapsing into granted/denied.
    @discardableResult
    public func requestPermission(provisional: Bool = false) async -> PushPermissionStatus {
        let status = await permissionManager.requestPermission(provisional: provisional)
        permissionStatus = status
        return status
    }

    /// Requests OS authorization and, when granted, registers for remote notifications so
    /// the OS actually delivers a device token.
    ///
    /// Without `registerForRemoteNotifications()` the SDK reported `.granted` and no token
    /// was ever registered until the host bridged it by hand. The token itself still
    /// arrives asynchronously through
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`, which the host
    /// forwards to `setApnsToken(_:)`.
    @discardableResult
    public func requestPushPermission(provisional: Bool = false) async -> PushPermissionStatus {
        let status = await requestPermission(provisional: provisional)
        guard status == .granted || status == .provisional else {
            log("Permission not granted (\(status.rawValue)) — skipping token registration")
            return status
        }
        registerForRemoteNotifications()
        return status
    }

    /// Soft prompt flow — the SDK never renders UI; the returned handle carries the copy
    /// and the accept/reject callbacks for the host's own modal.
    public func requestPermissionWithPrePrompt(_ options: PrePromptOptions) -> PrePromptHandle {
        permissionManager.requestPermissionWithPrePrompt(options)
    }

    /// Sink for the soft-prompt funnel events (`prompt_shown`, `soft_accepted`, …).
    public func setPrePromptTracker(_ tracker: PrePromptTracker?) {
        permissionManager.setTracker(tracker)
    }

    /// Returns true if notification permission is authorized.
    public func hasPermission() async -> Bool {
        await getPermissionStatus() == .granted
    }

    // MARK: - Token Management

    /// Update the APNS token (call from AppDelegate / NotificationService).
    ///
    /// This is the entry point for auto token-refresh on iOS: the OS always delivers
    /// the new token via `AppDelegate.didRegisterForRemoteNotificationsWithDeviceToken`,
    /// which the host must forward here. If the token differs from the last one registered
    /// with the backend, the SDK re-POSTs automatically (no-op when unchanged).
    public func setApnsToken(_ token: String) async {
        currentToken = token
        // Skip re-registration if this token was already sent to the server.
        // Uses registeredToken (last value confirmed with the backend) so a process
        // restart never silently skips re-registration just because currentToken matches.
        guard token != registeredToken else {
            log("Token unchanged, skipping re-registration")
            return
        }
        if isInitialized {
            await registerAndPersistToken(token)
        }
    }

    /// Clears the locally stored token only — no server call.
    public func invalidateLocalToken() async {
        currentToken = nil
        registeredToken = nil
        await secureStorage.remove(tokenKey)
        log("Local token invalidated")
    }

    /// Opt the user out: sends DELETE to server then clears locally.
    public func optOut() async {
        if let token = registeredToken ?? currentToken {
            await apiClient.removeToken(token, distinctId: distinctIdProvider())
        }
        await invalidateLocalToken()
        log("Opted out from push notifications")
    }

    // MARK: - Destroy

    public func destroy() {
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
        handlers = nil
        pendingHandlers = nil
        receivedCallbacks = []
        openedCallbacks = []
        dismissedCallbacks = []
        eventTracker = nil
#if canImport(UserNotifications)
        notificationDelegate = nil
#endif
        isInitialized = false
        log("Destroyed")
    }

    // MARK: - Getters

    public var currentPushToken: String? { currentToken }
    public var isReady: Bool { isInitialized }
    public var currentPermissionStatus: PushPermissionStatus { permissionStatus }

    // MARK: - Private Helpers

    private func applyConfig(_ config: NotificationsConfig) {
        self.config = config
        self.debug = config.debug
        permissionManager.setDebug(config.debug)
    }

    private func ensureHandlers() {
        if handlers == nil { handlers = NotificationHandlers() }
    }

    /// Builds the lifecycle tracker so `notification_delivered/displayed/clicked/dismissed`
    /// reach the server. Without an event batcher there is no pipeline to feed.
    private func setupEventTracker() async {
        guard let batcher = eventBatcher else {
            log("No event batcher injected — notification lifecycle events are disabled")
            return
        }
        let tracker = NotificationEventTracker(
            eventBatcher: batcher,
            secureStorage: secureStorage,
            deviceIdProvider: deviceIdProvider ?? { "" },
            debug: debug
        )
        await tracker.restoreFromStorage()
        eventTracker = tracker
    }

    private func installNotificationDelegate() {
#if canImport(UserNotifications)
        // UNUserNotificationCenter.current() crashes in CLI / XCTest command-line contexts
        // where there is no running application. Guard: the main bundle must be an .app.
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            log("Skipping delegate install (not running in an app context)")
            return
        }
        let delegate = PaywalloNotificationDelegate(
            handlers: { [weak self] in self?.handlers },
            tracker: eventTracker
        )
        notificationDelegate = delegate
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().delegate = delegate
        }
        log("UNUserNotificationCenter delegate installed")
#endif
    }

    private func registerForRemoteNotifications() {
#if canImport(UIKit) && os(iOS)
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }
        log("Registered for remote notifications")
#endif
    }

    private func refreshPermissionStatus() async {
        permissionStatus = await permissionManager.getStatus()
        log("Permission status: \(permissionStatus.rawValue)")
    }

    /// Polls for an APNS token with up to `retries` attempts separated by `delayMs` milliseconds.
    private func waitForApnsToken(retries: Int, delayMs: Int) async -> String? {
        // First check local storage for a previously persisted token
        if let stored = await secureStorage.get(tokenKey) {
            return stored
        }

        // Poll (in-memory token from AppDelegate callback)
        for attempt in 1...retries {
            if let t = currentToken { return t }
            log("Waiting for APNS token (attempt \(attempt)/\(retries))")
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
        }

        return currentToken
    }

    private func registerAndPersistToken(_ token: String) async {
        await apiClient.registerToken(token, distinctId: distinctIdProvider())
        registeredToken = token
        await secureStorage.set(tokenKey, value: token)
        log("Token registered: \(token.prefix(8))...")
    }

    private func subscribeTokenRefresh() {
        // On iOS, token refresh is fully reactive: the OS delivers the new token via
        // AppDelegate.didRegisterForRemoteNotificationsWithDeviceToken, and the host
        // forwards it through setApnsToken(_:). That method compares the incoming
        // token against registeredToken and re-POSTs only when they differ.
        // No additional async subscription is needed on the SDK side.
        tokenRefreshTask = nil
    }

    private func log(_ message: String) {
        guard debug else { return }
        print("[Paywallo:Notifications] \(message)")
    }
}
