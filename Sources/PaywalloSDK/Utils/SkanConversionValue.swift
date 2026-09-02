import Foundation

// MARK: - SKAdNetwork / AdAttributionKit conversion value schema
//
// Reference: `docs/skan-attribution-plan.md` in paywallo-server.
// Schema is LOCKED — changing what a value means corrupts postbacks already in flight.
//
// - coarse: `low` = installed · `medium` = trial active · `high` = paying
// - fine (0-63) = `stage * 8 + revenueTier`

/// User stage in the post-install funnel. Value 7 stays reserved.
public enum ConversionStage: Int, Sendable, Comparable, CaseIterable {
    case install = 0
    case onboardingComplete = 1
    case paywallViewed = 2
    case trialStarted = 3
    case trialConverted = 4
    case directPurchase = 5
    case retained = 6

    public static func < (lhs: ConversionStage, rhs: ConversionStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Coarse value — the only one revealed on a low-volume campaign.
public enum CoarseConversionValue: String, Sendable {
    case low
    case medium
    case high
}

public struct ConversionValue: Sendable, Equatable {
    /// fine value 0-63 for SKAdNetwork / AdAttributionKit.
    public let fine: Int
    /// coarse value — revealed even on a low-volume campaign.
    public let coarse: CoarseConversionValue
    /// Locks the postback (terminal state) — delivers the signal sooner.
    public let lock: Bool

    public init(fine: Int, coarse: CoarseConversionValue, lock: Bool) {
        self.fine = fine
        self.coarse = coarse
        self.lock = lock
    }
}

public enum SkanConversionValue {

    /// Terminal (paying) stages — coarse `high`, they lock the postback.
    private static let terminalStages: Set<ConversionStage> = [
        .trialConverted,
        .directPurchase,
        .retained,
    ]

    /// Accumulated USD revenue → tier 0-7.
    public static func revenueTier(_ revenueUsd: Double) -> Int {
        if revenueUsd <= 0 { return 0 }
        if revenueUsd < 5 { return 1 }
        if revenueUsd < 10 { return 2 }
        if revenueUsd < 25 { return 3 }
        if revenueUsd < 50 { return 4 }
        if revenueUsd < 100 { return 5 }
        if revenueUsd < 250 { return 6 }
        return 7
    }

    /// Computes the conversion value (fine + coarse + lock) from the funnel stage and
    /// the accumulated revenue. Pure function, no side effects.
    public static func compute(stage: ConversionStage, revenueUsd: Double) -> ConversionValue {
        let fine = stage.rawValue * 8 + revenueTier(revenueUsd)
        let isTerminal = terminalStages.contains(stage)
        let coarse: CoarseConversionValue = isTerminal
            ? .high
            : (stage >= .trialStarted ? .medium : .low)
        return ConversionValue(fine: fine, coarse: coarse, lock: isTerminal)
    }

    /// Decodes a 0-63 fine value back into `(stage, revenueTier)`.
    public static func decode(_ fine: Int) -> (stage: Int, revenueTier: Int) {
        (stage: fine >> 3, revenueTier: fine & 0b111)
    }
}
