import Foundation

public final class AnalyticsError: PaywalloError {
    public init(code: String, message: String) {
        super.init(domain: "analytics", code: code, message: message)
    }
}
