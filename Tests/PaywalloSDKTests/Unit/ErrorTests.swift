import XCTest
@testable import PaywalloSDK

final class ErrorTests: XCTestCase {

    // MARK: - PaywalloError Base

    func testPaywalloErrorProperties() {
        let error = PaywalloError(domain: "test", code: "TEST_CODE", message: "Test message")
        XCTAssertEqual(error.domain, "test")
        XCTAssertEqual(error.code, "TEST_CODE")
        XCTAssertEqual(error.message, "Test message")
    }

    func testPaywalloErrorDescription() {
        let error = PaywalloError(domain: "test", code: "CODE", message: "msg")
        XCTAssertEqual(error.description, "[test] CODE: msg")
    }

    func testPaywalloErrorLocalizedDescription() {
        let error = PaywalloError(domain: "test", code: "CODE", message: "User-facing message")
        XCTAssertEqual(error.localizedDescription, "User-facing message")
    }

    // MARK: - ClientError

    func testClientErrorDomain() {
        let error = ClientError(code: "TEST", message: "msg")
        XCTAssertEqual(error.domain, "client")
    }

    func testClientErrorCodes() {
        XCTAssertEqual(ClientErrorCode.notInitialized, "CLIENT_NOT_INITIALIZED")
        XCTAssertEqual(ClientErrorCode.missingAppKey, "CLIENT_MISSING_APP_KEY")
        XCTAssertEqual(ClientErrorCode.invalidEventName, "CLIENT_INVALID_EVENT_NAME")
        XCTAssertEqual(ClientErrorCode.providerMissing, "CLIENT_PROVIDER_MISSING")
        XCTAssertEqual(ClientErrorCode.insecureRequest, "CLIENT_INSECURE_REQUEST")
        XCTAssertEqual(ClientErrorCode.unknown, "CLIENT_UNKNOWN")
    }

    // MARK: - IdentityError

    func testIdentityErrorDomain() {
        let error = IdentityError(code: "TEST", message: "msg")
        XCTAssertEqual(error.domain, "identity")
    }

    func testIdentityErrorCodes() {
        XCTAssertEqual(IdentityErrorCode.notInitialized, "IDENTITY_NOT_INITIALIZED")
        XCTAssertEqual(IdentityErrorCode.deviceIdUnavailable, "IDENTITY_DEVICE_ID_UNAVAILABLE")
        XCTAssertEqual(IdentityErrorCode.storageReadFailed, "IDENTITY_STORAGE_READ_FAILED")
        XCTAssertEqual(IdentityErrorCode.storageWriteFailed, "IDENTITY_STORAGE_WRITE_FAILED")
        XCTAssertEqual(IdentityErrorCode.identifyFailed, "IDENTITY_IDENTIFY_FAILED")
    }

    // MARK: - SessionError

    func testSessionErrorDomain() {
        let error = SessionError(code: "TEST", message: "msg")
        XCTAssertEqual(error.domain, "session")
    }

    func testSessionErrorCodes() {
        XCTAssertEqual(SessionErrorCode.notInitialized, "SESSION_NOT_INITIALIZED")
        XCTAssertEqual(SessionErrorCode.startFailed, "SESSION_START_FAILED")
        XCTAssertEqual(SessionErrorCode.endFailed, "SESSION_END_FAILED")
        XCTAssertEqual(SessionErrorCode.restoreFailed, "SESSION_RESTORE_FAILED")
    }

    // MARK: - PurchaseError

    func testPurchaseErrorDomain() {
        let error = PurchaseError(code: "TEST", message: "msg")
        XCTAssertEqual(error.domain, "purchase")
    }

    func testPurchaseErrorUserCancelledDefault() {
        let error = PurchaseError(code: "TEST", message: "msg")
        XCTAssertFalse(error.userCancelled)
        XCTAssertNil(error.httpStatus)
    }

    func testPurchaseErrorUserCancelledTrue() {
        let error = PurchaseError(code: "CANCELLED", message: "msg", userCancelled: true)
        XCTAssertTrue(error.userCancelled)
    }

    func testPurchaseErrorHttpStatus() {
        let error = PurchaseError(code: "FAIL", message: "msg", httpStatus: 422)
        XCTAssertEqual(error.httpStatus, 422)
    }

