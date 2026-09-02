import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

// MARK: - Pre-prompt events

public enum PromptEventType: String, Sendable {
    case promptShown = "prompt_shown"
    case softAccepted = "soft_accepted"
    case softRejected = "soft_rejected"
    case osGranted = "os_granted"
    case osDenied = "os_denied"
}

/// Sink for the soft-prompt funnel. Optional: with none injected the events are
/// dropped, exactly like the RN SDK, which has no default prompt channel either.
public protocol PrePromptTracker: AnyObject {
    func trackPromptEvent(_ event: PromptEventType)
}

// MARK: - Pre-prompt handle

public struct PrePromptOptions {
    public var title: String
    public var body: String
    public var acceptLabel: String?
    public var rejectLabel: String?
    public var provisional: Bool

    public init(
        title: String,
        body: String,
        acceptLabel: String? = nil,
        rejectLabel: String? = nil,
        provisional: Bool = false
    ) {
        self.title = title
        self.body = body
        self.acceptLabel = acceptLabel
        self.rejectLabel = rejectLabel
        self.provisional = provisional
    }
}

/// What the host drives from its own bottom sheet / modal — the SDK never renders UI.
/// `accept()` and `reject()` are idempotent: only the first one settles the prompt, so a
/// double tap cannot emit the funnel event twice or re-open the OS dialog.
public final class PrePromptHandle {
    public let title: String
    public let body: String
    public let acceptLabel: String?
    public let rejectLabel: String?

    private let lock = NSLock()
    private var settled = false

    private let onAccept: () async -> PushPermissionStatus
    private let onReject: () -> Void
    private let currentStatus: () async -> PushPermissionStatus

    init(
        title: String,
        body: String,
        acceptLabel: String?,
        rejectLabel: String?,
        onAccept: @escaping () async -> PushPermissionStatus,
        onReject: @escaping () -> Void,
        currentStatus: @escaping () async -> PushPermissionStatus
    ) {
        self.title = title
        self.body = body
        self.acceptLabel = acceptLabel
        self.rejectLabel = rejectLabel
        self.onAccept = onAccept
        self.onReject = onReject
        self.currentStatus = currentStatus
    }

    /// Call after the user taps accept in the custom UI.
    public func accept() async -> PushPermissionStatus {
        guard settle() else { return await currentStatus() }
        return await onAccept()
    }

    /// Call after the user taps reject in the custom UI. The OS dialog is never shown,
    /// so the permission is still undecided.
    @discardableResult
    public func reject() -> PushPermissionStatus {
        guard settle() else { return .notDetermined }
        onReject()
        return .notDetermined
    }

    private func settle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if settled { return false }
        settled = true
        return true
    }
}

// MARK: - PermissionManager

/// Owns the push permission status and the soft-prompt flow.
public final class PermissionManager {

    private weak var tracker: PrePromptTracker?
    private var debug: Bool

    public init(debug: Bool = false, tracker: PrePromptTracker? = nil) {
        self.debug = debug
        self.tracker = tracker
    }

    public func setTracker(_ tracker: PrePromptTracker?) {
        self.tracker = tracker
    }

    public func setDebug(_ debug: Bool) {
        self.debug = debug
    }

    // MARK: - Status

    public func getStatus() async -> PushPermissionStatus {
#if canImport(UserNotifications)
        // UNUserNotificationCenter.current() crashes in CLI / XCTest command-line contexts
        // where there is no running application. Guard: the main bundle must be an .app.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .notDetermined }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.map(settings.authorizationStatus)
#else
        return .notDetermined
#endif
    }

    /// Requests OS authorization and returns the resulting status.
    ///
    /// `requestAuthorization` only answers "granted or not" — a provisional grant also
    /// reports `true` — so the real status is read back from the settings afterwards.
    /// That read-back is what makes `.provisional` reachable at all.
    public func requestPermission(provisional: Bool = false) async -> PushPermissionStatus {
#if canImport(UserNotifications)
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .notDetermined }

        var options: UNAuthorizationOptions = [.alert, .sound, .badge]
        if provisional {
            options.insert(.provisional)
        }

        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: options)
        } catch {
            // A throw here means the prompt never resolved; the settings read below still
            // reports the truth, so the failure does not need to propagate.
            log("permission request error: \(error)")
        }

        let status = await getStatus()
        log("permission status after request: \(status.rawValue)")
        emitOsEvent(status)
        return status
#else
        return .notDetermined
#endif
    }

    // MARK: - Pre-prompt

    /// Soft prompt flow — the SDK never renders UI. Returns a handle with accept/reject
    /// that the host calls from its own bottom sheet / modal, and emits the funnel events
    /// through the injected tracker.
    public func requestPermissionWithPrePrompt(_ options: PrePromptOptions) -> PrePromptHandle {
        log("pre-prompt shown")
        emitPromptEvent(.promptShown)

        return PrePromptHandle(
            title: options.title,
            body: options.body,
            acceptLabel: options.acceptLabel,
            rejectLabel: options.rejectLabel,
            onAccept: { [weak self] in
                guard let self = self else { return .notDetermined }
                self.emitPromptEvent(.softAccepted)
                self.log("pre-prompt accepted")
                return await self.requestPermission(provisional: options.provisional)
            },
            onReject: { [weak self] in
                self?.emitPromptEvent(.softRejected)
                self?.log("pre-prompt rejected")
            },
            currentStatus: { [weak self] in
                await self?.getStatus() ?? .notDetermined
            }
        )
    }

    // MARK: - Private

#if canImport(UserNotifications)
    private static func map(_ status: UNAuthorizationStatus) -> PushPermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied: return .denied
        case .provisional: return .provisional
        default: return .notDetermined
        }
    }
#endif

    private func emitPromptEvent(_ event: PromptEventType) {
        tracker?.trackPromptEvent(event)
    }

    private func emitOsEvent(_ status: PushPermissionStatus) {
        switch status {
        case .granted, .provisional: emitPromptEvent(.osGranted)
        case .denied: emitPromptEvent(.osDenied)
        case .notDetermined: break
        }
    }

    private func log(_ message: String) {
        guard debug else { return }
        print("[Paywallo:Notifications] \(message)")
    }
}
