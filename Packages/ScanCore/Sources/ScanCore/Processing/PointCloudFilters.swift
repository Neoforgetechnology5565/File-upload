import Foundation

/// Point-cloud cleanup operations. All are pure functions that return new
/// clouds and check for task cancellation periodically so long-running
/// processing can be cancelled from the UI.
public enum PointCloudFilters {
    /// Removes points with fewer than `minNeighbors` other points within
    /// `radius`. Uses a hash grid with cell size == radius, so each query only
    /// inspects 27 cells (O(n·k)).
    public static func radiusOutlierRemoval(
        _ cloud: PointCloud,
        radius: Float,
        minNeighbors: Int
    ) throws -> PointCloud {
        guard cloud.count > 0, radius > 0, minNeighbors > 0 else { return cloud }
        var cells: [VoxelKey: [Int]] = [:]
        cells.reserveCapacity(cloud.count / 2)
        for (i, p) in cloud.positions.enumerated() {
            guard let key = VoxelKey(position: p, voxelSize: radius) else { continue }
            cells[key, default: []].append(i)
        }

        let radiusSquared = radius * radius
        var kept: [Int] = []
        kept.reserveCapacity(cloud.count)

        for (i, p) in cloud.positions.enumerated() {
            if i % 50_000 == 0 { try Task.checkCancellation() }
            guard let key = VoxelKey(position: p, voxelSize: radius) else { continue }
            var neighbors = 0
            search: for dx: Int32 in -1...1 {
                for dy: Int32 in -1...1 {
                    for dz: Int32 in -1...1 {
                        guard let bucket = cells[key.offset(dx, dy, dz)] else { continue }
                        for j in bucket where j != i {
                            if (cloud.positions[j] - p).lengthSquared <= radiusSquared {
                                neighbors += 1
                                if neighbors >= minNeighbors { break search }
                            }
                        }
                    }
                }
            }
            if neighbors >= minNeighbors { kept.append(i) }
        }
        return cloud.subset(kept)
    }

    /// Keeps one averaged point per voxel.
    public static func voxelDownsample(_ cloud: PointCloud, voxelSize: Float) -> PointCloud {
        guard cloud.count > 0, voxelSize > 0 else { return cloud }
        var grid = VoxelGrid(voxelSize: voxelSize, maxVoxels: cloud.count)
        for i in 0..<cloud.count {
            grid.insert(cloud.positions[i], color: cloud.colors?[i])
        }
        return grid.makePointCloud(minObservations: 1)
    }

    /// Removes points outside the given box.
    public static func crop(_ cloud: PointCloud, to box: BoundingBox) -> PointCloud {
        let indices = cloud.positions.indices.filter { box.contains(cloud.positions[$0]) }
        return cloud.subset(indices)
    }
}
