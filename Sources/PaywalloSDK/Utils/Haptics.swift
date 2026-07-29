import Foundation

#if canImport(UIKit)
import UIKit

/// Lightweight wrapper around UIImpactFeedbackGenerator.
/// All calls are no-ops on non-iOS platforms (tvOS, macOS Catalyst, etc.)
public enum Haptics {
    public enum Style {
        case light
        case medium
        case heavy

        #if canImport(UIKit)
        var uiStyle: UIImpactFeedbackGenerator.FeedbackStyle {
            switch self {
            case .light:  return .light
            case .medium: return .medium
            case .heavy:  return .heavy
            }
        }
        #endif
    }

    /// Triggers an impact haptic on the main thread.
    /// Safe to call from any thread — dispatches to main automatically.
    public static func impact(_ style: Style = .light) {
        let uiStyle = style.uiStyle
        DispatchQueue.main.async {
            let generator = UIImpactFeedbackGenerator(style: uiStyle)
            generator.prepare()
            generator.impactOccurred()
        }
    }
}

#else

// MARK: - Non-iOS stub

public enum Haptics {
    public enum Style { case light, medium, heavy }
    public static func impact(_ style: Style = .light) {}
}

#endif
