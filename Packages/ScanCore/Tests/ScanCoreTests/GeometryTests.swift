import XCTest
@testable import ScanCore

final class VectorMathTests: XCTestCase {
    func testDotCrossLength() {
        let a = Vector3(1, 0, 0), b = Vector3(0, 1, 0)
        XCTAssertEqual(a.dot(b), 0)
        XCTAssertEqual(a.cross(b), Vector3(0, 0, 1))
        XCTAssertEqual(Vector3(3, 4, 0).length, 5)
        XCTAssertEqual(Vector3(0, 0, 9).normalized, Vector3(0, 0, 1))
        XCTAssertEqual(Vector3.zero.normalized, .zero)
    }

    func testTriangleArea() {
        XCTAssertEqual(GeometryMath.triangleArea(.zero, Vector3(2, 0, 0), Vector3(0, 2, 0)), 2, accuracy: 1e-6)
    }

    func testMedian() {
        XCTAssertEqual(GeometryMath.median([3, 1, 2]), 2)
        XCTAssertEqual(GeometryMath.median([4, 1, 2, 3]), 2.5)
        XCTAssertNil(GeometryMath.median([]))
    }

    func testTransformComposition() {
        let t = Transform3D(translation: Vector3(1, 2, 3))
        let r = Transform3D(rotationY: .pi / 2)
        let p = (t * r).transformPoint(Vector3(1, 0, 0))
        XCTAssertEqual(p.x, 1, accuracy: 1e-5)
        XCTAssertEqual(p.y, 2, accuracy: 1e-5)
        XCTAssertEqual(p.z, 2, accuracy: 1e-5) // (1,0,0) rotated +90° about Y → (0,0,-1)
        XCTAssertEqual(t.transformDirection(Vector3(0, 1, 0)), Vector3(0, 1, 0))
    }

    func testBoundingBox() throws {
        let box = try XCTUnwrap(BoundingBox(points: [Vector3(1, 2, 3), Vector3(-1, 0, 5), Vector3(.nan, 0, 0)]))
        XCTAssertEqual(box.min, Vector3(-1, 0, 3))
        XCTAssertEqual(box.max, Vector3(1, 2, 5))
        XCTAssertEqual(box.center, Vector3(0, 1, 4))
        XCTAssertNil(BoundingBox(points: [Vector3]()))
    }

    func testRayTriangleIntersection() throws {
        let ray = try XCTUnwrap(Ray(origin: Vector3(0.2, 0.2, 5), direction: Vector3(0, 0, -1)))
        let t = ray.intersectTriangle(.zero, Vector3(1, 0, 0), Vector3(0, 1, 0))
        XCTAssertEqual(try XCTUnwrap(t), 5, accuracy: 1e-5)
        XCTAssertNil(ray.intersectTriangle(Vector3(5, 5, 0), Vector3(6, 5, 0), Vector3(5, 6, 0)))
    }

    func testPointPickerPrefersClosestToRay() throws {
        let ray = try XCTUnwrap(Ray(origin: .zero, direction: Vector3(0, 0, -1)))
        let points = [Vector3(0.5, 0, -1), Vector3(0.001, 0, -2), Vector3(0, 0, 3)]
        XCTAssertEqual(PointPicker.pick(positions: points, ray: ray), 1)
        XCTAssertNil(PointPicker.pick(positions: [Vector3(1, 0, -1)], ray: ray))
    }
}

final class MeshTests: XCTestCase {
    func testBoxMeshIsValidAndClosed() throws {
        let box = RoomMeshBuilder.box(size: Vector3(2, 1, 0.5))
        try box.validate()
        XCTAssertEqual(box.vertexCount, 24)
        XCTAssertEqual(box.triangleCount, 12)
        let expectedArea: Float = 7 // 2 × (2·1 + 2·0.5 + 1·0.5)
        XCTAssertEqual(MeshStatistics.surfaceArea(box), expectedArea, accuracy: 1e-5)
        // Outward winding: face normal agrees with stored vertex normal.
        for face in 0..<box.triangleCount {
            let (a, b, c) = box.triangle(face)
            let n = GeometryMath.faceNormal(a, b, c).normalized
            XCTAssertGreaterThan(n.dot(box.normals![Int(box.indices[face * 3])]), 0.99)
        }
    }

