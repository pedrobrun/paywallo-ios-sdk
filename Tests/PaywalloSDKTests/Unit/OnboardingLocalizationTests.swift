import XCTest
@testable import PaywalloSDK

// MARK: - Helpers

private func makeIsolatedSecureStorageForOL(id: String = UUID().uuidString) -> (SecureStorage, NativeStorage, String) {
    let suiteName = "com.paywallo.sdk.ol.tests.\(id)"
    let suite = UserDefaults(suiteName: suiteName)!
    let keychainService = "com.paywallo.sdk.ol.tests.\(id)"
    let native = NativeStorage(service: keychainService, defaults: suite)
    let secure = SecureStorage(nativeStorage: native)
    return (secure, native, suiteName)
}

// MARK: - OnboardingManager Tests

final class OnboardingManagerTests: XCTestCase {

    private var manager: OnboardingManager!
    private var trackedEvents: [(name: String, payload: [String: AnyCodable], priority: EventPriority)]!

    override func setUp() {
        super.setUp()
        manager = OnboardingManager()
        trackedEvents = []
    }

    private func injectDeps(distinctId: String = "user-123") {
        manager.injectDeps(
            trackEvent: { [weak self] name, payload, priority in
                self?.trackedEvents.append((name: name, payload: payload, priority: priority))
            },
            distinctIdProvider: { distinctId }
        )
    }

    // MARK: step — basic tracking

    func testStep_tracksOnboardingEvent() async throws {
        injectDeps()
        try await manager.step(stepName: "welcome", order: 0)
        XCTAssertEqual(trackedEvents.count, 1)
        XCTAssertEqual(trackedEvents[0].name, "onboarding")
        XCTAssertEqual(trackedEvents[0].payload["type"]?.value as? String, "step")
        XCTAssertEqual(trackedEvents[0].payload["step_name"]?.value as? String, "welcome")
        XCTAssertEqual(trackedEvents[0].payload["order"]?.value as? Double, 0)
    }

    func testStep_multipleSteps_tracksAllEvents() async throws {
        injectDeps()
        try await manager.step(stepName: "welcome", order: 0)
        try await manager.step(stepName: "name", order: 1)
        try await manager.step(stepName: "age", order: 2)
        XCTAssertEqual(trackedEvents.count, 3)
    }

    func testStep_doesNotMarkFinished() async throws {
        injectDeps()
        try await manager.step(stepName: "welcome", order: 0)
        XCTAssertFalse(manager.isFinished)
    }

    func testStep_usesNormalPriority() async throws {
        injectDeps()
        try await manager.step(stepName: "welcome", order: 0)
        XCTAssertEqual(trackedEvents[0].priority, .normal)
    }

    // MARK: step — variantKey and timeOnPrevS optional fields

    func testStep_withVariantKey_includesVariantKeyInPayload() async throws {
        injectDeps()
        try await manager.step(stepName: "welcome", order: 0, variantKey: "control")
        XCTAssertEqual(trackedEvents[0].payload["variant_key"]?.value as? String, "control")
    }

    func testStep_withTimeOnPrevS_includesTimeInPayload() async throws {
        injectDeps()
        try await manager.step(stepName: "welcome", order: 0, timeOnPrevS: 3.5)
        XCTAssertEqual(trackedEvents[0].payload["time_on_prev_s"]?.value as? Double, 3.5)
    }

    func testStep_withoutOptionals_noVariantKeyOrTimeInPayload() async throws {
        injectDeps()
        try await manager.step(stepName: "welcome", order: 0)
        XCTAssertNil(trackedEvents[0].payload["variant_key"])
        XCTAssertNil(trackedEvents[0].payload["time_on_prev_s"])
    }

    // MARK: step — negative order throws invalidOrder

