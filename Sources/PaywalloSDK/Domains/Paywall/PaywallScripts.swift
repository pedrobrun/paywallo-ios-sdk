import Foundation

// MARK: - PaywallScripts

/// Generates JavaScript snippets injected into WKWebView for the paywall JS bridge.
public enum PaywallScripts {

    // MARK: - Bridge Injection

    /// Builds the JS that installs window.ReactNativeWebView and polls for window.receiveNativeMessage.
    /// Polls at 100ms intervals, up to 50 attempts (5 seconds total).
    public static func buildPaywallInjectionScript() -> String {
        return """
        (function() {
            'use strict';

            // Install the ReactNativeWebView bridge shim
            if (!window.ReactNativeWebView) {
                window.ReactNativeWebView = {
                    postMessage: function(data) {
                        window.webkit.messageHandlers.paywallo.postMessage(data);
                    }
                };
            }

            // Poll for window.receiveNativeMessage up to 50 times at 100ms intervals
            var attempts = 0;
            var maxAttempts = 50;
            var pollInterval = 100;

            function pollForReceiver() {
                attempts++;
                if (typeof window.receiveNativeMessage === 'function') {
                    // Bridge is ready — nothing more to do
                    return;
                }
                if (attempts < maxAttempts) {
                    setTimeout(pollForReceiver, pollInterval);
                }
            }

            pollForReceiver();
        })();
        """
    }

    // MARK: - Paywall Data

    /// Builds the JS that sends paywall data to the web app.
    /// Mirrors the RN SDK wire format:
    ///   `{ type: "paywall", data: { craftData, products, primaryProductId,
    ///      secondaryProductId, tertiaryProductId, currentLanguage, defaultLanguage } }`
    /// Polls for `window.receiveNativeMessage` up to 50 times at 100 ms intervals,
    /// identical to the RN SDK polling pattern.
    ///
    /// `currentLanguage`/`defaultLanguage` são lidos aqui e não recebidos por parâmetro,
    /// igual ao RN: o renderer web resolve as strings localizadas do craft com eles, e
    /// deixar isso a cargo do caller já deu paywall renderizado no idioma errado.
    /// - Parameters:
    ///   - craftData: Serialized craft/config JSON string for the paywall renderer.
    ///   - products: Array of `Product` values — encoded to JSON via `JSONEncoder`.
    ///   - primaryProductId: Optional primary product identifier.
    ///   - secondaryProductId: Optional secondary product identifier.
    ///   - tertiaryProductId: Optional tertiary product identifier.
    public static func buildPaywallDataScript(
        craftData: String,
        products: [Product],
        primaryProductId: String?,
        secondaryProductId: String?,
        tertiaryProductId: String? = nil
    ) -> String {
        let productsJSON = encodeProductsJSON(products)
        let primaryJSON = jsString(primaryProductId)
        let secondaryJSON = jsString(secondaryProductId)
        let tertiaryJSON = jsString(tertiaryProductId)
        let currentLanguageJSON = jsString(Localization.shared.getCurrentLanguage())
        let defaultLanguageJSON = jsString(Localization.defaultLanguage)
        let escapedCraftData = craftData.jsEscaped

        return "(function(){" +
            "var d={type:\"paywall\",data:{craftData:\"\(escapedCraftData)\"," +
            "products:\(productsJSON)," +
            "primaryProductId:\(primaryJSON)," +
            "secondaryProductId:\(secondaryJSON)," +
            "tertiaryProductId:\(tertiaryJSON)," +
            "currentLanguage:\(currentLanguageJSON)," +
            "defaultLanguage:\(defaultLanguageJSON)}};" +
            "var a=0,m=50;" +
            "function t(){a++;if(typeof window.receiveNativeMessage===\"function\"){window.receiveNativeMessage(d);return;}if(a<m){setTimeout(t,100);}}" +
            "t();" +
            "})();true;"
    }

    // MARK: - Purchase State

    /// Builds the JS that sends a purchaseState message back to the webview.
    /// Matches the RN SDK wire format: `{ type: "purchaseState", data: { isPurchasing: bool } }`.
    /// - Parameter isPurchasing: true while a purchase is in progress, false when done.
    public static func buildPurchaseStateScript(isPurchasing: Bool) -> String {
        let value = isPurchasing ? "true" : "false"
        return "if(window.receiveNativeMessage){window.receiveNativeMessage({type:\"purchaseState\",data:{isPurchasing:\(value)}});}true;"
    }

    // MARK: - Private Helpers

    /// Literal JS: string escapada entre aspas, ou `null`.
    private static func jsString(_ value: String?) -> String {
        guard let value = value else { return "null" }
        return "\"\(value.jsEscaped)\""
    }

    private static func encodeProductsJSON(_ products: [Product]) -> String {
        let encoder = JSONEncoder()
        // DO NOT use .convertToSnakeCase — web app expects camelCase keys
        // (productId, localizedPrice, priceValue, subscriptionPeriod, etc.)
        guard let data = try? encoder.encode(products),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}

// MARK: - String + JS Escaping

private extension String {
    /// Escapes characters that would break a JS string literal.
    var jsEscaped: String {
        var result = self
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: "\"", with: "\\\"")
        result = result.replacingOccurrences(of: "\n", with: "\\n")
        result = result.replacingOccurrences(of: "\r", with: "\\r")
        result = result.replacingOccurrences(of: "\t", with: "\\t")
        return result
    }
}
