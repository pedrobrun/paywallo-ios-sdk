import Foundation
#if canImport(UserNotifications)
import UserNotifications
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

    // MARK: - State

    private var isInitialized = false
    private var config = NotificationsConfig()
    private var debug = false

    private var currentToken: String?
    private var registeredToken: String?

    // Deferred handler setup
    private var pendingHandlers: (() -> Void)?
    private var handlers: NotificationHandlers?

    // Token refresh subscription (stored so we can cancel on destroy)
    private var tokenRefreshTask: Task<Void, Never>?

    // Storage keys (bare keys — SecureStorage prepends its own prefix)
    private let tokenKey = PaywalloConstants.pushTokenKey

    // MARK: - Init

    public init(
        apiClient: ApiClient,
        secureStorage: SecureStorage = .shared,
        distinctIdProvider: @escaping () -> String
    ) {
        self.apiClient = apiClient
        self.secureStorage = secureStorage
        self.distinctIdProvider = distinctIdProvider
    }

    // MARK: - Initialize

    /// Full init sequence:
    /// applyConfig → apply deferred handlers → refreshPermissionStatus
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

    // MARK: - Permission

    /// Wraps UNUserNotificationCenter.requestAuthorization
    @discardableResult
    public func requestPermission(provisional: Bool = false) async -> Bool {
#if canImport(UserNotifications)
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        do {
            var options: UNAuthorizationOptions = [.alert, .sound, .badge]
            if provisional {
                if #available(iOS 12, *) {
                    options.insert(.provisional)
                }
            }
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: options)
            log("Permission request result: \(granted)")
            return granted
        } catch {
            log("Permission request error: \(error)")
            return false
        }
#else
        return false
#endif
    }

    /// Returns true if notification permission is authorized.
    public func hasPermission() async -> Bool {
#if canImport(UserNotifications)
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
#else
        return false
#endif
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
        isInitialized = false
        log("Destroyed")
    }

    // MARK: - Getters

    public var currentPushToken: String? { currentToken }
    public var isReady: Bool { isInitialized }

    // MARK: - Private Helpers

    private func applyConfig(_ config: NotificationsConfig) {
        self.config = config
        self.debug = config.debug
    }

    private func refreshPermissionStatus() async {
#if canImport(UserNotifications)
        // UNUserNotificationCenter.current() crashes in CLI / XCTest command-line contexts
        // where there is no running application. Guard: the main bundle must be an .app bundle.
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            log("Skipping permission refresh (not running in an app context)")
            return
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        log("Permission status: \(settings.authorizationStatus.rawValue)")
#endif
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
