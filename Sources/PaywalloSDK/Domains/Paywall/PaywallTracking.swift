import Foundation

// MARK: - PaywallTracking

/// Handles paywall analytics event emission.
public final class PaywallTracking {

    private let batcher: EventBatcherProtocol
    private let sessionManager: SessionManager
    private let debug: Bool

    /// Tracks whether paywall_viewed / open have already been emitted for this cycle.
    private var viewedEmitted = false

    public init(batcher: EventBatcherProtocol, sessionManager: SessionManager, debug: Bool = false) {
        self.batcher = batcher
        self.sessionManager = sessionManager
        self.debug = debug
    }

    // MARK: - Reset Per Cycle

    /// Call this before showing a new paywall to reset the once-per-cycle guard.
    public func resetCycle() {
        viewedEmitted = false
    }

    // MARK: - Visible

    /// Emit $paywall_viewed (legacy) AND paywall {type: "open"} — once per cycle.
    public func emitPaywallVisible(
        paywallId: String,
        placement: String,
        variantKey: String? = nil,
        variantId: String? = nil,
        campaignId: String? = nil
    ) {
        guard !viewedEmitted else { return }
        viewedEmitted = true

        let sessionId = sessionManager.getSessionId()

        // Legacy event (camelCase keys to match RN SDK)
        var legacyProps: [String: AnyCodable] = [
            "paywallId": AnyCodable(paywallId),
            "placement": AnyCodable(placement),
        ]
        if let v = sessionId   { legacyProps["sessionId"]   = AnyCodable(v) }
        if let v = variantKey  { legacyProps["variantKey"]  = AnyCodable(v) }
        if let v = campaignId  { legacyProps["campaignId"]  = AnyCodable(v) }
        if let v = variantId   { legacyProps["variant_id"]  = AnyCodable(v) }

        batcher.enqueue(name: "$paywall_viewed", properties: legacyProps, priority: .normal, timestamp: nil)

        // Canonical V2 event (snake_case keys)
        var v2Props: [String: AnyCodable] = [
            "type": AnyCodable("open"),
            "paywall_id": AnyCodable(paywallId),
            "placement": AnyCodable(placement),
            "opened_at": AnyCodable(ISO8601DateFormatter().string(from: Date())),
        ]
        // `sessionId` camelCase, igual ao `closed` e ao recovery de heartbeat — é a chave
        // que o RN emite em TODOS os eventos de paywall (viewed e closed). Emitir
        // `session_id` só aqui deixava o `viewed` sem sessão do lado do servidor.
        if let v = sessionId   { v2Props["sessionId"]    = AnyCodable(v) }
        if let v = variantKey  { v2Props["variant_key"]  = AnyCodable(v) }
        if let v = campaignId  { v2Props["campaign_id"]  = AnyCodable(v) }
        if let v = variantId   { v2Props["variant_id"]   = AnyCodable(v) }

        batcher.enqueue(name: "paywall", properties: v2Props, priority: .normal, timestamp: nil)

        log("emitted paywall open: \(paywallId) at \(placement)")
    }

    // MARK: - Closed

    /// Emit paywall {type: "closed"} with duration, close reason, and optional variant/campaign context.
    public func emitPaywallClosed(
        paywallId: String,
        placement: String,
        durationS: Double,
        closeReason: String,
        scrollDepth: Double? = nil,
        variantKey: String? = nil,
        variantId: String? = nil,
        campaignId: String? = nil
    ) {
        let sessionId = sessionManager.getSessionId()

        var props: [String: AnyCodable] = [
            "type": AnyCodable("closed"),
            "paywall_id": AnyCodable(paywallId),
            "placement": AnyCodable(placement),
            "closed_at": AnyCodable(ISO8601DateFormatter().string(from: Date())),
            "duration_s": AnyCodable(durationS),
            "close_reason": AnyCodable(closeReason),
        ]

        if let depth = scrollDepth { props["scroll_depth"] = AnyCodable(depth) }
        if let v = variantKey      { props["variant_key"]  = AnyCodable(v) }
        if let v = variantId       { props["variant_id"]   = AnyCodable(v) }
        if let v = campaignId      { props["campaign_id"]  = AnyCodable(v) }
        // `sessionId` camelCase de propósito: é a chave que o RN emite no `closed` e a
        // que o recovery de heartbeat já usa. Emitir `session_id` aqui deixava metade
        // dos `closed` sem sessão do lado do servidor.
        if let v = sessionId       { props["sessionId"]    = AnyCodable(v) }

        batcher.enqueue(name: "paywall", properties: props, priority: .critical, timestamp: nil)

        log("emitted paywall closed: \(paywallId), reason=\(closeReason), duration=\(durationS)s")
    }

    // MARK: - Private

    private func log(_ message: String) {
        guard debug else { return }
        print("[Paywallo:PaywallTracking] \(message)")
    }
}
