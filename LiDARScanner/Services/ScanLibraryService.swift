import Foundation
import ScanCore

extension Notification.Name {
    /// Posted (on the main thread) whenever scans are added, changed or deleted.
    static let scanLibraryDidChange = Notification.Name("ScanLibraryDidChange")
}

/// Coordinates metadata (`ScanRepository`) and files (`StorageService`) so
/// they never get out of sync. View models use this instead of touching the
/// repository or the file system directly.
final class ScanLibraryService: @unchecked Sendable {
    private let repository: ScanRepository
    private let storage: StorageService
    private let cloudSync: CloudSyncService

    init(repository: ScanRepository, storage: StorageService, cloudSync: CloudSyncService) {
        self.repository = repository
        self.storage = storage
        self.cloudSync = cloudSync
    }

    // MARK: Queries

    func scans(matching query: ScanQuery = ScanQuery()) async throws -> [Scan] {
        try await repository.scans(matching: query)
    }

    func scan(id: UUID) async throws -> Scan {
        guard let scan = try await repository.scan(id: id) else { throw AppError.scanNotFound }
        return scan
    }

    func count() async throws -> Int {
        try await repository.count()
    }

    /// Decodes the geometry file off the main thread.
    func loadGeometry(for scan: Scan) async throws -> ScanGeometry {
        guard let file = scan.files.geometryFile else { throw StorageError.fileMissing("geometry") }
        let url = storage.fileURL(file, scanID: scan.id)
        return try await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: url.path) else { throw StorageError.fileMissing(file) }
            return try ScanGeometryCodec.read(from: url)
        }.value
    }

    func thumbnailURL(for scan: Scan) -> URL? {
        guard let file = scan.files.thumbnailFile else { return nil }
        let url = storage.fileURL(file, scanID: scan.id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func fileURL(_ relativePath: String, for scan: Scan) -> URL {
        storage.fileURL(relativePath, scanID: scan.id)
    }

    func diskUsage(for scan: Scan) -> Int64 {
        storage.totalSize(for: scan.id)
    }

    // MARK: Mutations

    /// Commits a processed scan's staging files and persists its metadata.
    @discardableResult
    func save(_ processed: ProcessedScan, name: String, notes: String, measurements: [ScanMeasurement], ownerID: String?) async throws -> Scan {
        var scan = processed.scan
        scan.name = try ScanNameValidator.validate(name)
        scan.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        scan.measurements = measurements
        scan.ownerID = ownerID
        scan.updatedAt = Date()
        scan.syncState = cloudSync.isConfigured && ownerID != nil ? .pendingUpload : .localOnly

        try storage.commitStaging(processed.stagingDirectory, scanID: scan.id)
        do {
            try await repository.save(scan)
        } catch {
            // Roll back files so we never leave orphaned payloads.
            try? storage.deleteFiles(for: scan.id)
            throw error
        }
        if scan.syncState == .pendingUpload {
            try? await cloudSync.enqueueUpload(scanID: scan.id)
        }
        await notifyChange()
        return scan
    }

    func discard(_ processed: ProcessedScan) {
        storage.discardStaging(processed.stagingDirectory)
    }

    @discardableResult
    func rename(id: UUID, to newName: String) async throws -> Scan {
        let name = try ScanNameValidator.validate(newName)
        return try await mutate(id: id) { $0.name = name }
    }

    @discardableResult
    func updateNotes(id: UUID, notes: String) async throws -> Scan {
        try await mutate(id: id) { $0.notes = notes }
    }

    @discardableResult
    func updateMeasurements(id: UUID, measurements: [ScanMeasurement]) async throws -> Scan {
        try await mutate(id: id) { $0.measurements = measurements }
    }

    @discardableResult
    func recordExport(id: UUID, record: ExportRecord) async throws -> Scan {
        try await mutate(id: id) { $0.exports.append(record) }
    }

    func delete(id: UUID) async throws {
        try storage.deleteFiles(for: id)
        try await repository.delete(id: id)
        await notifyChange()
    }

    func exportsDirectory(for scan: Scan) throws -> URL {
        try storage.exportsDirectory(for: scan.id)
    }

    // MARK: Helpers

    private func mutate(id: UUID, _ change: (inout Scan) -> Void) async throws -> Scan {
        var scan = try await self.scan(id: id)
        change(&scan)
        scan.updatedAt = Date()
        if scan.syncState == .synced { scan.syncState = .pendingUpload }
        try await repository.save(scan)
        await notifyChange()
        return scan
    }

    @MainActor
    private func notifyChange() {
        NotificationCenter.default.post(name: .scanLibraryDidChange, object: nil)
    }
}