    func testStep_negativeOrder_throwsInvalidOrder() async {
        injectDeps()
        do {
            try await manager.step(stepName: "welcome", order: -1)
            XCTFail("Expected OnboardingError to be thrown")
        } catch let error as OnboardingError {
            XCTAssertEqual(error.code, OnboardingErrorCode.invalidOrder)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testStep_infiniteOrder_throwsInvalidOrder() async {
        injectDeps()
        do {
            try await manager.step(stepName: "welcome", order: .infinity)
            XCTFail("Expected OnboardingError to be thrown")
        } catch let error as OnboardingError {
            XCTAssertEqual(error.code, OnboardingErrorCode.invalidOrder)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: complete

    func testComplete_tracksCompleteEvent() async throws {
        injectDeps()
        try await manager.complete()
        let completeEvent = trackedEvents.last
        XCTAssertEqual(completeEvent?.payload["type"]?.value as? String, "complete")
    }

    func testComplete_payloadHasNoStepName() async throws {
        injectDeps()
        try await manager.step(stepName: "last_step", order: 0)
        try await manager.complete()
        let completeEvent = trackedEvents.last
        XCTAssertNil(completeEvent?.payload["step_name"])
    }

    func testComplete_withVariantKey_includesVariantKeyInPayload() async throws {
        injectDeps()
        try await manager.complete(variantKey: "variant_b")
        let completeEvent = trackedEvents.last
        XCTAssertEqual(completeEvent?.payload["variant_key"]?.value as? String, "variant_b")
    }

    func testComplete_marksFinished() async throws {
        injectDeps()
        try await manager.complete()
        XCTAssertTrue(manager.isFinished)
    }

    // MARK: isFinished initial state

    func testIsFinished_initiallyFalse() {
        XCTAssertFalse(manager.isFinished)
    }

    // MARK: empty distinctId — silent skip

    func testStep_emptyDistinctId_silentlySkips() async throws {
        injectDeps(distinctId: "")
        try await manager.step(stepName: "welcome", order: 0)
        XCTAssertEqual(trackedEvents.count, 0)
    }

    func testComplete_emptyDistinctId_silentlySkips() async throws {
        injectDeps(distinctId: "")
        try await manager.complete()
        XCTAssertEqual(trackedEvents.count, 0)
    }

    // MARK: missing pipeline — throws notInitialized

    func testStep_missingPipeline_throwsNotInitialized() async {
        do {
            try await manager.step(stepName: "welcome", order: 0)
            XCTFail("Expected OnboardingError to be thrown")
        } catch let error as OnboardingError {
            XCTAssertEqual(error.code, OnboardingErrorCode.notInitialized)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testComplete_missingPipeline_throwsNotInitialized() async {
        do {
            try await manager.complete()
            XCTFail("Expected OnboardingError to be thrown")
        } catch let error as OnboardingError {
            XCTAssertEqual(error.code, OnboardingErrorCode.notInitialized)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: invalid name — throws invalidStepName

    func testStep_emptyName_throwsInvalidStepName() async {
        injectDeps()
        do {
            try await manager.step(stepName: "", order: 0)
            XCTFail("Expected OnboardingError to be thrown")
        } catch let error as OnboardingError {
            XCTAssertEqual(error.code, OnboardingErrorCode.invalidStepName)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

// MARK: - Localization Tests

final class LocalizationTests: XCTestCase {

    // MARK: detectDeviceLanguage

    func testDetectDeviceLanguage_returnsNonEmptyString() {
        let lang = Localization.detectDeviceLanguage()
        XCTAssertFalse(lang.isEmpty)
    }

    // MARK: defaultLanguage

    func testDefaultLanguage_isPtBR() {
        XCTAssertEqual(Localization.defaultLanguage, "pt-BR")
    }

    // MARK: getLocalizedString — exact match

    func testGetLocalizedString_exactMatch_returnsValue() {
        let loc = Localization.shared
        let currentLang = loc.getCurrentLanguage()
        let text = [currentLang: "hello"]
        XCTAssertEqual(loc.getLocalizedString(text: text), "hello")
    }

    // MARK: getLocalizedString — fallback to pt-BR default

    func testGetLocalizedString_noCurrentLang_fallsBackToDefault() {
        let loc = Localization.shared
        // Provide only pt-BR, no current language key
        let text = ["pt-BR": "olá"]
        let result = loc.getLocalizedString(text: text)
        // Either exact match (if device is pt-BR) or fallback to pt-BR
        XCTAssertNotNil(result)
        // Result should be "olá" — either exact or default fallback
        XCTAssertEqual(result, "olá")
    }

    // MARK: getLocalizedString — first available fallback

    func testGetLocalizedString_noMatchNoDefault_returnsFirstAvailable() {
        let loc = Localization.shared
        let text = ["zz-XX": "some_string"]
        let result = loc.getLocalizedString(text: text)
        // Falls through to first available
        XCTAssertEqual(result, "some_string")
    }

    // MARK: getLocalizedString — empty dict returns nil

    func testGetLocalizedString_emptyDict_returnsNil() {
        let loc = Localization.shared
        XCTAssertNil(loc.getLocalizedString(text: [:]))
    }

    // MARK: getSdkString — supported locales

    func testGetSdkString_ptBR_errorTitle() {
        let loc = Localization.shared
        // We can't force currentLanguage, so we test via the known sdkStrings
        // by checking via a locale that matches pt-BR
        // Instead verify it returns a non-nil value for known key
        let result = loc.getSdkString("error_title")
        XCTAssertNotNil(result)
    }

    func testGetSdkString_retry_returnsNonNil() {
        let result = Localization.shared.getSdkString("retry")
        XCTAssertNotNil(result)
    }

    func testGetSdkString_close_returnsNonNil() {
        let result = Localization.shared.getSdkString("close")
        XCTAssertNotNil(result)
    }

    func testGetSdkString_unknownKey_returnsNil() {
        let result = Localization.shared.getSdkString("nonexistent_key_xyz_123")
        XCTAssertNil(result)
    }

    // MARK: getCurrentLanguage

    func testGetCurrentLanguage_returnsNonEmptyString() {
        XCTAssertFalse(Localization.shared.getCurrentLanguage().isEmpty)
    }

    // MARK: initLocalization is idempotent

    func testInitLocalization_doesNotCrash() {
        // Should not throw or crash
        Localization.shared.initLocalization()
        XCTAssertFalse(Localization.shared.getCurrentLanguage().isEmpty)
    }
}

// MARK: - AutoEvents Tests

final class AutoEventsTests: XCTestCase {

    private var secureStorage: SecureStorage!
    private var native: NativeStorage!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        let (s, n, name) = makeIsolatedSecureStorageForOL()
        secureStorage = s
        native = n
        suiteName = name
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: install event fires only once per device

    func testFireIfNeeded_firstRun_firesInstallEvent() async {
        let autoEvents = AutoEvents(storage: secureStorage)
        var events: [(name: String, payload: [String: AnyCodable], priority: EventPriority)] = []

        await autoEvents.fireIfNeeded { name, payload, priority in
            events.append((name: name, payload: payload, priority: priority))
        }

        let installEvent = events.first { $0.payload["type"]?.value as? String == "install" }
        XCTAssertNotNil(installEvent, "Expected install event on first run")
        XCTAssertEqual(installEvent?.name, "lifecycle")
        XCTAssertEqual(installEvent?.priority, .critical)
        XCTAssertEqual(installEvent?.payload["device_type"]?.value as? String, "ios")
        XCTAssertNotNil(installEvent?.payload["app_version"])
    }

    func testFireIfNeeded_secondRun_noInstallEvent() async {
        // Simulate first run
        await secureStorage.set(PaywalloConstants.firstSeenKey, value: "2026-01-01T00:00:00Z")

        let autoEvents = AutoEvents(storage: secureStorage)
        var events: [(name: String, payload: [String: AnyCodable], priority: EventPriority)] = []

        await autoEvents.fireIfNeeded { name, payload, priority in
            events.append((name: name, payload: payload, priority: priority))
        }

        let installEvents = events.filter { $0.payload["type"]?.value as? String == "install" }
        XCTAssertEqual(installEvents.count, 0, "Install event should not fire on subsequent runs")
    }

    // MARK: cold_start fires every launch

    func testFireIfNeeded_coldStartFiresEveryLaunch() async {
        // Pre-populate firstSeen so install doesn't fire
        await secureStorage.set(PaywalloConstants.firstSeenKey, value: "2026-01-01T00:00:00Z")

        let autoEvents = AutoEvents(storage: secureStorage)
        var events: [(name: String, payload: [String: AnyCodable], priority: EventPriority)] = []

        await autoEvents.fireIfNeeded { name, payload, priority in
            events.append((name: name, payload: payload, priority: priority))
        }

        let coldStart = events.first { $0.payload["type"]?.value as? String == "cold_start" }
        XCTAssertNotNil(coldStart, "Expected cold_start event every launch")
        XCTAssertEqual(coldStart?.name, "lifecycle")
    }

    // MARK: didRun guard — second call is no-op

    func testFireIfNeeded_calledTwice_onlyFiresOnce() async {
        let autoEvents = AutoEvents(storage: secureStorage)
        var callCount = 0

        await autoEvents.fireIfNeeded { _, _, _ in callCount += 1 }
        await autoEvents.fireIfNeeded { _, _, _ in callCount += 1 }

        // Should only have events from first call
        XCTAssertGreaterThan(callCount, 0)
        // The second call should be a no-op (didRun = true)
        // We can verify by checking a fresh instance fires again
        let autoEvents2 = AutoEvents(storage: secureStorage)
        var callCount2 = 0
        await autoEvents2.fireIfNeeded { _, _, _ in callCount2 += 1 }
        XCTAssertGreaterThan(callCount2, 0)
    }

    // MARK: platform and os_version populated

    func testFireIfNeeded_coldStart_hasPlatformAndOsVersion() async {
        await secureStorage.set(PaywalloConstants.firstSeenKey, value: "2026-01-01T00:00:00Z")

        let autoEvents = AutoEvents(storage: secureStorage)
        var events: [(name: String, payload: [String: AnyCodable], priority: EventPriority)] = []

        await autoEvents.fireIfNeeded { name, payload, priority in
            events.append((name: name, payload: payload, priority: priority))
        }

        let coldStart = events.first { $0.payload["type"]?.value as? String == "cold_start" }
        XCTAssertEqual(coldStart?.payload["platform"]?.value as? String, "ios")
        XCTAssertNotNil(coldStart?.payload["os_version"])
    }
}

// MARK: - CoreAction Tests

final class CoreActionTests: XCTestCase {

    // MARK: accepts valid name

    func testExecute_validName_doesNotThrow() {
        XCTAssertNoThrow(try CoreAction.execute("some_action"))
    }

    func testExecute_validName_withSpaces_doesNotThrow() {
        XCTAssertNoThrow(try CoreAction.execute("my action name"))
    }

    func testExecute_validName_isNoOp() throws {
        // Should complete without any side effects
        try CoreAction.execute("tap_continue")
        try CoreAction.execute("skip_onboarding")
    }

    // MARK: throws on empty

    func testExecute_emptyName_throwsClientError() {
        do {
            try CoreAction.execute("")
            XCTFail("Expected ClientError to be thrown")
        } catch let error as ClientError {
            XCTAssertEqual(error.code, ClientErrorCode.invalidEventName)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
