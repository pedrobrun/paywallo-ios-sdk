import Foundation

public final class SessionError: PaywalloError {
    public init(code: String, message: String) {
        super.init(domain: "session", code: code, message: message)
    }
}

public enum SessionErrorCode {
    public static let notInitialized = "SESSION_NOT_INITIALIZED"
    public static let startFailed = "SESSION_START_FAILED"
    public static let endFailed = "SESSION_END_FAILED"
    public static let restoreFailed = "SESSION_RESTORE_FAILED"
}
