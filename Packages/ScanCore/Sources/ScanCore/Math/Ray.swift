import Foundation

/// A ray in world space. `direction` is always normalized.
public struct Ray: Equatable, Sendable {
    public let origin: Vector3
    public let direction: Vector3

    /// Returns nil if `direction` is degenerate.
    public init?(origin: Vector3, direction: Vector3) {
        let n = direction.normalized
        guard n != .zero, origin.isFiniteVector else { return nil }
        self.origin = origin
        self.direction = n
    }

    /// Ray through two points (e.g. near-plane and far-plane unprojections).
    public init?(from near: Vector3, through far: Vector3) {
        self.init(origin: near, direction: far - near)
    }

    public func point(at t: Float) -> Vector3 {
        origin + direction * t
    }

    /// Signed parameter of the orthogonal projection of `p` onto the ray line.
    public func projectedParameter(of p: Vector3) -> Float {
        (p - origin).dot(direction)
    }

    /// Perpendicular distance between `p` and the infinite ray line.
    public func perpendicularDistance(to p: Vector3) -> Float {
        let t = projectedParameter(of: p)
        return (p - point(at: t)).length
    }

    /// Möller–Trumbore ray/triangle intersection. Returns the ray parameter.
    public func intersectTriangle(_ a: Vector3, _ b: Vector3, _ c: Vector3) -> Float? {
        let epsilon: Float = 1e-7
        let edge1 = b - a
        let edge2 = c - a
        let h = direction.cross(edge2)
        let det = edge1.dot(h)
        if abs(det) < epsilon { return nil }
        let invDet = 1 / det
        let s = origin - a
        let u = invDet * s.dot(h)
        if u < 0 || u > 1 { return nil }
        let q = s.cross(edge1)
        let v = invDet * direction.dot(q)
        if v < 0 || u + v > 1 { return nil }
        let t = invDet * edge2.dot(q)
        return t > epsilon ? t : nil
    }
}
