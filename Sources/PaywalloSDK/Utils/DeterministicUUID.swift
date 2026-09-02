import Foundation

/// Derives a stable UUID (v4 shape) from an arbitrary seed. Same seed → same UUID,
/// forever, on any platform.
///
/// Byte-for-byte port of the React Native SDK's `deterministicUUID` (src/utils/uuid.ts).
/// The two SDKs MUST agree: `installEventId` is derived from `"{appKey}:{stableKey}"`
/// and the backend dedups installs on it — a divergent hash turns a reinstall into a
/// brand-new install in the data.
///
/// FNV-1a 32-bit run four times with different bases to fill the 128 bits. Not
/// cryptographic — this exists for backend dedup, not for security.
public func deterministicUUID(_ seed: String) -> String {
    let basis: UInt32 = 2_166_136_261
    let h0 = fnv1a32(seed, basis)
    let h1 = fnv1a32(seed, basis ^ 0x0f0f_0f0f)
    let h2 = fnv1a32(seed, basis ^ 0xf0f0_f0f0)
    let h3 = fnv1a32(seed, basis ^ 0xaaaa_aaaa)

    let s1 = hex32(h0, 8)
    let s2 = hex32(h1 >> 16, 4)
    let s3 = "4" + hex32(h1 & 0x0fff, 3)
    let s4 = hex32(0x8 | ((h2 >> 30) & 0x3), 1) + hex32((h2 >> 18) & 0x0fff, 3)
    let s5 = hex32(h2 & 0xffff, 4) + hex32(h3, 8)

    return "\(s1)-\(s2)-\(s3)-\(s4)-\(s5)"
}

/// Iterates `utf16`, not `utf8`: the JS original hashes `charCodeAt`, which yields UTF-16
/// code units. Hashing bytes instead agrees with RN on ASCII and silently diverges on
/// every accented or emoji seed — the kind of drift that only shows up in production data.
private func fnv1a32(_ seed: String, _ basis: UInt32) -> UInt32 {
    var hash = basis
    for unit in seed.utf16 {
        // `&*` and the UInt32 width reproduce JS's `Math.imul(...) >>> 0`: wrap on
        // overflow instead of trapping.
        hash = (hash ^ UInt32(unit)) &* 16_777_619
    }
    return hash
}

/// Lowercase hex, left-padded then trimmed to exactly `length` — mirrors
/// `padStart(len, "0").slice(-len)`.
private func hex32(_ value: UInt32, _ length: Int) -> String {
    let raw = String(value, radix: 16)
    if raw.count >= length { return String(raw.suffix(length)) }
    return String(repeating: "0", count: length - raw.count) + raw
}