    func testMergedMeshOffsetsIndices() throws {
        let a = RoomMeshBuilder.box(size: .one)
        let b = RoomMeshBuilder.box(size: .one).transformed(by: Transform3D(translation: Vector3(5, 0, 0)))
        let merged = TriangleMesh.merged([a, b])
        try merged.validate()
        XCTAssertEqual(merged.vertexCount, 48)
        XCTAssertEqual(merged.indices.max(), 47)
    }

    func testMergeDropsPartialAttributes() {
        var a = RoomMeshBuilder.box(size: .one)
        a.colors = nil
        let b = RoomMeshBuilder.box(size: .one, color: SIMD3(1, 2, 3))
        XCTAssertNil(TriangleMesh.merged([a, b]).colors)
    }

    func testValidationCatchesBadIndices() {
        let mesh = TriangleMesh(positions: [.zero, .one], indices: [0, 1, 2])
        XCTAssertThrowsError(try mesh.validate())
        XCTAssertThrowsError(try TriangleMesh(positions: [.zero], indices: [0, 0]).validate())
    }

    func testWeldingMergesDuplicateSeamVertices() throws {
        // Two triangles sharing an edge but with duplicated vertices (as ARMeshAnchor chunks do).
        let mesh = TriangleMesh(
            positions: [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0),
                        Vector3(1, 0, 0.0001), Vector3(1, 1, 0), Vector3(0, 1, 0.0001)],
            indices: [0, 1, 2, 3, 4, 5]
        )
        let welded = try MeshCleanup.vertexClustering(mesh, cellSize: 0.002)
        XCTAssertEqual(welded.vertexCount, 4)
        XCTAssertEqual(welded.triangleCount, 2)
    }

    func testDegenerateAndSmallComponentRemoval() throws {
        let big = RoomMeshBuilder.box(size: .one)
        let welded = try MeshCleanup.vertexClustering(big, cellSize: 0.001) // 8 shared corners
        let speck = TriangleMesh(positions: [Vector3(9, 9, 9), Vector3(9.01, 9, 9), Vector3(9, 9.01, 9)], indices: [0, 1, 2])
        let degenerate = TriangleMesh(positions: [Vector3(5, 5, 5), Vector3(5, 5, 5), Vector3(6, 5, 5)], indices: [0, 1, 2])
        var mesh = TriangleMesh.merged([welded, speck, degenerate])
        mesh = MeshCleanup.removeDegenerateTriangles(mesh)
        XCTAssertEqual(mesh.triangleCount, 13)
        mesh = try MeshCleanup.removeSmallComponents(mesh, minTriangles: 5)
        XCTAssertEqual(mesh.triangleCount, 12)
        XCTAssertEqual(mesh.vertexCount, 8)
        try mesh.validate()
    }

    func testDecimationRespectsBudget() throws {
        // Dense grid of 100x100 quads.
        var positions: [Vector3] = []
        var indices: [UInt32] = []
        let n = 100
        for z in 0...n { for x in 0...n { positions.append(Vector3(Float(x) * 0.01, 0, Float(z) * 0.01)) } }
        for z in 0..<n {
            for x in 0..<n {
                let i = UInt32(z * (n + 1) + x)
                let j = i + UInt32(n + 1)
                indices += [i, j, i + 1, i + 1, j, j + 1]
            }
        }
        let mesh = TriangleMesh(positions: positions, indices: indices)
        let decimated = try MeshCleanup.decimate(mesh, maxTriangles: 2_000, initialCellSize: 0.015)
        XCTAssertLessThanOrEqual(decimated.triangleCount, 2_000)
        XCTAssertGreaterThan(decimated.triangleCount, 0)
        try decimated.validate()
    }

    func testComputedNormalsPointUpForFloor() {
        let mesh = TriangleMesh(positions: [.zero, Vector3(0, 0, 1), Vector3(1, 0, 0)], indices: [0, 1, 2])
        let normals = MeshCleanup.computeVertexNormals(mesh)
        XCTAssertEqual(normals[0], Vector3(0, 1, 0))
    }
}

