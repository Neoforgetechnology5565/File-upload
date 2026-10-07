import XCTest
@testable import ScanCore

final class ScanMetadataTests: XCTestCase {
    private func makeScan(name: String, type: ScanType, created: TimeInterval, notes: String = "") -> Scan {
        Scan(name: name, createdAt: Date(timeIntervalSince1970: created), type: type, device: .unknown, notes: notes)
    }

    func testCodableRoundTripPreservesEverything() throws {
        var scan = makeScan(name: "Kitchen", type: .room, created: 1000)
        scan.status = .completed
        scan.files = ScanFileManifest(geometryFile: ScanFileManifest.geometryFileName, thumbnailFile: ScanFileManifest.thumbnailFileName)
        scan.statistics = ScanStatistics(pointCount: 10, vertexCount: 20, triangleCount: 5, surfaceArea: 1.5, boundingBoxSize: Vector3(1, 2, 3), captureDuration: 42)
        scan.measurements = [try MeasurementEngine().measure(.distance, points: [.zero, .one])]
        scan.exports = [ExportRecord(format: .ply, fileName: "Kitchen.ply", byteCount: 123)]
        scan.metadata = ["preset": "space"]

        // Default date coding is exact; ISO-8601 would drop sub-second precision.
        let decoded = try JSONDecoder().decode(Scan.self, from: JSONEncoder().encode(scan))
        XCTAssertEqual(decoded, scan)
    }

    func testDefaultsAndDerivedValues() {
        var scan = makeScan(name: "A", type: .object, created: 0)
        XCTAssertEqual(scan.updatedAt, scan.createdAt)
        XCTAssertEqual(scan.syncState, .localOnly)
        XCTAssertFalse(scan.isExported)
        scan.exports = [
            ExportRecord(format: .obj, fileName: "a.obj", byteCount: 1, exportedAt: Date(timeIntervalSince1970: 10)),
            ExportRecord(format: .obj, fileName: "b.obj", byteCount: 1, exportedAt: Date(timeIntervalSince1970: 20))
        ]
        XCTAssertTrue(scan.isExported)
        XCTAssertEqual(scan.lastExport(of: .obj)?.fileName, "b.obj")
        XCTAssertNil(scan.lastExport(of: .usdz))
    }

    func testStatisticsFromGeometry() {
        let mesh = RoomMeshBuilder.box(size: Vector3(1, 1, 1))
        let geometry = ScanGeometry(pointCloud: PointCloud(positions: [.zero, Vector3(2, 0, 0)]), mesh: mesh)
        let stats = ScanStatistics.make(from: geometry, captureDuration: 12)
        XCTAssertEqual(stats.pointCount, 2)
        XCTAssertEqual(stats.vertexCount, 24)
        XCTAssertEqual(stats.triangleCount, 12)
        XCTAssertEqual(stats.surfaceArea ?? 0, 6, accuracy: 1e-5)
        XCTAssertEqual(stats.boundingBoxSize?.x ?? 0, 2.5, accuracy: 1e-5)
        XCTAssertEqual(stats.captureDuration, 12)
        XCTAssertNil(stats.room)
    }

    func testNameValidation() throws {
        XCTAssertEqual(try ScanNameValidator.validate("  Desk  "), "Desk")
        XCTAssertThrowsError(try ScanNameValidator.validate("   ")) { error in
            XCTAssertEqual(error as? ScanNameValidator.ValidationError, .empty)
        }
        XCTAssertThrowsError(try ScanNameValidator.validate(String(repeating: "a", count: 81)))
        XCTAssertTrue(ScanNameValidator.defaultName(for: .room).hasPrefix("Room"))
    }

