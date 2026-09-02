import Foundation

public final class ClientError: PaywalloError {
    public init(code: String, message: String) {
        super.init(domain: "client", code: code, message: message)
    }
}

public enum ClientErrorCode {
    public static let notInitialized = "CLIENT_NOT_INITIALIZED"
    public static let missingAppKey = "CLIENT_MISSING_APP_KEY"
    public static let invalidEventName = "CLIENT_INVALID_EVENT_NAME"
    public static let reservedEventName = "CLIENT_RESERVED_EVENT_NAME"
    public static let providerMissing = "CLIENT_PROVIDER_MISSING"
    public static let insecureRequest = "CLIENT_INSECURE_REQUEST"
    public static let invalidApiUrl = "CLIENT_INVALID_API_URL"
    public static let unknown = "CLIENT_UNKNOWN"
    public static let eventDeliveryFailed = "CLIENT_EVENT_DELIVERY_FAILED"
}
