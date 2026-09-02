import XCTest
@testable import PaywalloSDK

// MARK: - classifyInstall matrix

final class InstallClassifierTests: XCTestCase {

    private func classify(
        hasResidue: Bool,
        hasNewSignal: Bool = false,
        storedAppVersion: String? = "1.0.0",
        currentAppVersion: String? = "1.0.0",
        isClockFresh: Bool? = nil
    ) -> InstallClassification {
        classifyInstall(
            InstallClassificationInput(
                hasResidue: hasResidue,
                hasNewSignal: hasNewSignal,
                storedAppVersion: storedAppVersion,
                currentAppVersion: currentAppVersion,
                isClockFresh: isClockFresh
            )
        )
    }

    func testNoResidue_isNewInstall() {
        XCTAssertEqual(classify(hasResidue: false), .newInstall)
    }

    func testNoResidue_staleClock_noSignal_isStaleRestore() {
        XCTAssertEqual(classify(hasResidue: false, hasNewSignal: false, isClockFresh: false), .staleRestore)
    }

    /// A campaign signal is stronger evidence than a restored device clock, so it always
    /// wins the freshness gate.
    func testNoResidue_staleClock_withSignal_isNewInstall() {
        XCTAssertEqual(classify(hasResidue: false, hasNewSignal: true, isClockFresh: false), .newInstall)
    }

    func testNoResidue_freshClock_isNewInstall() {
        XCTAssertEqual(classify(hasResidue: false, isClockFresh: true), .newInstall)
    }

    /// Absent freshness data must never gate — only an explicit mismatch does.
    func testNoResidue_nilClockFresh_isNewInstall() {
        XCTAssertEqual(classify(hasResidue: false, isClockFresh: nil), .newInstall)
    }

    func testResidue_sameVersion_isRelaunch() {
        XCTAssertEqual(classify(hasResidue: true, storedAppVersion: "2.0.0", currentAppVersion: "2.0.0"), .relaunch)
    }

    func testResidue_versionBump_isAppUpdate() {
        XCTAssertEqual(classify(hasResidue: true, storedAppVersion: "1.0.0", currentAppVersion: "2.0.0"), .appUpdate)
    }

    func testResidue_missingStoredVersion_isUnknownResidue() {
        XCTAssertEqual(classify(hasResidue: true, storedAppVersion: nil), .unknownResidue)
    }

    func testResidue_missingCurrentVersion_isUnknownResidue() {
        XCTAssertEqual(classify(hasResidue: true, currentAppVersion: nil), .unknownResidue)
    }

    /// Decision 12/08: a reinstall never fires, click or not. A new campaign signal does
    /// NOT override residue.
    func testResidue_withNewSignal_stillDoesNotBecomeNewInstall() {
        XCTAssertEqual(classify(hasResidue: true, hasNewSignal: true), .relaunch)
        XCTAssertEqual(
            classify(hasResidue: true, hasNewSignal: true, storedAppVersion: "1.0.0", currentAppVersion: "2.0.0"),
            .appUpdate
        )
    }

    // MARK: shouldFireInstall

    func testOnlyNewInstallFires() {
        XCTAssertTrue(shouldFireInstall(.newInstall))
        for classification: InstallClassification in [.reinstallAttributed, .appUpdate, .relaunch, .unknownResidue, .staleRestore] {
            XCTAssertFalse(shouldFireInstall(classification), "\(classification) must not fire")
        }
    }
}

// MARK: - hasNewCampaignSignal

final class InstallCampaignSignalTests: XCTestCase {

    private let now: Double = 1_700_000_000_000

    private func hasSignal(
        lastInstallAtMs: Double?,
        referrerClickTimestampSeconds: Double? = nil,
        attributionCapturedAtMs: Double? = nil
    ) -> Bool {
        hasNewCampaignSignal(
            CampaignSignalInput(
                lastInstallAtMs: lastInstallAtMs,
                referrerClickTimestampSeconds: referrerClickTimestampSeconds,
                attributionCapturedAtMs: attributionCapturedAtMs,
                now: now
            )
        )
    }

