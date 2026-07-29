import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

public typealias NetworkListener = (Bool) -> Void

public final class NetworkMonitor {
    public static let shared = NetworkMonitor()

    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "com.paywallo.sdk.network", qos: .utility)
    private var listeners: [UUID: NetworkListener] = [:]
    private var currentStatus: NWPath.Status = .requiresConnection
    private var initialized = false
    private var debug = false

    public init() {
        self.monitor = NWPathMonitor()
    }

    public func initialize() {
        guard !initialized else { return }
        initialized = true

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let previousOnline = self.isOnline()
            self.currentStatus = path.status
            let nowOnline = self.isOnline()

            if previousOnline != nowOnline {
                self.log("Network state changed: \(nowOnline ? "online" : "offline")")
                self.notifyListeners(nowOnline)
            }
        }

        monitor.start(queue: monitorQueue)
        setupAppStateListeners()
        log("Initialized")
    }

    private func setupAppStateListeners() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        #endif
    }

    #if canImport(UIKit)
    @objc private func handleDidBecomeActive() {
        if initialized {
            // NWPathMonitor auto-resumes, but we re-check and notify
            let online = isOnline()
            notifyListeners(online)
        }
    }

    @objc private func handleDidEnterBackground() {
        // NWPathMonitor continues in background — no action needed
        // but we could pause if battery optimization is needed
    }
    #endif

    // MARK: - Public API

    public func isOnline() -> Bool {
        if !initialized {
            return true  // optimistic — don't block on cold start
        }
        // requiresConnection is treated as unknown/optimistic
        return currentStatus == .satisfied || currentStatus == .requiresConnection
    }

    public func isInitialized() -> Bool {
        initialized
    }

    @discardableResult
    public func addListener(_ listener: @escaping NetworkListener) -> () -> Void {
        let id = UUID()
        listeners[id] = listener
        return { [weak self] in
            self?.listeners.removeValue(forKey: id)
        }
    }

    public func dispose() {
        monitor.cancel()
        listeners.removeAll()
        initialized = false
        currentStatus = .requiresConnection
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Private

    private func notifyListeners(_ online: Bool) {
        let currentListeners = listeners.values
        DispatchQueue.main.async {
            for listener in currentListeners {
                listener(online)
            }
        }
    }

    private func log(_ message: String) {
        guard debug else { return }
        print("[Paywallo:Network] \(message)")
    }

    public func setDebug(_ debug: Bool) {
        self.debug = debug
    }
}
