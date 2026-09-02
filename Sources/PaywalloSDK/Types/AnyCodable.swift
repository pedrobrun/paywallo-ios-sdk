import Foundation

public struct AnyCodable: Codable, Equatable, Hashable, @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        // Unwrap a nested box first. `[String: AnyCodable]` casts happily to `[String: Any]`,
        // so a dictionary of boxes used to re-wrap into AnyCodable(AnyCodable(...)); the inner
        // box matched no case below and hit `default`. Because a throw here aborts the WHOLE
        // envelope, one nested box silently dropped an entire event batch (e.g. every field of
        // $app_installed, not just the offending one).
        if let nested = value as? AnyCodable {
            try container.encode(nested)
            return
        }

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let string as String:
            try container.encode(string)
        // Every fixed-width integer type, not just `Int`: `as? Int` does NOT numerically
        // convert in Swift, so a UInt64 (DeviceInfo's totalDisk/totalRam) fell through to the
        // throw. Values beyond Int's range degrade to Double rather than aborting the batch.
        case let int as Int:
            try container.encode(int)
        case let int as Int64:
            try container.encode(int)
        case let int as Int32:
            try container.encode(Int(int))
        case let int as Int16:
            try container.encode(Int(int))
        case let int as Int8:
            try container.encode(Int(int))
        case let uint as UInt:
            if uint <= UInt(Int.max) { try container.encode(Int(uint)) } else { try container.encode(Double(uint)) }
        case let uint as UInt64:
            if uint <= UInt64(Int.max) { try container.encode(Int(uint)) } else { try container.encode(Double(uint)) }
        case let uint as UInt32:
            try container.encode(Int(uint))
        case let uint as UInt16:
            try container.encode(Int(uint))
        case let uint as UInt8:
            try container.encode(Int(uint))
        case let double as Double:
            try container.encode(double)
        case let float as Float:
            try container.encode(Double(float))
        case let number as NSNumber:
            try container.encode(number.doubleValue)
        case let date as Date:
            try container.encode(ISO8601DateFormatter().string(from: date))
        case let url as URL:
            try container.encode(url.absoluteString)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            // A boxed `Optional.none` matches none of the cases above (it is not NSNull).
            // Encoding it as null keeps the surrounding event intact — an absent field is a
            // far better outcome than a dropped batch.
            if isNilOptional(value) {
                try container.encodeNil()
                return
            }
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported type"))
        }
    }

    /// True for a `nil` wrapped in `Any` (`Optional<T>.none`), which no `as?` cast catches.
    private func isNilOptional(_ value: Any) -> Bool {
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional && mirror.children.isEmpty
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case is (NSNull, NSNull): return true
        case let (l as Bool, r as Bool): return l == r
        case let (l as Int, r as Int): return l == r
        case let (l as Double, r as Double): return l == r
        case let (l as String, r as String): return l == r
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch value {
        case is NSNull: hasher.combine(0)
        case let bool as Bool: hasher.combine(bool)
        case let int as Int: hasher.combine(int)
        case let double as Double: hasher.combine(double)
        case let string as String: hasher.combine(string)
        default: hasher.combine(1)
        }
    }
}
