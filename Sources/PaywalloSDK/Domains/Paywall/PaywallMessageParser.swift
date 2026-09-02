import Foundation

public struct PaywallMessage {
    public let type: String
    public var productId: String?
    public var url: String?
    public var timestamp: Double?
    public var variantKey: String?
    /// `payload.style` do `haptic` — já normalizado para `light`/`medium`/`heavy`.
    public var style: String?
    public let messageId: String
}

public enum PaywallMessageParser {
    private static let allowedTypes: Set<String> = [
        "purchase", "close", "restore", "select-product", "open-url", "ready", "haptic"
    ]

    private static let hapticStyles: Set<String> = ["light", "medium", "heavy"]

    public static func parse(_ jsonString: String) -> PaywallMessage? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              allowedTypes.contains(type) else { return nil }

        // Payload fields are nested under the "payload" key, matching the
        // webview wire format: { type, id?, payload?: { productId?, url?, timestamp?, style? } }
        let payload = json["payload"] as? [String: Any]
        let productId = payload?["productId"] as? String
        let url = payload?["url"] as? String
        let timestamp = payload?["timestamp"] as? Double
        let variantKey = payload?["variantKey"] as? String
        // `?? nil` achata o `Any??` do optional chaining — sem isso um payload ausente
        // viraria um `Any` não-nil e todo `close`/`ready` ganharia estilo de haptic.
        let rawStyle: Any? = payload?["style"] ?? nil
        let style = normalizeStyle(rawStyle)

        // Optional top-level id field (prefer over derived id)
        let explicitId = json["id"] as? String

        let messageId = explicitId ?? deriveMessageId(type: type, productId: productId, url: url, timestamp: timestamp)

        return PaywallMessage(
            type: type,
            productId: productId,
            url: url,
            timestamp: timestamp,
            variantKey: variantKey,
            style: style,
            messageId: messageId
        )
    }

    /// Estilo presente mas fora do enum cai em `light` (o webview pediu vibração, e um
    /// valor novo não pode virar silêncio); ausente continua `nil` para o caller usar
    /// o default dele.
    private static func normalizeStyle(_ raw: Any?) -> String? {
        guard let raw = raw else { return nil }
        guard let value = raw as? String, hapticStyles.contains(value) else { return "light" }
        return value
    }

    private static func deriveMessageId(type: String, productId: String?, url: String?, timestamp: Double?) -> String {
        if let productId = productId { return "\(type):\(productId)" }
        if let url = url { return "\(type):\(url)" }
        if let timestamp = timestamp { return "\(type):\(formatTimestamp(timestamp))" }
        return "\(type):"
    }

    /// O timestamp chega como número JS e o RN o interpola sem casa decimal
    /// (`1735689600000`). Interpolar o `Double` do Swift produziria
    /// `1735689600000.0` e as duas plataformas dedupariam com chaves diferentes.
    private static func formatTimestamp(_ timestamp: Double) -> String {
        guard timestamp == timestamp.rounded(), timestamp.magnitude < 9.007199254740992e15 else {
            return "\(timestamp)"
        }
        return "\(Int64(timestamp))"
    }
}
