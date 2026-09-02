import Foundation

public enum EventFamily: String, Codable, Sendable {
    case lifecycle
    case identify
    case paywall
    case transaction
    case onboarding
    case notification
    case custom
}

public enum LifecycleType: String, Codable, Sendable {
    case install, coldStart = "cold_start", foreground, background, sessionStart = "session_start", sessionEnd = "session_end"
}

public enum PaywallEventType: String, Codable, Sendable {
    case viewed, closed, purchased
}

public enum TransactionType: String, Codable, Sendable {
    case completed, failed, refunded, renewed, canceled, expired
    case trialStarted = "trial_started"
}

public enum NotificationType: String, Codable, Sendable {
    case delivered  = "delivered"
    case displayed  = "displayed"
    case clicked    = "clicked"
    case dismissed  = "dismissed"
}

public enum OnboardingType: String, Codable, Sendable {
    case step, complete
}

public enum CloseReason: String, Codable, Sendable {
    case dismiss, cta, purchase, error, timeout
}

public enum EventFamilies {

    /// Deprecated event names — silently dropped in V2
    public static let deprecatedEventNames: Set<String> = [
        "$paywall_purchased",
        "$paywall_product_selected",
        "$core_action",
        "$campaign_impression",
        "$app_open",
        "$app_background",
        "$app_foreground",
        "session.end",
    ]

    /// Event name validation regex
    private static let eventNameRegex = try! NSRegularExpression(
        pattern: #"^(\$[a-zA-Z0-9_]+|[a-z][a-z0-9_]*)$"#
    )

    /// Check if event name is deprecated
    public static func isDeprecated(_ eventName: String) -> Bool {
        deprecatedEventNames.contains(eventName)
    }

    /// Detect family from event name
    public static func detectFamily(_ eventName: String) -> EventFamily {
        switch eventName {
        case "lifecycle": return .lifecycle
        case "identify": return .identify
        case "paywall": return .paywall
        case "transaction": return .transaction
        case "onboarding": return .onboarding
        case "notification": return .notification
        default: return .custom
        }
    }

    /// Validate event name format
    public static func isValidEventName(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        return eventNameRegex.firstMatch(in: name, range: range) != nil
    }

    /// Validate event properties against family schema (warn-only)
    ///
    /// Light manual shape check, not a mirror of the server's strict schema. It exists to
    /// give a clear debug-build signal when the integrator sends something obviously wrong
    /// (missing id, unknown type). The real validation runs server-side, and the event flows
    /// either way so production analytics never go silent.
    public static func validateEvent(
        eventName: String,
        properties: [String: Any]?,
        debug: Bool = false
    ) -> (ok: Bool, family: EventFamily) {
        let family = detectFamily(eventName)
        let props = properties ?? [:]

        // Required identifiers, checked even when the payload is empty: these are the fields
        // whose absence makes the server reject the whole envelope.
        switch family {
        case .identify:
            let distinctId = props["distinct_id"] as? String
            if distinctId?.isEmpty != false {
                if debug { print("[Paywallo:Events] identify requires a non-empty \"distinct_id\"") }
                return (false, family)
            }
        case .paywall:
            let paywallId = props["paywall_id"] as? String
            if paywallId?.isEmpty != false {
                if debug { print("[Paywallo:Events] paywall requires a non-empty \"paywall_id\"") }
                return (false, family)
            }
        case .transaction:
            if props["transaction_id"] as? String == nil, props["tx_id"] as? String == nil {
                if debug { print("[Paywallo:Events] transaction requires \"transaction_id\" (or legacy \"tx_id\")") }
                return (false, family)
            }
        case .lifecycle, .onboarding, .notification, .custom:
            break
        }

        // For canonical families, check that 'type' field matches allowed values
        switch family {
        case .lifecycle:
            if let type = props["type"] as? String {
                let valid = LifecycleType(rawValue: type) != nil
                if !valid && debug {
                    print("[Paywallo:Events] Invalid lifecycle type: \(type)")
                }
                return (valid, family)
            }
        case .paywall:
            if let type = props["type"] as? String {
                let valid = PaywallEventType(rawValue: type) != nil
                if !valid && debug {
                    print("[Paywallo:Events] Invalid paywall type: \(type)")
                }
                return (valid, family)
            }
        case .transaction:
            if let type = props["type"] as? String {
                let valid = TransactionType(rawValue: type) != nil
                if !valid && debug {
                    print("[Paywallo:Events] Invalid transaction type: \(type)")
                }
                return (valid, family)
            }
            if let currency = props["currency"] as? String, currency.count != 3 {
                if debug { print("[Paywallo:Events] Currency must be exactly 3 chars") }
                return (false, family)
            }
        case .notification:
            if let type = props["type"] as? String {
                let valid = NotificationType(rawValue: type) != nil
                if !valid && debug {
                    print("[Paywallo:Events] Invalid notification type: \(type)")
                }
                return (valid, family)
            }
        case .onboarding:
            if let type = props["type"] as? String {
                let valid = OnboardingType(rawValue: type) != nil
                if !valid && debug {
                    print("[Paywallo:Events] Invalid onboarding type: \(type)")
                }
                return (valid, family)
            }
        case .identify, .custom:
            break  // No strict validation for these
        }

        return (true, family)
    }
}
