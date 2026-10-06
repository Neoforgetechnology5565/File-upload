import XCTest
@testable import ScanCore

final class MeasurementTests: XCTestCase {
    private let engine = MeasurementEngine()

    func testDistanceIsEuclidean() throws {
        let m = try engine.measure(.distance, points: [Vector3(0, 0, 0), Vector3(3, 4, 0)])
        XCTAssertEqual(m.result, .length(meters: 5))
        XCTAssertEqual(m.kind, .distance)
    }

    func testDistanceIn3D() throws {
        let result = try DistanceTool().compute([Vector3(1, 2, 3), Vector3(2, 4, 5)])
        guard case .length(let meters) = result else { return XCTFail("expected length") }
        XCTAssertEqual(meters, 3, accuracy: 1e-6)
    }

    func testHeightUsesOnlyVerticalAxis() throws {
        let result = try HeightTool().compute([Vector3(0, 0.5, 0), Vector3(10, 2.0, -7)])
        guard case .length(let meters) = result else { return XCTFail("expected length") }
        XCTAssertEqual(meters, 1.5, accuracy: 1e-6)
    }

    func testHorizontalDistanceIgnoresHeight() throws {
        let result = try HorizontalDistanceTool().compute([Vector3(0, 0, 0), Vector3(3, 100, 4)])
        guard case .length(let meters) = result else { return XCTFail("expected length") }
        XCTAssertEqual(meters, 5, accuracy: 1e-5)
    }

    func testPolygonAreaOfUnitSquareOnFloor() throws {
        let square = [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1)]
        let result = try PolygonAreaTool().compute(square)
        guard case .area(let area) = result else { return XCTFail("expected area") }
        XCTAssertEqual(area, 1, accuracy: 1e-6)
    }

    func testPolygonAreaOfTiltedTriangle() throws {
        // Right triangle with legs 2 and 3 on a wall plane (x/y).
        let result = try PolygonAreaTool().compute([Vector3(0, 0, 5), Vector3(2, 0, 5), Vector3(0, 3, 5)])
        guard case .area(let area) = result else { return XCTFail("expected area") }
        XCTAssertEqual(area, 3, accuracy: 1e-5)
    }

    func testCollinearPolygonIsDegenerate() {
        XCTAssertThrowsError(try PolygonAreaTool().compute([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(2, 0, 0)])) { error in
            XCTAssertEqual(error as? MeasurementError, .degenerate)
        }
    }

    func testInsufficientPoints() {
        XCTAssertThrowsError(try DistanceTool().compute([Vector3(0, 0, 0)])) { error in
            XCTAssertEqual(error as? MeasurementError, .insufficientPoints(required: 2, provided: 1))
        }
    }

    func testTooManyPoints() {
        XCTAssertThrowsError(try DistanceTool().compute([.zero, .one, .zero]))
    }

    func testNonFinitePointRejected() {
        XCTAssertThrowsError(try DistanceTool().compute([.zero, Vector3(.nan, 0, 0)])) { error in
            XCTAssertEqual(error as? MeasurementError, .invalidPoint)
        }
    }

    func testBoundingBoxTool() throws {
        let result = try BoundingBoxTool().compute([Vector3(-1, 0, 2), Vector3(1, 3, -2), Vector3(0, 1, 0)])
        XCTAssertEqual(result, .box(size: Vector3(2, 3, 4)))
    }

    func testToolCompletion() {
        XCTAssertTrue(DistanceTool().isComplete(pointCount: 2))
        XCTAssertFalse(DistanceTool().isComplete(pointCount: 1))
        XCTAssertFalse(PolygonAreaTool().isComplete(pointCount: 10))
    }

    func testModelBounds() throws {
        let geometry = ScanGeometry(pointCloud: PointCloud(positions: [Vector3(0, 0, 0), Vector3(1, 2, 3)]))
        let m = try engine.modelBounds(of: geometry)
        XCTAssertEqual(m.result, .box(size: Vector3(1, 2, 3)))
    }

    func testMeasurementCodableRoundTrip() throws {
        let m = try engine.measure(.area, points: [.zero, Vector3(1, 0, 0), Vector3(0, 0, 1)], label: "Tabletop")
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(ScanMeasurement.self, from: data)
        XCTAssertEqual(decoded, m)
    }

    func testEngineSupportsAllDefaultKinds() {
        XCTAssertEqual(Set(engine.availableKinds), Set(MeasurementKind.allCases))
    }
}

final class LengthUnitTests: XCTestCase {
    func testConversions() {
        XCTAssertEqual(LengthUnit.centimeters.convert(meters: 1.5), 150, accuracy: 1e-9)
        XCTAssertEqual(LengthUnit.millimeters.convert(meters: 0.25), 250, accuracy: 1e-9)
        XCTAssertEqual(LengthUnit.feet.convert(meters: 0.3048), 1, accuracy: 1e-9)
        XCTAssertEqual(LengthUnit.inches.convert(meters: 0.0254), 1, accuracy: 1e-9)
        XCTAssertEqual(LengthUnit.feet.toMeters(10), 3.048, accuracy: 1e-9)
    }

    func testAreaConversion() {
        XCTAssertEqual(LengthUnit.centimeters.convert(squareMeters: 1), 10_000, accuracy: 1e-6)
        XCTAssertEqual(LengthUnit.feet.convert(squareMeters: 1), 10.7639, accuracy: 1e-3)
    }

    func testFormatting() {
        XCTAssertEqual(LengthUnit.meters.format(meters: 1.23456), "1.23 m")
        XCTAssertEqual(LengthUnit.centimeters.format(meters: 1.23456), "123.5 cm")
        XCTAssertEqual(LengthUnit.millimeters.format(meters: 0.0124), "12 mm")
        XCTAssertEqual(LengthUnit.meters.format(squareMeters: 2), "2.00 m²")
    }

    func testResultFormatting() {
        let box = MeasurementResult.box(size: Vector3(1, 2, 3))
        XCTAssertEqual(box.formatted(unit: .meters), "W 1.00 m × D 3.00 m × H 2.00 m")
    }
}
