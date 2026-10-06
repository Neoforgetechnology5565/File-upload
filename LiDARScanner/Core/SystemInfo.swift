import Foundation
import os
import ScanCore
import UIKit

/// Device and process information used for scan metadata and resource checks.
enum SystemInfo {
    /// Hardware model identifier, e.g. "iPhone16,1" (simulator reports the simulated model).
    static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    @MainActor
    static func deviceInfo(hasLiDAR: Bool) -> DeviceInfo {
        DeviceInfo(
            modelIdentifier: modelIdentifier,
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            hasLiDAR: hasLiDAR,
            appVersion: appVersion
        )
    }
}

/// Memory headroom checks based on `os_proc_available_memory()`, which
/// reports how much more memory this process can allocate before iOS
/// terminates it (the jetsam limit) — the relevant number for large scans.
enum MemoryMonitor {
    /// Below this, capture stops accumulating new samples.
    static let captureStopThreshold: UInt64 = 250 * 1024 * 1024
    /// Below this, processing refuses to start.
    static let processingMinimum: UInt64 = 150 * 1024 * 1024

    static var availableBytes: UInt64 {
        UInt64(os_proc_available_memory())
    }

    /// `os_proc_available_memory` returns 0 when unsupported (e.g. some
    /// simulators); treat that as "unknown" rather than "out of memory".
    static var isLowForCapture: Bool {
        let available = availableBytes
        return available > 0 && available < captureStopThreshold
    }

    static var canStartProcessing: Bool {
        let available = availableBytes
        return available == 0 || available >= processingMinimum
    }
}
