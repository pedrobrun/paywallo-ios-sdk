import XCTest
@testable import PaywalloSDK

final class InstallIdempotencyTests: XCTestCase {

    private var storage: SecureStorage!
    private var native: NativeStorage!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        let suite = "com.paywallo.sdk.idempotency.tests.\(UUID().uuidString)"
        suiteName = suite
        native = NativeStorage(service: suite, defaults: UserDefaults(suiteName: suite)!)
        storage = SecureStorage(nativeStorage: native)
        // The launch guard is process-wide by design; each case starts from a cold launch.
        InstallIdempotency.resetInstallGuardForTests()
    }

    override func tearDown() async throws {
        await InstallIdempotency.clearInstallState(storage: storage)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - checkAndArmInstallGuard

    func testFirstCall_returnsFalse_andArmsPreSendFlag() async {
        let hasResidue = await InstallIdempotency.checkAndArmInstallGuard(storage: storage)
        XCTAssertFalse(hasResidue)
        XCTAssertEqual(native.get(PaywalloConstants.appInstalledSentKey), "1")
    }

    /// The whole point of the in-memory guard: a second concurrent path must bail before
    /// reaching the storage reads.
    func testSecondCallInSameLaunch_returnsTrue() async {
        _ = await InstallIdempotency.checkAndArmInstallGuard(storage: storage)
        let second = await InstallIdempotency.checkAndArmInstallGuard(storage: storage)
        XCTAssertTrue(second)
    }

    func testConcurrentCalls_onlyOneSeesFalse() async {
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<8 {
                group.addTask { await InstallIdempotency.checkAndArmInstallGuard(storage: self.storage) }
            }
            var collected: [Bool] = []
            for await result in group { collected.append(result) }
            return collected
        }
        XCTAssertEqual(results.filter { $0 == false }.count, 1)
    }

    func testExistingInstallTrackedFlag_returnsTrue() async {
        await storage.set(PaywalloConstants.installTrackedKey, value: "1700000000000")
        let hasResidue = await InstallIdempotency.checkAndArmInstallGuard(storage: storage)
        XCTAssertTrue(hasResidue)
    }

    /// Residue left by an SDK version that used the `@panel:` prefix, written through the
    /// regular storage layer.
    func testLegacyFlagResidue_returnsTrue() async {
        native.set(PaywalloConstants.legacyInstallTrackedKey, value: "1")
        let hasResidue = await InstallIdempotency.checkAndArmInstallGuard(storage: storage)
        XCTAssertTrue(hasResidue)
    }

    // MARK: - markInstallTracked

    func testMarkInstallTracked_writesTimestampInBothLayers() async {
        await InstallIdempotency.markInstallTracked(storage: storage, installedAt: 1_700_000_000_123)

        let secure = await storage.get(PaywalloConstants.installTrackedKey)
        XCTAssertEqual(secure, "1700000000123")
        XCTAssertEqual(native.get(PaywalloConstants.legacyInstallTrackedKey), "1700000000123")
    }

    // MARK: - resolveInstallEventId

    /// appKey FIRST in the seed — the RN SDK builds `"{appKey}:{stableKey}"` and the two
    /// must derive the same id.
    func testDeterministicFromAppKeyAndDeviceKey() async {
        let id = await InstallIdempotency.resolveInstallEventId(
            deviceKey: "idfv-1", appKey: "appkey", storage: storage
        )
        XCTAssertEqual(id, deterministicUUID("appkey:idfv-1"))
    }

    func testStableAcrossCalls() async {
        let first = await InstallIdempotency.resolveInstallEventId(
            deviceKey: "idfv-1", appKey: "appkey", storage: storage
        )
        let second = await InstallIdempotency.resolveInstallEventId(
            deviceKey: "idfv-1", appKey: "appkey", storage: storage
        )
        XCTAssertEqual(first, second)
    }

    func testDifferentAppKey_differentId() async {
        let a = await InstallIdempotency.resolveInstallEventId(deviceKey: "idfv-1", appKey: "a", storage: storage)
        let b = await InstallIdempotency.resolveInstallEventId(deviceKey: "idfv-1", appKey: "b", storage: storage)
        XCTAssertNotEqual(a, b)
    }

    /// Android ID survives a GAID reset, so it outranks the ad-derived device key.
    func testAndroidIdTakesPrecedenceOverDeviceKey() async {
        let id = await InstallIdempotency.resolveInstallEventId(
            deviceKey: "idfv-1", appKey: "appkey", androidId: "android-1", storage: storage
        )
        XCTAssertEqual(id, deterministicUUID("appkey:android-1"))
    }

    func testBlankAndroidIdFallsBackToDeviceKey() async {
        let id = await InstallIdempotency.resolveInstallEventId(
            deviceKey: "idfv-1", appKey: "appkey", androidId: "   ", storage: storage
        )
        XCTAssertEqual(id, deterministicUUID("appkey:idfv-1"))
    }

    /// Without the epoch in the seed the id comes from hardware, never changes on reset,
    /// and the server drops the "new" install on event_id dedup.
    func testDevResetEpochRotatesTheId() async {
        let before = await InstallIdempotency.resolveInstallEventId(
            deviceKey: "idfv-1", appKey: "appkey", storage: storage
        )
        native.set(PaywalloConstants.devResetEpochKey, value: "1700000000000")
        let after = await InstallIdempotency.resolveInstallEventId(
            deviceKey: "idfv-1", appKey: "appkey", storage: storage
        )
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after, deterministicUUID("appkey:idfv-1:1700000000000"))
    }

    /// The random fallback CANNOT be re-derived, so it is the only variant that persists.
    func testNoDeviceKey_generatesAndPersistsRandomId() async {
        let first = await InstallIdempotency.resolveInstallEventId(
            deviceKey: nil, appKey: "appkey", storage: storage
        )
        XCTAssertEqual(native.get(PaywalloConstants.installEventIdKey), first)

        let second = await InstallIdempotency.resolveInstallEventId(
            deviceKey: nil, appKey: "appkey", storage: storage
        )
        XCTAssertEqual(first, second)
    }

    func testDeterministicIdIsNotPersisted() async {
        _ = await InstallIdempotency.resolveInstallEventId(
            deviceKey: "idfv-1", appKey: "appkey", storage: storage
        )
        XCTAssertNil(native.get(PaywalloConstants.installEventIdKey))
    }

    func testLegacyEventIdIsMigratedSilently() async {
        native.set(PaywalloConstants.legacyInstallEventIdKey, value: "legacy-event-id")
        let id = await InstallIdempotency.getOrCreateInstallEventId(storage: storage)
        XCTAssertEqual(id, "legacy-event-id")
        XCTAssertEqual(native.get(PaywalloConstants.installEventIdKey), "legacy-event-id")
    }

    // MARK: - classifyInstallAttempt

    func testClassifyNoResidue_isNewInstall() async {
        let classification = await InstallIdempotency.classifyInstallAttempt(
            storage: storage,
            params: ClassifyInstallAttemptParams(hasResidue: false, currentAppVersion: "1.0.0")
        )
        XCTAssertEqual(classification, .newInstall)
    }

    func testClassifyResidue_versionBump_isAppUpdate() async {
        await storage.set(PaywalloConstants.installAppVersionKey, value: "1.0.0")
        let classification = await InstallIdempotency.classifyInstallAttempt(
            storage: storage,
            params: ClassifyInstallAttemptParams(hasResidue: true, currentAppVersion: "2.0.0")
        )
        XCTAssertEqual(classification, .appUpdate)
    }

    /// Mandatory side effect: without rewriting APP_VERSION, one real version bump would
    /// mislabel every relaunch after it as `app_update` forever.
    func testStoredAppVersionIsRewrittenOnChange() async {
        await storage.set(PaywalloConstants.installAppVersionKey, value: "1.0.0")
        _ = await InstallIdempotency.classifyInstallAttempt(
            storage: storage,
            params: ClassifyInstallAttemptParams(hasResidue: true, currentAppVersion: "2.0.0")
        )
        let stored = await storage.get(PaywalloConstants.installAppVersionKey)
        XCTAssertEqual(stored, "2.0.0")

        let second = await InstallIdempotency.classifyInstallAttempt(
            storage: storage,
            params: ClassifyInstallAttemptParams(hasResidue: true, currentAppVersion: "2.0.0")
        )
        XCTAssertEqual(second, .relaunch)
    }

    func testStoredAppVersionIsWrittenEvenWithoutResidue() async {
        _ = await InstallIdempotency.classifyInstallAttempt(
            storage: storage,
            params: ClassifyInstallAttemptParams(hasResidue: false, currentAppVersion: "3.1.4")
        )
        let stored = await storage.get(PaywalloConstants.installAppVersionKey)
        XCTAssertEqual(stored, "3.1.4")
    }

    /// The last install timestamp comes from INSTALL_TRACKED, so a capture older than it
    /// is not a new signal.
    func testCaptureOlderThanLastInstall_doesNotOverrideResidue() async {
        let installedAt: Double = Date().timeIntervalSince1970 * 1000
        await InstallIdempotency.markInstallTracked(storage: storage, installedAt: installedAt)
        await storage.set(PaywalloConstants.installAppVersionKey, value: "1.0.0")

        let olderIso = ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: (installedAt - 60_000) / 1000)
        )
        let classification = await InstallIdempotency.classifyInstallAttempt(
            storage: storage,
            params: ClassifyInstallAttemptParams(
                hasResidue: true,
                attributionCapturedAtIso: olderIso,
                currentAppVersion: "1.0.0"
            )
        )
        XCTAssertEqual(classification, .relaunch)
    }

    func testMalformedCapturedAtIsIgnored() async {
        let classification = await InstallIdempotency.classifyInstallAttempt(
            storage: storage,
            params: ClassifyInstallAttemptParams(
                hasResidue: false,
                attributionCapturedAtIso: "not-a-date",
                currentAppVersion: "1.0.0"
            )
        )
        XCTAssertEqual(classification, .newInstall)
    }

    // MARK: - clearInstallState

    /// Every key must leave through the SAME layer that wrote it. The bug this covers:
    /// `SecureStorage.remove` re-prefixes with `@paywallo:`, so calling it on a key
    /// written by `NativeStorage.set` deletes nothing and the reset stops half-way.
    func testClearRemovesBothStorageLayers() async {
        await storage.set(PaywalloConstants.installTrackedKey, value: "1")
        await storage.set(PaywalloConstants.deferredMatchDoneKey, value: "1")
        await storage.set(PaywalloConstants.deferredMatchStateKey, value: "{}")
        await storage.set(PaywalloConstants.installAppVersionKey, value: "1.0.0")
        await storage.set(PaywalloConstants.anonIdKey, value: "anon-1")
        native.set(PaywalloConstants.appInstalledSentKey, value: "1")
        native.set(PaywalloConstants.installEventIdKey, value: "event-1")
        native.set(PaywalloConstants.legacyInstallTrackedKey, value: "1")
        native.set(PaywalloConstants.legacyInstallEventIdKey, value: "event-legacy")
        native.set(PaywalloConstants.legacyDeferredMatchDoneKey, value: "1")
        native.set(PaywalloConstants.legacyAnonIdCurrentKey, value: "anon-legacy")

        await InstallIdempotency.clearInstallState(storage: storage)

        let secureLeftovers = await [
            storage.get(PaywalloConstants.installTrackedKey),
            storage.get(PaywalloConstants.deferredMatchDoneKey),
            storage.get(PaywalloConstants.deferredMatchStateKey),
            storage.get(PaywalloConstants.installAppVersionKey),
            storage.get(PaywalloConstants.anonIdKey),
        ]
        XCTAssertEqual(secureLeftovers.compactMap { $0 }, [])

        for key in [
            PaywalloConstants.appInstalledSentKey,
            PaywalloConstants.installEventIdKey,
            PaywalloConstants.legacyInstallTrackedKey,
            PaywalloConstants.legacyInstallEventIdKey,
            PaywalloConstants.legacyDeferredMatchDoneKey,
            PaywalloConstants.legacyAnonIdCurrentKey,
        ] {
            XCTAssertNil(native.get(key), "\(key) survived the reset")
        }
    }

    func testClearStampsDevResetEpoch() async {
        await InstallIdempotency.clearInstallState(storage: storage)
        XCTAssertNotNil(native.get(PaywalloConstants.devResetEpochKey))
    }

    func testClearRearmsTheLaunchGuard() async {
        _ = await InstallIdempotency.checkAndArmInstallGuard(storage: storage)
        await InstallIdempotency.clearInstallState(storage: storage)
        let hasResidue = await InstallIdempotency.checkAndArmInstallGuard(storage: storage)
        XCTAssertFalse(hasResidue)
    }
}
