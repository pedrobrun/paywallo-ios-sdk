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
    ///   `{ type: "paywall", data: { craftData, products, primaryProductId, secondaryProductId } }`
    /// Polls for `window.receiveNativeMessage` up to 50 times at 100 ms intervals,
    /// identical to the RN SDK polling pattern.
    /// - Parameters:
    ///   - craftData: Serialized craft/config JSON string for the paywall renderer.
    ///   - products: Array of `Product` values — encoded to JSON via `JSONEncoder`.
    ///   - primaryProductId: Optional primary product identifier.
    ///   - secondaryProductId: Optional secondary product identifier.
    public static func buildPaywallDataScript(
        craftData: String,
        products: [Product],
        primaryProductId: String?,
        secondaryProductId: String?
    ) -> String {
        let productsJSON = encodeProductsJSON(products)
        let primaryJSON = primaryProductId.map { "\"\($0.jsEscaped)\"" } ?? "null"
        let secondaryJSON = secondaryProductId.map { "\"\($0.jsEscaped)\"" } ?? "null"
        let escapedCraftData = craftData.jsEscaped

        return "(function(){" +
            "var d={type:\"paywall\",data:{craftData:\"\(escapedCraftData)\"," +
            "products:\(productsJSON)," +
            "primaryProductId:\(primaryJSON)," +
            "secondaryProductId:\(secondaryJSON)}};" +
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