    func testQueryFilteringAndSorting() {
        let scans = [
            makeScan(name: "Bedroom", type: .room, created: 10),
            makeScan(name: "chair", type: .object, created: 30, notes: "oak"),
            makeScan(name: "Attic", type: .room, created: 20)
        ]
        XCTAssertEqual(ScanQuery().apply(to: scans).map(\.name), ["chair", "Attic", "Bedroom"])
        XCTAssertEqual(ScanQuery(sortOrder: .oldestFirst).apply(to: scans).map(\.name), ["Bedroom", "Attic", "chair"])
        XCTAssertEqual(ScanQuery(sortOrder: .nameAscending).apply(to: scans).map(\.name), ["Attic", "Bedroom", "chair"])
        XCTAssertEqual(ScanQuery(type: .room).apply(to: scans).count, 2)
        XCTAssertEqual(ScanQuery(searchText: "OAK").apply(to: scans).map(\.name), ["chair"])
        XCTAssertEqual(ScanQuery(searchText: "room", type: .object).apply(to: scans).count, 0)
    }
}

final class ScanFeedbackTests: XCTestCase {
    private let analyzer = ScanFeedbackAnalyzer(thresholds: .object)

    func testTrackingStatesMapToGuidance() {
        XCTAssertEqual(analyzer.feedback(for: .init(tracking: .initializing), hasCapturedData: false), .initializing)
        XCTAssertEqual(analyzer.feedback(for: .init(tracking: .excessiveMotion), hasCapturedData: false), .tooFast)
        XCTAssertEqual(analyzer.feedback(for: .init(tracking: .relocalizing), hasCapturedData: true), .relocalizing)
        XCTAssertEqual(analyzer.feedback(for: .init(tracking: .notAvailable), hasCapturedData: true), .trackingUnavailable)
        if case .lowTracking = analyzer.feedback(for: .init(tracking: .insufficientFeatures), hasCapturedData: false) {} else {
            XCTFail("expected low tracking")
        }
    }

    func testSpeedThresholds() {
        XCTAssertEqual(analyzer.feedback(for: .init(tracking: .normal, linearSpeed: 1.0), hasCapturedData: false), .tooFast)
        XCTAssertEqual(analyzer.feedback(for: .init(tracking: .normal, angularSpeed: 2.0), hasCapturedData: false), .tooFast)
        XCTAssertEqual(analyzer.feedback(for: .init(tracking: .normal, linearSpeed: 0.5), hasCapturedData: false), .moveSlowly)
        XCTAssertEqual(analyzer.feedback(for: .init(tracking: .normal, linearSpeed: 0.1), hasCapturedData: false), .tracking)
        XCTAssertEqual(analyzer.feedback(for: .init(tracking: .normal, linearSpeed: 0.1), hasCapturedData: true), .areaCaptured)
    }

    func testDistanceGuidance() {
        XCTAssertEqual(analyzer.feedback(for: .init(tracking: .normal, medianCenterDepth: 3), hasCapturedData: false), .moveCloser)
        XCTAssertEqual(analyzer.feedback(for: .init(tracking: .normal, medianCenterDepth: 0.1), hasCapturedData: false), .moveFarther)
        let space = ScanFeedbackAnalyzer(thresholds: .space)
        XCTAssertEqual(space.feedback(for: .init(tracking: .normal, medianCenterDepth: 3), hasCapturedData: false), .tracking)
    }

    func testCaptureGating() {
        XCTAssertTrue(ScanFeedback.tracking.allowsCapture)
        XCTAssertTrue(ScanFeedback.moveSlowly.allowsCapture)
        XCTAssertFalse(ScanFeedback.tooFast.allowsCapture)
        XCTAssertFalse(ScanFeedback.relocalizing.allowsCapture)
        XCTAssertFalse(ScanFeedback.paused.allowsCapture)
    }

    func testAngleBetween() {
        XCTAssertEqual(ScanFeedbackAnalyzer.angleBetween(Vector3(1, 0, 0), Vector3(0, 1, 0)), .pi / 2, accuracy: 1e-5)
        XCTAssertEqual(ScanFeedbackAnalyzer.angleBetween(Vector3(1, 0, 0), Vector3(2, 0, 0)), 0, accuracy: 1e-3)
    }
}
