import Foundation

// MARK: - ProductFormatter

public enum ProductFormatter {

    // MARK: - Period to Days

    /// Converts ISO 8601 duration period strings to number of days.
    /// P1D → 1, P1W → 7, P1M → 30, P1Y → 365
    public static func periodToDays(_ period: String) -> Int? {
        let p = period.uppercased()

        // Match patterns: P{n}D, P{n}W, P{n}M, P{n}Y
        let patterns: [(suffix: String, multiplier: Int)] = [
            ("D", 1),
            ("W", 7),
            ("M", 30),
            ("Y", 365),
        ]

        for (suffix, multiplier) in patterns {
            // e.g. P1M, P3M, P12M
            let prefix = "P"
            if p.hasPrefix(prefix) && p.hasSuffix(suffix) {
                let numberPart = p.dropFirst(prefix.count).dropLast(suffix.count)
                if let n = Int(numberPart) {
                    return n * multiplier
                }
            }
        }

        return nil
    }

    // MARK: - Per-Period Price Calculations

    /// Calculates per-period prices (monthly and weekly) from a daily price.
    /// Returns (pricePerMonth, pricePerWeek, pricePerDay)
    public static func calculatePerPeriodPrices(priceValue: Double, period: String, currency: String) -> (pricePerMonth: String?, pricePerWeek: String?, pricePerDay: String?) {
        guard let days = periodToDays(period), days > 0 else {
            return (nil, nil, nil)
        }

        let dailyPrice = priceValue / Double(days)

        let monthlyPrice = dailyPrice * 30.0
        let weeklyPrice = dailyPrice * 7.0

        let pricePerDay = formatCurrency(dailyPrice, currency: currency)
        let pricePerMonth: String?
        let pricePerWeek: String?

        // Only compute monthly if period is not already monthly
        let upperPeriod = period.uppercased()
        if upperPeriod == "P1M" || upperPeriod == "P30D" {
            pricePerMonth = formatCurrency(priceValue, currency: currency)
        } else {
            pricePerMonth = formatCurrency(monthlyPrice, currency: currency)
        }

        if upperPeriod == "P1W" || upperPeriod == "P7D" {
            pricePerWeek = formatCurrency(priceValue, currency: currency)
        } else {
            pricePerWeek = formatCurrency(weeklyPrice, currency: currency)
        }

        return (pricePerMonth, pricePerWeek, pricePerDay)
    }

    // MARK: - Product Type Mapping

    /// Maps StoreKit / server product type strings to PaywalloSDK ProductType.
    public static func mapProductType(_ rawType: String) -> ProductType {
        switch rawType.lowercased() {
        case "subscription", "autorenewable", "auto_renewable", "autorenewablesubscription":
            return .subscription
        case "consumable":
            return .consumable
        case "nonconsumable", "non_consumable", "nonrenewingsubscription", "non_renewing", "nonrenewable":
            return .nonConsumable
        default:
            return .subscription
        }
    }

    // MARK: - Trial Days Formatting

    /// Formats trial days count with locale-aware label.
    /// - For pt* locales: "X dias"
    /// - For all others: "X days"
    public static func formatTrialDays(_ days: Int, locale: Locale = .current) -> String {
        let languageCode: String
        if #available(iOS 16.0, macOS 13.0, *) {
            languageCode = locale.language.languageCode?.identifier ?? locale.languageCode ?? ""
        } else {
            languageCode = locale.languageCode ?? ""
        }
        if languageCode.lowercased().hasPrefix("pt") {
            return "\(days) dias"
        }
        return "\(days) days"
    }

    // MARK: - Server Product BRL Fallback

    /// Builds a Product from ServerProductInfo when StoreKit is unavailable,
    /// using BRL formatting as the fallback currency.
    public static func buildFromServerProduct(_ serverProduct: ServerProductInfo, locale: Locale = .current) -> Product {
        let priceValue = serverProduct.price ?? 0.0
        let currency = "BRL"
        let formattedPrice = formatCurrency(priceValue, currency: currency)

        var subscriptionPeriod: String? = serverProduct.billingPeriod
        var trialDays: Int? = serverProduct.trialDays

        var pricePerMonth: String?
        var pricePerWeek: String?
        var pricePerDay: String?

        if let period = serverProduct.billingPeriod {
            let prices = calculatePerPeriodPrices(priceValue: priceValue, period: period, currency: currency)
            pricePerMonth = prices.pricePerMonth
            pricePerWeek = prices.pricePerWeek
            pricePerDay = prices.pricePerDay
        }

        let trialLabel: String?
        if let days = trialDays {
            trialLabel = formatTrialDays(days, locale: locale)
        } else {
            trialLabel = nil
        }

        return Product(
            productId: serverProduct.storeProductId,
            title: serverProduct.name,
            description: "",
            price: formattedPrice,
            priceValue: priceValue,
            currency: currency,
            localizedPrice: formattedPrice,
            type: .subscription,
            subscriptionPeriod: subscriptionPeriod,
            freeTrialPeriod: trialLabel,
            trialDays: trialDays,
            pricePerMonth: pricePerMonth,
            pricePerWeek: pricePerWeek,
            pricePerDay: pricePerDay
        )
    }

    // MARK: - Private Helpers

    private static func formatCurrency(_ value: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}
