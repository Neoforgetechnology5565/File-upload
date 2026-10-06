import Foundation
import OSLog

/// Centralized unified-logging categories. Never log personal data
/// (emails, names) — use `privacy: .private` when unavoidable.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.example.lidarscanner"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let scanning = Logger(subsystem: subsystem, category: "scanning")
    static let room = Logger(subsystem: subsystem, category: "roomplan")
    static let processing = Logger(subsystem: subsystem, category: "processing")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let export = Logger(subsystem: subsystem, category: "export")
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let viewer = Logger(subsystem: subsystem, category: "viewer")
}
