import Foundation

/// A batch of world-space LiDAR samples extracted from one ARFrame.
public struct PointBatch: Sendable {
    public var positions: [Vector3]
    public var colors: [SIMD3<UInt8>]?

    public init(positions: [Vector3], colors: [SIMD3<UInt8>]? = nil) {
        self.positions = positions
        self.colors = colors
    }
}

public struct AccumulatorStatistics: Equatable, Sendable {
    public var voxelCount: Int
    public var batchesProcessed: Int
    public var samplesProcessed: Int
    public var budgetReached: Bool

    public static let zero = AccumulatorStatistics(voxelCount: 0, batchesProcessed: 0, samplesProcessed: 0, budgetReached: false)
}

/// Thread-safe accumulation of depth samples over the lifetime of a scan.
///
/// ARKit delivers frames on the session delegate queue; batches are handed to
/// this actor so fusion never blocks frame delivery or the main thread.
public actor PointCloudAccumulator {
    private var grid: VoxelGrid
    private var stats = AccumulatorStatistics.zero
    private var acceptingSamples = true

    public init(voxelSize: Float, maxPoints: Int) {
        grid = VoxelGrid(voxelSize: voxelSize, maxVoxels: maxPoints)
    }

    @discardableResult
    public func add(_ batch: PointBatch) -> AccumulatorStatistics {
        guard acceptingSamples else { return stats }
        let colors = batch.colors
        for i in 0..<batch.positions.count {
            grid.insert(batch.positions[i], color: colors.flatMap { i < $0.count ? $0[i] : nil })
        }
        stats.voxelCount = grid.voxelCount
        stats.batchesProcessed += 1
        stats.samplesProcessed += batch.positions.count
        stats.budgetReached = grid.isFull
        return stats
    }

    /// Stops accepting new samples (e.g. on memory pressure) while keeping data.
    public func setAcceptingSamples(_ accepting: Bool) {
        acceptingSamples = accepting
    }

    public func statistics() -> AccumulatorStatistics { stats }

    public func snapshotGrid() -> VoxelGrid { grid }

    public func makePointCloud(minObservations: Int) -> PointCloud {
        grid.makePointCloud(minObservations: minObservations)
    }

    public func reset() {
        grid.removeAll()
        stats = .zero
        acceptingSamples = true
    }
}
