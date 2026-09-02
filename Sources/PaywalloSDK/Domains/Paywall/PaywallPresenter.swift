import Foundation

#if canImport(UIKit)
import UIKit

#if canImport(WebKit)
import WebKit
#endif

// MARK: - PaywallPresenterDelegate

public protocol PaywallPresenterDelegate: AnyObject {
    func paywallPresenter(
        _ presenter: PaywallPresenter,
        didRequestPurchase productId: String,
        placement: String,
        variantKey: String?
    )
    func paywallPresenter(_ presenter: PaywallPresenter, didRequestRestore: Void)
    func paywallPresenter(_ presenter: PaywallPresenter, didRequestOpenURL url: String)
    func paywallPresenter(_ presenter: PaywallPresenter, didSelectProduct productId: String)
    func paywallPresenterDidClose(_ presenter: PaywallPresenter, closeReason: String)
}

// MARK: - PaywallPresenter

/// UIViewController that hosts PaywalloWebView and handles paywall lifecycle.
public final class PaywallPresenter: UIViewController {

    // MARK: - Constants

    private static let timeoutMs: Int = PaywalloConstants.paywallTimeoutMs  // 30 min

    // MARK: - Dependencies

    public weak var delegate: PaywallPresenterDelegate?

    private let paywallId: String
    private let placement: String
    private let paywallURL: URL
    private let tracking: PaywallTracking
    private let heartbeat: PaywallHeartbeat

    // MARK: - Paywall Config

    private let craftData: String
    private let products: [Product]
    private let primaryProductId: String?
    private let secondaryProductId: String?
    private let tertiaryProductId: String?

    // MARK: - Variant / Campaign Context

    private let variantKey: String?
    private let variantId: String?
    private let campaignId: String?

    // MARK: - State

    private var isPaywallReady = false
    private var isClosed = false
    private var presentedAtMs: Double = 0
    private var timeoutTimer: Timer?
    private var backgroundObserver: NSObjectProtocol?

    // MARK: - UI

#if canImport(WebKit)
    private var paywalloWebView: PaywalloWebView?
#endif

    private lazy var loadingView: UIView = {
        let view = UIView()
        view.backgroundColor = .systemBackground
        view.translatesAutoresizingMaskIntoConstraints = false

        let indicator = UIActivityIndicatorView(style: .large)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimating()
        view.addSubview(indicator)

        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        return view
    }()

    private lazy var errorView: UIView = {
        let view = UIView()
        view.backgroundColor = .systemBackground
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = "Unable to load paywall."
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("Close", for: .normal)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(errorCloseButtonTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            closeButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
            closeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])

