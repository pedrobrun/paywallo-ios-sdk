import XCTest
@testable import PaywalloSDK

/// The conversion value schema is LOCKED: changing what a value means corrupts postbacks
/// already in flight. These assertions are the lock.
final class SkanConversionValueTests: XCTestCase {

    // MARK: - revenueTier

    func testRevenueTier_zeroAndNegative() {
        XCTAssertEqual(SkanConversionValue.revenueTier(0), 0)
        XCTAssertEqual(SkanConversionValue.revenueTier(-1), 0)
    }

    func testRevenueTier_boundaries() {
        XCTAssertEqual(SkanConversionValue.revenueTier(0.01), 1)
        XCTAssertEqual(SkanConversionValue.revenueTier(4.99), 1)
        XCTAssertEqual(SkanConversionValue.revenueTier(5), 2)
        XCTAssertEqual(SkanConversionValue.revenueTier(9.99), 2)
        XCTAssertEqual(SkanConversionValue.revenueTier(10), 3)
        XCTAssertEqual(SkanConversionValue.revenueTier(24.99), 3)
        XCTAssertEqual(SkanConversionValue.revenueTier(25), 4)
        XCTAssertEqual(SkanConversionValue.revenueTier(49.99), 4)
        XCTAssertEqual(SkanConversionValue.revenueTier(50), 5)
        XCTAssertEqual(SkanConversionValue.revenueTier(99.99), 5)
        XCTAssertEqual(SkanConversionValue.revenueTier(100), 6)
        XCTAssertEqual(SkanConversionValue.revenueTier(249.99), 6)
        XCTAssertEqual(SkanConversionValue.revenueTier(250), 7)
        XCTAssertEqual(SkanConversionValue.revenueTier(10_000), 7)
    }

    // MARK: - Stage raw values

    func testConversionStage_rawValues() {
        XCTAssertEqual(ConversionStage.install.rawValue, 0)
        XCTAssertEqual(ConversionStage.onboardingComplete.rawValue, 1)
        XCTAssertEqual(ConversionStage.paywallViewed.rawValue, 2)
        XCTAssertEqual(ConversionStage.trialStarted.rawValue, 3)
        XCTAssertEqual(ConversionStage.trialConverted.rawValue, 4)
        XCTAssertEqual(ConversionStage.directPurchase.rawValue, 5)
        XCTAssertEqual(ConversionStage.retained.rawValue, 6)
    }

    // MARK: - Full schema table (LOCKED)

    func testCompute_lockedTable() {
        let cases: [(stage: ConversionStage, revenue: Double, fine: Int, coarse: CoarseConversionValue, lock: Bool)] = [
            (.install, 0, 0, .low, false),
            (.onboardingComplete, 0, 8, .low, false),
            (.paywallViewed, 0, 16, .low, false),
            (.trialStarted, 0, 24, .medium, false),
            (.trialConverted, 0, 32, .high, true),
            (.directPurchase, 0, 40, .high, true),
            (.retained, 0, 48, .high, true),
            (.trialConverted, 12, 35, .high, true),
            (.trialConverted, 30, 36, .high, true),
            (.directPurchase, 12, 43, .high, true),
            (.directPurchase, 30, 44, .high, true),
            (.directPurchase, 300, 47, .high, true),
            (.retained, 12, 51, .high, true),
        ]

        for testCase in cases {
            let value = SkanConversionValue.compute(stage: testCase.stage, revenueUsd: testCase.revenue)
            XCTAssertEqual(value.fine, testCase.fine, "fine for \(testCase.stage)/\(testCase.revenue)")
            XCTAssertEqual(value.coarse, testCase.coarse, "coarse for \(testCase.stage)/\(testCase.revenue)")
            XCTAssertEqual(value.lock, testCase.lock, "lock for \(testCase.stage)/\(testCase.revenue)")
        }
    }

    func testCompute_fineNeverExceedsSixBits() {
        for stage in ConversionStage.allCases {
            let value = SkanConversionValue.compute(stage: stage, revenueUsd: 10_000)
            XCTAssertLessThanOrEqual(value.fine, 63)
            XCTAssertGreaterThanOrEqual(value.fine, 0)
        }
    }

    // MARK: - decode

    func testDecode_roundTripsEveryStageAndTier() {
        for stage in ConversionStage.allCases {
            for tier in 0...7 {
                let fine = stage.rawValue * 8 + tier
                let decoded = SkanConversionValue.decode(fine)
                XCTAssertEqual(decoded.stage, stage.rawValue)
                XCTAssertEqual(decoded.revenueTier, tier)
            }
        }
    }

    func testDecode_knownValues() {
        XCTAssertEqual(SkanConversionValue.decode(35).stage, 4)
        XCTAssertEqual(SkanConversionValue.decode(35).revenueTier, 3)
        XCTAssertEqual(SkanConversionValue.decode(47).stage, 5)
        XCTAssertEqual(SkanConversionValue.decode(47).revenueTier, 7)
    }
}
