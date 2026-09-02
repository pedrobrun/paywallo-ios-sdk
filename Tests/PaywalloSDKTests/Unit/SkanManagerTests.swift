import XCTest
@testable import PaywalloSDK

// MARK: - Helpers

private func makeIsolatedSkanStorage(id: String = UUID().uuidString)
    -> (SecureStorage, String)
{
    let name = "com.paywallo.sdk.skan.tests.\(id)"
    let suite = UserDefaults(suiteName: name)!
    let native = NativeStorage(service: name, defaults: suite)
    return (SecureStorage(nativeStorage: native), name)
}

/// Records every conversion value handed to the native bridge and lets a test decide
/// whether Apple accepts it.
private final class SkanUpdateSpy: @unchecked Sendable {
    struct Call: Equatable {
        let fine: Int
        let coarse: CoarseConversionValue
        let lock: Bool
    }

    private let lock = NSLock()
    private var storedCalls: [Call] = []
    var accept = true

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return storedCalls
    }

    func record(_ fine: Int, _ coarse: CoarseConversionValue, _ shouldLock: Bool) -> Bool {
        lock.lock()
        storedCalls.append(Call(fine: fine, coarse: coarse, lock: shouldLock))
        let accepted = accept
        lock.unlock()
        return accepted
    }
}

// MARK: - Tests

final class SkanManagerTests: XCTestCase {

    private var storage: SecureStorage!
    private var suiteName: String!
    private var spy: SkanUpdateSpy!
    private var manager: SkanManager!