    func testNoSignals_isFalse() {
        XCTAssertFalse(hasSignal(lastInstallAtMs: now - 1000))
    }

    func testClickNewerThanLastInstall_isTrue() {
        XCTAssertTrue(hasSignal(lastInstallAtMs: now - 10_000, referrerClickTimestampSeconds: now / 1000))
    }

    func testClickOlderThanLastInstall_isFalse() {
        XCTAssertFalse(hasSignal(lastInstallAtMs: now, referrerClickTimestampSeconds: (now - 60_000) / 1000))
    }

    func testClickWithoutPriorInstall_isTrue() {
        XCTAssertTrue(hasSignal(lastInstallAtMs: nil, referrerClickTimestampSeconds: (now - 999_999_999) / 1000))
    }

    func testRecentCapture_isTrue() {
        XCTAssertTrue(hasSignal(lastInstallAtMs: now - 100_000, attributionCapturedAtMs: now - 1000))
    }

    /// Older than the 24h click window — a deep link opened last week is not evidence of
    /// a click that caused this install.
    func testCaptureOutsideWindow_isFalse() {
        XCTAssertFalse(hasSignal(lastInstallAtMs: nil, attributionCapturedAtMs: now - 25 * 60 * 60 * 1000))
    }

    func testCaptureOlderThanLastInstall_isFalse() {
        XCTAssertFalse(hasSignal(lastInstallAtMs: now - 1000, attributionCapturedAtMs: now - 5000))
    }
}

// MARK: - isInstallClockFresh

final class InstallClockFreshnessTests: XCTestCase {

    private let now: Double = 1_700_000_000_000

    private func isFresh(first: Double?, sdk: Double?, lastUpdate: Double? = nil) -> Bool {
        isInstallClockFresh(
            InstallClockFreshnessInput(
                packageFirstInstallAtMs: first,
                sdkFirstRunAtMs: sdk,
                packageLastUpdateAtMs: lastUpdate
            )
        )
    }

    /// On iOS both package timestamps are nil, so the gate is inert by design.
    func testMissingPackageData_isFresh() {
        XCTAssertTrue(isFresh(first: nil, sdk: now))
    }

    func testMissingSdkMarker_isFresh() {
        XCTAssertTrue(isFresh(first: now, sdk: nil))
    }

    func testWithin24h_isFresh() {
        XCTAssertTrue(isFresh(first: now, sdk: now + 23 * 60 * 60 * 1000))
    }

    func testBeyond24h_isNotFresh() {
        XCTAssertFalse(isFresh(first: now, sdk: now + 48 * 60 * 60 * 1000))
    }

    /// Side-load-then-update: firstInstallTime predates SDK integration, lastUpdateTime
    /// corroborates it.
    func testLastUpdateRescuesStaleFirstInstall() {
        let sdkFirstRun = now + 48 * 60 * 60 * 1000
        XCTAssertTrue(isFresh(first: now, sdk: sdkFirstRun, lastUpdate: sdkFirstRun - 1000))
    }
}

// MARK: - signals snapshot round-trip

final class InstallClassificationSignalsTests: XCTestCase {

    func testHasAppVersionKeyIsDerivedFromPreviousAppVersion() {
        let withVersion = buildInstallClassificationSignals(
            hasInstallTrackedKey: true,
            hasLegacyInstallTrackedKey: false,
            previousAppVersion: "1.0.0",
            idfvChanged: false,
            syncedIdentityKeyExists: false
        )
        XCTAssertTrue(withVersion.hasAppVersionKey)

        let withoutVersion = buildInstallClassificationSignals(
            hasInstallTrackedKey: true,
            hasLegacyInstallTrackedKey: false,
            previousAppVersion: nil,
            idfvChanged: false,
            syncedIdentityKeyExists: false
        )
        XCTAssertFalse(withoutVersion.hasAppVersionKey)
    }

