import Foundation

/// Signature of the native conversion-value update. Injectable so tests can run
/// off-device — SKAdNetwork has no implementation in the simulator or a CLI process.
public typealias SkanConversionValueUpdater = @Sendable (Int, CoarseConversionValue, Bool) async -> Bool

// MARK: - Serial report queue

/// Serial chain that preserves CALL ORDER.
///
/// Being an `actor` gives `SkanManager` mutual exclusion but NOT FIFO: two `Task`s
/// created back-to-back may run in either order, and that is exactly the race this
/// must prevent — trial and purchase in the same tick would both read the pre-trial
/// state and the purchase would be classified as `DirectPurchase` instead of
/// `TrialConverted`. Chaining each operation onto the previous one under a lock makes
/// the order of `enqueue` calls the order of execution, and gives read-after-write.
private final class SkanReportQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never> = Task {}

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = tail
        tail = Task {
            await previous.value
            await operation()
        }
        lock.unlock()
    }

    /// Snapshot of the tail. Kept non-async on purpose: taking an `NSLock` inside an async
    /// function is unsafe (the thread can change across a suspension) and is an error under
    /// the Swift 6 language mode.
    private func currentTail() -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        return tail
    }

    /// Awaits everything queued so far.
    func drain() async {
        await currentTail().value
    }
}

// MARK: - SkanManager

