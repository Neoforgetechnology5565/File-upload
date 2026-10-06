import Foundation

public enum MeasurementKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Straight-line 3D distance between two points.
    case distance
    /// Vertical (gravity-aligned Y) difference between two points.
    case height
    /// Horizontal distance (ignores Y) between two points — e.g. a width.
    case horizontalDistance
    /// Planar polygon area from three or more points.
    case area
    /// Axis-aligned extent of the selected points.
    case boundingBox

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .distance: return "Distance"
        case .height: return "Height"
        case .horizontalDistance: return "Width"
        case .area: return "Area"
        case .boundingBox: return "Bounding Box"
        }
    }

    public var systemImage: String {
        switch self {
        case .distance: return "ruler"
        case .height: return "arrow.up.and.down"
        case .horizontalDistance: return "arrow.left.and.right"
        case .area: return "square.dashed"
        case .boundingBox: return "cube.transparent"
        }
    }
}

public enum MeasurementResult: Codable, Equatable, Sendable {
    case length(meters: Double)
    case area(squareMeters: Double)
    case box(size: Vector3)

    public func formatted(unit: LengthUnit) -> String {
        switch self {
        case .length(let meters):
            return unit.format(meters: meters)
        case .area(let squareMeters):
            return unit.format(squareMeters: squareMeters)
        case .box(let size):
            let parts = [size.x, size.z, size.y].map { unit.format(meters: Double($0)) }
            return "W \(parts[0]) × D \(parts[1]) × H \(parts[2])"
        }
    }
}

public enum MeasurementError: Error, Equatable, LocalizedError {
    case insufficientPoints(required: Int, provided: Int)
    case tooManyPoints(maximum: Int, provided: Int)
    case invalidPoint
    case degenerate

    public var errorDescription: String? {
        switch self {
        case let .insufficientPoints(required, provided):
            return "This measurement needs at least \(required) points (\(provided) selected)."
        case let .tooManyPoints(maximum, provided):
            return "This measurement uses at most \(maximum) points (\(provided) selected)."
        case .invalidPoint:
            return "One of the selected points is invalid."
        case .degenerate:
            return "The selected points do not define a measurable shape."
        }
    }
}

/// A measurement tool. New tools (volume, angle, perimeter…) are added by
/// conforming a type and registering it with `MeasurementEngine`.
public protocol MeasurementTool: Sendable {
    var kind: MeasurementKind { get }
    var minimumPoints: Int { get }
    /// nil means unbounded.
    var maximumPoints: Int? { get }
    func compute(_ points: [Vector3]) throws -> MeasurementResult
}

public extension MeasurementTool {
    func validate(_ points: [Vector3]) throws {
        guard points.allSatisfy(\.isFiniteVector) else { throw MeasurementError.invalidPoint }
        if points.count < minimumPoints {
            throw MeasurementError.insufficientPoints(required: minimumPoints, provided: points.count)
        }
        if let maximumPoints, points.count > maximumPoints {
            throw MeasurementError.tooManyPoints(maximum: maximumPoints, provided: points.count)
        }
    }

    /// True when the tool can finalize automatically after this many points.
    func isComplete(pointCount: Int) -> Bool {
        if let maximumPoints { return pointCount >= maximumPoints }
        return false
    }
}

public struct DistanceTool: MeasurementTool {
    public init() {}
    public var kind: MeasurementKind { .distance }
    public var minimumPoints: Int { 2 }
    public var maximumPoints: Int? { 2 }

    public func compute(_ points: [Vector3]) throws -> MeasurementResult {
        try validate(points)
        return .length(meters: Double(points[0].distance(to: points[1])))
    }
}

public struct HeightTool: MeasurementTool {
    public init() {}
    public var kind: MeasurementKind { .height }
    public var minimumPoints: Int { 2 }
    public var maximumPoints: Int? { 2 }

    public func compute(_ points: [Vector3]) throws -> MeasurementResult {
        try validate(points)
        return .length(meters: Double(abs(points[1].y - points[0].y)))
    }
}

public struct HorizontalDistanceTool: MeasurementTool {
    public init() {}
    public var kind: MeasurementKind { .horizontalDistance }
    public var minimumPoints: Int { 2 }
    public var maximumPoints: Int? { 2 }

    public func compute(_ points: [Vector3]) throws -> MeasurementResult {
        try validate(points)
        let d = points[1] - points[0]
        return .length(meters: Double((d.x * d.x + d.z * d.z).squareRoot()))
    }
}

/// Area of the polygon formed by the points in order (Newell's method).
/// Exact for planar polygons; for slightly non-planar input it yields the area
/// of the projection onto the polygon's average plane.
public struct PolygonAreaTool: MeasurementTool {
    public init() {}
    public var kind: MeasurementKind { .area }
    public var minimumPoints: Int { 3 }
    public var maximumPoints: Int? { nil }

    public func compute(_ points: [Vector3]) throws -> MeasurementResult {
        try validate(points)
        let area = GeometryMath.newellAreaVector(points).length
        guard area > 1e-8 else { throw MeasurementError.degenerate }
        return .area(squareMeters: Double(area))
    }
}

public struct BoundingBoxTool: MeasurementTool {
    public init() {}
    public var kind: MeasurementKind { .boundingBox }
    public var minimumPoints: Int { 2 }
    public var maximumPoints: Int? { nil }

    public func compute(_ points: [Vector3]) throws -> MeasurementResult {
        try validate(points)
        guard let box = BoundingBox(points: points) else { throw MeasurementError.degenerate }
        return .box(size: box.size)
    }
}
