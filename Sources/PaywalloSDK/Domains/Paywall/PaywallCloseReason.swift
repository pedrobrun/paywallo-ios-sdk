import Foundation

// MARK: - PaywallCloseReason

/// Maps legacy close reason strings to their canonical forms.
public enum PaywallCloseReason {

    /// Canonical close reason values.
    public static let canonical: Set<String> = ["dismiss", "cta", "purchase", "error", "timeout"]

    /// Maps a legacy or canonical close reason string to its canonical form.
    /// Returns the input unchanged if it is already canonical.
    /// Returns "dismiss" as the default fallback for unknown values.
    public static func canonicalize(_ reason: String) -> String {
        switch reason {
        // Legacy → canonical
        case "dismissed":   return "dismiss"
        case "purchased":   return "purchase"
        case "backgrounded": return "dismiss"
        case "timeout":     return "timeout"

        // Already canonical
        case "dismiss":     return "dismiss"
        case "cta":         return "cta"
        case "purchase":    return "purchase"
        case "error":       return "error"

        // Unknown → default
        default:            return "dismiss"
        }
    }

    /// Returns true if the given reason is a canonical close reason.
    public static func isCanonical(_ reason: String) -> Bool {
        canonical.contains(reason)
    }
}