    func testPurchaseErrorCodes() {
        XCTAssertEqual(PurchaseErrorCode.notInitialized, "PURCHASE_NOT_INITIALIZED")
        XCTAssertEqual(PurchaseErrorCode.productNotFound, "PRODUCT_NOT_FOUND")
        XCTAssertEqual(PurchaseErrorCode.purchaseFailed, "PURCHASE_FAILED")
        XCTAssertEqual(PurchaseErrorCode.restoreFailed, "RESTORE_FAILED")
        XCTAssertEqual(PurchaseErrorCode.validationFailed, "VALIDATION_FAILED")
        XCTAssertEqual(PurchaseErrorCode.userCancelled, "USER_CANCELLED")
        XCTAssertEqual(PurchaseErrorCode.networkError, "PURCHASE_NETWORK_ERROR")
        XCTAssertEqual(PurchaseErrorCode.storeError, "PURCHASE_STORE_ERROR")
        XCTAssertEqual(PurchaseErrorCode.pendingPurchase, "PURCHASE_PENDING")
        XCTAssertEqual(PurchaseErrorCode.deferredPurchase, "PURCHASE_DEFERRED")
        XCTAssertEqual(PurchaseErrorCode.storeNotAvailable, "PURCHASE_STORE_NOT_AVAILABLE")
    }

    func testPurchaseErrorFactory() {
        let error = PurchaseErrorFactory.create(PurchaseErrorCode.userCancelled)
        XCTAssertEqual(error.code, "USER_CANCELLED")
        XCTAssertTrue(error.userCancelled)
        XCTAssertEqual(error.message, "Purchase was cancelled.")
    }

    func testPurchaseErrorFactoryCustomMessage() {
        let error = PurchaseErrorFactory.create(PurchaseErrorCode.purchaseFailed, message: "Custom msg")
        XCTAssertEqual(error.message, "Custom msg")
        XCTAssertFalse(error.userCancelled)
    }

    // MARK: - PaywallDomainError

    func testPaywallDomainErrorDomain() {
        let error = PaywallDomainError(code: "TEST", message: "msg")
        XCTAssertEqual(error.domain, "paywall")
    }

    func testPaywallErrorCodes() {
        XCTAssertEqual(PaywallErrorCode.notInitialized, "PAYWALL_NOT_INITIALIZED")
        XCTAssertEqual(PaywallErrorCode.notFound, "PAYWALL_NOT_FOUND")
        XCTAssertEqual(PaywallErrorCode.renderFailed, "PAYWALL_RENDER_FAILED")
        XCTAssertEqual(PaywallErrorCode.loadFailed, "PAYWALL_LOAD_FAILED")
        XCTAssertEqual(PaywallErrorCode.dismissFailed, "PAYWALL_DISMISS_FAILED")
        XCTAssertEqual(PaywallErrorCode.invalidConfig, "PAYWALL_INVALID_CONFIG")
    }

    // MARK: - CampaignError

    func testCampaignErrorDomain() {
        let error = CampaignError(code: "TEST", message: "msg")
        XCTAssertEqual(error.domain, "campaign")
    }

    func testCampaignErrorCodes() {
        XCTAssertEqual(CampaignErrorCode.notInitialized, "CAMPAIGN_NOT_INITIALIZED")
        XCTAssertEqual(CampaignErrorCode.fetchFailed, "CAMPAIGN_FETCH_FAILED")
        XCTAssertEqual(CampaignErrorCode.preloadFailed, "CAMPAIGN_PRELOAD_FAILED")
        XCTAssertEqual(CampaignErrorCode.notFound, "CAMPAIGN_NOT_FOUND")
        XCTAssertEqual(CampaignErrorCode.presentFailed, "CAMPAIGN_PRESENT_FAILED")
    }

    // MARK: - NotificationsError

    func testNotificationsErrorDomain() {
        let error = NotificationsError(code: "TEST", message: "msg")
        XCTAssertEqual(error.domain, "notifications")
    }

    func testNotificationsErrorDetails() {
        let error = NotificationsError(code: "TEST", message: "msg", details: "extra info")
        XCTAssertEqual(error.details as? String, "extra info")
    }

    func testNotificationsErrorCodes() {
        XCTAssertEqual(NotificationsErrorCode.tokenUnavailable, "TOKEN_UNAVAILABLE")
        XCTAssertEqual(NotificationsErrorCode.permissionDenied, "PERMISSION_DENIED")
        XCTAssertEqual(NotificationsErrorCode.registrationFailed, "REGISTRATION_FAILED")
        XCTAssertEqual(NotificationsErrorCode.notInitialized, "NOT_INITIALIZED")
        XCTAssertEqual(NotificationsErrorCode.aborted, "ABORTED")
    }

    func testTokenUnavailableError() {
        let error = TokenUnavailableError()
        XCTAssertEqual(error.code, "TOKEN_UNAVAILABLE")
        XCTAssertEqual(error.domain, "notifications")
        XCTAssertEqual(error.message, "APNS token not available")
    }

    func testPermissionDeniedError() {
        let error = PermissionDeniedError()
        XCTAssertEqual(error.code, "PERMISSION_DENIED")
        XCTAssertEqual(error.domain, "notifications")
    }

