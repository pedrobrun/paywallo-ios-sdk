import Foundation

public final class Localization {
    public static let shared = Localization()

    public static let defaultLanguage = "pt-BR"

    private var currentLanguage: String

    // SDK strings for error/retry/close buttons
    private let sdkStrings: [String: [String: String]] = [
        "pt-BR": ["error_title": "Ops, algo deu errado", "retry": "Tentar novamente", "close": "Fechar"],
        "pt": ["error_title": "Ops, algo deu errado", "retry": "Tentar novamente", "close": "Fechar"],
        "en": ["error_title": "Oops, something went wrong", "retry": "Try again", "close": "Close"],
        "en-US": ["error_title": "Oops, something went wrong", "retry": "Try again", "close": "Close"],
        "en-GB": ["error_title": "Oops, something went wrong", "retry": "Try again", "close": "Close"],
        "es": ["error_title": "Ups, algo salió mal", "retry": "Intentar de nuevo", "close": "Cerrar"],
        "es-419": ["error_title": "Ups, algo salió mal", "retry": "Intentar de nuevo", "close": "Cerrar"],
    ]

    private init() {
        currentLanguage = Self.detectDeviceLanguage()
    }

    public func initLocalization() {
        currentLanguage = Self.detectDeviceLanguage()
    }

    public static func detectDeviceLanguage() -> String {
        if let preferred = Locale.preferredLanguages.first {
            return preferred
        }
        return Locale.current.identifier
    }

    public func getCurrentLanguage() -> String { currentLanguage }

    public func getLocalizedString(text: [String: String]) -> String? {
        // Try exact match
        if let value = text[currentLanguage] { return value }
        // Try default language
        if let value = text[Self.defaultLanguage] { return value }
        // Return first available
        return text.values.first
    }

    public func getSdkString(_ key: String) -> String? {
        // Try current language
        if let strings = sdkStrings[currentLanguage], let value = strings[key] { return value }
        // Try base language code (e.g., "pt" from "pt-BR")
        let baseCode = String(currentLanguage.prefix(2))
        if let strings = sdkStrings[baseCode], let value = strings[key] { return value }
        // Try default
        if let strings = sdkStrings[Self.defaultLanguage], let value = strings[key] { return value }
        // Try first available
        for langStrings in sdkStrings.values {
            if let value = langStrings[key] { return value }
        }
        return nil
    }
}
