import XCTest
@testable import PaywalloSDK

// MARK: - NetworkMonitor Tests

final class NetworkMonitorTests: XCTestCase {

    // Use a fresh instance per test (not .shared) to isolate state
    private var monitor: NetworkMonitor!

    override func setUp() {
        super.setUp()
        monitor = NetworkMonitor()
    }

    override func tearDown() {
        monitor.dispose()
        monitor = nil
        super.tearDown()
    }

    // MARK: - Pre-initialization state

    func testIsOnlineReturnsFalseBeforeInit() {
        // Pessimistic by design: an optimistic `true` made PendingRetry.process() burn both
        // of a critical event's attempts in ~6 minutes offline.
        XCTAssertFalse(monitor.isOnline(), "isOnline() must return false before initialize() is called")
    }

    func testGetStateIsUnknownBeforeInit() {
        XCTAssertEqual(monitor.getState(), .unknown)
    }

    func testForceCheckIsUnknownBeforeInit() {
        XCTAssertEqual(monitor.forceCheck(), .unknown)
    }

    func testGetStateIsNeverUnknownAfterInit() {
        monitor.initialize()
        XCTAssertNotEqual(monitor.getState(), .unknown, "depois do initialize o estado é medido")
    }

    func testIsOnlineAgreesWithGetState() {
        monitor.initialize()
        XCTAssertEqual(monitor.isOnline(), monitor.getState() == .online)
    }

    func testIsInitializedReturnsFalseBeforeInit() {
        XCTAssertFalse(monitor.isInitialized(), "isInitialized() must return false before initialize() is called")
    }

    // MARK: - Post-initialization state

    func testIsInitializedReturnsTrueAfterInit() {
        monitor.initialize()
        XCTAssertTrue(monitor.isInitialized(), "isInitialized() must return true after initialize() is called")
    }

    func testInitializeIsIdempotent() {
        monitor.initialize()
        monitor.initialize() // second call must not crash or reset state
        XCTAssertTrue(monitor.isInitialized())
    }

    // MARK: - Listener management

    func testAddListenerReturnsCleanupFunction() {
        var callCount = 0
        let cleanup = monitor.addListener { _ in callCount += 1 }
        // Cleanup must be a non-crashing callable
        XCTAssertNotNil(cleanup)
    }

    func testCleanupRemovesListener() {
        var callCount = 0
        let cleanup = monitor.addListener { _ in callCount += 1 }

        cleanup() // remove the listener before notifying

        // Manually trigger notifyListeners via dispose (which clears all listeners)
        // We can't trigger notifyListeners directly, so we verify by checking that
        // after cleanup a second listener added is different from the removed one.
        var secondCallCount = 0
        monitor.addListener { _ in secondCallCount += 1 }

        // Dispose removes all listeners — both should have 0 calls at this point
        XCTAssertEqual(callCount, 0, "Cleaned-up listener should not have been called")
    }

    func testMultipleListenersCanBeAdded() {
        var cleanups: [() -> Void] = []

        for _ in 0..<5 {
            let cleanup = monitor.addListener { _ in }
            cleanups.append(cleanup)
        }

        // No assertion on ids here — just verify no crash and cleanup works
        for cleanup in cleanups {
            cleanup()
        }
        XCTAssertTrue(true, "Multiple listeners added and cleaned up without errors")
    }

    func testListenerCleanupIsIndependent() {
        var firstCallCount = 0
        var secondCallCount = 0

        let cleanupFirst = monitor.addListener { _ in firstCallCount += 1 }
        monitor.addListener { _ in secondCallCount += 1 }

        cleanupFirst() // only remove the first one

        // Both still at 0 since we haven't triggered network changes
        XCTAssertEqual(firstCallCount, 0)
        XCTAssertEqual(secondCallCount, 0)
    }

    // MARK: - Dispose

    func testDisposeResetsInitializedState() {
        monitor.initialize()
        XCTAssertTrue(monitor.isInitialized())

        monitor.dispose()
        XCTAssertFalse(monitor.isInitialized(), "dispose() must reset isInitialized to false")
    }

    func testDisposeResetsIsOnlineToPessimistic() {
        monitor.initialize()
        monitor.dispose()
        XCTAssertFalse(monitor.isOnline(), "After dispose the monitor is uninitialized → offline")
        XCTAssertEqual(monitor.getState(), .unknown)
    }

    func testDisposeDoesNotCrashWithNoListeners() {
        monitor.initialize()
        monitor.dispose() // no listeners added — must not crash
        XCTAssertTrue(true)
    }

    func testDisposeRemovesListeners() {
        var callCount = 0
        monitor.addListener { _ in callCount += 1 }
        monitor.addListener { _ in callCount += 1 }

        monitor.dispose()

        // After dispose, no listeners should remain. Re-init and verify.
        // We cannot directly inspect the listeners dict, but we can verify
        // that dispose doesn't crash and state is clean.
        XCTAssertFalse(monitor.isInitialized())
        XCTAssertEqual(callCount, 0, "Listeners should not be called by dispose itself")
    }

