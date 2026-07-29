import Foundation

public enum CoreAction {
    /// Validated no-op. Maintained for API compatibility.
    public static func execute(_ actionName: String) throws {
        guard !actionName.isEmpty else {
            throw ClientError(code: ClientErrorCode.invalidEventName, message: "Action name cannot be empty")
        }
        // No-op in V2 — maintained for API compatibility
    }
}
