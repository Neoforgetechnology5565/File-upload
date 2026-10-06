import ScanCore
import SwiftData
import XCTest
@testable import LiDARScanner

final class SwiftDataScanRepositoryTests: XCTestCase {
    private func makeRepository() throws -> SwiftDataScanRepository {
        SwiftDataScanRepository(container: try SwiftDataScanRepository.makeContainer(inMemory: true))
    }

    func testInsertFetchUpdateDelete() async throws {
        let repository = try makeRepository()
        var scan = TestFactory.scan(name: "Desk")
        scan.measurements = [try MeasurementEngine().measure(.distance, points: [.zero, Vector3(1, 0, 0)])]
        scan.metadata = ["capture.preset": "object"]

        try await repository.save(scan)
        let fetched = try await repository.scan(id: scan.id)
        XCTAssertEqual(fetched, scan)
        let countAfterInsert = try await repository.count()
        XCTAssertEqual(countAfterInsert, 1)

        scan.name = "Standing Desk"
        scan.status = .failed
        try await repository.save(scan)
        let updated = try await repository.scan(id: scan.id)
        XCTAssertEqual(updated?.name, "Standing Desk")
        XCTAssertEqual(updated?.status, .failed)
        let countAfterUpdate = try await repository.count()
        XCTAssertEqual(countAfterUpdate, 1, "save must upsert, not duplicate")

        try await repository.delete(id: scan.id)
        let deleted = try await repository.scan(id: scan.id)
        XCTAssertNil(deleted)
    }

    func testQueryFiltersByTypeAndText() async throws {
        let repository = try makeRepository()
        try await repository.save(TestFactory.scan(name: "Kitchen", type: .room, created: Date(timeIntervalSince1970: 100)))
        try await repository.save(TestFactory.scan(name: "Chair", type: .object, created: Date(timeIntervalSince1970: 200)))
        try await repository.save(TestFactory.scan(name: "Living Room", type: .room, created: Date(timeIntervalSince1970: 300)))

        let rooms = try await repository.scans(matching: ScanQuery(type: .room))
        XCTAssertEqual(rooms.map(\.name), ["Living Room", "Kitchen"])

        let search = try await repository.scans(matching: ScanQuery(searchText: "chair"))
        XCTAssertEqual(search.map(\.name), ["Chair"])

        let byName = try await repository.scans(matching: ScanQuery(sortOrder: .nameAscending))
        XCTAssertEqual(byName.map(\.name), ["Chair", "Kitchen", "Living Room"])
    }

    func testRecordColumnsOverridePayload() throws {
        let scan = TestFactory.scan(name: "Original")
        let record = ScanRecord(scan: scan, payload: try ScanRecordCoding.encode(scan))
        record.name = "Renamed"
        record.statusRaw = ProcessingStatus.failed.rawValue
        let domain = try record.toDomain()
        XCTAssertEqual(domain.name, "Renamed")
        XCTAssertEqual(domain.status, .failed)
    }
}

final class LocalFileStorageServiceTests: XCTestCase {
    func testStagingCommitAndDelete() throws {
        let storage = try TestFactory.temporaryStorage()
        let staging = try storage.makeStagingDirectory()
        try storage.write(Data("hello".utf8), to: staging.appendingPathComponent("a.txt"))

        let id = UUID()
        try storage.commitStaging(staging, scanID: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        let committed = storage.fileURL("a.txt", scanID: id)
        XCTAssertEqual(try String(contentsOf: committed), "hello")
        XCTAssertGreaterThan(storage.totalSize(for: id), 0)

        try storage.deleteFiles(for: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.scanDirectory(for: id).path))
    }

