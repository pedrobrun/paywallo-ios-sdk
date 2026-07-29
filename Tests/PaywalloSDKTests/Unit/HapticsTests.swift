import XCTest
@testable import PaywalloSDK

/// Tests for the Haptics utility.
///
/// On non-iOS platforms (macOS, Linux) Haptics.impact() is a no-op stub — we verify
/// it never throws or crashes. On iOS (UIKit available) the actual generator runs
/// on the main thread; we just verify the call doesn't crash (UIKit is available in
/// XCTest on device/simulator).
final class HapticsTests: XCTestCase {

    // MARK: - 1. No-op / non-crash on any platform

    func testImpactLightDoesNotCrash() {
        // Must not throw, trap, or crash regardless of platform.
        XCTAssertNoThrow(Haptics.impact(.light))
    }

    func testImpactMediumDoesNotCrash() {
        XCTAssertNoThrow(Haptics.impact(.medium))
    }

    func testImpactHeavyDoesNotCrash() {
        XCTAssertNoThrow(Haptics.impact(.heavy))
    }

    func testImpactDefaultStyleDoesNotCrash() {
        // Default argument is .light
        XCTAssertNoThrow(Haptics.impact())
    }

    // MARK: - 2. PaywallMessageParser accepts "haptic" type

    func testPaywallMessageParserAcceptsHapticType() {
        let json = """
        {"type":"haptic","id":"msg_haptic_1"}
        """
        let message = PaywallMessageParser.parse(json)
        XCTAssertNotNil(message, "'haptic' must be an allowed PaywallMessage type")
        XCTAssertEqual(message?.type, "haptic")
    }

    func testPaywallMessageParserHapticHasMessageId() {
        let json = """
        {"type":"haptic","id":"hap_001"}
        """
        let message = PaywallMessageParser.parse(json)
        XCTAssertEqual(message?.messageId, "hap_001")
    }

    func testPaywallMessageParserHapticWithoutIdDerivesFallbackId() {
        let json = """
        {"type":"haptic"}
        """
        let message = PaywallMessageParser.parse(json)
        XCTAssertNotNil(message)
        // Derived id for a type with no productId/url/timestamp is "haptic:"
        XCTAssertEqual(message?.messageId, "haptic:")
    }
}