/// Owner of the SKAdNetwork conversion value.
///
/// Two Apple rules dictate the design:
///
/// 1. The advertised app must call update at least once for the conversion window to
///    open. Without it there is NO postback — not even for the ad network. That is why
///    `openConversionWindow()` runs on the first launch with fine 0.
/// 2. An update with a value lower than the previous one is discarded, and a locked
///    postback accepts nothing more. Since funnel milestones can arrive out of order
///    (seeing the paywall again after subscribing), we keep the highest value ever sent
///    and never regress.
///
/// A single owner per app: if another SDK (an MMP) also writes the conversion value,
/// the two trample each other and the signal reaching the ad network becomes noise.
public actor SkanManager {

    public static let shared = SkanManager()

    private struct SkanState {
        var highestFine: Int
        var locked: Bool
    }

    /// `"purchase"` stays pending: the stage depends on persisted state, resolved later.
    private enum ResolvedStage {
        case stage(ConversionStage)
        case purchase
    }

    // MARK: - Dependencies

    private let storage: SecureStorage
    private let isAvailable: @Sendable () -> Bool
    private let updateConversionValue: SkanConversionValueUpdater
    private let queue = SkanReportQueue()

    // MARK: - State

    private var state: SkanState?
    private var debug = false

    // MARK: - Init

    public init(
        storage: SecureStorage = .shared,
        isAvailable: @escaping @Sendable () -> Bool = { NativeSkan.isAvailable() },
        updateConversionValue: @escaping SkanConversionValueUpdater = { fine, coarse, lock in
            await NativeSkan.updateConversionValue(fine, coarse: coarse, lock: lock)
        }
    ) {
        self.storage = storage
        self.isAvailable = isAvailable
        self.updateConversionValue = updateConversionValue
    }

    public func injectDeps(debug: Bool) {
        self.debug = debug
    }

    // MARK: - Conversion window

    /// Opens the conversion window. Idempotent: after the first send the persisted state
    /// already holds fine 0 and any extra call is dropped by the monotonicity guard.
    public nonisolated func openConversionWindow() {
        queue.enqueue { [self] in
            await self.report(.install, revenueUsd: 0)
        }
    }

    // MARK: - Report

    /// Records a funnel milestone. `revenueUsd` must only be filled in when the purchase
    /// currency is USD — converting on the client without an FX rate would push the
    /// revenue tier several levels above the real one.
    ///
    /// A failure here never propagates: SKAN is an auxiliary signal and must never take
    /// down the app flow.
    public func report(_ stage: ConversionStage, revenueUsd: Double = 0) async {
        guard isAvailable() else { return }

        let current = await loadState()
        // Lock guard comes before any computation: a locked postback accepts nothing.
        if current.locked { return }

        // highestFine starts at -1, so the fine 0 of the first launch passes here and any
        // repetition of it (on the following launches) is blocked.
        let value = SkanConversionValue.compute(stage: stage, revenueUsd: revenueUsd)
        if value.fine <= current.highestFine { return }

        let accepted = await updateConversionValue(value.fine, value.coarse, value.lock)
        guard accepted else {
            log("update recusado pela Apple (fine: \(value.fine))")
            return
        }

        // Persist ONLY after the update is accepted: writing beforehand would let a
        // refused update block every later milestone through the monotonicity guard.
        let updated = SkanState(highestFine: value.fine, locked: value.lock)
        state = updated
        await persist(updated)
        log("conversion value enviado (fine: \(value.fine), coarse: \(value.coarse.rawValue), lock: \(value.lock))")
    }

    // MARK: - Observe

    /// Translates the events the SDK already emits into funnel stages. Wired to the
    /// EventBatcher choke point, so it covers both purchase paths (native StoreKit and
    /// Superwall) without touching each emitter.
    ///
    /// Fire-and-forget: the caller is the hot event path.
    public nonisolated func observe(_ eventName: String, properties: [String: AnyCodable]?) {
        guard let resolved = Self.stageFor(eventName: eventName, properties: properties) else { return }
        let revenueUsd = Self.revenueUsdFrom(properties)

        queue.enqueue { [self] in
            switch resolved {
            case .purchase:
                await self.reportPurchase(revenueUsd: revenueUsd)
            case .stage(let stage):
                await self.report(stage, revenueUsd: revenueUsd)
            }
        }
    }

    /// Purchase: whether this is a trial conversion or a direct purchase can only be known
    /// AFTER reading the persisted state — which is why it cannot be resolved in
    /// `stageFor`, that runs synchronously on the hot path before any await.
    private func reportPurchase(revenueUsd: Double) async {
        guard isAvailable() else { return }

        let current = await loadState()
        let previousStage = current.highestFine >> 3
        let stage: ConversionStage = previousStage >= ConversionStage.trialStarted.rawValue
            ? .trialConverted
            : .directPurchase
        await report(stage, revenueUsd: revenueUsd)
    }

    // MARK: - Event mapping

    private static func stageFor(eventName: String, properties: [String: AnyCodable]?) -> ResolvedStage? {
        if eventName == "$paywall_viewed" { return .stage(.paywallViewed) }

        let type = properties?["type"]?.value as? String

        // The RN SDK maps `$onboarding_completed`, which no emitter ever sends — its
        // OnboardingManager emits `onboarding` with `type: "complete"` — so stage 1 is
        // dead code there. Here we map the event the SDK actually emits.
        if eventName == "onboarding" {
            return type == "complete" ? .stage(.onboardingComplete) : nil
        }

        guard eventName == "transaction" else { return nil }

        switch type {
        case "trial_started": return .stage(.trialStarted)
        // `renewed` is what marks retention (corrected in 2.7.1 — it used to read another type).
        case "renewed": return .stage(.retained)
        case "completed": return .purchase
        default: return nil
        }
    }

    /// The SDK only knows the price in the local currency and does no FX conversion.
    /// Adding BRL as if it were USD would push the revenue tier several levels above the
    /// real one, so outside USD the tier stays 0 — the stage, which dominates the fine
    /// value, remains correct.
    private static func revenueUsdFrom(_ properties: [String: AnyCodable]?) -> Double {
        guard properties?["currency"]?.value as? String == "USD" else { return 0 }
        let amount = numericValue(properties?["amount"]) ?? numericValue(properties?["full_price"])
        guard let amount = amount, amount > 0 else { return 0 }
        return amount
    }

    private static func numericValue(_ value: AnyCodable?) -> Double? {
        switch value?.value {
        case let double as Double: return double
        case let int as Int: return Double(int)
        case let number as NSNumber: return number.doubleValue
        default: return nil
        }
    }

    // MARK: - Persistence

    private func loadState() async -> SkanState {
        if let state = state { return state }

        async let rawFine = storage.get(PaywalloConstants.skanHighestFineKey)
        async let rawLocked = storage.get(PaywalloConstants.skanLockedKey)
        let (fine, locked) = await (rawFine, rawLocked)

        // -1 when absent or non-finite: it is the -1 that lets the fine 0 of the first
        // launch through the monotonicity guard, and blocks its repetition afterwards.
        var highestFine = -1
        if let raw = fine, let parsed = Double(raw), parsed.isFinite {
            highestFine = Int(parsed)
        }

        let loaded = SkanState(highestFine: highestFine, locked: locked == "1")
        state = loaded
        return loaded
    }

    private func persist(_ state: SkanState) async {
        await storage.set(PaywalloConstants.skanHighestFineKey, value: String(state.highestFine))
        // `locked` is only ever written when true — the state never unlocks.
        if state.locked {
            await storage.set(PaywalloConstants.skanLockedKey, value: "1")
        }
    }

    // MARK: - Testing helpers

    /// Awaits every queued report. Test seam — production is fire-and-forget.
    public nonisolated func waitForPendingReports() async {
        await queue.drain()
    }

    /// Only for tests — the real state lives in the Keychain.
    public func resetForTests() {
        state = nil
    }

    // MARK: - Logging

    private func log(_ message: String) {
        guard debug else { return }
        print("[Paywallo][SKAN] \(message)")
    }
}
