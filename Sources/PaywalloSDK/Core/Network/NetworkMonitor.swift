import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

public typealias NetworkListener = (Bool) -> Void

/// Mirrors the RN `NetworkState` triple so callers can tell "not measured yet" apart from
/// "measured and offline".
public enum NetworkState: String, Sendable {
    case online
    case offline
    case unknown
}

public final class NetworkMonitor {
    public static let shared = NetworkMonitor()

    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "com.paywallo.sdk.network", qos: .utility)
    private let lock = NSLock()
    private var listeners: [UUID: NetworkListener] = [:]
    private var currentStatus: NWPath.Status = .requiresConnection
    private var initialized = false
    private var debug = false

    public init() {
        self.monitor = NWPathMonitor()
    }

    public func initialize() {
        lock.lock()
        guard !initialized else {
            lock.unlock()
            return
        }
        initialized = true
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let previousOnline = self.isOnline()
            self.lock.lock()
            self.currentStatus = path.status
            self.lock.unlock()
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
        guard isInitialized() else { return }
        // NWPathMonitor auto-resumes, but we re-check and notify
        notifyListeners(forceCheck() == .online)
    }

    @objc private func handleDidEnterBackground() {
        // NWPathMonitor continues in background — no action needed
        // but we could pause if battery optimization is needed
    }
    #endif

    // MARK: - Public API

    /// Pessimistic by design: anything that is not a measured `.satisfied` path counts as
    /// offline. An optimistic `true` made `PendingRetry.process()` burn both of a critical
    /// event's attempts in ~6 minutes of a dead connection, so the event died before the
    /// network came back.
    public func isOnline() -> Bool {
        getState() == .online
    }

    public func getState() -> NetworkState {
        lock.lock()
        defer { lock.unlock() }
        guard initialized else { return .unknown }
        // `.requiresConnection` means the path needs a connection to be established
        // (e.g. VPN on demand) — not a usable route right now.
        return currentStatus == .satisfied ? .online : .offline
    }

    /// Re-reads the live path instead of waiting for the next update callback. Used on
    /// foreground, where the state may have changed while the process was suspended.
    @discardableResult
    public func forceCheck() -> NetworkState {
        guard isInitialized() else { return .unknown }
        lock.lock()
        currentStatus = monitor.currentPath.status
        lock.unlock()
        return getState()
    }

    public func isInitialized() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return initialized
    }

    @discardableResult
    public func addListener(_ listener: @escaping NetworkListener) -> () -> Void {
        let id = UUID()
        lock.lock()
        listeners[id] = listener
        lock.unlock()
        return { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.listeners.removeValue(forKey: id)
            self.lock.unlock()
        }
    }

    public func dispose() {
        monitor.cancel()
        lock.lock()
        listeners.removeAll()
        initialized = false
        currentStatus = .requiresConnection
        lock.unlock()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Private

    private func notifyListeners(_ online: Bool) {
        lock.lock()
        let currentListeners = Array(listeners.values)
        lock.unlock()
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
