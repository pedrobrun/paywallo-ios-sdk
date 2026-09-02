import Foundation

// MARK: - PaywallCloseReason

/// Maps legacy close reason strings to their canonical forms.
public enum PaywallCloseReason {

    /// Canonical close reason values.
    public static let canonical: Set<String> = ["dismiss", "cta", "purchase", "error", "timeout"]

    /// Maps a legacy or canonical close reason string to its canonical form.
    /// Anything outside the legacy map is returned unchanged — collapsing unknown
    /// values into "dismiss" hid every reason the enum grows to carry, and the
    /// canonical set is validated server-side anyway.
    public static func canonicalize(_ reason: String) -> String {
        switch reason {
        // Legacy → canonical
        case "dismissed":   return "dismiss"
        case "purchased":   return "purchase"
        case "backgrounded": return "dismiss"

        // Já canônico (ou desconhecido) → passa cru
        default:            return reason
        }
    }

    /// Returns true if the given reason is a canonical close reason.
    public static func isCanonical(_ reason: String) -> Bool {
        canonical.contains(reason)
    }
}
