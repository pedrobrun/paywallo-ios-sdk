import Foundation

public struct IngestContext: Codable {
    public var sdkVersion: String?
    public var platform: String?
    public var distinctId: String?
    public var sessionId: String?
    public var deviceId: String?
    public var appVersion: String?
    public var osVersion: String?
    public var deviceModel: String?
    public var timezone: String?
    public var locale: String?
    public var attribution: [String: AnyCodable]?
    public var ids: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case sdkVersion = "sdk_version"
        case platform
        case distinctId = "distinct_id"
        case sessionId = "session_id"
        case deviceId = "device_id"
        case appVersion = "app_version"
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case timezone
        case locale
        case attribution
        case ids
    }

    public init() {}
}

public struct IngestEvent: Codable {
    public let id: String
    public let family: String
    /// Milliseconds since Unix epoch — stored as Int64 so JSONEncoder emits an integer
    /// (not a float like `1715000000000.0`) which the server Zod schema requires (`z.number().int()`).
    public let timestamp: Int64
    public var payload: [String: AnyCodable]

    enum CodingKeys: String, CodingKey {
        case id
        case family = "name"
        case timestamp = "ts"
        case payload
    }

    public init(
        id: String = UUID().uuidString,
        family: String,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        payload: [String: AnyCodable] = [:]
    ) {
        self.id = id
        self.family = family
        self.timestamp = timestamp
        self.payload = payload
    }
}

public struct IngestEnvelope: Codable {
    public let context: IngestContext
    public let events: [IngestEvent]

    public init(context: IngestContext, events: [IngestEvent]) {
        self.context = context
        self.events = events
    }
}

/// Aliases for context key promotion (camelCase → snake_case variants)
private let contextAliases: [String: WritableKeyPath<IngestContext, String?>] = [
    "distinct_id": \.distinctId,
    "distinctId": \.distinctId,
    "session_id": \.sessionId,
    "sessionId": \.sessionId,
    "device_id": \.deviceId,
    "deviceId": \.deviceId,
    "app_version": \.appVersion,
    "appVersion": \.appVersion,
    "sdk_version": \.sdkVersion,
    "sdkVersion": \.sdkVersion,
    "os_version": \.osVersion,
    "osVersion": \.osVersion,
    "systemVersion": \.osVersion,
    "device_model": \.deviceModel,
    "deviceModel": \.deviceModel,
    "model": \.deviceModel,
    "timezone": \.timezone,
    "timeZone": \.timezone,
    "locale": \.locale,
    "platform": \.platform,
]

public enum V2EnvelopeBuilder {

    /// Build a V2 ingest envelope from raw events.
    /// - Parameters:
    ///   - events: Raw event data (family, name, payload, timestamp)
    ///   - providerContext: Context from the event context provider (attribution, ads, device)
    public static func build(
        events: [(family: EventFamily, name: String, payload: [String: AnyCodable], timestamp: TimeInterval)],
        providerContext: IngestContext? = nil
    ) -> IngestEnvelope {
        var context = providerContext ?? IngestContext()

        // Set baseline fields
        if context.sdkVersion == nil {
            context.sdkVersion = PaywalloConstants.sdkVersion
        }
        if context.platform == nil {
            context.platform = PaywalloConstants.sdkPlatform
        }

        var ingestEvents: [IngestEvent] = []

        for event in events {
            var payload = event.payload

            // Promote known keys from payload to context (provider context wins)
            for (key, keyPath) in contextAliases {
                if let value = payload[key]?.value as? String {
                    // Only promote if context slot is empty (provider wins)
                    if context[keyPath: keyPath] == nil {
                        context[keyPath: keyPath] = value
                    }
                    payload.removeValue(forKey: key)
                }
            }

            // Handle attribution dict in payload
            if let attribution = payload["attribution"] {
                if context.attribution == nil {
                    if let dict = attribution.value as? [String: Any] {
                        context.attribution = dict.mapValues { AnyCodable($0) }
                    }
                }
                payload.removeValue(forKey: "attribution")
            }

            // Handle ids dict in payload
            if let ids = payload["ids"] {
                if context.ids == nil {
                    if let dict = ids.value as? [String: Any] {
                        context.ids = dict.mapValues { AnyCodable($0) }
                    }
                }
                payload.removeValue(forKey: "ids")
            }

            // For custom events, inject event_name
            if event.family == .custom {
                payload["event_name"] = AnyCodable(event.name)
            }

            let ingestEvent = IngestEvent(
                family: event.family.rawValue,
                timestamp: Int64(event.timestamp),
                payload: payload
            )
            ingestEvents.append(ingestEvent)
        }

        // Fallback: distinct_id from first event if provider didn't set
        if context.distinctId == nil, let firstEvent = events.first {
            if let distinctId = firstEvent.payload["distinct_id"]?.value as? String {
                context.distinctId = distinctId
            } else if let distinctId = firstEvent.payload["distinctId"]?.value as? String {
                context.distinctId = distinctId
            }
        }

        return IngestEnvelope(context: context, events: ingestEvents)
    }
}
