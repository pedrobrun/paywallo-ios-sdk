import Foundation

public final class PlanError: PaywalloError {
    public init(code: String, message: String) {
        super.init(domain: "plan", code: code, message: message)
    }
}
