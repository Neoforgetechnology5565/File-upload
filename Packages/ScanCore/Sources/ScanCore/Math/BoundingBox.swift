import Foundation

/// Axis-aligned bounding box in world space (meters).
public struct BoundingBox: Codable, Equatable, Hashable, Sendable {
    public var min: Vector3
    public var max: Vector3

    public init(min: Vector3, max: Vector3) {
        self.min = pointwiseMin(min, max)
        self.max = pointwiseMax(min, max)
    }

    /// Returns nil when the sequence contains no finite points.
    public init?<S: Sequence>(points: S) where S.Element == Vector3 {
        var lower = Vector3(repeating: .greatestFiniteMagnitude)
        var upper = Vector3(repeating: -.greatestFiniteMagnitude)
        var found = false
        for p in points where p.isFiniteVector {
            lower = pointwiseMin(lower, p)
            upper = pointwiseMax(upper, p)
            found = true
        }
        guard found else { return nil }
        self.min = lower
        self.max = upper
    }

    public var size: Vector3 { max - min }
    public var center: Vector3 { (min + max) * 0.5 }
    public var diagonalLength: Float { size.length }
    public var volume: Float { size.x * size.y * size.z }

    public mutating func expand(toInclude p: Vector3) {
        min = pointwiseMin(min, p)
        max = pointwiseMax(max, p)
    }

    public func union(_ other: BoundingBox) -> BoundingBox {
        BoundingBox(min: pointwiseMin(min, other.min), max: pointwiseMax(max, other.max))
    }

    public func contains(_ p: Vector3) -> Bool {
        p.x >= min.x && p.y >= min.y && p.z >= min.z &&
            p.x <= max.x && p.y <= max.y && p.z <= max.z
    }

    public var corners: [Vector3] {
        [
            Vector3(min.x, min.y, min.z), Vector3(max.x, min.y, min.z),
            Vector3(min.x, max.y, min.z), Vector3(max.x, max.y, min.z),
            Vector3(min.x, min.y, max.z), Vector3(max.x, min.y, max.z),
            Vector3(min.x, max.y, max.z), Vector3(max.x, max.y, max.z)
        ]
    }
}
