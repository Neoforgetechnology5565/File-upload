import Foundation

/// Convenience alias used throughout ScanCore. Positions are expressed in
/// meters in the ARKit/RoomPlan world coordinate system (Y up, gravity aligned).
public typealias Vector3 = SIMD3<Float>

/// Vector helpers implemented on top of the Swift standard library SIMD types.
///
/// These intentionally do not depend on Apple's `simd` module so ScanCore
/// stays portable and testable on any platform. Method names were chosen so
/// they never collide with the free functions exported by `simd`.
public extension SIMD3 where Scalar == Float {
    func dot(_ other: SIMD3<Float>) -> Float {
        (self * other).sum()
    }

    func cross(_ other: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(
            y * other.z - z * other.y,
            z * other.x - x * other.z,
            x * other.y - y * other.x
        )
    }

    var lengthSquared: Float { dot(self) }

    var length: Float { lengthSquared.squareRoot() }

    /// Unit-length copy of the vector, or `.zero` for (near) zero vectors.
    var normalized: SIMD3<Float> {
        let len = length
        return len > Float.ulpOfOne ? self / len : .zero
    }

    func distance(to other: SIMD3<Float>) -> Float {
        (self - other).length
    }

    var isFiniteVector: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}

public enum GeometryMath {
    /// Area of the triangle (a, b, c) in square units.
    public static func triangleArea(_ a: Vector3, _ b: Vector3, _ c: Vector3) -> Float {
        (b - a).cross(c - a).length * 0.5
    }

    /// Unnormalized face normal (length == 2 * area).
    public static func faceNormal(_ a: Vector3, _ b: Vector3, _ c: Vector3) -> Vector3 {
        (b - a).cross(c - a)
    }

    /// Newell's method: area vector of a (planar) polygon. Its length is the
    /// polygon area; its direction is the polygon normal.
    public static func newellAreaVector(_ polygon: [Vector3]) -> Vector3 {
        guard polygon.count >= 3 else { return .zero }
        var normal = Vector3.zero
        for i in 0..<polygon.count {
            let current = polygon[i]
            let next = polygon[(i + 1) % polygon.count]
            normal.x += (current.y - next.y) * (current.z + next.z)
            normal.y += (current.z - next.z) * (current.x + next.x)
            normal.z += (current.x - next.x) * (current.y + next.y)
        }
        return normal * 0.5
    }

    /// Median of a non-empty array (copies & partially sorts the input).
    public static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) * 0.5
        }
        return sorted[mid]
    }
}