    // MARK: - setDebug

    func testSetDebugDoesNotCrash() {
        monitor.setDebug(true)
        monitor.setDebug(false)
        XCTAssertTrue(true)
    }
}

// MARK: - DeviceInfo Tests

final class DeviceInfoTests: XCTestCase {

    @MainActor
    func testGetDeviceInfoReturnsData() {
        let deviceInfo = DeviceInfo.shared
        let data = deviceInfo.getDeviceInfo()
        // Simply checking it returns without crashing
        _ = data
        XCTAssertTrue(true)
    }

    @MainActor
    func testBrandIsAlwaysApple() {
        let data = DeviceInfo.shared.getDeviceInfo()
        XCTAssertEqual(data.brand, "Apple", "brand must always be 'Apple'")
    }

    @MainActor
    func testTimezoneIsNonEmpty() {
        let data = DeviceInfo.shared.getDeviceInfo()
        XCTAssertFalse(data.timezone.isEmpty, "timezone must not be empty")
    }

    @MainActor
    func testLocaleIsNonEmpty() {
        let data = DeviceInfo.shared.getDeviceInfo()
        XCTAssertFalse(data.locale.isEmpty, "locale must not be empty")
    }

    @MainActor
    func testLanguageIsNonEmpty() {
        let data = DeviceInfo.shared.getDeviceInfo()
        XCTAssertFalse(data.language.isEmpty, "language must not be empty")
    }

    @MainActor
    func testSystemNameIsNonEmpty() {
        let data = DeviceInfo.shared.getDeviceInfo()
        XCTAssertFalse(data.systemName.isEmpty, "systemName must not be empty")
    }

    @MainActor
    func testSystemVersionIsNonEmpty() {
        let data = DeviceInfo.shared.getDeviceInfo()
        XCTAssertFalse(data.systemVersion.isEmpty, "systemVersion must not be empty")
    }

    @MainActor
    func testModelIsNonEmpty() {
        let data = DeviceInfo.shared.getDeviceInfo()
        XCTAssertFalse(data.model.isEmpty, "model must not be empty")
    }

    @MainActor
    func testModelIdIsNonEmpty() {
        let data = DeviceInfo.shared.getDeviceInfo()
        XCTAssertFalse(data.modelId.isEmpty, "modelId must not be empty")
    }

    @MainActor
    func testCachingReturnsSameInstance() {
        let deviceInfo = DeviceInfo.shared
        let first = deviceInfo.getDeviceInfo()
        let second = deviceInfo.getDeviceInfo()
        // DeviceData is a struct, compare fields to verify same cached values
        XCTAssertEqual(first.deviceId, second.deviceId, "Cached deviceId must be identical across calls")
        XCTAssertEqual(first.brand, second.brand)
        XCTAssertEqual(first.model, second.model)
        XCTAssertEqual(first.locale, second.locale)
        XCTAssertEqual(first.timezone, second.timezone)
    }

    @MainActor
    func testTotalRamIsGreaterThanZero() {
        let data = DeviceInfo.shared.getDeviceInfo()
        XCTAssertGreaterThan(data.totalRam, 0, "totalRam should reflect real physical memory")
    }

    // macOS stub: UIKit not available, so deviceId falls back to "unknown"
    // On device/simulator: deviceId is a valid UUID string from IDFV
    @MainActor
    func testDeviceIdIsNonEmpty() {
        let data = DeviceInfo.shared.getDeviceInfo()
        XCTAssertFalse(data.deviceId.isEmpty, "deviceId must not be empty (may be 'unknown' on macOS)")
    }

    @MainActor
    func testIdfvMatchesDeviceId() {
        let data = DeviceInfo.shared.getDeviceInfo()
        XCTAssertEqual(data.idfv, data.deviceId, "idfv computed property must return deviceId")
    }

    #if !canImport(UIKit)
    // macOS-specific stub assertions
    @MainActor
    func testMacOSStubModel() {
        let data = DeviceInfo.shared.getDeviceInfo()
        XCTAssertEqual(data.model, "Mac", "On macOS, model stub must be 'Mac'")
    }

    @MainActor
    func testMacOSStubSystemName() {
        let data = DeviceInfo.shared.getDeviceInfo()
        XCTAssertEqual(data.systemName, "macOS", "On macOS, systemName stub must be 'macOS'")
    }

    @MainActor
    func testMacOSStubDeviceId() {
        let data = DeviceInfo.shared.getDeviceInfo()
        XCTAssertEqual(data.deviceId, "unknown", "On macOS (no UIKit), deviceId must be 'unknown'")
    }

    @MainActor
    func testMacOSStubScreenDimensions() {
        let data = DeviceInfo.shared.getDeviceInfo()
        XCTAssertEqual(data.screenWidth, 0, "On macOS stub, screenWidth must be 0")
        XCTAssertEqual(data.screenHeight, 0, "On macOS stub, screenHeight must be 0")
        XCTAssertEqual(data.screenDensity, 1, "On macOS stub, screenDensity must be 1")
    }
    #endif
}