    override func setUp() {
        super.setUp()
        let (s, name) = makeIsolatedSkanStorage()
        storage = s
        suiteName = name
        spy = SkanUpdateSpy()
        manager = makeManager()
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Fresh manager over the SAME storage — simulates a new app launch.
    private func makeManager() -> SkanManager {
        let spy = self.spy!
        return SkanManager(
            storage: storage,
            isAvailable: { true },
            updateConversionValue: { fine, coarse, lock in spy.record(fine, coarse, lock) }
        )
    }

    // MARK: - openConversionWindow

    func testOpenConversionWindow_sendsInstallWithFineZero() async {
        manager.openConversionWindow()
        await manager.waitForPendingReports()

        XCTAssertEqual(spy.calls, [.init(fine: 0, coarse: .low, lock: false)])
    }

    func testOpenConversionWindow_isIdempotentAcrossLaunches() async {
        manager.openConversionWindow()
        await manager.waitForPendingReports()

        // New launch, same persisted state: the monotonicity guard drops the repeat.
        let relaunched = makeManager()
        relaunched.openConversionWindow()
        await relaunched.waitForPendingReports()

        XCTAssertEqual(spy.calls.count, 1)
    }

    // MARK: - Monotonicity guard

    func testReport_equalFine_isDropped() async {
        await manager.report(.paywallViewed, revenueUsd: 0)
        await manager.report(.paywallViewed, revenueUsd: 0)

        XCTAssertEqual(spy.calls, [.init(fine: 16, coarse: .low, lock: false)])
    }

    func testReport_lowerFine_isDropped() async {
        await manager.report(.trialStarted, revenueUsd: 0)   // fine 24
        await manager.report(.paywallViewed, revenueUsd: 0)  // fine 16 — regression

        XCTAssertEqual(spy.calls, [.init(fine: 24, coarse: .medium, lock: false)])
    }

    func testReport_higherFine_isSent() async {
        await manager.report(.paywallViewed, revenueUsd: 0)
        await manager.report(.trialStarted, revenueUsd: 0)

        XCTAssertEqual(spy.calls.map(\.fine), [16, 24])
    }

    // MARK: - Lock guard

    func testReport_afterTerminalStage_everythingIsBlocked() async {
        await manager.report(.trialConverted, revenueUsd: 0)  // fine 32, lock
        await manager.report(.retained, revenueUsd: 0)        // fine 48, would be higher

        XCTAssertEqual(spy.calls.map(\.fine), [32])
    }

    func testReport_lockPersists_acrossLaunches() async {
        await manager.report(.directPurchase, revenueUsd: 0)

        let relaunched = makeManager()
        await relaunched.report(.retained, revenueUsd: 0)

        XCTAssertEqual(spy.calls.map(\.fine), [40])
    }

    // MARK: - Persist only after acceptance

    func testReport_refusedByApple_persistsNothing() async {
        spy.accept = false
        await manager.report(.paywallViewed, revenueUsd: 0)

        let storedFine = await storage.get(PaywalloConstants.skanHighestFineKey)
        XCTAssertNil(storedFine)

        // A later milestone is not blocked by the refused one.
        spy.accept = true
        let relaunched = makeManager()
        await relaunched.report(.paywallViewed, revenueUsd: 0)

        XCTAssertEqual(spy.calls.map(\.fine), [16, 16])
    }

    func testReport_accepted_persistsHighestFine() async {
        await manager.report(.trialStarted, revenueUsd: 0)

        let storedFine = await storage.get(PaywalloConstants.skanHighestFineKey)
        let storedLock = await storage.get(PaywalloConstants.skanLockedKey)
        XCTAssertEqual(storedFine, "24")
        XCTAssertNil(storedLock)
    }

    func testReport_terminalStage_persistsLockedFlag() async {
        await manager.report(.trialConverted, revenueUsd: 0)

        let storedLock = await storage.get(PaywalloConstants.skanLockedKey)
        XCTAssertEqual(storedLock, "1")
    }

    // MARK: - Serialization (the trial-then-purchase race)

    func testObserve_trialAndPurchaseSameTick_resolvesToTrialConverted() async {
        manager.observe("transaction", properties: ["type": AnyCodable("trial_started")])
        manager.observe("transaction", properties: ["type": AnyCodable("completed")])
        await manager.waitForPendingReports()

        // 24 = TrialStarted, 32 = TrialConverted. Without the serial queue the purchase
        // would read the pre-trial state and land on DirectPurchase (40).
        XCTAssertEqual(spy.calls.map(\.fine), [24, 32])
    }

    func testObserve_purchaseWithoutTrial_resolvesToDirectPurchase() async {
        manager.observe("transaction", properties: ["type": AnyCodable("completed")])
        await manager.waitForPendingReports()

        XCTAssertEqual(spy.calls.map(\.fine), [40])
    }

    // MARK: - Event mapping

    func testObserve_paywallViewed() async {
        manager.observe("$paywall_viewed", properties: nil)
        await manager.waitForPendingReports()

        XCTAssertEqual(spy.calls.map(\.fine), [16])
    }

    func testObserve_onboardingComplete_usesTheEventTheSDKActuallyEmits() async {
        manager.observe("onboarding", properties: ["type": AnyCodable("complete")])
        await manager.waitForPendingReports()

        XCTAssertEqual(spy.calls.map(\.fine), [8])
    }

    func testObserve_onboardingStep_isIgnored() async {
        manager.observe("onboarding", properties: ["type": AnyCodable("step")])
        await manager.waitForPendingReports()

        XCTAssertTrue(spy.calls.isEmpty)
    }

    func testObserve_renewed_mapsToRetained() async {
        manager.observe("transaction", properties: ["type": AnyCodable("renewed")])
        await manager.waitForPendingReports()

        XCTAssertEqual(spy.calls.map(\.fine), [48])
    }

    func testObserve_unknownEvent_isIgnored() async {
        manager.observe("session_start", properties: nil)
        manager.observe("transaction", properties: ["type": AnyCodable("failed")])
        await manager.waitForPendingReports()

        XCTAssertTrue(spy.calls.isEmpty)
    }

    // MARK: - Revenue

    func testObserve_usdPurchase_addsRevenueTier() async {
        manager.observe("transaction", properties: [
            "type": AnyCodable("completed"),
            "amount": AnyCodable(29.9),
            "currency": AnyCodable("USD"),
        ])
        await manager.waitForPendingReports()

        // DirectPurchase (40) + tier 4 (25 <= 29.9 < 50)
        XCTAssertEqual(spy.calls.map(\.fine), [44])
    }

    func testObserve_nonUsdPurchase_scoresRevenueAsZero() async {
        manager.observe("transaction", properties: [
            "type": AnyCodable("completed"),
            "amount": AnyCodable(149.9),
            "currency": AnyCodable("BRL"),
        ])
        await manager.waitForPendingReports()

        // 149.90 BRL is ~30 USD; converting without an FX rate would score tier 6 (fine 46).
        XCTAssertEqual(spy.calls.map(\.fine), [40])
    }

    func testObserve_fallsBackToFullPriceWhenAmountIsAbsent() async {
        manager.observe("transaction", properties: [
            "type": AnyCodable("completed"),
            "full_price": AnyCodable(12.0),
            "currency": AnyCodable("USD"),
        ])
        await manager.waitForPendingReports()

        XCTAssertEqual(spy.calls.map(\.fine), [43])
    }

    func testObserve_zeroAmount_scoresTierZero() async {
        manager.observe("transaction", properties: [
            "type": AnyCodable("completed"),
            "amount": AnyCodable(0.0),
            "currency": AnyCodable("USD"),
        ])
        await manager.waitForPendingReports()

        XCTAssertEqual(spy.calls.map(\.fine), [40])
    }

    // MARK: - Availability

    func testReport_whenUnavailable_isNoOp() async {
        let spy = self.spy!
        let unavailable = SkanManager(
            storage: storage,
            isAvailable: { false },
            updateConversionValue: { fine, coarse, lock in spy.record(fine, coarse, lock) }
        )
        await unavailable.report(.paywallViewed, revenueUsd: 0)

        XCTAssertTrue(spy.calls.isEmpty)
    }
}
