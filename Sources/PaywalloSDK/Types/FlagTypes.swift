import Foundation

public struct FlagVariant: Codable, Sendable {
    public let variant: String?
    public var payload: [String: AnyCodable]?

    public init(variant: String?, payload: [String: AnyCodable]? = nil) {
        self.variant = variant
        self.payload = payload
    }
}

public struct ConditionalFlagResult: Codable, Sendable {
    public let value: Bool
    public let flagKey: String

    public init(value: Bool, flagKey: String) {
        self.value = value
        self.flagKey = flagKey
    }
}

public struct ConditionalFlagContext: Codable, Sendable {
    public var platform: String?
    public var appVersion: String?
    public var country: String?
    public var distinctId: String?

    public init(platform: String? = nil, appVersion: String? = nil, country: String? = nil, distinctId: String? = nil) {
        self.platform = platform
        self.appVersion = appVersion
        self.country = country
        self.distinctId = distinctId
    }
}
