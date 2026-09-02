import Foundation

public enum Gender: String, Codable, Sendable {
    case male = "m"
    case female = "f"
}

public struct IdentifyOptions: Codable, Sendable {
    public var email: String?
    public var properties: [String: AnyCodable]?
    public var phone: String?
    public var firstName: String?
    public var lastName: String?
    public var dateOfBirth: String?  // YYYY-MM-DD
    public var gender: Gender?
    /// CEP. Enviado top-level no body do identify (não dentro de `traits`), com trim,
    /// e omitido quando vazio. Alimenta o matching do CAPI.
    public var zipCode: String?

    public init(
        email: String? = nil,
        properties: [String: AnyCodable]? = nil,
        phone: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        dateOfBirth: String? = nil,
        gender: Gender? = nil,
        zipCode: String? = nil
    ) {
        self.email = email
        self.properties = properties
        self.phone = phone
        self.firstName = firstName
        self.lastName = lastName
        self.dateOfBirth = dateOfBirth
        self.gender = gender
        self.zipCode = zipCode
    }
}

public struct TrackEventOptions: Sendable {
    public var properties: [String: AnyCodable]?
    public var timestamp: TimeInterval?
    public var priority: EventPriority?

    public init(
        properties: [String: AnyCodable]? = nil,
        timestamp: TimeInterval? = nil,
        priority: EventPriority? = nil
    ) {
        self.properties = properties
        self.timestamp = timestamp
        self.priority = priority
    }
}

public enum EventPriority: String, Codable, Sendable {
    case critical
    case normal
}
