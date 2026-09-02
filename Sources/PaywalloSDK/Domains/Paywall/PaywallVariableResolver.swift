import Foundation

// MARK: - PaywallVariableResolver

/// Resolves {{variableName}} template variables in paywall content.
/// Supports namespaces: device, user, products (selected/primary/secondary/tertiary).
/// Unknown paths resolve to "" (empty string).
public enum PaywallVariableResolver {

    // MARK: - Public API

    public struct Context {
        public var deviceInfo: [String: String]
        public var userInfo: [String: String]
        public var selectedProduct: Product?
        public var primaryProduct: Product?
        public var secondaryProduct: Product?
        public var tertiaryProduct: Product?
        /// Último fallback antes de `""`: variáveis que o painel define por campanha e
        /// que o SDK não conhece pelo nome.
        public var customVariables: [String: String]

        public init(
            deviceInfo: [String: String] = [:],
            userInfo: [String: String] = [:],
            selectedProduct: Product? = nil,
            primaryProduct: Product? = nil,
            secondaryProduct: Product? = nil,
            tertiaryProduct: Product? = nil,
            customVariables: [String: String] = [:]
        ) {
            self.deviceInfo = deviceInfo
            self.userInfo = userInfo
            self.selectedProduct = selectedProduct
            self.primaryProduct = primaryProduct
            self.secondaryProduct = secondaryProduct
            self.tertiaryProduct = tertiaryProduct
            self.customVariables = customVariables
        }

        /// Todos os produtos que o contexto conhece — base de `products.hasIntroductoryOffer`.
        var allProducts: [Product] {
            [selectedProduct, primaryProduct, secondaryProduct, tertiaryProduct].compactMap { $0 }
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
            return resolveProductsVariable(key, context: context)

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
            return resolveLegacyVariable(path, context: context)
                ?? context.customVariables[path]
                ?? ""
        }
    }

    // MARK: - Namespace Resolvers

    /// Chaves fixas: o namespace é contrato com o editor do painel, não um dump do
    /// dicionário — qualquer outra chave resolve para "" em vez de vazar o que o SDK
    /// tiver coletado.
    private static func resolveDeviceVariable(_ key: String, deviceInfo: [String: String]) -> String {
        switch key {
        case "name", "model", "os", "osVersion", "locale": return deviceInfo[key] ?? ""
        default: return ""
        }
    }

    private static func resolveUserVariable(_ key: String, userInfo: [String: String]) -> String {
        switch key {
        case "id", "name", "email": return userInfo[key] ?? ""
        default: return ""
        }
    }

    private static func resolveProductsVariable(_ key: String, context: Context) -> String {
        // products.hasIntroductoryOffer — flag do conjunto, não de um slot: o craft usa
        // para decidir se mostra o bloco de oferta antes de o usuário escolher o plano.
        if key == "hasIntroductoryOffer" {
            return context.allProducts.contains(where: { $0.introductoryPrice != nil }) ? "true" : "false"
        }

        // products.selected.xxx, products.primary.xxx, products.secondary.xxx, products.tertiary.xxx
        let subParts = key.split(separator: ".", maxSplits: 1).map(String.init)
        guard subParts.count == 2 else { return "" }

        let product: Product?
        switch subParts[0] {
        case "selected":  product = context.selectedProduct
        case "primary":   product = context.primaryProduct
        case "secondary": product = context.secondaryProduct
        case "tertiary":  product = context.tertiaryProduct
        default:          product = nil
        }

        guard let p = product else { return "" }
        return resolveProductProperty(subParts[1], product: p)
    }

    /// Variáveis legadas sem namespace, de craft antigo que continua publicado.
    private static func resolveLegacyVariable(_ name: String, context: Context) -> String? {
        switch name {
        case "device_name":
            return context.deviceInfo["name"] ?? ""
        case "product_price":
            guard let p = context.selectedProduct else { return nil }
            return p.localizedPrice
        case "trial_period":
            guard let p = context.selectedProduct else { return nil }
            return p.freeTrialPeriod ?? ""
        default:
            return nil
        }
    }

    private static func resolveProductProperty(_ prop: String, product: Product) -> String {
        switch prop {
        case "id":                    return product.productId
        case "productId":             return product.productId
        case "name":                  return product.title
        case "title":                 return product.title
        case "description":           return product.description
        // `price` é o preço formatado que o craft renderiza — `product.price` é o valor
        // cru ("9.99"), sem símbolo nem moeda, e vazava assim para a tela.
        case "price":                 return product.localizedPrice
        case "localizedPrice":        return product.localizedPrice
        case "priceValue":            return String(product.priceValue)
        case "currency":              return product.currency
        // Sem preço mensal derivado (produto não-assinatura, período não reconhecido)
        // o craft mostrava vazio no lugar de um preço — cai no preço cheio.
        case "pricePerMonth":         return product.pricePerMonth ?? product.localizedPrice
        case "pricePerWeek":          return product.pricePerWeek ?? ""
        case "pricePerDay":           return product.pricePerDay ?? ""
        case "period":                return product.subscriptionPeriod ?? ""
        case "renewalPeriod":         return product.subscriptionPeriod ?? ""
        case "subscriptionPeriod":    return product.subscriptionPeriod ?? ""
        case "trialPeriod":           return product.freeTrialPeriod ?? ""
        case "freeTrialPeriod":       return product.freeTrialPeriod ?? ""
        case "introPrice":            return product.introductoryPrice ?? ""
        case "introductoryPrice":     return product.introductoryPrice ?? ""
        case "introductoryPriceValue":
            if let v = product.introductoryPriceValue { return String(v) }
            return ""
        case "hasFreeTrial":          return product.freeTrialPeriod != nil ? "true" : "false"
        case "hasIntroOffer":         return product.introductoryPrice != nil ? "true" : "false"
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
