import Foundation

public enum Environment: String, Codable, Sendable {
    case production = "Production"
    case sandbox = "Sandbox"
}

public struct PaywalloConfig: Codable, Sendable {
    public let appKey: String
    public var apiUrl: String?
    public var debug: Bool?
    public var environment: Environment?

    public init(appKey: String, apiUrl: String? = nil, debug: Bool? = nil, environment: Environment? = nil) {
        self.appKey = appKey
        self.apiUrl = apiUrl
        self.debug = debug
        self.environment = environment
    }
}

public struct PaywallErrorStrings: Codable, Sendable {
    public var title: String?
    public var retry: String?
    public var close: String?

    public init(title: String? = nil, retry: String? = nil, close: String? = nil) {
        self.title = title
        self.retry = retry
        self.close = close
    }
}

public struct SessionFlagConfig: Codable, Sendable {
    public let keys: [String]
    public let timeout: TimeInterval?

    public init(keys: [String], timeout: TimeInterval? = nil) {
        self.keys = keys
        self.timeout = timeout
    }
}

public struct NotificationConfig: Codable, Sendable {
    public var enabled: Bool
    public var provisional: Bool?

    public init(enabled: Bool = true, provisional: Bool? = nil) {
        self.enabled = enabled
        self.provisional = provisional
    }
}

public struct PaywalloInitConfig: Sendable {
    public let appKey: String
    /// Aponta o SDK para outro backend. Sem isto, produção. Só para testar contra um servidor local.
    /// Validado no init: `https`, ou `http` em localhost/127.0.0.1/192.168.x — nunca cai em produção em silêncio.
    public var apiUrl: String?
    public var debug: Bool?
    public var environment: Environment?
    public var autoStartSession: Bool?
    /// Fila offline removida (03/08/2026) — campo aceito mas **ignorado**, sai na 3.0.0.
    /// Ver `docs/incidents/2026-08-03-critical-event-loss.md` no SDK React Native.
    public var offlineQueueEnabled: Bool?
    public var timeout: TimeInterval?
    public var errorStrings: PaywallErrorStrings?
    public var sessionFlags: SessionFlagConfig?
    public var subscriptionCacheTTL: TimeInterval?
    public var autoPreloadCampaign: String?
    public var notifications: Bool?
    /// Passe `false` para desligar os updates de conversion value do SKAdNetwork.
    /// Default: ligado. Desligue se outro SDK no mesmo app já for dono do conversion
    /// value — dois escritores corrompem o sinal (é um valor único e monotônico por app).
    public var skan: Bool?
    /// Placements de paywall a pré-carregar no init.
    public var preloadPaywalls: [String]?
    /// Sobrescreve a versão do app reportada no contexto dos eventos.
    public var appVersion: String?
    public var onError: (@Sendable (PaywalloError) -> Void)?

    public init(
        appKey: String,
        apiUrl: String? = nil,
        debug: Bool? = nil,
        environment: Environment? = nil,
        autoStartSession: Bool? = nil,
        offlineQueueEnabled: Bool? = nil,
        timeout: TimeInterval? = nil,
        errorStrings: PaywallErrorStrings? = nil,
        sessionFlags: SessionFlagConfig? = nil,
        subscriptionCacheTTL: TimeInterval? = nil,
        autoPreloadCampaign: String? = nil,
        notifications: Bool? = nil,
        skan: Bool? = nil,
        preloadPaywalls: [String]? = nil,
        appVersion: String? = nil,
        onError: (@Sendable (PaywalloError) -> Void)? = nil
    ) {
        self.appKey = appKey
        self.apiUrl = apiUrl
        self.debug = debug
        self.environment = environment
        self.autoStartSession = autoStartSession
        self.offlineQueueEnabled = offlineQueueEnabled
        self.timeout = timeout
        self.errorStrings = errorStrings
        self.sessionFlags = sessionFlags
        self.subscriptionCacheTTL = subscriptionCacheTTL
        self.autoPreloadCampaign = autoPreloadCampaign
        self.notifications = notifications
        self.skan = skan
        self.preloadPaywalls = preloadPaywalls
        self.appVersion = appVersion
        self.onError = onError
    }
}
