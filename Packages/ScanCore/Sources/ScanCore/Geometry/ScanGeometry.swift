import Foundation

/// The complete processed 3D representation of a scan.
///
/// - Object/spatial scans populate `mesh` (ARKit scene reconstruction) and/or
///   `pointCloud` (LiDAR depth samples).
/// - Room scans populate `room` (RoomPlan parametric model).
public struct ScanGeometry: Equatable, Sendable {
    public var pointCloud: PointCloud?
    public var mesh: TriangleMesh?
    public var room: RoomModel?

    public init(pointCloud: PointCloud? = nil, mesh: TriangleMesh? = nil, room: RoomModel? = nil) {
        self.pointCloud = pointCloud
        self.mesh = mesh
        self.room = room
    }

    public var isEmpty: Bool {
        (pointCloud?.isEmpty ?? true) && (mesh?.isEmpty ?? true) && (room?.elements.isEmpty ?? true)
    }

    public var hasMesh: Bool { !(mesh?.isEmpty ?? true) || !(room?.elements.isEmpty ?? true) }
    public var hasPointCloud: Bool { !(pointCloud?.isEmpty ?? true) }

    /// Mesh used for triangle-based exports. For rooms this is generated from
    /// the parametric model.
    public var exportableMesh: TriangleMesh? {
        if let mesh, !mesh.isEmpty { return mesh }
        if let room, !room.elements.isEmpty { return RoomMeshBuilder.mesh(for: room) }
        return nil
    }

    /// Grouped meshes (one per room element, or a single group for a scan mesh).
    public var namedMeshes: [NamedMesh] {
        if let room, !room.elements.isEmpty {
            return RoomMeshBuilder.namedMeshes(for: room)
        }
        if let mesh, !mesh.isEmpty {
            return [NamedMesh(name: "scan_mesh", materialName: "scan", color: SIMD3(200, 200, 205), mesh: mesh)]
        }
        return []
    }

    public var boundingBox: BoundingBox? {
        let boxes = [pointCloud?.boundingBox, mesh?.boundingBox, room?.boundingBox].compactMap { $0 }
        guard var result = boxes.first else { return nil }
        for box in boxes.dropFirst() { result = result.union(box) }
        return result
    }
}