final class VoxelAndPointCloudTests: XCTestCase {
    func testVoxelGridFusesObservations() {
        var grid = VoxelGrid(voxelSize: 0.01, maxVoxels: 100)
        XCTAssertEqual(grid.insert(Vector3(0.001, 0.001, 0.001), color: SIMD3(100, 0, 0)), .created)
        XCTAssertEqual(grid.insert(Vector3(0.003, 0.003, 0.003), color: SIMD3(200, 0, 0)), .merged)
        XCTAssertEqual(grid.insert(Vector3(0.5, 0.5, 0.5)), .created)
        XCTAssertEqual(grid.voxelCount, 2)
        let cloud = grid.makePointCloud(minObservations: 2)
        XCTAssertEqual(cloud.count, 1)
        XCTAssertEqual(cloud.positions[0].x, 0.002, accuracy: 1e-6)
        XCTAssertEqual(cloud.colors?[0], SIMD3(150, 0, 0))
    }

    func testVoxelBudget() {
        var grid = VoxelGrid(voxelSize: 0.01, maxVoxels: 2)
        grid.insert(Vector3(0, 0, 0))
        grid.insert(Vector3(1, 0, 0))
        XCTAssertEqual(grid.insert(Vector3(2, 0, 0)), .rejected)
        XCTAssertTrue(grid.isFull)
        XCTAssertEqual(grid.insert(Vector3(0.001, 0, 0)), .merged)
    }

    func testNonFinitePointsRejected() {
        var grid = VoxelGrid(voxelSize: 0.01, maxVoxels: 10)
        XCTAssertEqual(grid.insert(Vector3(.infinity, 0, 0)), .rejected)
    }

    func testRadiusOutlierRemoval() throws {
        var positions: [Vector3] = []
        for x in 0..<10 { for z in 0..<10 { positions.append(Vector3(Float(x) * 0.01, 0, Float(z) * 0.01)) } }
        positions.append(Vector3(5, 5, 5)) // isolated outlier
        let filtered = try PointCloudFilters.radiusOutlierRemoval(PointCloud(positions: positions), radius: 0.025, minNeighbors: 3)
        XCTAssertEqual(filtered.count, 100)
        XCTAssertFalse(filtered.positions.contains(Vector3(5, 5, 5)))
    }

    func testAccumulatorActor() async {
        let accumulator = PointCloudAccumulator(voxelSize: 0.01, maxPoints: 1000)
        await accumulator.add(PointBatch(positions: [.zero, Vector3(0.001, 0, 0), Vector3(1, 1, 1)]))
        let stats = await accumulator.statistics()
        XCTAssertEqual(stats.voxelCount, 2)
        XCTAssertEqual(stats.samplesProcessed, 3)
        await accumulator.setAcceptingSamples(false)
        await accumulator.add(PointBatch(positions: [Vector3(3, 3, 3)]))
        let afterPause = await accumulator.statistics()
        XCTAssertEqual(afterPause.voxelCount, 2)
        await accumulator.reset()
        let afterReset = await accumulator.statistics()
        XCTAssertEqual(afterReset, .zero)
    }

    func testColorizeAndNormalTransfer() throws {
        var grid = VoxelGrid(voxelSize: 0.05, maxVoxels: 100)
        grid.insert(Vector3(0, 0, 0), color: SIMD3(255, 0, 0))
        let mesh = MeshCleanup.withVertexNormals(TriangleMesh(positions: [Vector3(0.01, 0, 0), Vector3(0, 0, 0.04), Vector3(0.04, 0, 0)], indices: [0, 1, 2]))
        let colored = try AttributeTransfer.colorize(mesh, from: grid)
        XCTAssertEqual(colored.colors?[0], SIMD3(255, 0, 0))

        let cloud = try AttributeTransfer.transferNormals(from: mesh, to: PointCloud(positions: [Vector3(0.01, 0.001, 0), Vector3(9, 9, 9)]), searchRadius: 0.05)
        XCTAssertEqual(cloud.normals?[0], Vector3(0, 1, 0))
        XCTAssertEqual(cloud.normals?[1], .zero)
    }

