import Foundation
import RoomPlan
import ScanCore

/// Capture-time choices for object/spatial scanning. Each preset maps to real
/// sensor-range and density parameters used by the ARKit pipeline.
enum ObjectScanPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Small/medium objects scanned up close.
    case object
    /// Large objects, furniture, or whole spaces.
    case space

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .object: return "Object"
        case .space: return "Space"
        }
    }

    var detail: String {
        switch self {
        case .object: return "Close range (≤ 1.5 m), finer detail. Best for items on a table or the floor."
        case .space: return "Up to ~4.5 m, coarser detail. Best for furniture, corners and areas."
        }
    }

    /// Voxel size for fusing LiDAR samples (meters).
    var voxelSize: Float {
        switch self {
        case .object: return 0.005
        case .space: return 0.015
        }
    }

    var thresholds: FeedbackThresholds {
        switch self {
        case .object: return .object
        case .space: return .space
        }
    }

    /// Hard cap on fused points to bound memory.
    var maxPoints: Int {
        switch self {
        case .object: return 1_500_000
        case .space: return 2_000_000
        }
    }
}

/// How densely each depth frame is sampled.
enum PointDensity: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .high: return "High"
        }
    }

    /// Pixel stride in the 256×192 LiDAR depth map.
    var depthStride: Int {
        switch self {
        case .standard: return 4
        case .high: return 2
        }
    }
}

/// What the user is about to scan. Created on the New Scan screen.
struct ScanDraft: Hashable, Sendable {
    var name: String
    var notes: String
    var type: ScanType
    var preset: ObjectScanPreset

    static func make(type: ScanType = .room) -> ScanDraft {
        ScanDraft(name: ScanNameValidator.defaultName(for: type), notes: "", type: type, preset: .object)
    }
}

/// Raw data captured by the object/spatial pipeline (all real sensor data).
struct ObjectCaptureResult: @unchecked Sendable {
    /// Merged world-space ARMeshAnchor geometry.
    var rawMesh: TriangleMesh
    /// Fused LiDAR depth samples.
    var grid: VoxelGrid
    var meshAnchorCount: Int
    var captureDuration: TimeInterval
    var preset: ObjectScanPreset
}

/// Output of a capture screen, handed to the processing stage.
enum CaptureOutput: @unchecked Sendable {
    case room(CapturedRoomData, duration: TimeInterval)
    case object(ObjectCaptureResult)

    var scanType: ScanType {
        switch self {
        case .room: return .room
        case .object: return .object
        }
    }
}
