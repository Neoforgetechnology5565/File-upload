import XCTest
@testable import ScanCore

final class PLYWriterTests: XCTestCase {
    private func sampleCloud() -> PointCloud {
        PointCloud(
            positions: [Vector3(0, 0, 0), Vector3(1, 2, 3), Vector3(-1, 0.5, 2)],
            colors: [SIMD3(255, 0, 0), SIMD3(0, 255, 0), SIMD3(0, 0, 255)],
            normals: [Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)]
        )
    }

    func testBinaryPointCloudHeaderAndSize() throws {
        let data = try PLYWriter().data(for: sampleCloud())
        let info = try ExportValidator.validatePLY(data)
        XCTAssertEqual(info.format, "binary_little_endian")
        XCTAssertEqual(info.vertexCount, 3)
        XCTAssertEqual(info.faceCount, 0)
        XCTAssertEqual(info.properties, ["x", "y", "z", "nx", "ny", "nz", "red", "green", "blue"])
        XCTAssertEqual(data.count, info.headerLength + 3 * 27)
    }

    func testBinaryValuesAreLittleEndianFloats() throws {
        let data = try PLYWriter().data(for: PointCloud(positions: [Vector3(1.5, -2, 0.25)]))
        let info = try ExportValidator.validatePLY(data)
        var reader = BinaryReader(data: data.dropFirst(info.headerLength))
        XCTAssertEqual(try reader.readFloat(), 1.5)
        XCTAssertEqual(try reader.readFloat(), -2)
        XCTAssertEqual(try reader.readFloat(), 0.25)
        XCTAssertEqual(reader.remaining, 0)
    }

    func testASCIIMeshWithFaces() throws {
        let mesh = RoomMeshBuilder.box(size: .one, color: SIMD3(10, 20, 30))
        let data = try PLYWriter(encoding: .ascii).data(for: mesh)
        let info = try ExportValidator.validatePLY(data)
        XCTAssertEqual(info.format, "ascii")
        XCTAssertEqual(info.vertexCount, 24)
        XCTAssertEqual(info.faceCount, 12)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("property list uchar uint vertex_indices"))
        XCTAssertTrue(text.hasSuffix("3 20 22 23\n"))
    }

    func testBinaryMeshSizeIncludesFaces() throws {
        let mesh = RoomMeshBuilder.box(size: .one)
        let data = try PLYWriter().data(for: mesh)
        let info = try ExportValidator.validatePLY(data)
        XCTAssertEqual(data.count, info.headerLength + 24 * 24 + 12 * 13)
    }

    func testEmptyCloudIsRejected() {
        XCTAssertThrowsError(try PLYWriter().data(for: PointCloud())) { error in
            XCTAssertEqual(error as? ExportError, .nothingToExport(.ply))
        }
    }

    func testValidatorDetectsTruncation() throws {
        let data = try PLYWriter().data(for: sampleCloud())
        XCTAssertThrowsError(try ExportValidator.validatePLY(data.dropLast(2)))
    }
}

final class OBJWriterTests: XCTestCase {
    func testRoomExportHasGroupsMaterialsAndNormals() throws {
        let room = RoomModelTests.sampleRoom()
        let output = try OBJWriter(includeVertexColors: false).makeOutput(groups: RoomMeshBuilder.namedMeshes(for: room), baseName: "living")
        let info = try ExportValidator.validateOBJ(output.obj)
        XCTAssertEqual(info.vertexCount, 4 * 24)
        XCTAssertEqual(info.normalCount, 4 * 24)
        XCTAssertEqual(info.faceCount, 4 * 12)
        XCTAssertEqual(output.mtlFileName, "living.mtl")

        let obj = try XCTUnwrap(String(data: output.obj, encoding: .utf8))
        XCTAssertTrue(obj.contains("mtllib living.mtl"))
        XCTAssertTrue(obj.contains("usemtl wall"))
        XCTAssertTrue(obj.contains("usemtl object"))
        // Second group's faces are offset by the first group's 24 vertices.
        XCTAssertTrue(obj.contains("f 25//25"))

        let mtl = try XCTUnwrap(String(data: output.mtl, encoding: .utf8))
        XCTAssertTrue(mtl.contains("newmtl wall"))
        XCTAssertTrue(mtl.contains("newmtl door"))
        XCTAssertTrue(mtl.contains("Kd "))
    }

