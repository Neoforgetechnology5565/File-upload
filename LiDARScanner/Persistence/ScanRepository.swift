import Foundation
import ScanCore

/// Storage-agnostic access to scan metadata.
///
/// The UI and services depend only on this protocol. Implementations:
/// - `SwiftDataScanRepository` — on-device default.
/// - `InMemoryScanRepository` — previews, unit tests, UI tests.
/// - A future cloud repository (e.g. a REST/Firestore/S3-backed one) can
///   conform to the same protocol, or wrap the local one for offline caching.
protocol ScanRepository: Sendable {
    func scans(matching query: ScanQuery) async throws -> [Scan]
    func scan(id: UUID) async throws -> Scan?
    /// Inserts or updates (upsert by `id`).
    func save(_ scan: Scan) async throws
    func delete(id: UUID) async throws
    func count() async throws -> Int
}

enum RepositoryError: Error, LocalizedError, Equatable {
    case corruptedRecord(UUID)
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .corruptedRecord(let id): return "The scan record \(id.uuidString) could not be read."
        case .underlying(let message): return message
        }
    }
}

/// Thread-safe in-memory repository.
actor InMemoryScanRepository: ScanRepository {
    private var storage: [UUID: Scan]

    init(scans: [Scan] = []) {
        storage = Dictionary(uniqueKeysWithValues: scans.map { ($0.id, $0) })
    }

    func scans(matching query: ScanQuery) async throws -> [Scan] {
        query.apply(to: Array(storage.values))
    }

    func scan(id: UUID) async throws -> Scan? {
        storage[id]
    }

    func save(_ scan: Scan) async throws {
        storage[scan.id] = scan
    }

    func delete(id: UUID) async throws {
        storage[id] = nil
    }

    func count() async throws -> Int {
        storage.count
    }
}
