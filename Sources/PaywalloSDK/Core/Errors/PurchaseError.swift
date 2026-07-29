import Foundation

public final class PurchaseError: PaywalloError {
    public let userCancelled: Bool
    public let httpStatus: Int?

    public init(code: String, message: String, userCancelled: Bool = false, httpStatus: Int? = nil) {
        self.userCancelled = userCancelled
        self.httpStatus = httpStatus
        super.init(domain: "purchase", code: code, message: message)
    }
}

public enum PurchaseErrorCode {
    public static let notInitialized = "PURCHASE_NOT_INITIALIZED"
    public static let productNotFound = "PRODUCT_NOT_FOUND"
    public static let purchaseFailed = "PURCHASE_FAILED"
    public static let restoreFailed = "RESTORE_FAILED"
    public static let validationFailed = "VALIDATION_FAILED"
    public static let userCancelled = "USER_CANCELLED"
    public static let networkError = "PURCHASE_NETWORK_ERROR"
    public static let storeError = "PURCHASE_STORE_ERROR"
    public static let pendingPurchase = "PURCHASE_PENDING"
    public static let deferredPurchase = "PURCHASE_DEFERRED"
    public static let storeNotAvailable = "PURCHASE_STORE_NOT_AVAILABLE"
}

public enum PurchaseErrorFactory {
    private static let defaultMessages: [String: String] = [
        PurchaseErrorCode.notInitialized: "Purchase controller not initialized. Call init() first.",
        PurchaseErrorCode.productNotFound: "Product not found in store.",
        PurchaseErrorCode.purchaseFailed: "Purchase failed. Please try again.",
        PurchaseErrorCode.restoreFailed: "Failed to restore purchases. Please try again.",
        PurchaseErrorCode.validationFailed: "Failed to validate purchase with server.",
        PurchaseErrorCode.userCancelled: "Purchase was cancelled.",
        PurchaseErrorCode.networkError: "Network error. Please check your connection.",
        PurchaseErrorCode.storeError: "Store error. Please try again later.",
        PurchaseErrorCode.pendingPurchase: "Purchase is pending approval.",
        PurchaseErrorCode.deferredPurchase: "Purchase is deferred (e.g., parental approval required).",
        PurchaseErrorCode.storeNotAvailable: "In-app purchases are not available on this device.",
    ]

    public static func create(_ code: String, message: String? = nil) -> PurchaseError {
        let msg = message ?? defaultMessages[code] ?? "Unknown purchase error"
        let cancelled = code == PurchaseErrorCode.userCancelled
        return PurchaseError(code: code, message: msg, userCancelled: cancelled)
    }
}
