import ScanCore
import XCTest
@testable import LiDARScanner

final class ExportServiceTests: XCTestCase {
    private var directory: URL!
    private let service = DefaultExportService()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testPLYExportOfPointCloudIsValid() async throws {
        let scan = TestFactory.scan(name: "Chair / v2")
        let artifact = try await service.export(scan: scan, geometry: TestFactory.objectGeometry(), format: .ply, options: ExportOptions(), roomUSDZURL: nil, to: directory)
        XCTAssertEqual(artifact.primaryURL.lastPathComponent, "Chair___v2.ply")
        let info = try ExportValidator.validatePLY(try Data(contentsOf: artifact.primaryURL))
        XCTAssertEqual(info.vertexCount, 50)
        XCTAssertEqual(info.properties, ["x", "y", "z", "nx", "ny", "nz", "red", "green", "blue"])
    }

    func testPLYMeshOption() async throws {
        let options = ExportOptions(plyEncoding: .ascii, plyContent: .mesh, objIncludeVertexColors: true)
        let artifact = try await service.export(scan: TestFactory.scan(), geometry: TestFactory.objectGeometry(), format: .ply, options: options, roomUSDZURL: nil, to: directory)
        let info = try ExportValidator.validatePLY(try Data(contentsOf: artifact.primaryURL))
        XCTAssertEqual(info.format, "ascii")
        XCTAssertEqual(info.faceCount, 12)
    }

    func testOBJExportWritesObjAndMtl() async throws {
        let artifact = try await service.export(scan: TestFactory.scan(name: "Box"), geometry: TestFactory.objectGeometry(), format: .obj, options: ExportOptions(), roomUSDZURL: nil, to: directory)
        XCTAssertEqual(artifact.shareURLs.map(\.lastPathComponent), ["Box.obj", "Box.mtl"])
        let info = try ExportValidator.validateOBJ(try Data(contentsOf: artifact.primaryURL))
        XCTAssertEqual(info.faceCount, 12)
        XCTAssertEqual(info.normalCount, 24)
    }

    func testRoomOBJHasPerElementGroups() async throws {
        let artifact = try await service.export(scan: TestFactory.scan(type: .room), geometry: TestFactory.roomGeometry(), format: .obj, options: ExportOptions(), roomUSDZURL: nil, to: directory)
        let text = try String(contentsOf: artifact.primaryURL)
        XCTAssertTrue(text.contains("o wall_1_wall"))
        XCTAssertTrue(text.contains("o object_1_table"))
    }

    func testUSDZExportIsValidPackage() async throws {
        let artifact = try await service.export(scan: TestFactory.scan(), geometry: TestFactory.objectGeometry(), format: .usdz, options: ExportOptions(), roomUSDZURL: nil, to: directory)
        let info = try ExportValidator.validateUSDZ(try Data(contentsOf: artifact.primaryURL))
        XCTAssertFalse(info.entryPaths.isEmpty)
        XCTAssertGreaterThan(artifact.byteCount, 0)
    }

    func testPointCloudOnlyUSDZUsesUSDAPoints() async throws {
        let geometry = ScanGeometry(pointCloud: PointCloud(positions: [.zero, Vector3(0.1, 0, 0)]))
        let artifact = try await service.export(scan: TestFactory.scan(), geometry: geometry, format: .usdz, options: ExportOptions(), roomUSDZURL: nil, to: directory)
        let info = try ExportValidator.validateUSDZ(try Data(contentsOf: artifact.primaryURL))
        XCTAssertEqual(info.entryPaths, ["scan.usda"])
    }

    func testInvalidRoomPlanUSDZFallsBackToGeneratedModel() async throws {
        let bogus = directory.appendingPathComponent("room.usdz")
        try Data("not a zip".utf8).write(to: bogus)
        let artifact = try await service.export(scan: TestFactory.scan(type: .room), geometry: TestFactory.roomGeometry(), format: .usdz, options: ExportOptions(), roomUSDZURL: bogus, to: directory)
        XCTAssertNoThrow(try ExportValidator.validateUSDZ(try Data(contentsOf: artifact.primaryURL)))
    }

    func testAvailability() {
        let empty = ScanGeometry()
        XCTAssertFalse(service.availability(of: .ply, for: TestFactory.scan(), geometry: empty).isAvailable)
        XCTAssertTrue(service.availability(of: .usdz, for: TestFactory.scan(type: .room), geometry: TestFactory.roomGeometry()).isAvailable)
        let points = ScanGeometry(pointCloud: PointCloud(positions: [.zero]))
        XCTAssertEqual(service.availability(of: .obj, for: TestFactory.scan(), geometry: points), .available("Vertices only (point cloud has no faces)"))
    }

    func testNothingToExportError() async {
        do {
            _ = try await service.export(scan: TestFactory.scan(), geometry: ScanGeometry(), format: .obj, options: ExportOptions(), roomUSDZURL: nil, to: directory)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? ExportError, .nothingToExport(.obj))
        }
    }
}
