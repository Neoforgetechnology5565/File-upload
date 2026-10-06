import Foundation

public enum GeometryError: Error, Equatable, LocalizedError {
    case attributeCountMismatch(attribute: String, expected: Int, actual: Int)
    case indexCountNotMultipleOfThree(Int)
    case indexOutOfRange(index: UInt32, vertexCount: Int)
    case nonFiniteValue(attribute: String)
    case empty

    public var errorDescription: String? {
        switch self {
        case let .attributeCountMismatch(attribute, expected, actual):
            return "Geometry attribute '\(attribute)' has \(actual) values, expected \(expected)."
        case let .indexCountNotMultipleOfThree(count):
            return "Triangle index count \(count) is not a multiple of 3."
        case let .indexOutOfRange(index, vertexCount):
            return "Triangle index \(index) is out of range for \(vertexCount) vertices."
        case let .nonFiniteValue(attribute):
            return "Geometry attribute '\(attribute)' contains non-finite values."
        case .empty:
            return "The geometry contains no data."
        }
    }
}

/// A colored, optionally oriented point cloud in world space (meters).
public struct PointCloud: Equatable, Sendable {
    public var positions: [Vector3]
    /// sRGB colors, one per point, when captured from the camera image.
    public var colors: [SIMD3<UInt8>]?
    /// Unit normals, one per point, when available.
    public var normals: [Vector3]?

    public init(positions: [Vector3] = [], colors: [SIMD3<UInt8>]? = nil, normals: [Vector3]? = nil) {
        self.positions = positions
        self.colors = colors
        self.normals = normals
    }

    public static let empty = PointCloud()

    public var count: Int { positions.count }
    public var isEmpty: Bool { positions.isEmpty }
    public var hasColors: Bool { colors != nil }
    public var hasNormals: Bool { normals != nil }
    public var boundingBox: BoundingBox? { BoundingBox(points: positions) }

    public func validate() throws {
        if let colors, colors.count != positions.count {
            throw GeometryError.attributeCountMismatch(attribute: "color", expected: positions.count, actual: colors.count)
        }
        if let normals, normals.count != positions.count {
            throw GeometryError.attributeCountMismatch(attribute: "normal", expected: positions.count, actual: normals.count)
        }
        if positions.contains(where: { !$0.isFiniteVector }) {
            throw GeometryError.nonFiniteValue(attribute: "position")
        }
    }

    /// Returns a copy containing only the points at `indices` (attributes kept in sync).
    public func subset(_ indices: [Int]) -> PointCloud {
        PointCloud(
            positions: indices.map { positions[$0] },
            colors: colors.map { c in indices.map { c[$0] } },
            normals: normals.map { n in indices.map { n[$0] } }
        )
    }

    public func transformed(by transform: Transform3D) -> PointCloud {
        PointCloud(
            positions: positions.map(transform.transformPoint),
            colors: colors,
            normals: normals.map { $0.map { transform.transformDirection($0).normalized } }
        )
    }
}
