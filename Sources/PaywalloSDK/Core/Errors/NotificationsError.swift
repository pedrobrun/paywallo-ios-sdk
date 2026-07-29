import Foundation

public class NotificationsError: PaywalloError {
    public let details: Any?

    public init(code: String, message: String, details: Any? = nil) {
        self.details = details
        super.init(domain: "notifications", code: code, message: message)
    }
}

public enum NotificationsErrorCode {
    public static let tokenUnavailable = "TOKEN_UNAVAILABLE"
    public static let permissionDenied = "PERMISSION_DENIED"
    public static let registrationFailed = "REGISTRATION_FAILED"
    public static let notInitialized = "NOT_INITIALIZED"
    public static let aborted = "ABORTED"
}

public final class TokenUnavailableError: NotificationsError {
    public init(message: String = "APNS token not available") {
        super.init(code: NotificationsErrorCode.tokenUnavailable, message: message)
    }
}

public final class PermissionDeniedError: NotificationsError {
    public init(message: String = "Push notification permission denied") {
        super.init(code: NotificationsErrorCode.permissionDenied, message: message)
    }
}

public final class RegistrationFailedError: NotificationsError {
    public init(message: String = "Token registration failed", details: Any? = nil) {
        super.init(code: NotificationsErrorCode.registrationFailed, message: message, details: details)
    }
}
