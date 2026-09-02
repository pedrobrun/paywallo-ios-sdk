import Foundation

/// Context resolved once per batch and hoisted out of every individual event of the V2
/// ingest envelope, so a field lives once on the envelope instead of N times in `events[]`.
public struct IngestContext: Codable {
    public var sdkVersion: String?
    public var platform: String?
    public var distinctId: String?
    public var sessionId: String?
    public var deviceId: String?
    public var appVersion: String?
    public var appBuild: String?
    public var bundleId: String?
    public var osVersion: String?
    public var deviceModel: String?
    public var timezone: String?
    public var locale: String?
    public var country: String?
    public var carrier: String?
    public var screenWidth: Double?
    public var screenHeight: Double?
    public var screenDensity: Double?
    public var attribution: [String: AnyCodable]?
    public var ids: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case sdkVersion = "sdk_version"
        case platform
        case distinctId = "distinct_id"
        case sessionId = "session_id"
        case deviceId = "device_id"
        case appVersion = "app_version"
        case appBuild = "app_build"
        case bundleId = "bundle_id"
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case timezone
        case locale
        case country
        case carrier
        case screenWidth = "screen_width"
        case screenHeight = "screen_height"
        case screenDensity = "screen_density"
        case attribution
        case ids
    }

    public init() {}
}

/// One raw event on its way into the envelope.
public struct EventInput {
    public let family: EventFamily
    public let name: String
    public let payload: [String: AnyCodable]
    /// Milliseconds since Unix epoch.
    public let timestamp: TimeInterval
    /// Feeds the `context.distinct_id` fallback when neither the provider nor the payload
    /// carries one — without it an envelope built from a payload-less event fails the
    /// server schema and the whole batch is rejected.
    public let distinctId: String

    public init(
        family: EventFamily,
        name: String,
        payload: [String: AnyCodable] = [:],
        timestamp: TimeInterval = Date().timeIntervalSince1970 * 1000,
        distinctId: String = ""
    ) {
        self.family = family
        self.name = name
        self.payload = payload
        self.timestamp = timestamp
        self.distinctId = distinctId
    }
}

public struct IngestEvent: Codable {
    public let id: String
    public let family: String
    /// Milliseconds since Unix epoch — stored as Int64 so JSONEncoder emits an integer
    /// (not a float like `1715000000000.0`) which the server Zod schema requires (`z.number().int()`).
    public let timestamp: Int64
    public var payload: [String: AnyCodable]
    /// Sibling of `payload`, not nested in it — the server reads `ev.installClassification`.
    public let installClassification: String?

    enum CodingKeys: String, CodingKey {
        case id
        case family = "name"
        case timestamp = "ts"
        case payload
        case installClassification
    }

