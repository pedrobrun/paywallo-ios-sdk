import Foundation

open class PaywalloError: Error, CustomStringConvertible {
    public let code: String
    public let domain: String
    public let message: String

    public init(domain: String, code: String, message: String) {
        self.domain = domain
        self.code = code
        self.message = message
    }

    public var description: String {
        "[\(domain)] \(code): \(message)"
    }

    public var localizedDescription: String {
        message
    }
}
