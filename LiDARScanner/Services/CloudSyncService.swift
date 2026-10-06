import Foundation
import ScanCore

enum CloudSyncError: Error, LocalizedError, Equatable {
    case notConfigured
    case notSignedIn
    case transferFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Cloud sync is not configured for this build."
        case .notSignedIn: return "Sign in with an account to sync scans."
        case .transferFailed(let reason): return "Sync failed: \(reason)"
        }
    }
}

struct SyncSummary: Equatable, Sendable {
    var uploaded: Int
    var downloaded: Int
    var failed: Int
}

/// Integration point for cloud synchronization.
///
/// CONFIGURATION POINT: implement this protocol for your backend (S3 presigned
/// uploads, Firebase Storage, Supabase Storage, CloudKit…) and return it from
/// `AppContainer.live()`. A typical implementation:
///  1. reads `Scan` metadata from `ScanRepository` and files from
///     `StorageService.scanDirectory(for:)`,
///  2. uploads them, then saves the scan with `syncState = .synced`,
///  3. downloads remote scans into the same local structure.
/// No other part of the app needs to change.
protocol CloudSyncService: Sendable {
    var isConfigured: Bool { get }
    func enqueueUpload(scanID: UUID) async throws
    func syncNow() async throws -> SyncSummary
}

/// Default: cloud sync disabled. Scans stay `SyncState.localOnly`.
struct DisabledCloudSyncService: CloudSyncService {
    var isConfigured: Bool { false }

    func enqueueUpload(scanID: UUID) async throws {
        throw CloudSyncError.notConfigured
    }

    func syncNow() async throws -> SyncSummary {
        throw CloudSyncError.notConfigured
    }
}
