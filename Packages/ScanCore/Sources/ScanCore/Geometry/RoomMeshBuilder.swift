import Foundation

/// A named piece of geometry, used by exporters that preserve object grouping
/// (OBJ groups / materials, USD prims).
public struct NamedMesh: Equatable, Sendable {
    public var name: String
    public var materialName: String
    public var color: SIMD3<UInt8>
    public var mesh: TriangleMesh

    public init(name: String, materialName: String, color: SIMD3<UInt8>, mesh: TriangleMesh) {
        self.name = name
        self.materialName = materialName
        self.color = color
        self.mesh = mesh
    }
}

/// Converts the parametric RoomPlan representation (oriented boxes) into
/// triangle meshes for viewing and OBJ/PLY export.
///
/// RoomPlan reports surfaces as zero-thickness rectangles; we give them a
/// small, documented thickness so they form closed, printable solids.
public enum RoomMeshBuilder {
    /// Thickness applied to planar surfaces (meters).
    public static let wallThickness: Float = 0.10
    /// Doors/windows/openings are slightly thicker so they remain visible
    /// when embedded in their parent wall.
    public static let insetThickness: Float = 0.12
    public static let floorThickness: Float = 0.02

    public static func boxDimensions(for element: RoomElement) -> Vector3 {
        var d = element.dimensions
        if d.z <= 0.0001 {
            switch element.kind {
            case .wall: d.z = wallThickness
            case .door, .window, .opening: d.z = insetThickness
            case .floor: d.z = floorThickness
            case .object: d.z = 0.01
            }
        }
        return Vector3(max(d.x, 0.001), max(d.y, 0.001), max(d.z, 0.001))
    }

    /// One mesh per element, in world space.
    public static func namedMeshes(for room: RoomModel) -> [NamedMesh] {
        var counters: [RoomElementKind: Int] = [:]
        return room.elements.map { element in
            counters[element.kind, default: 0] += 1
            let index = counters[element.kind] ?? 1
            let safeCategory = element.category
                .lowercased()
                .map { $0.isLetter || $0.isNumber ? $0 : "_" }
            let name = "\(element.kind.rawValue)_\(index)_\(String(safeCategory))"
            let mesh = box(size: boxDimensions(for: element), color: element.kind.displayColor)
                .transformed(by: element.transform)
            return NamedMesh(
                name: name,
                materialName: element.kind.rawValue,
                color: element.kind.displayColor,
                mesh: mesh
            )
        }
    }

    public static func mesh(for room: RoomModel) -> TriangleMesh {
        TriangleMesh.merged(namedMeshes(for: room).map(\.mesh))
    }

    /// Axis-aligned box centered at the origin with flat per-face normals
    /// (24 vertices, 12 triangles, CCW winding seen from outside).
    public static func box(size: Vector3, color: SIMD3<UInt8>? = nil) -> TriangleMesh {
        let h = size * 0.5
        // (normal, u axis, v axis) per face; u × v == normal ⇒ CCW from outside.
        let faces: [(Vector3, Vector3, Vector3)] = [
            (Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)),
            (Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)),
            (Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, -1)),
            (Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)),
            (Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)),
            (Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0))
        ]
        var positions: [Vector3] = []
        var normals: [Vector3] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(24)
        normals.reserveCapacity(24)
        indices.reserveCapacity(36)

        for (normal, u, v) in faces {
            let base = UInt32(positions.count)
            let center = normal * h
            let uh = u * h
            let vh = v * h
            positions.append(center - uh - vh)
            positions.append(center + uh - vh)
            positions.append(center + uh + vh)
            positions.append(center - uh + vh)
            normals.append(contentsOf: repeatElement(normal, count: 4))
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }
        return TriangleMesh(
            positions: positions,
            normals: normals,
            colors: color.map { Array(repeating: $0, count: positions.count) },
            indices: indices
        )
    }
}
