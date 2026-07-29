import Foundation

public final class CampaignError: PaywalloError {
    public init(code: String, message: String) {
        super.init(domain: "campaign", code: code, message: message)
    }
}

public enum CampaignErrorCode {
    public static let notInitialized = "CAMPAIGN_NOT_INITIALIZED"
    public static let fetchFailed = "CAMPAIGN_FETCH_FAILED"
    public static let preloadFailed = "CAMPAIGN_PRELOAD_FAILED"
    public static let notFound = "CAMPAIGN_NOT_FOUND"
    public static let presentFailed = "CAMPAIGN_PRESENT_FAILED"
}
