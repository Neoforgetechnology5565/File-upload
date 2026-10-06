import Foundation

/// A column-major 4x4 affine transform.
///
/// Memory layout and semantics match `simd_float4x4` (columns c0...c3, with
/// the translation in c3), so the app layer can convert losslessly between
/// the two (see `Transform3D+simd.swift` in the app target).
public struct Transform3D: Codable, Equatable, Hashable, Sendable {
    public var c0: SIMD4<Float>
    public var c1: SIMD4<Float>
    public var c2: SIMD4<Float>
    public var c3: SIMD4<Float>

    public init(c0: SIMD4<Float>, c1: SIMD4<Float>, c2: SIMD4<Float>, c3: SIMD4<Float>) {
        self.c0 = c0
        self.c1 = c1
        self.c2 = c2
        self.c3 = c3
    }

    public static let identity = Transform3D(
        c0: SIMD4(1, 0, 0, 0),
        c1: SIMD4(0, 1, 0, 0),
        c2: SIMD4(0, 0, 1, 0),
        c3: SIMD4(0, 0, 0, 1)
    )

    public init(translation t: Vector3) {
        self = .identity
        c3 = SIMD4(t.x, t.y, t.z, 1)
    }

    /// Rotation around the world Y (up) axis.
    public init(rotationY radians: Float) {
        let c = cos(radians)
        let s = sin(radians)
        self.init(
            c0: SIMD4(c, 0, -s, 0),
            c1: SIMD4(0, 1, 0, 0),
            c2: SIMD4(s, 0, c, 0),
            c3: SIMD4(0, 0, 0, 1)
        )
    }

    public init(scale s: Vector3) {
        self.init(
            c0: SIMD4(s.x, 0, 0, 0),
            c1: SIMD4(0, s.y, 0, 0),
            c2: SIMD4(0, 0, s.z, 0),
            c3: SIMD4(0, 0, 0, 1)
        )
    }

    public var translation: Vector3 {
        Vector3(c3.x, c3.y, c3.z)
    }

    /// Transforms a position (w = 1).
    @inline(__always)
    public func transformPoint(_ p: Vector3) -> Vector3 {
        let r = c0 * p.x + c1 * p.y + c2 * p.z + c3
        return Vector3(r.x, r.y, r.z)
    }

    /// Transforms a direction (w = 0). For rigid transforms (ARKit anchors,
    /// RoomPlan surfaces) this is also the correct normal transform.
    @inline(__always)
    public func transformDirection(_ d: Vector3) -> Vector3 {
        let r = c0 * d.x + c1 * d.y + c2 * d.z
        return Vector3(r.x, r.y, r.z)
    }

    /// Matrix product `lhs * rhs` (apply rhs first, then lhs).
    public static func * (lhs: Transform3D, rhs: Transform3D) -> Transform3D {
        func mul(_ v: SIMD4<Float>) -> SIMD4<Float> {
            lhs.c0 * v.x + lhs.c1 * v.y + lhs.c2 * v.z + lhs.c3 * v.w
        }
        return Transform3D(c0: mul(rhs.c0), c1: mul(rhs.c1), c2: mul(rhs.c2), c3: mul(rhs.c3))
    }

    /// Flattened column-major array of 16 floats (USD/Model I/O friendly).
    public var columnMajorArray: [Float] {
        [c0.x, c0.y, c0.z, c0.w,
         c1.x, c1.y, c1.z, c1.w,
         c2.x, c2.y, c2.z, c2.w,
         c3.x, c3.y, c3.z, c3.w]
    }
}
