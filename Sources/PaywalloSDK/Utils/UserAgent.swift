import Foundation

/// Builds the `User-Agent` value for every outgoing SDK request.
///
/// Format: `PaywalloSDK/<version> (<osName>[ <systemVersion>][; <model>])`
/// Fallback (device info not collected yet): `PaywalloSDK/<version> (ios)`.
///
/// The format is ua-parser-js compatible so the server can extract OS_NAME and
/// OS_VERSION for probabilistic attribution matching — without them the match
/// loses the strongest non-deterministic signal it has.
public func buildUserAgent(sdkVersion: String) -> String {
    // Strip non-printable-ASCII and the UA structural characters that would break
    // header validation on devices with non-ASCII model names (Korean, Chinese,
    // Russian…). Applied BEFORE the validity check so a string that cleans down to
    // nothing is treated as absent instead of emitting an empty segment.
    func clean(_ value: String) -> String {
        let printable = value.unicodeScalars.filter { $0.value >= 0x20 && $0.value <= 0x7E }
        return String(String.UnicodeScalarView(printable))
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: ";", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isValid(_ value: String?) -> Bool {
        guard let value = value else { return false }
        let cleaned = clean(value)
        return !cleaned.isEmpty && cleaned != "unknown"
    }

    // Synchronous cached read: the UA is built once per ApiClient, potentially before
    // the first `getDeviceInfo()` await has resolved.
    guard let info = DeviceInfo.shared.getCached() else {
        return "PaywalloSDK/\(sdkVersion) (\(clean(PaywalloConstants.sdkPlatform)))"
    }

    var parts: [String] = [isValid(info.systemName) ? clean(info.systemName) : clean(PaywalloConstants.sdkPlatform)]
    if isValid(info.systemVersion) { parts.append(clean(info.systemVersion)) }

    let model = info.modelId.isEmpty ? info.model : info.modelId
    let detail = isValid(model) ? "; \(clean(model))" : ""

    return "PaywalloSDK/\(sdkVersion) (\(parts.joined(separator: " "))\(detail))"
}