    /// One nested object, not a flattened spread — the server's boundedProperties budget
    /// is 50 top-level keys and `$app_installed` already spends most of it.
    func testToPayloadCarriesEveryField() {
        let payload = buildInstallClassificationSignals(
            hasInstallTrackedKey: true,
            hasLegacyInstallTrackedKey: true,
            previousAppVersion: "1.2.3",
            idfvChanged: true,
            syncedIdentityKeyExists: true
        ).toPayload()

        XCTAssertEqual(payload["hasInstallTrackedKey"] as? Bool, true)
        XCTAssertEqual(payload["hasLegacyInstallTrackedKey"] as? Bool, true)
        XCTAssertEqual(payload["hasAppVersionKey"] as? Bool, true)
        XCTAssertEqual(payload["previousAppVersion"] as? String, "1.2.3")
        XCTAssertEqual(payload["idfvChanged"] as? Bool, true)
        XCTAssertEqual(payload["syncedIdentityKeyExists"] as? Bool, true)
        XCTAssertEqual(payload.count, 8)
    }

    /// The signals ride inside ONE `AnyCodable`, which re-wraps each value. An
    /// `AnyCodable` holding an `AnyCodable` — or a boxed `Optional.none` — matches none of
    /// its encode cases and throws, failing the encode of the WHOLE `$app_installed` body.
    /// Absent values must therefore be `NSNull`, and no value may already be an AnyCodable.
    func testToPayloadSurvivesJsonEncodingWhenNested() throws {
        let signals = buildInstallClassificationSignals(
            hasInstallTrackedKey: false,
            hasLegacyInstallTrackedKey: false,
            previousAppVersion: nil,
            idfvChanged: false,
            syncedIdentityKeyExists: false
        )

        let encoded = try JSONEncoder().encode(["installSignals": AnyCodable(signals.toPayload())])
        let decoded = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let nested = decoded?["installSignals"] as? [String: Any]

        XCTAssertEqual(nested?["hasInstallTrackedKey"] as? Bool, false)
        XCTAssertTrue(nested?["previousAppVersion"] is NSNull)
    }

    /// The snapshot alone must be enough to reclassify later, without live storage.
    func testClassifyFromSignalsReproducesTheDecision() {
        let signals = buildInstallClassificationSignals(
            hasInstallTrackedKey: true,
            hasLegacyInstallTrackedKey: false,
            previousAppVersion: "1.0.0",
            idfvChanged: false,
            syncedIdentityKeyExists: false
        )
        XCTAssertEqual(
            classifyInstallFromSignals(signals: signals, hasNewSignal: false, currentAppVersion: "2.0.0"),
            .appUpdate
        )
        XCTAssertEqual(
            classifyInstallFromSignals(signals: signals, hasNewSignal: false, currentAppVersion: "1.0.0"),
            .relaunch
        )
    }

    func testClassifyFromSignals_noResidue_isNewInstall() {
        let signals = buildInstallClassificationSignals(
            hasInstallTrackedKey: false,
            hasLegacyInstallTrackedKey: false,
            previousAppVersion: nil,
            idfvChanged: false,
            syncedIdentityKeyExists: false
        )
        XCTAssertEqual(
            classifyInstallFromSignals(signals: signals, hasNewSignal: false, currentAppVersion: "1.0.0"),
            .newInstall
        )
    }

    /// The legacy `@panel:` flag is residue too — SDKs that wrote it must not re-fire.
    func testLegacyFlagAloneCountsAsResidue() {
        let signals = buildInstallClassificationSignals(
            hasInstallTrackedKey: false,
            hasLegacyInstallTrackedKey: true,
            previousAppVersion: "1.0.0",
            idfvChanged: false,
            syncedIdentityKeyExists: false
        )
        XCTAssertEqual(
            classifyInstallFromSignals(signals: signals, hasNewSignal: true, currentAppVersion: "1.0.0"),
            .relaunch
        )
    }
}
