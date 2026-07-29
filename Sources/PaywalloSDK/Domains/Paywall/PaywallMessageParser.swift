import Foundation

public struct PaywallMessage {
    public let type: String
    public var productId: String?
    public var url: String?
    public var timestamp: Double?
    public var variantKey: String?
    public let messageId: String
}

public enum PaywallMessageParser {
    private static let allowedTypes: Set<String> = [
        "purchase", "close", "restore", "select-product", "open-url", "ready", "haptic"
    ]

    public static func parse(_ jsonString: String) -> PaywallMessage? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              allowedTypes.contains(type) else { return nil }

        // Payload fields are nested under the "payload" key, matching the
        // webview wire format: { type, id?, payload?: { productId?, url?, timestamp? } }
        let payload = json["payload"] as? [String: Any]
        let productId = payload?["productId"] as? String
        let url = payload?["url"] as? String
        let timestamp = payload?["timestamp"] as? Double
        let variantKey = payload?["variantKey"] as? String

        // Optional top-level id field (prefer over derived id)
        let explicitId = json["id"] as? String

        let messageId = explicitId ?? deriveMessageId(type: type, productId: productId, url: url, timestamp: timestamp)

        return PaywallMessage(
            type: type,
            productId: productId,
            url: url,
            timestamp: timestamp,
            variantKey: variantKey,
            messageId: messageId
        )
    }

    private static func deriveMessageId(type: String, productId: String?, url: String?, timestamp: Double?) -> String {
        if let productId = productId { return "\(type):\(productId)" }
        if let url = url { return "\(type):\(url)" }
        if let timestamp = timestamp { return "\(type):\(timestamp)" }
        return "\(type):"
    }
}
