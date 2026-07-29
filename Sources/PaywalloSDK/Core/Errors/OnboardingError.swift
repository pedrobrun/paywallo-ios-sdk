import Foundation

public final class OnboardingError: PaywalloError {
    public init(code: String, message: String) {
        super.init(domain: "onboarding", code: code, message: message)
    }
}

public enum OnboardingErrorCode {
    public static let notInitialized = "ONBOARDING_NOT_INITIALIZED"
    public static let invalidStepName = "ONBOARDING_INVALID_STEP_NAME"
    public static let invalidOrder = "ONBOARDING_INVALID_ORDER"
}
