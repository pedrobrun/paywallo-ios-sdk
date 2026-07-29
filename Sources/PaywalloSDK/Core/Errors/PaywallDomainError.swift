import Foundation

public final class PaywallDomainError: PaywalloError {
    public init(code: String, message: String) {
        super.init(domain: "paywall", code: code, message: message)
    }
}

public enum PaywallErrorCode {
    public static let notInitialized = "PAYWALL_NOT_INITIALIZED"
    public static let notFound = "PAYWALL_NOT_FOUND"
    public static let renderFailed = "PAYWALL_RENDER_FAILED"
    public static let loadFailed = "PAYWALL_LOAD_FAILED"
    public static let dismissFailed = "PAYWALL_DISMISS_FAILED"
    public static let invalidConfig = "PAYWALL_INVALID_CONFIG"
}
