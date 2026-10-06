import Foundation

/// Tunable parameters for turning raw object/spatial capture data into the
/// final `ScanGeometry`.
public struct ObjectProcessingOptions: Equatable, Sendable {
    /// Voxel size used while fusing depth samples (meters).
    public var voxelSize: Float
    /// Voxels must be seen at least this many times to be kept.
    public var minObservations: Int
    /// Radius outlier filter (multiples of `voxelSize`).
    public var outlierRadiusMultiplier: Float
    public var outlierMinNeighbors: Int
    /// Distance at which duplicated ARMeshAnchor seam vertices are merged.
    public var weldTolerance: Float
    /// Connected mesh fragments smaller than this are discarded.
    public var minComponentTriangles: Int
    /// Upper bound on triangles kept for viewing/export.
    public var maxTriangles: Int

    public init(
        voxelSize: Float,
        minObservations: Int,
        outlierRadiusMultiplier: Float,
        outlierMinNeighbors: Int,
        weldTolerance: Float,
        minComponentTriangles: Int,
        maxTriangles: Int
    ) {
        self.voxelSize = voxelSize
        self.minObservations = minObservations
        self.outlierRadiusMultiplier = outlierRadiusMultiplier
        self.outlierMinNeighbors = outlierMinNeighbors
        self.weldTolerance = weldTolerance
        self.minComponentTriangles = minComponentTriangles
        self.maxTriangles = maxTriangles
    }

    public static func `default`(voxelSize: Float) -> ObjectProcessingOptions {
        ObjectProcessingOptions(
            voxelSize: voxelSize,
            minObservations: 2,
            outlierRadiusMultiplier: 2.5,
            outlierMinNeighbors: 3,
            weldTolerance: 0.002,
            minComponentTriangles: 12,
            maxTriangles: 400_000
        )
    }
}

public enum ProcessingStep: String, CaseIterable, Sendable {
    case preparing
    case filteringPoints
    case cleaningMesh
    case simplifyingMesh
    case computingNormals
    case colorizing
    case savingFiles
    case renderingThumbnail
    case buildingRoomModel
    case exportingRoomModel

    public var displayName: String {
        switch self {
        case .preparing: return "Preparing capture data"
        case .filteringPoints: return "Filtering point cloud"
        case .cleaningMesh: return "Cleaning mesh"
        case .simplifyingMesh: return "Optimizing mesh size"
        case .computingNormals: return "Computing surface normals"
        case .colorizing: return "Applying camera colors"
        case .savingFiles: return "Saving scan files"
        case .renderingThumbnail: return "Rendering preview"
        case .buildingRoomModel: return "Building room model"
        case .exportingRoomModel: return "Generating 3D room model"
        }
    }
}

public struct ObjectProcessingReport: Equatable, Sendable {
    public var rawVoxelCount: Int
    public var finalPointCount: Int
    public var rawTriangleCount: Int
    public var finalTriangleCount: Int
    public var removedOutliers: Int
}

/// Deterministic, hardware-independent processing for object/spatial scans.
///
/// Input is real data captured by the ARKit pipeline: the merged world-space
/// `ARMeshAnchor` geometry and the fused LiDAR depth samples (`VoxelGrid`).
public enum ObjectScanProcessingPipeline {
    public static func process(
        rawMesh: TriangleMesh,
        grid: VoxelGrid,
        options: ObjectProcessingOptions,
        progress: (ProcessingStep) -> Void = { _ in }
    ) throws -> (geometry: ScanGeometry, report: ObjectProcessingReport) {
        progress(.preparing)
        try Task.checkCancellation()

        // 1. Point cloud: require repeated observations, but do not discard
        //    almost everything when the user moved quickly.
        progress(.filteringPoints)
        var cloud = grid.makePointCloud(minObservations: options.minObservations)
        if grid.voxelCount > 0, cloud.count < grid.voxelCount / 5 {
            cloud = grid.makePointCloud(minObservations: 1)
        }
        let beforeOutliers = cloud.count
        cloud = try PointCloudFilters.radiusOutlierRemoval(
            cloud,
            radius: options.voxelSize * options.outlierRadiusMultiplier,
            minNeighbors: options.outlierMinNeighbors
        )
        let removedOutliers = beforeOutliers - cloud.count

        // 2. Mesh: weld anchor seams, drop degenerate faces & floating noise.
        var mesh = rawMesh
        if !mesh.isEmpty {
            progress(.cleaningMesh)
            mesh = try MeshCleanup.vertexClustering(mesh, cellSize: options.weldTolerance)
            mesh = MeshCleanup.removeDegenerateTriangles(mesh)
            mesh = try MeshCleanup.removeSmallComponents(mesh, minTriangles: options.minComponentTriangles)

            if mesh.triangleCount > options.maxTriangles {
                progress(.simplifyingMesh)
                mesh = try MeshCleanup.decimate(
                    mesh,
                    maxTriangles: options.maxTriangles,
                    initialCellSize: max(options.voxelSize * 0.5, options.weldTolerance * 2)
                )
            }

            progress(.computingNormals)
            if mesh.normals == nil {
                mesh.normals = MeshCleanup.computeVertexNormals(mesh)
            }

            progress(.colorizing)
            mesh = try AttributeTransfer.colorize(mesh, from: grid)
        }

        // 3. Normals for the point cloud, where the mesh provides them.
        if !mesh.isEmpty, !cloud.isEmpty {
            cloud = try AttributeTransfer.transferNormals(
                from: mesh,
                to: cloud,
                searchRadius: options.voxelSize * 3
            )
        }

        let geometry = ScanGeometry(
            pointCloud: cloud.isEmpty ? nil : cloud,
            mesh: mesh.isEmpty ? nil : mesh,
            room: nil
        )
        let report = ObjectProcessingReport(
            rawVoxelCount: grid.voxelCount,
            finalPointCount: cloud.count,
            rawTriangleCount: rawMesh.triangleCount,
            finalTriangleCount: mesh.triangleCount,
            removedOutliers: removedOutliers
        )
        return (geometry, report)
    }
}
