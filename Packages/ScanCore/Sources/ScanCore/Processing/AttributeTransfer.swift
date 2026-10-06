import Foundation

/// Transfers per-point attributes between representations captured by the
/// same scan (e.g. camera colors from the fused point cloud onto the mesh,
/// surface normals from the mesh onto the point cloud).
public enum AttributeTransfer {
    /// Colors mesh vertices using the nearest colored voxel of the fused
    /// LiDAR point cloud. Vertices with no colored voxel nearby get `fallback`.
    /// Returns the mesh unchanged if the grid holds no color information.
    public static func colorize(
        _ mesh: TriangleMesh,
        from grid: VoxelGrid,
        fallback: SIMD3<UInt8> = SIMD3(160, 160, 165)
    ) throws -> TriangleMesh {
        guard grid.voxelCount > 0, !mesh.positions.isEmpty else { return mesh }
        var colors: [SIMD3<UInt8>] = []
        colors.reserveCapacity(mesh.vertexCount)
        var matched = 0
        for (i, p) in mesh.positions.enumerated() {
            if i % 100_000 == 0 { try Task.checkCancellation() }
            if let c = grid.nearestColor(to: p) {
                colors.append(c)
                matched += 1
            } else {
                colors.append(fallback)
            }
        }
        guard matched > 0 else { return mesh }
        var result = mesh
        result.colors = colors
        return result
    }

    /// Assigns each point the normal of the nearest mesh vertex within
    /// `searchRadius`. Points without a nearby vertex receive a zero normal,
    /// which consumers must treat as "unknown". Returns nil normals when the
    /// mesh has no normals.
    public static func transferNormals(
        from mesh: TriangleMesh,
        to cloud: PointCloud,
        searchRadius: Float
    ) throws -> PointCloud {
        guard let meshNormals = mesh.normals, !mesh.positions.isEmpty, cloud.count > 0, searchRadius > 0 else {
            return cloud
        }
        var cells: [VoxelKey: [Int]] = [:]
        for (i, p) in mesh.positions.enumerated() {
            guard let key = VoxelKey(position: p, voxelSize: searchRadius) else { continue }
            cells[key, default: []].append(i)
        }
        var normals = [Vector3](repeating: .zero, count: cloud.count)
        let radiusSquared = searchRadius * searchRadius
        for (i, p) in cloud.positions.enumerated() {
            if i % 100_000 == 0 { try Task.checkCancellation() }
            guard let key = VoxelKey(position: p, voxelSize: searchRadius) else { continue }
            var best: (Float, Int)?
            for dx: Int32 in -1...1 {
                for dy: Int32 in -1...1 {
                    for dz: Int32 in -1...1 {
                        guard let bucket = cells[key.offset(dx, dy, dz)] else { continue }
                        for j in bucket {
                            let d = (mesh.positions[j] - p).lengthSquared
                            if d <= radiusSquared, best == nil || d < best!.0 {
                                best = (d, j)
                            }
                        }
                    }
                }
            }
            if let best { normals[i] = meshNormals[best.1] }
        }
        var result = cloud
        result.normals = normals
        return result
    }
}