    func testVertexColorsExtension() throws {
        let mesh = RoomMeshBuilder.box(size: .one, color: SIMD3(255, 0, 0))
        let output = try OBJWriter(includeVertexColors: true).makeOutput(
            groups: [NamedMesh(name: "m", materialName: "scan", color: SIMD3(255, 0, 0), mesh: mesh)],
            baseName: "x"
        )
        let obj = try XCTUnwrap(String(data: output.obj, encoding: .utf8))
        XCTAssertTrue(obj.contains(" 1.0000 0.0000 0.0000\n"))
        XCTAssertNoThrow(try ExportValidator.validateOBJ(output.obj))
    }

    func testPointCloudOBJ() throws {
        let output = try OBJWriter().makePointCloudOutput(PointCloud(positions: [.zero, .one]), baseName: "p")
        let info = try ExportValidator.validateOBJ(output.obj)
        XCTAssertEqual(info.vertexCount, 2)
        XCTAssertEqual(info.faceCount, 0)
    }

    func testValidatorRejectsOutOfRangeFace() {
        XCTAssertThrowsError(try ExportValidator.validateOBJ(Data("v 0 0 0\nv 1 0 0\nf 1 2 3\n".utf8)))
    }

    func testNothingToExport() {
        XCTAssertThrowsError(try OBJWriter().makeOutput(groups: [], baseName: "x"))
    }
}

final class USDZTests: XCTestCase {
    func testCRC32KnownValue() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }

    func testPackagerAlignsEveryEntry() throws {
        let usda = Data("#usda 1.0\n".utf8)
        let package = try USDZPackager.package([
            .init(path: "scan.usda", data: usda),
            .init(path: "textures/a.png", data: Data(repeating: 7, count: 37)),
            .init(path: "x.txt", data: Data(repeating: 1, count: 3))
        ])
        let info = try ExportValidator.validateUSDZ(package)
        XCTAssertEqual(info.entryPaths, ["scan.usda", "textures/a.png", "x.txt"])
    }

    func testPackagerRequiresUSDRootLayer() {
        XCTAssertThrowsError(try USDZPackager.package([.init(path: "a.png", data: Data([1]))])) { error in
            XCTAssertEqual(error as? USDZPackager.PackagingError, .rootLayerMustBeUSD("a.png"))
        }
        XCTAssertThrowsError(try USDZPackager.package([]))
        XCTAssertThrowsError(try USDZPackager.package([.init(path: "../evil.usda", data: Data())]))
    }

    func testValidatorDetectsCorruption() throws {
        var package = try USDZPackager.package([.init(path: "scan.usda", data: Data("#usda 1.0\n".utf8))])
        package[70] ^= 0xFF // flip a payload byte
        XCTAssertThrowsError(try ExportValidator.validateUSDZ(package))
    }

    func testUSDAContainsMeshPointsAndMaterials() throws {
        let cloud = PointCloud(positions: [Vector3(0, 0, 0), Vector3(1, 0, 0)], colors: [SIMD3(255, 0, 0), SIMD3(0, 0, 255)])
        var mesh = RoomMeshBuilder.box(size: .one)
        mesh.colors = (0..<mesh.vertexCount).map { SIMD3(UInt8($0), 0, 0) }
        let usda = try USDAWriter().makeUSDA(
            meshes: [NamedMesh(name: "scan mesh", materialName: "scan", color: SIMD3(200, 200, 200), mesh: mesh)],
            pointCloud: cloud
        )
        XCTAssertTrue(usda.hasPrefix("#usda 1.0"))
        XCTAssertTrue(usda.contains("defaultPrim = \"Scan\""))
        XCTAssertTrue(usda.contains("metersPerUnit = 1"))
        XCTAssertTrue(usda.contains("def Mesh \"scan_mesh\""))
        XCTAssertTrue(usda.contains("def Points \"point_cloud\""))
        XCTAssertTrue(usda.contains("UsdPrimvarReader_float3"))
        XCTAssertTrue(usda.contains("rel material:binding = </Scan/Materials/scan>"))
        XCTAssertEqual(usda.components(separatedBy: "{").count, usda.components(separatedBy: "}").count)

        let package = try USDZPackager.package([.init(path: "scan.usda", data: Data(usda.utf8))])
        XCTAssertNoThrow(try ExportValidator.validateUSDZ(package))
    }

    func testUSDARoomUsesConstantColors() throws {
        let usda = try USDAWriter().makeUSDA(meshes: RoomMeshBuilder.namedMeshes(for: RoomModelTests.sampleRoom()), pointCloud: nil)
        XCTAssertFalse(usda.contains("UsdPrimvarReader_float3"))
        XCTAssertTrue(usda.contains("def Material \"wall\""))
    }

    func testIdentifierSanitizing() {
        let writer = USDAWriter()
        XCTAssertEqual(writer.identifier("1 bad-name"), "_1_bad_name")
        XCTAssertEqual(writer.identifier(""), "unnamed")
    }
}
