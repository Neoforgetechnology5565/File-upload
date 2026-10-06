import Foundation

/// An indexed triangle mesh in world space (meters).
///
/// This is the single internal mesh representation used by the viewer,
/// measurement engine and every exporter, regardless of whether the data came
/// from ARKit scene reconstruction (`ARMeshAnchor`) or from RoomPlan.
public struct TriangleMesh: Equatable, Sendable {
    public var positions: [Vector3]
    public var normals: [Vector3]?
    public var colors: [SIMD3<UInt8>]?
    /// Counter-clockwise triangles, three indices per face.
    public var indices: [UInt32]

    public init(
        positions: [Vector3] = [],
        normals: [Vector3]? = nil,
        colors: [SIMD3<UInt8>]? = nil,
        indices: [UInt32] = []
    ) {
        self.positions = positions
        self.normals = normals
        self.colors = colors
        self.indices = indices
    }

    public static let empty = TriangleMesh()

    public var vertexCount: Int { positions.count }
    public var triangleCount: Int { indices.count / 3 }
    public var isEmpty: Bool { positions.isEmpty || indices.isEmpty }
    public var boundingBox: BoundingBox? { BoundingBox(points: positions) }

    public func validate() throws {
        if indices.count % 3 != 0 {
            throw GeometryError.indexCountNotMultipleOfThree(indices.count)
        }
        if let normals, normals.count != positions.count {
            throw GeometryError.attributeCountMismatch(attribute: "normal", expected: positions.count, actual: normals.count)
        }
        if let colors, colors.count != positions.count {
            throw GeometryError.attributeCountMismatch(attribute: "color", expected: positions.count, actual: colors.count)
        }
        let vertexCount = positions.count
        if let bad = indices.first(where: { Int($0) >= vertexCount }) {
            throw GeometryError.indexOutOfRange(index: bad, vertexCount: vertexCount)
        }
        if positions.contains(where: { !$0.isFiniteVector }) {
            throw GeometryError.nonFiniteValue(attribute: "position")
        }
    }

    public func triangle(_ face: Int) -> (Vector3, Vector3, Vector3) {
        let base = face * 3
        return (
            positions[Int(indices[base])],
            positions[Int(indices[base + 1])],
            positions[Int(indices[base + 2])]
        )
    }

    public func transformed(by transform: Transform3D) -> TriangleMesh {
        TriangleMesh(
            positions: positions.map(transform.transformPoint),
            normals: normals.map { $0.map { transform.transformDirection($0).normalized } },
            colors: colors,
            indices: indices
        )
    }

    /// Concatenates meshes. Normals/colors are kept only if every non-empty
    /// input provides them, so attributes always stay index-aligned.
    public static func merged(_ meshes: [TriangleMesh]) -> TriangleMesh {
        let parts = meshes.filter { !$0.positions.isEmpty }
        guard !parts.isEmpty else { return .empty }
        let keepNormals = parts.allSatisfy { $0.normals != nil }
        let keepColors = parts.allSatisfy { $0.colors != nil }

        var result = TriangleMesh()
        result.positions.reserveCapacity(parts.reduce(0) { $0 + $1.positions.count })
        result.indices.reserveCapacity(parts.reduce(0) { $0 + $1.indices.count })
        var normals: [Vector3] = []
        var colors: [SIMD3<UInt8>] = []

        for part in parts {
            let offset = UInt32(result.positions.count)
            result.positions.append(contentsOf: part.positions)
            result.indices.append(contentsOf: part.indices.map { $0 + offset })
            if keepNormals, let n = part.normals { normals.append(contentsOf: n) }
            if keepColors, let c = part.colors { colors.append(contentsOf: c) }
        }
        result.normals = keepNormals ? normals : nil
        result.colors = keepColors ? colors : nil
        return result
    }
}