    func testRegistrationFailedError() {
        let error = RegistrationFailedError(details: ["reason": "timeout"])
        XCTAssertEqual(error.code, "REGISTRATION_FAILED")
        XCTAssertNotNil(error.details)
    }

    // MARK: - OnboardingError

    func testOnboardingErrorDomain() {
        let error = OnboardingError(code: "TEST", message: "msg")
        XCTAssertEqual(error.domain, "onboarding")
    }

    func testOnboardingErrorCodes() {
        XCTAssertEqual(OnboardingErrorCode.notInitialized, "ONBOARDING_NOT_INITIALIZED")
        XCTAssertEqual(OnboardingErrorCode.invalidStepName, "ONBOARDING_INVALID_STEP_NAME")
    }

    // MARK: - PlanError & AnalyticsError

    func testPlanErrorDomain() {
        let error = PlanError(code: "TEST", message: "msg")
        XCTAssertEqual(error.domain, "plan")
    }

    func testAnalyticsErrorDomain() {
        let error = AnalyticsError(code: "TEST", message: "msg")
        XCTAssertEqual(error.domain, "analytics")
    }

    // MARK: - Error Code Uniqueness

    func testAllErrorCodesAreUnique() {
        var allCodes: [String] = []

        // Client
        allCodes.append(contentsOf: [
            ClientErrorCode.notInitialized, ClientErrorCode.missingAppKey,
            ClientErrorCode.invalidEventName, ClientErrorCode.providerMissing,
            ClientErrorCode.insecureRequest, ClientErrorCode.unknown
        ])

        // Identity
        allCodes.append(contentsOf: [
            IdentityErrorCode.notInitialized, IdentityErrorCode.deviceIdUnavailable,
            IdentityErrorCode.storageReadFailed, IdentityErrorCode.storageWriteFailed,
            IdentityErrorCode.identifyFailed
        ])

        // Session
        allCodes.append(contentsOf: [
            SessionErrorCode.notInitialized, SessionErrorCode.startFailed,
            SessionErrorCode.endFailed, SessionErrorCode.restoreFailed
        ])

        // Purchase
        allCodes.append(contentsOf: [
            PurchaseErrorCode.notInitialized, PurchaseErrorCode.productNotFound,
            PurchaseErrorCode.purchaseFailed, PurchaseErrorCode.restoreFailed,
            PurchaseErrorCode.validationFailed, PurchaseErrorCode.userCancelled,
            PurchaseErrorCode.networkError, PurchaseErrorCode.storeError,
            PurchaseErrorCode.pendingPurchase, PurchaseErrorCode.deferredPurchase,
            PurchaseErrorCode.storeNotAvailable
        ])

        // Paywall
        allCodes.append(contentsOf: [
            PaywallErrorCode.notInitialized, PaywallErrorCode.notFound,
            PaywallErrorCode.renderFailed, PaywallErrorCode.loadFailed,
            PaywallErrorCode.dismissFailed, PaywallErrorCode.invalidConfig
        ])

        // Campaign
        allCodes.append(contentsOf: [
            CampaignErrorCode.notInitialized, CampaignErrorCode.fetchFailed,
            CampaignErrorCode.preloadFailed, CampaignErrorCode.notFound,
            CampaignErrorCode.presentFailed
        ])

        // Notifications
        allCodes.append(contentsOf: [
            NotificationsErrorCode.tokenUnavailable, NotificationsErrorCode.permissionDenied,
            NotificationsErrorCode.registrationFailed, NotificationsErrorCode.notInitialized,
            NotificationsErrorCode.aborted
        ])

        // Onboarding
        allCodes.append(contentsOf: [
            OnboardingErrorCode.notInitialized, OnboardingErrorCode.invalidStepName
        ])

        let uniqueCodes = Set(allCodes)
        XCTAssertEqual(allCodes.count, uniqueCodes.count, "Found duplicate error codes")
    }

    // MARK: - Inheritance

    func testAllErrorsInheritFromPaywalloError() {
        let errors: [PaywalloError] = [
            ClientError(code: "T", message: "t"),
            IdentityError(code: "T", message: "t"),
            SessionError(code: "T", message: "t"),
            PurchaseError(code: "T", message: "t"),
            PaywallDomainError(code: "T", message: "t"),
            CampaignError(code: "T", message: "t"),
            NotificationsError(code: "T", message: "t"),
            OnboardingError(code: "T", message: "t"),
            PlanError(code: "T", message: "t"),
            AnalyticsError(code: "T", message: "t"),
        ]

        for error in errors {
            XCTAssertTrue(error is PaywalloError)
        }
    }
}