        return view
    }()

    // MARK: - Init

    public init(
        paywallId: String,
        placement: String,
        paywallURL: URL,
        craftData: String,
        products: [Product],
        primaryProductId: String?,
        secondaryProductId: String?,
        tertiaryProductId: String? = nil,
        tracking: PaywallTracking,
        heartbeat: PaywallHeartbeat,
        variantKey: String? = nil,
        variantId: String? = nil,
        campaignId: String? = nil
    ) {
        self.paywallId = paywallId
        self.placement = placement
        self.paywallURL = paywallURL
        self.craftData = craftData
        self.products = products
        self.primaryProductId = primaryProductId
        self.secondaryProductId = secondaryProductId
        self.tertiaryProductId = tertiaryProductId
        self.tracking = tracking
        self.heartbeat = heartbeat
        self.variantKey = variantKey
        self.variantId = variantId
        self.campaignId = campaignId
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupWebView()
        setupLoadingView()
        setupErrorView()
        setupBackgroundObserver()
        startTimeout()
        heartbeat.startHeartbeat(
            paywallId: paywallId,
            placement: placement,
            variantKey: variantKey,
            variantId: variantId,
            campaignId: campaignId
        )
        presentedAtMs = Date().timeIntervalSince1970 * 1000
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Reset the once-per-cycle guard so a shared PaywallTracking instance
        // correctly re-emits $paywall_viewed / paywall {type:"open"} on each presentation.
        tracking.resetCycle()
        tracking.emitPaywallVisible(
            paywallId: paywallId,
            placement: placement,
            variantKey: variantKey,
            variantId: variantId,
            campaignId: campaignId
        )
    }

    deinit {
        tearDown()
    }

    // MARK: - Setup

    private func setupWebView() {
#if canImport(WebKit)
        let wv = PaywalloWebView()
        wv.delegate = self
        wv.webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wv.webView)

        NSLayoutConstraint.activate([
            wv.webView.topAnchor.constraint(equalTo: view.topAnchor),
            wv.webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            wv.webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wv.webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        wv.load(url: paywallURL)
        paywalloWebView = wv
#endif
    }

    private func setupLoadingView() {
        view.addSubview(loadingView)
        NSLayoutConstraint.activate([
            loadingView.topAnchor.constraint(equalTo: view.topAnchor),
            loadingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            loadingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func setupErrorView() {
        view.addSubview(errorView)
        NSLayoutConstraint.activate([
            errorView.topAnchor.constraint(equalTo: view.topAnchor),
            errorView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            errorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func setupBackgroundObserver() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleBackground()
        }
    }

    // MARK: - Background Guard

    private func handleBackground() {
        closePaywall(reason: "dismiss")
    }

    // MARK: - Timeout

    private func startTimeout() {
        let interval = TimeInterval(PaywallPresenter.timeoutMs) / 1000.0
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.closePaywall(reason: "timeout")
        }
    }

    // MARK: - Message Handling

    private func handleMessage(_ message: PaywallMessage) {
        switch message.type {
        case "ready":
            handleReady()
        case "purchase":
            if let productId = message.productId {
                delegate?.paywallPresenter(
                    self,
                    didRequestPurchase: productId,
                    placement: placement,
                    variantKey: message.variantKey ?? variantKey
                )
            }
        case "close":
            closePaywall(reason: "dismiss")
        case "restore":
            delegate?.paywallPresenter(self, didRequestRestore: ())
        case "select-product":
            if let productId = message.productId {
                delegate?.paywallPresenter(self, didSelectProduct: productId)
            }
        case "open-url":
            if let url = message.url {
                delegate?.paywallPresenter(self, didRequestOpenURL: url)
            }
        case "haptic":
            Haptics.impact(hapticStyle(message.style))
        default:
            break
        }
    }

    /// O webview escolhe a intensidade por `payload.style`; sem estilo, cai no default
    /// leve. Ignorar o campo fazia todo feedback tátil sair igual.
    private func hapticStyle(_ raw: String?) -> Haptics.Style {
        switch raw {
        case "medium": return .medium
        case "heavy":  return .heavy
        default:       return .light
        }
    }

    private func handleReady() {
        isPaywallReady = true
        DispatchQueue.main.async {
            UIView.animate(withDuration: 0.2) {
                self.loadingView.alpha = 0
            } completion: { _ in
                self.loadingView.isHidden = true
            }
            self.sendPaywallData()
        }
    }

    private func sendPaywallData() {
#if canImport(WebKit)
        let script = PaywallScripts.buildPaywallDataScript(
            craftData: craftData,
            products: products,
            primaryProductId: primaryProductId,
            secondaryProductId: secondaryProductId,
            tertiaryProductId: tertiaryProductId
        )
        paywalloWebView?.evaluateJavaScript(script)
#endif
    }

    // MARK: - Close

    private func closePaywall(reason: String) {
        guard !isClosed else { return }
        let canonical = emitClosed(reason: reason)

        tearDown()
        delegate?.paywallPresenterDidClose(self, closeReason: canonical)

        DispatchQueue.main.async {
            self.dismiss(animated: true)
        }
    }

    /// Emissor único do `paywall {type: "closed"}`. Marca `isClosed` antes de emitir
    /// para que nenhum caminho de saída emita duas vezes.
    @discardableResult
    private func emitClosed(reason: String) -> String {
        isClosed = true

        let canonical = PaywallCloseReason.canonicalize(reason)
        let nowMs = Date().timeIntervalSince1970 * 1000
        let durationS = PaywallHeartbeat.calculateDurationS(presentedAt: presentedAtMs, lastSeen: nowMs)

        tracking.emitPaywallClosed(
            paywallId: paywallId,
            placement: placement,
            durationS: durationS,
            closeReason: canonical,
            variantKey: variantKey,
            variantId: variantId,
            campaignId: campaignId
        )
        return canonical
    }

    // MARK: - Error Fallback

    private func showError() {
        DispatchQueue.main.async {
            self.loadingView.isHidden = true
            self.errorView.isHidden = false
        }
    }

    @objc private func errorCloseButtonTapped() {
        closePaywall(reason: "error")
    }

    // MARK: - Tear Down

    private func tearDown() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil

        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
            backgroundObserver = nil
        }

        // O VC pode sumir sem passar por `closePaywall` — swipe-to-dismiss, o host
        // trocando a hierarquia, deinit. Sem este emit o `closed` se perdia de vez: o
        // recovery de crash também não pega, porque `stopHeartbeat` logo abaixo apaga
        // o snapshot que ele usaria.
        if !isClosed {
            emitClosed(reason: "dismiss")
        }

        heartbeat.stopHeartbeat()
    }
}

// MARK: - PaywalloWebViewDelegate

#if canImport(WebKit)
extension PaywallPresenter: PaywalloWebViewDelegate {
    public func webView(_ webView: PaywalloWebView, didReceiveMessage message: PaywallMessage) {
        DispatchQueue.main.async {
            self.handleMessage(message)
        }
    }

    public func webViewDidFinishLoad(_ webView: PaywalloWebView) {
        // Loading spinner stays until JS sends "ready"
    }

    public func webView(_ webView: PaywalloWebView, didFailWithError error: Error) {
        showError()
    }
}
#endif

#endif // canImport(UIKit)
