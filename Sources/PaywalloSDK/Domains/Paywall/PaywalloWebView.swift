import Foundation

#if canImport(WebKit)
import WebKit

#if canImport(UIKit)
import UIKit
#endif

// MARK: - PaywalloWebViewDelegate

public protocol PaywalloWebViewDelegate: AnyObject {
    func webView(_ webView: PaywalloWebView, didReceiveMessage message: PaywallMessage)
    func webViewDidFinishLoad(_ webView: PaywalloWebView)
    func webView(_ webView: PaywalloWebView, didFailWithError error: Error)
}

// MARK: - PaywalloWebView

/// WKWebView wrapper for paywall rendering.
/// - Injects the ReactNativeWebView bridge shim on page load.
/// - Handles messages from JS via the "paywallo" message handler.
/// - URL policy: allows https://, about:, mailto:, itms-apps://. Blocks http://, javascript:, data:.
public final class PaywalloWebView: NSObject {

    // MARK: - Public

    public let webView: WKWebView
    public weak var delegate: PaywalloWebViewDelegate?

    // MARK: - Init

    public override init() {
        let config = WKWebViewConfiguration()

        // Message handler placeholder — added after super.init
        let userContentController = WKUserContentController()
        config.userContentController = userContentController

        // Inject bridge script at document start
        let bridgeScript = WKUserScript(
            source: PaywallScripts.buildPaywallInjectionScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(bridgeScript)

        webView = WKWebView(frame: .zero, configuration: config)
#if os(iOS)
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
#endif

        super.init()

        // Add self as message handler (after super.init so weak refs are safe)
        userContentController.add(WeakMessageHandler(delegate: self), name: "paywallo")
        webView.navigationDelegate = self
    }

    // MARK: - Loading

    public func load(url: URL) {
        let request = URLRequest(url: url)
        webView.load(request)
    }

    public func load(htmlString: String, baseURL: URL? = nil) {
        webView.loadHTMLString(htmlString, baseURL: baseURL)
    }

    // MARK: - JS Evaluation

    public func evaluateJavaScript(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    public func sendPurchaseState(isPurchasing: Bool) {
        let script = PaywallScripts.buildPurchaseStateScript(isPurchasing: isPurchasing)
        evaluateJavaScript(script)
    }

    // MARK: - URL Policy

    private func isAllowedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }

        switch scheme {
        case "https", "about", "mailto", "itms-apps":
            return true
        case "http", "javascript", "data":
            return false
        default:
            return false
        }
    }
}

// MARK: - WKScriptMessageHandler

extension PaywalloWebView: WKScriptMessageHandler {
    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive scriptMessage: WKScriptMessage
    ) {
        guard let body = scriptMessage.body as? String else { return }

        if let message = PaywallMessageParser.parse(body) {
            delegate?.webView(self, didReceiveMessage: message)
        }
    }
}

// MARK: - WKNavigationDelegate

extension PaywalloWebView: WKNavigationDelegate {

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        delegate?.webViewDidFinishLoad(self)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        delegate?.webView(self, didFailWithError: error)
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        delegate?.webView(self, didFailWithError: error)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        // mailto: and App Store links must be opened by the OS — WKWebView
        // cannot load them inline. Cancel the navigation and hand off to UIApplication.
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "mailto" || scheme == "itms-apps" {
#if os(iOS)
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
#endif
            decisionHandler(.cancel)
            return
        }

        if isAllowedURL(url) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }
}

// MARK: - WeakMessageHandler (avoids WKWebView retain cycle)

private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: PaywalloWebView?

    init(delegate: PaywalloWebView) {
        self.delegate = delegate
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

#endif // canImport(WebKit)
