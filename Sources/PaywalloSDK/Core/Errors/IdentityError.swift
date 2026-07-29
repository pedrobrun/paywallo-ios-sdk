import Foundation

public final class IdentityError: PaywalloError {
    public init(code: String, message: String) {
        super.init(domain: "identity", code: code, message: message)
    }
}

public enum IdentityErrorCode {
    public static let notInitialized = "IDENTITY_NOT_INITIALIZED"
    public static let deviceIdUnavailable = "IDENTITY_DEVICE_ID_UNAVAILABLE"
    public static let storageReadFailed = "IDENTITY_STORAGE_READ_FAILED"
    public static let storageWriteFailed = "IDENTITY_STORAGE_WRITE_FAILED"
    public static let identifyFailed = "IDENTITY_IDENTIFY_FAILED"
}
