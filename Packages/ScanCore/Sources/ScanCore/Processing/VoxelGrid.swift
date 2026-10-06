import Foundation

/// Integer voxel coordinate.
public struct VoxelKey: Hashable, Sendable {
    public let x: Int32
    public let y: Int32
    public let z: Int32

    public init(x: Int32, y: Int32, z: Int32) {
        self.x = x
        self.y = y
        self.z = z
    }

    /// Returns nil for non-finite or out-of-range positions.
    public init?(position p: Vector3, voxelSize: Float) {
        let scaled = p / voxelSize
        guard scaled.isFiniteVector,
              abs(scaled.x) < Float(Int32.max - 1),
              abs(scaled.y) < Float(Int32.max - 1),
              abs(scaled.z) < Float(Int32.max - 1) else { return nil }
        x = Int32(scaled.x.rounded(.down))
        y = Int32(scaled.y.rounded(.down))
        z = Int32(scaled.z.rounded(.down))
    }

    public func offset(_ dx: Int32, _ dy: Int32, _ dz: Int32) -> VoxelKey {
        VoxelKey(x: x &+ dx, y: y &+ dy, z: z &+ dz)
    }
}

/// Sparse voxel grid that fuses repeated LiDAR observations of the same
/// surface into a single averaged point per voxel.
///
/// This bounds memory (one entry per occupied voxel, plus a hard budget),
/// averages out depth noise across frames, and lets us reject points that were
/// observed only once (likely noise) when building the final cloud.
public struct VoxelGrid: Sendable {
    public let voxelSize: Float
    public let maxVoxels: Int

    private var lookup: [VoxelKey: Int] = [:]
    private var positionSums: [Vector3] = []
    private var colorSums: [SIMD3<Float>] = []
    private var colorCounts: [UInt32] = []
    private var observationCounts: [UInt32] = []

    public init(voxelSize: Float, maxVoxels: Int) {
        precondition(voxelSize > 0, "voxelSize must be positive")
        self.voxelSize = voxelSize
        self.maxVoxels = max(1, maxVoxels)
    }

    public var voxelCount: Int { observationCounts.count }
    public var isFull: Bool { voxelCount >= maxVoxels }

    public enum InsertResult: Equatable {
        case created
        case merged
        case rejected
    }

    @discardableResult
    public mutating func insert(_ position: Vector3, color: SIMD3<UInt8>? = nil) -> InsertResult {
        guard let key = VoxelKey(position: position, voxelSize: voxelSize) else { return .rejected }
        let colorValue = color.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
        if let index = lookup[key] {
            positionSums[index] += position
            observationCounts[index] &+= 1
            if let colorValue {
                colorSums[index] += colorValue
                colorCounts[index] &+= 1
            }
            return .merged
        }
        guard !isFull else { return .rejected }
        lookup[key] = observationCounts.count
        positionSums.append(position)
        observationCounts.append(1)
        colorSums.append(colorValue ?? .zero)
        colorCounts.append(colorValue == nil ? 0 : 1)
        return .created
    }

    public mutating func removeAll() {
        lookup.removeAll(keepingCapacity: false)
        positionSums.removeAll()
        colorSums.removeAll()
        colorCounts.removeAll()
        observationCounts.removeAll()
    }

    /// Averaged position of a voxel.
    public func position(at index: Int) -> Vector3 {
        positionSums[index] / Float(observationCounts[index])
    }

    public func color(at index: Int) -> SIMD3<UInt8>? {
        guard colorCounts[index] > 0 else { return nil }
        let c = colorSums[index] / Float(colorCounts[index])
        return SIMD3<UInt8>(
            UInt8(clamping: Int(c.x.rounded())),
            UInt8(clamping: Int(c.y.rounded())),
            UInt8(clamping: Int(c.z.rounded()))
        )
    }

    /// Nearest colored voxel to `position`, searching the 3×3×3 neighborhood.
    public func nearestColor(to position: Vector3) -> SIMD3<UInt8>? {
        guard let key = VoxelKey(position: position, voxelSize: voxelSize) else { return nil }
        var best: (distance: Float, color: SIMD3<UInt8>)?
        for dx: Int32 in -1...1 {
            for dy: Int32 in -1...1 {
                for dz: Int32 in -1...1 {
                    guard let index = lookup[key.offset(dx, dy, dz)],
                          let sampleColor = self.color(at: index) else { continue }
                    let d = (self.position(at: index) - position).lengthSquared
                    if best == nil || d < best!.distance {
                        best = (d, sampleColor)
                    }
                }
            }
        }
        return best?.color
    }

    /// Builds a point cloud from voxels observed at least `minObservations` times.
    public func makePointCloud(minObservations: Int = 1) -> PointCloud {
        var positions: [Vector3] = []
        var colors: [SIMD3<UInt8>] = []
        positions.reserveCapacity(voxelCount)
        let anyColor = colorCounts.contains { $0 > 0 }
        if anyColor { colors.reserveCapacity(voxelCount) }

        for index in 0..<voxelCount where observationCounts[index] >= UInt32(max(1, minObservations)) {
            positions.append(position(at: index))
            if anyColor {
                colors.append(color(at: index) ?? SIMD3(128, 128, 128))
            }
        }
        return PointCloud(positions: positions, colors: anyColor ? colors : nil)
    }
}
