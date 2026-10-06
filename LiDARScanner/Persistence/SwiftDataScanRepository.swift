import Foundation
import ScanCore
import SwiftData

/// Background SwiftData store. `@ModelActor` gives this actor its own
/// `ModelContext` bound to a serial executor, so database work never runs on
/// the main thread.
@ModelActor
actor SwiftDataScanStore {
    func fetchScans(type: ScanType?) throws -> [Scan] {
        var descriptor = FetchDescriptor<ScanRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        if let type {
            let raw = type.rawValue
            descriptor.predicate = #Predicate<ScanRecord> { $0.typeRaw == raw }
        }
        let records = try modelContext.fetch(descriptor)
        return records.compactMap { record in
            do {
                return try record.toDomain()
            } catch {
                Log.persistence.error("Skipping unreadable scan record: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    func fetchScan(id: UUID) throws -> Scan? {
        try fetchRecord(id: id)?.toDomain()
    }

    func upsert(_ scan: Scan) throws {
        let payload = try ScanRecordCoding.encode(scan)
        if let existing = try fetchRecord(id: scan.id) {
            existing.update(from: scan, payload: payload)
        } else {
            modelContext.insert(ScanRecord(scan: scan, payload: payload))
        }
        try modelContext.save()
    }

    func delete(id: UUID) throws {
        guard let record = try fetchRecord(id: id) else { return }
        modelContext.delete(record)
        try modelContext.save()
    }

    func count() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<ScanRecord>())
    }

    private func fetchRecord(id: UUID) throws -> ScanRecord? {
        var descriptor = FetchDescriptor<ScanRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

/// SwiftData-backed `ScanRepository` (the default on-device store).
final class SwiftDataScanRepository: ScanRepository, @unchecked Sendable {
    private let store: SwiftDataScanStore

    init(container: ModelContainer) {
        store = SwiftDataScanStore(modelContainer: container)
    }

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([ScanRecord.self])
        let configuration = ModelConfiguration("Scans", schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    func scans(matching query: ScanQuery) async throws -> [Scan] {
        // Type filtering happens in the database; text search and sorting use
        // the shared ScanQuery logic so every repository behaves identically.
        let scans = try await wrap { try await self.store.fetchScans(type: query.type) }
        return query.apply(to: scans)
    }

    func scan(id: UUID) async throws -> Scan? {
        try await wrap { try await self.store.fetchScan(id: id) }
    }

    func save(_ scan: Scan) async throws {
        try await wrap { try await self.store.upsert(scan) }
    }

    func delete(id: UUID) async throws {
        try await wrap { try await self.store.delete(id: id) }
    }

    func count() async throws -> Int {
        try await wrap { try await self.store.count() }
    }

    private func wrap<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            Log.persistence.error("Repository error: \(error.localizedDescription, privacy: .public)")
            throw StorageError.writeFailed(error.localizedDescription)
        }
    }
}
