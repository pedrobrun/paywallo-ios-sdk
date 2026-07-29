import Foundation
#if canImport(UIKit)
import UIKit
import CoreTelephony
#endif

public struct DeviceData: Codable, Sendable {
    public let deviceId: String        // IDFV (iOS) or UUID fallback
    public let model: String           // UIDevice.model
    public let modelId: String         // hw.machine sysctl
    public let systemName: String      // UIDevice.systemName
    public let systemVersion: String   // UIDevice.systemVersion
    public let appVersion: String      // CFBundleShortVersionString
    public let buildNumber: String     // CFBundleVersion
    public let bundleId: String        // Bundle.main.bundleIdentifier
    public let brand: String           // "Apple"
    public let totalDisk: UInt64       // bytes
    public let freeDisk: UInt64        // bytes
    public let totalRam: UInt64        // bytes
    public let carrier: String
    public let darwinVersion: String?
    public let screenWidth: Double
    public let screenHeight: Double
    public let screenDensity: Double   // UIScreen.main.scale
    public let locale: String
    public let language: String
    public let timezone: String

    public var idfv: String { deviceId }
}

public final class DeviceInfo: @unchecked Sendable {
    public static let shared = DeviceInfo()

    private var cachedData: DeviceData?
    private let lock = NSLock()

    private init() {}

    /// Synchronous read of the last collected DeviceData. Returns nil if `getDeviceInfo()` hasn't
    /// been called yet. Safe to call from any thread / non-async context.
    public func getCached() -> DeviceData? {
        lock.lock()
        defer { lock.unlock() }
        return cachedData
    }

    @MainActor
    public func getDeviceInfo() -> DeviceData {
        lock.lock()
        if let cached = cachedData {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let bundle = Bundle.main
        let info = bundle.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = info?["CFBundleVersion"] as? String ?? "unknown"
        let bundleId = bundle.bundleIdentifier ?? "unknown"

        // Disk stats
        var totalDisk: UInt64 = 0
        var freeDisk: UInt64 = 0
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            totalDisk = (attrs[.systemSize] as? NSNumber)?.uint64Value ?? 0
            freeDisk = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        }

        let modelId = Self.getModelIdentifier()
        let darwinVersion = Self.getDarwinVersion()
        let totalRam = ProcessInfo.processInfo.physicalMemory
        let locale = Locale.current.identifier
        let language = Locale.preferredLanguages.first ?? Locale.current.identifier
        let timezone = TimeZone.current.identifier

#if canImport(UIKit)
        let device = UIDevice.current
        let deviceId = device.identifierForVendor?.uuidString ?? "unknown"
        let model = device.model
        let systemName = device.systemName
        let systemVersion = device.systemVersion

        var carrier = "unknown"
        let networkInfo = CTTelephonyNetworkInfo()
        if let providers = networkInfo.serviceSubscriberCellularProviders,
           let first = providers.values.first,
           let name = first.carrierName {
            carrier = name
        }

        let screen = UIScreen.main
        let screenWidth = Double(screen.bounds.width)
        let screenHeight = Double(screen.bounds.height)
        let screenDensity = Double(screen.scale)
#else
        let deviceId = "unknown"
        let model = "Mac"
        let systemName = "macOS"
        let systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let carrier = "unknown"
        let screenWidth: Double = 0
        let screenHeight: Double = 0
        let screenDensity: Double = 1
#endif

        let data = DeviceData(
            deviceId: deviceId,
            model: model,
            modelId: modelId,
            systemName: systemName,
            systemVersion: systemVersion,
            appVersion: appVersion,
            buildNumber: buildNumber,
            bundleId: bundleId,
            brand: "Apple",
            totalDisk: totalDisk,
            freeDisk: freeDisk,
            totalRam: totalRam,
            carrier: carrier,
            darwinVersion: darwinVersion,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            screenDensity: screenDensity,
            locale: locale,
            language: language,
            timezone: timezone
        )

        lock.lock()
        cachedData = data
        lock.unlock()

        return data
    }

    // MARK: - Sysctl Helpers

    private static func getModelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }

    private static func getDarwinVersion() -> String? {
        var size = 0
        sysctlbyname("kern.osrelease", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var release = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.osrelease", &release, &size, nil, 0)
        return String(cString: release)
    }
}
