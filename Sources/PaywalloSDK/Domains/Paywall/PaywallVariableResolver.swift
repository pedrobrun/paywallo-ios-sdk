import Foundation

// MARK: - PaywallVariableResolver

/// Resolves {{variableName}} template variables in paywall content.
/// Supports namespaces: device, user, products (selected/primary/secondary).
/// Unknown paths resolve to "" (empty string).
public enum PaywallVariableResolver {

    // MARK: - Public API

    public struct Context {
        public var deviceInfo: [String: String]
        public var userInfo: [String: String]
        public var selectedProduct: Product?
        public var primaryProduct: Product?
        public var secondaryProduct: Product?

        public init(
            deviceInfo: [String: String] = [:],
            userInfo: [String: String] = [:],
            selectedProduct: Product? = nil,
            primaryProduct: Product? = nil,
            secondaryProduct: Product? = nil
        ) {
            self.deviceInfo = deviceInfo
            self.userInfo = userInfo
            self.selectedProduct = selectedProduct
            self.primaryProduct = primaryProduct
            self.secondaryProduct = secondaryProduct
        }
    }

    private static let templateRegex = try! NSRegularExpression(pattern: #"\{\{([^}]+)\}\}"#)

    /// Resolve all {{...}} variables in the given template string.
    public static func resolve(_ template: String, context: Context) -> String {
        let nsTemplate = template as NSString
        let range = NSRange(location: 0, length: nsTemplate.length)
        let matches = templateRegex.matches(in: template, range: range)

        guard !matches.isEmpty else { return template }

        var result = template
        // Process in reverse order so replacements don't shift indices
        for match in matches.reversed() {
            let fullRange = match.range
            let varRange = match.range(at: 1)
            guard varRange.location != NSNotFound else { continue }

            let varName = nsTemplate.substring(with: varRange).trimmingCharacters(in: .whitespaces)
            let value = resolveVariable(varName, context: context)

            if let swiftRange = Range(fullRange, in: result) {
                result = result.replacingCharacters(in: swiftRange, with: value)
            }
        }

        return result
    }

    // MARK: - Variable Resolution

    private static func resolveVariable(_ path: String, context: Context) -> String {
        let parts = path.split(separator: ".", maxSplits: 1).map(String.init)

        guard !parts.isEmpty else { return "" }

        let namespace = parts[0]
        let key = parts.count > 1 ? parts[1] : ""

        switch namespace {
        case "device":
            return resolveDeviceVariable(key, deviceInfo: context.deviceInfo)

        case "user":
            return resolveUserVariable(key, userInfo: context.userInfo)

        case "products":
            // products.selected.xxx, products.primary.xxx, products.secondary.xxx
            let subParts = key.split(separator: ".", maxSplits: 1).map(String.init)
            guard subParts.count == 2 else { return "" }

            let slot = subParts[0]
            let prop = subParts[1]

            let product: Product?
            switch slot {
            case "selected": product = context.selectedProduct
            case "primary":  product = context.primaryProduct
            case "secondary": product = context.secondaryProduct
            default:         product = nil
            }

            guard let p = product else { return "" }
            return resolveProductProperty(prop, product: p)

        // Legacy aliases: directly reference product without namespace
        case "selectedProduct":
            guard let p = context.selectedProduct else { return "" }
            return resolveProductProperty(key, product: p)

        case "primaryProduct":
            guard let p = context.primaryProduct else { return "" }
            return resolveProductProperty(key, product: p)

        case "secondaryProduct":
            guard let p = context.secondaryProduct else { return "" }
            return resolveProductProperty(key, product: p)

        default:
            return ""
        }
    }

    // MARK: - Namespace Resolvers

    private static func resolveDeviceVariable(_ key: String, deviceInfo: [String: String]) -> String {
        deviceInfo[key] ?? ""
    }

    private static func resolveUserVariable(_ key: String, userInfo: [String: String]) -> String {
        userInfo[key] ?? ""
    }

    private static func resolveProductProperty(_ prop: String, product: Product) -> String {
        switch prop {
        case "id":                    return product.productId
        case "productId":             return product.productId
        case "name":                  return product.title
        case "title":                 return product.title
        case "description":           return product.description
        case "price":                 return product.price
        case "localizedPrice":        return product.localizedPrice
        case "priceValue":            return String(product.priceValue)
        case "currency":              return product.currency
        case "pricePerMonth":         return product.pricePerMonth ?? ""
        case "pricePerWeek":          return product.pricePerWeek ?? ""
        case "pricePerDay":           return product.pricePerDay ?? ""
        case "subscriptionPeriod":    return product.subscriptionPeriod ?? ""
        case "introductoryPrice":     return product.introductoryPrice ?? ""
        case "introductoryPriceValue":
            if let v = product.introductoryPriceValue { return String(v) }
            return ""
        case "freeTrialPeriod":       return product.freeTrialPeriod ?? ""
        case "trialDays":
            if let d = product.trialDays { return String(d) }
            return ""
        case "savings":               return product.savings ?? ""
        case "savingsPercent":        return product.savingsPercent ?? ""
        case "type":                  return product.type.rawValue
        default:                      return ""
        }
    }
}
