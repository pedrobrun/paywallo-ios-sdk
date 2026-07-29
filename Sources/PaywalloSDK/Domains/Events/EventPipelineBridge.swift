import Foundation

public enum EventPipelineBridge {

    /// Serialize event properties for the V2 pipeline.
    /// - Primitives (String, Int, Double, Bool) pass through as-is
    /// - null/nil values pass through
    /// - Complex types (Dict, Array) are serialized to JSON strings
    public static func serializeProperties(_ properties: [String: Any]?) -> [String: AnyCodable]? {
        guard let properties = properties else { return nil }

        var result: [String: AnyCodable] = [:]

        for (key, value) in properties {
            if value is NSNull {
                result[key] = AnyCodable(NSNull())
            } else if let str = value as? String {
                result[key] = AnyCodable(str)
            } else if let num = value as? Int {
                result[key] = AnyCodable(num)
            } else if let num = value as? Double {
                result[key] = AnyCodable(num)
            } else if let bool = value as? Bool {
                result[key] = AnyCodable(bool)
            } else {
                // Complex type → serialize to JSON string
                if let jsonData = try? JSONSerialization.data(withJSONObject: value),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    result[key] = AnyCodable(jsonString)
                }
            }
        }

        return result.isEmpty ? nil : result
    }

    /// Convert AnyCodable properties, serializing complex values
    public static func serializeCodableProperties(_ properties: [String: AnyCodable]?) -> [String: AnyCodable]? {
        guard let properties = properties else { return nil }

        var result: [String: AnyCodable] = [:]

        for (key, value) in properties {
            switch value.value {
            case is NSNull:
                result[key] = value
            case is String, is Int, is Double, is Bool:
                result[key] = value
            default:
                // Complex type → serialize to JSON string
                if let jsonData = try? JSONSerialization.data(withJSONObject: value.value),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    result[key] = AnyCodable(jsonString)
                } else {
                    result[key] = value  // fallback: pass through
                }
            }
        }

        return result.isEmpty ? nil : result
    }
}