    func testProcessingPipelineProducesValidGeometry() throws {
        var grid = VoxelGrid(voxelSize: 0.01, maxVoxels: 100_000)
        for x in 0..<20 {
            for z in 0..<20 {
                let p = Vector3(Float(x) * 0.01 + 0.005, 0, Float(z) * 0.01 + 0.005)
                grid.insert(p, color: SIMD3(10, 20, 30))
                grid.insert(p, color: SIMD3(10, 20, 30))
            }
        }
        let rawMesh = RoomMeshBuilder.box(size: Vector3(0.2, 0.01, 0.2))
        var steps: [ProcessingStep] = []
        let (geometry, report) = try ObjectScanProcessingPipeline.process(
            rawMesh: rawMesh,
            grid: grid,
            options: .default(voxelSize: 0.01),
            progress: { steps.append($0) }
        )
        XCTAssertEqual(report.rawVoxelCount, 400)
        XCTAssertEqual(geometry.pointCloud?.count, 400)
        XCTAssertNotNil(geometry.pointCloud?.normals)
        let mesh = try XCTUnwrap(geometry.mesh)
        try mesh.validate()
        XCTAssertNotNil(mesh.normals)
        XCTAssertNotNil(mesh.colors)
        XCTAssertTrue(steps.contains(.cleaningMesh))
    }
}

final class RoomModelTests: XCTestCase {
    static func sampleRoom() -> RoomModel {
        let wallA = RoomElement(kind: .wall, category: "Wall", dimensions: Vector3(4, 2.5, 0),
                                transform: Transform3D(translation: Vector3(0, 1.25, -1.5)), confidence: "high")
        let wallB = RoomElement(kind: .wall, category: "Wall", dimensions: Vector3(3, 2.4, 0),
                                transform: Transform3D(translation: Vector3(2, 1.2, 0)) * Transform3D(rotationY: .pi / 2), confidence: "high")
        let door = RoomElement(kind: .door, category: "Door (closed)", dimensions: Vector3(0.9, 2.0, 0),
                               transform: Transform3D(translation: Vector3(0, 1.0, -1.5)), confidence: "medium", parentID: wallA.id)
        let table = RoomElement(kind: .object, category: "Table", dimensions: Vector3(1.2, 0.75, 0.8),
                                transform: Transform3D(translation: Vector3(0, 0.375, 0)), confidence: "high")
        return RoomModel(elements: [wallA, wallB, door, table])
    }

    func testSummary() throws {
        let summary = Self.sampleRoom().summary
        XCTAssertEqual(summary.wallCount, 2)
        XCTAssertEqual(summary.doorCount, 1)
        XCTAssertEqual(summary.objectCount, 1)
        XCTAssertEqual(summary.totalWallLength, 7, accuracy: 1e-5)
        XCTAssertEqual(summary.maxWallHeight, 2.5, accuracy: 1e-5)
        XCTAssertEqual(summary.objectCategories["Table"], 1)
        let extent = try XCTUnwrap(summary.footprintExtent)
        XCTAssertEqual(extent.x, 4, accuracy: 0.01)
    }

    func testRoomMeshesAreValid() throws {
        let room = Self.sampleRoom()
        let named = RoomMeshBuilder.namedMeshes(for: room)
        XCTAssertEqual(named.count, 4)
        XCTAssertEqual(Set(named.map(\.name)).count, 4)
        let mesh = RoomMeshBuilder.mesh(for: room)
        try mesh.validate()
        XCTAssertEqual(mesh.triangleCount, 48)
    }

    func testGeometryCodecRoundTrip() throws {
        let cloud = PointCloud(positions: [Vector3(1, 2, 3), Vector3(-1, 0.5, 2)],
                               colors: [SIMD3(1, 2, 3), SIMD3(250, 251, 252)],
                               normals: [Vector3(0, 1, 0), Vector3(1, 0, 0)])
        let geometry = ScanGeometry(pointCloud: cloud, mesh: RoomMeshBuilder.box(size: .one, color: SIMD3(9, 9, 9)), room: Self.sampleRoom())
        let data = try ScanGeometryCodec.encode(geometry)
        let decoded = try ScanGeometryCodec.decode(data)
        XCTAssertEqual(decoded, geometry)
    }

    func testCodecRejectsGarbageAndTruncation() throws {
        XCTAssertThrowsError(try ScanGeometryCodec.decode(Data("nope".utf8)))
        let data = try ScanGeometryCodec.encode(ScanGeometry(mesh: RoomMeshBuilder.box(size: .one)))
        XCTAssertThrowsError(try ScanGeometryCodec.decode(data.prefix(data.count - 5))) { error in
            guard case .corrupted = error as? ScanGeometryCodecError else { return XCTFail("expected corrupted, got \(error)") }
        }
    }
}
