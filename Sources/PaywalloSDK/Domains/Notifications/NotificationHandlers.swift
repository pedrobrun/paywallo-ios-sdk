import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

// MARK: - Notification Payload

public struct NotificationPayload {
    public let notificationId: String?
    public let campaignId: String?
    public let variantKey: String?
    public let messageId: String?
    public let appUserId: String?
    public let failureReason: String?
    public let deepLink: String?
    public let rawUserInfo: [AnyHashable: Any]

    public init(userInfo: [AnyHashable: Any]) {
        self.rawUserInfo    = userInfo
        self.notificationId = userInfo["notification_id"] as? String
        self.campaignId     = userInfo["campaign_id"] as? String
        self.variantKey     = userInfo["variant_key"] as? String
            ?? userInfo["variantKey"] as? String
        self.messageId      = userInfo["message_id"] as? String
            ?? userInfo["messageId"] as? String
        self.appUserId      = userInfo["app_user_id"] as? String
            ?? userInfo["appUserId"] as? String
        self.failureReason  = userInfo["failure_reason"] as? String
            ?? userInfo["failureReason"] as? String
        self.deepLink       = userInfo["deep_link"] as? String
            ?? userInfo["deepLink"] as? String
    }
}

// MARK: - DeepLinkResolver

public struct DeepLinkResolver {
    public typealias Handler = (String) -> Void

    private var handlers: [(prefix: String, handler: Handler)] = []

    public mutating func register(prefix: String, handler: @escaping Handler) {
        handlers.append((prefix: prefix, handler: handler))
    }

    public func resolve(_ url: String) {
        for entry in handlers {
            if url.hasPrefix(entry.prefix) {
                entry.handler(url)
                return
            }
        }
        // No match — fallback
    }
}

// MARK: - Pre-subscribe Buffer

/// Buffers notification events that arrive before subscribers are ready.
public final class NotificationEventBuffer {
    private static let maxEvents = 100

    private var buffer: [NotificationPayload] = []

    public func push(_ payload: NotificationPayload) {
        if buffer.count >= Self.maxEvents {
            buffer.removeFirst()  // oldest out
        }
        buffer.append(payload)
    }

    public func drain() -> [NotificationPayload] {
        let events = buffer
        buffer.removeAll()
        return events
    }

    public var count: Int { buffer.count }
}

// MARK: - NotificationHandlers

public struct NotificationHandlers {
    // MARK: - Callbacks

    public var onReceived:  ((NotificationPayload) -> Void)?
    public var onOpened:    ((NotificationPayload) -> Void)?
    public var onDismissed: ((NotificationPayload) -> Void)?

    // MARK: - Deep Link

    public var deepLinkResolver = DeepLinkResolver()

    // MARK: - Pre-subscribe buffer

    public let receivedBuffer  = NotificationEventBuffer()
    public let openedBuffer    = NotificationEventBuffer()
    public let dismissedBuffer = NotificationEventBuffer()

    public init() {}

    // MARK: - Dispatch

    public func handleReceived(_ payload: NotificationPayload) {
        if let handler = onReceived {
            handler(payload)
        } else {
            receivedBuffer.push(payload)
        }
    }

    public func handleOpened(_ payload: NotificationPayload) {
        if let handler = onOpened {
            handler(payload)
        } else {
            openedBuffer.push(payload)
        }

        if let deepLink = payload.deepLink {
            deepLinkResolver.resolve(deepLink)
        }
    }

    public func handleDismissed(_ payload: NotificationPayload) {
        if let handler = onDismissed {
            handler(payload)
        } else {
            dismissedBuffer.push(payload)
        }
    }

    // MARK: - Drain buffers after subscriber attaches

    public func drainReceived() -> [NotificationPayload] { receivedBuffer.drain() }
    public func drainOpened()   -> [NotificationPayload] { openedBuffer.drain() }
    public func drainDismissed() -> [NotificationPayload] { dismissedBuffer.drain() }
}

// MARK: - UNUserNotificationCenterDelegate Bridge

#if canImport(UserNotifications)

/// Drop-in UNUserNotificationCenterDelegate implementation that routes events
/// through NotificationHandlers. Set this as UNUserNotificationCenter.current().delegate
/// and wire in the handlers via NotificationsManager.setupHandlers().
public final class PaywalloNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    private var handlers: () -> NotificationHandlers?
    private var tracker: NotificationEventTracker?

    public init(
        handlers: @escaping () -> NotificationHandlers?,
        tracker: NotificationEventTracker? = nil
    ) {
        self.handlers = handlers
        self.tracker = tracker
    }

    // MARK: - Foreground display

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let payload = NotificationPayload(userInfo: notification.request.content.userInfo)
        handlers()?.handleReceived(payload)

        Task { [weak self] in
            await self?.tracker?.trackReceived(
                notificationId: payload.notificationId,
                campaignId: payload.campaignId,
                variantKey: payload.variantKey,
                messageId: payload.messageId,
                appUserId: payload.appUserId
            )
        }

        completionHandler([.banner, .sound, .badge])
    }

    // MARK: - Interaction response

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let payload = NotificationPayload(userInfo: response.notification.request.content.userInfo)

        if response.actionIdentifier == UNNotificationDismissActionIdentifier {
            handlers()?.handleDismissed(payload)
            Task { [weak self] in
                await self?.tracker?.trackDismissed(
                    notificationId: payload.notificationId,
                    campaignId: payload.campaignId,
                    variantKey: payload.variantKey,
                    messageId: payload.messageId,
                    appUserId: payload.appUserId
                )
            }
        } else {
            handlers()?.handleOpened(payload)
            Task { [weak self] in
                await self?.tracker?.trackOpened(
                    notificationId: payload.notificationId,
                    campaignId: payload.campaignId,
                    variantKey: payload.variantKey,
                    messageId: payload.messageId,
                    appUserId: payload.appUserId
                )
            }
        }

        completionHandler()
    }
}

#endif