    func testPurgeStaleStaging() throws {
        let storage = try TestFactory.temporaryStorage()
        let staging = try storage.makeStagingDirectory()
        storage.purgeStaleStagingDirectories()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testDiscardIgnoresPathsOutsideStaging() throws {
        let storage = try TestFactory.temporaryStorage()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("keep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        storage.discardStaging(outside)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testExportsDirectoryIsRemovable() throws {
        let storage = try TestFactory.temporaryStorage()
        let id = UUID()
        let exports = try storage.exportsDirectory(for: id)
        try Data([1]).write(to: exports.appendingPathComponent("x.ply"))
        try storage.removeAllExports()
        XCTAssertFalse(FileManager.default.fileExists(atPath: exports.path))
    }
}

final class ScanLibraryServiceTests: XCTestCase {
    private func makeLibrary() throws -> (ScanLibraryService, InMemoryScanRepository, LocalFileStorageService) {
        let repository = InMemoryScanRepository()
        let storage = try TestFactory.temporaryStorage()
        return (ScanLibraryService(repository: repository, storage: storage, cloudSync: DisabledCloudSyncService()), repository, storage)
    }

    func testSaveCommitsFilesAndMetadata() async throws {
        let (library, repository, storage) = try makeLibrary()
        let processed = try TestFactory.processedScan(storage: storage)
        let measurement = try MeasurementEngine().measure(.distance, points: [.zero, .one])

        let saved = try await library.save(processed, name: "  My Chair ", notes: "oak", measurements: [measurement], ownerID: "u1")
        XCTAssertEqual(saved.name, "My Chair")
        XCTAssertEqual(saved.measurements, [measurement])
        XCTAssertEqual(saved.ownerID, "u1")
        XCTAssertEqual(saved.syncState, .localOnly)
        let stored = try await repository.scan(id: saved.id)
        XCTAssertEqual(stored, saved)

        let geometry = try await library.loadGeometry(for: saved)
        XCTAssertEqual(geometry, processed.geometry)
        XCTAssertNotNil(library.thumbnailURL(for: saved))
        XCTAssertFalse(FileManager.default.fileExists(atPath: processed.stagingDirectory.path))
    }

    func testSaveRejectsEmptyName() async throws {
        let (library, repository, storage) = try makeLibrary()
        let processed = try TestFactory.processedScan(storage: storage)
        do {
            _ = try await library.save(processed, name: "   ", notes: "", measurements: [], ownerID: nil)
            XCTFail("expected validation error")
        } catch {
            XCTAssertEqual(AppError.from(error), .invalidInput(ScanNameValidator.ValidationError.empty.localizedDescription))
        }
        let count = try await repository.count()
        XCTAssertEqual(count, 0)
    }

    func testRenameMeasurementsExportsAndDelete() async throws {
        let (library, _, storage) = try makeLibrary()
        let saved = try await library.save(try TestFactory.processedScan(storage: storage), name: "A", notes: "", measurements: [], ownerID: nil)

        let renamed = try await library.rename(id: saved.id, to: "B")
        XCTAssertEqual(renamed.name, "B")
        XCTAssertGreaterThanOrEqual(renamed.updatedAt, saved.updatedAt)

        let measurement = try MeasurementEngine().measure(.height, points: [.zero, Vector3(0, 2, 0)])
        let measured = try await library.updateMeasurements(id: saved.id, measurements: [measurement])
        XCTAssertEqual(measured.measurements.count, 1)

        let exported = try await library.recordExport(id: saved.id, record: ExportRecord(format: .ply, fileName: "B.ply", byteCount: 10))
        XCTAssertTrue(exported.isExported)

        try await library.delete(id: saved.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.scanDirectory(for: saved.id).path))
        do {
            _ = try await library.scan(id: saved.id)
            XCTFail("expected not found")
        } catch {
            XCTAssertEqual(error as? AppError, .scanNotFound)
        }
    }

    func testDiscardRemovesStaging() throws {
        let (library, _, storage) = try makeLibrary()
        let processed = try TestFactory.processedScan(storage: storage)
        library.discard(processed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: processed.stagingDirectory.path))
    }
}