    public init(
        id: String = UUID().uuidString,
        family: String,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        payload: [String: AnyCodable] = [:],
        installClassification: String? = nil
    ) {
        self.id = id
        self.family = family
        self.timestamp = timestamp
        self.payload = payload
        self.installClassification = installClassification
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

/// A context field plus the payload keys that promote into it. Modelled as closures rather
/// than a `WritableKeyPath<IngestContext, String?>` because the slots are no longer all
/// strings — `screen_*` are numeric and `attribution`/`ids` are objects.
private struct ContextSlot {
    let aliases: [String]
    let isFilled: (IngestContext) -> Bool
    let assign: (inout IngestContext, AnyCodable) -> Void
    /// Promoted to the context AND kept in the event payload.
    let copiedNotMoved: Bool

    static func string(
        _ aliases: [String],
        _ keyPath: WritableKeyPath<IngestContext, String?>,
        copiedNotMoved: Bool = false
    ) -> ContextSlot {
        ContextSlot(
            aliases: aliases,
            isFilled: { $0[keyPath: keyPath] != nil },
            assign: { context, value in
                if let string = value.value as? String { context[keyPath: keyPath] = string }
            },
            copiedNotMoved: copiedNotMoved
        )
    }

    static func number(_ aliases: [String], _ keyPath: WritableKeyPath<IngestContext, Double?>) -> ContextSlot {
        ContextSlot(
            aliases: aliases,
            isFilled: { $0[keyPath: keyPath] != nil },
            assign: { context, value in
                if let double = value.value as? Double { context[keyPath: keyPath] = double }
                else if let int = value.value as? Int { context[keyPath: keyPath] = Double(int) }
            },
            copiedNotMoved: false
        )
    }

    static func dictionary(
        _ aliases: [String],
        _ keyPath: WritableKeyPath<IngestContext, [String: AnyCodable]?>
    ) -> ContextSlot {
        ContextSlot(
            aliases: aliases,
            isFilled: { $0[keyPath: keyPath] != nil },
            assign: { context, value in
                if let dict = value.value as? [String: Any] {
                    context[keyPath: keyPath] = dict.mapValues { AnyCodable($0) }
                } else if let dict = value.value as? [String: AnyCodable] {
                    context[keyPath: keyPath] = dict
                }
            },
            copiedNotMoved: false
        )
    }
}

public enum V2EnvelopeBuilder {

    /// Keys promoted to the shared `context` when they show up in an event payload. Each
    /// promoted key is stripped from the per-event payload so the envelope stays
    /// V2-compliant — no duplication between `context` and `events[i].payload` — except the
    /// `copiedNotMoved` ones, where the payload carries what the CALLER passed and the
    /// context what the DEVICE says.
    ///
    /// `country` needs both sides: in the context it feeds attribution matching (the device
    /// region), in the payload it is the explicit `identify()` trait — the app knows the
    /// user's country better than the handset locale does. While it was move-only,
    /// `identify(id, ["country": "MX"])` vanished on the way and everyone in Mexico with an
    /// English phone was filed as "US".
    ///
    /// `app_build`, `bundle_id`, `carrier` and the `screen_*` keys take the canonical
    /// snake_case alias ONLY: they come from the context provider, never from event
    /// properties. Adding a camelCase alias would promote — and therefore DELETE — the
    /// `screenWidth`/`screenHeight` keys the server still reads from the `$app_installed`
    /// payload.
    private static let contextSlots: [ContextSlot] = [
        .string(["distinct_id", "distinctId"], \.distinctId),
        .string(["session_id", "sessionId"], \.sessionId),
        .string(["device_id", "deviceId"], \.deviceId),
        .string(["app_version", "appVersion"], \.appVersion),
        .string(["app_build"], \.appBuild),
        .string(["bundle_id"], \.bundleId),
        .string(["sdk_version", "sdkVersion"], \.sdkVersion),
        .string(["platform"], \.platform),
        .string(["os_version", "osVersion", "systemVersion"], \.osVersion),
        .string(["device_model", "deviceModel", "model"], \.deviceModel),
        .string(["timezone", "timeZone"], \.timezone),
        .string(["locale"], \.locale),
        .string(["country", "regionCode"], \.country, copiedNotMoved: true),
        .string(["carrier"], \.carrier),
        .number(["screen_width"], \.screenWidth),
        .number(["screen_height"], \.screenHeight),
        .number(["screen_density"], \.screenDensity),
        .dictionary(["attribution"], \.attribution),
        .dictionary(["ids"], \.ids),
    ]

    /// Flat device-ID keys mirrored from event properties into `context.ids`. Unlike
    /// `contextSlots` these are COPIED, not moved, so the server parser that still reads them
    /// from `events[i].payload` (e.g. `$app_installed`) keeps working. Provider values always
    /// win: a key already in `context.ids` is never overwritten.
    private static let idsPromoAliases: [(key: String, aliases: [String])] = [
        ("idfv", ["idfv"]),
        ("gaid", ["gaid"]),
        ("fb_anon_id", ["fbAnonId", "fb_anon_id"]),
        ("idfa", ["idfa"]),
    ]

    /// A payload `installEventId` only becomes the event id when it is a real UUID v4 — the
    /// server dedups the install on that id, and a malformed one would create a second
    /// install instead of collapsing into the first.
    private static let uuidV4Regex = try! NSRegularExpression(
        pattern: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
        options: [.caseInsensitive]
    )

    private static func isValidUUIDv4(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return uuidV4Regex.firstMatch(in: value, range: range) != nil
    }

    /// Build the V2 envelope `{context: {...}, events: [{id, ts, name, payload}]}`.
    public static func build(
        events: [EventInput],
        providerContext: IngestContext? = nil,
        debug: Bool = false
    ) -> IngestEnvelope {
        var context = providerContext ?? IngestContext()

        var ingestEvents: [IngestEvent] = []
        for event in events {
            var payload = event.payload

            for slot in contextSlots {
                for alias in slot.aliases {
                    guard let value = payload[alias] else { continue }
                    if !(value.value is NSNull), !slot.isFilled(context) {
                        slot.assign(&context, value)
                    }
                    if !slot.copiedNotMoved { payload.removeValue(forKey: alias) }
                }
            }

            if event.family == .custom {
                payload["event_name"] = AnyCodable(event.name)
            }

            var id = UUID().uuidString
            if let candidate = payload["installEventId"]?.value as? String, isValidUUIDv4(candidate) {
                id = candidate
                payload.removeValue(forKey: "installEventId")
            }

            var installClassification: String?
            if let candidate = payload["installClassification"]?.value as? String, !candidate.isEmpty {
                installClassification = candidate
                payload.removeValue(forKey: "installClassification")
            }

            ingestEvents.append(IngestEvent(
                id: id,
                family: event.family.rawValue,
                timestamp: Int64(event.timestamp),
                payload: payload,
                installClassification: installClassification
            ))
        }

        // Baseline fields the SDK always knows synchronously. Provider values win so
        // app-specific overrides are honoured.
        if context.sdkVersion == nil { context.sdkVersion = PaywalloConstants.sdkVersion }
        if context.platform == nil { context.platform = PaywalloConstants.sdkPlatform }
        if context.distinctId == nil, let first = events.first, !first.distinctId.isEmpty {
            context.distinctId = first.distinctId
        }
        if debug, context.distinctId?.isEmpty != false {
            // Never log the raw context — it carries device IDs (idfa/gaid/idfv) and
            // attribution (PII). Metadata only.
            print("[Paywallo:ENVELOPE] distinct_id is empty after resolution — envelope will fail schema",
                  ["eventCount": events.count,
                   "firstEventName": events.first?.name ?? "",
                   "contextKeys": contextKeys(providerContext)] as [String: Any])
        }

        // Mirror device IDs into `context.ids` so every envelope has one canonical location
        // for them, without breaking the parsers that still read them from the payload.
        var idsFromProps: [String: AnyCodable] = [:]
        let existingIds = context.ids
        for event in events {
            for promo in idsPromoAliases {
                if existingIds?[promo.key] != nil { continue }
                if idsFromProps[promo.key] != nil { continue }
                for alias in promo.aliases {
                    if let value = event.payload[alias]?.value as? String, !value.isEmpty {
                        idsFromProps[promo.key] = AnyCodable(value)
                        break
                    }
                }
            }
        }
        if !idsFromProps.isEmpty {
            var merged = idsFromProps
            for (key, value) in context.ids ?? [:] { merged[key] = value }
            context.ids = merged
        }

        return IngestEnvelope(context: context, events: ingestEvents)
    }

    /// Key names only — used by the debug log above, which must never print values.
    private static func contextKeys(_ context: IngestContext?) -> [String] {
        guard let context = context,
              let data = try? JSONEncoder().encode(context),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return object.keys.sorted()
    }
}
