import ARKit
import AVFoundation
import Foundation
import RoomPlan
import ScanCore

enum CameraAuthorization: String, Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

/// Snapshot of what the current device can do. Every flag comes from a real
/// ARKit / RoomPlan / AVFoundation capability query.
struct DeviceCapabilities: Equatable, Sendable {
    var supportsWorldTracking: Bool
    /// LiDAR is inferred from scene-reconstruction support, which ARKit only
    /// offers on devices with the LiDAR Scanner.
    var hasLiDAR: Bool
    var supportsSceneDepth: Bool
    var supportsSmoothedSceneDepth: Bool
    var supportsMeshReconstruction: Bool
    var supportsMeshClassification: Bool
    var supportsRoomPlan: Bool
    var cameraAuthorization: CameraAuthorization

    var canScanObjects: Bool {
        supportsWorldTracking && hasLiDAR && supportsSceneDepth && supportsMeshReconstruction
    }

    var canScanRooms: Bool {
        supportsRoomPlan
    }

    var canScanAnything: Bool { canScanObjects || canScanRooms }

    var isCameraDenied: Bool {
        cameraAuthorization == .denied || cameraAuthorization == .restricted
    }

    func canScan(_ type: ScanType) -> Bool {
        switch type {
        case .room: return canScanRooms
        case .object: return canScanObjects
        }
    }

    static let unsupported = DeviceCapabilities(
        supportsWorldTracking: false,
        hasLiDAR: false,
        supportsSceneDepth: false,
        supportsSmoothedSceneDepth: false,
        supportsMeshReconstruction: false,
        supportsMeshClassification: false,
        supportsRoomPlan: false,
        cameraAuthorization: .notDetermined
    )

    static let fullySupported = DeviceCapabilities(
        supportsWorldTracking: true,
        hasLiDAR: true,
        supportsSceneDepth: true,
        supportsSmoothedSceneDepth: true,
        supportsMeshReconstruction: true,
        supportsMeshClassification: true,
        supportsRoomPlan: true,
        cameraAuthorization: .authorized
    )
}

/// Abstraction over hardware capability queries so non-LiDAR logic (view
/// models, navigation) can be tested on the simulator and in CI.
protocol DeviceCapabilityProviding: Sendable {
    func capabilities() -> DeviceCapabilities
    func requestCameraAccess() async -> CameraAuthorization
}

struct SystemDeviceCapabilityProvider: DeviceCapabilityProviding {
    func capabilities() -> DeviceCapabilities {
        let worldTracking = ARWorldTrackingConfiguration.isSupported
        return DeviceCapabilities(
            supportsWorldTracking: worldTracking,
            hasLiDAR: worldTracking && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh),
            supportsSceneDepth: worldTracking && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
            supportsSmoothedSceneDepth: worldTracking && ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth),
            supportsMeshReconstruction: worldTracking && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh),
            supportsMeshClassification: worldTracking && ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification),
            supportsRoomPlan: RoomCaptureSession.isSupported,
            cameraAuthorization: Self.cameraAuthorization()
        )
    }

    func requestCameraAccess() async -> CameraAuthorization {
        switch Self.cameraAuthorization() {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            return granted ? .authorized : .denied
        case let status:
            return status
        }
    }

    static func cameraAuthorization() -> CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
}

/// Deterministic provider for previews, unit tests and UI tests. It only
/// affects capability *reporting*; it never produces scan data.
struct FixedCapabilityProvider: DeviceCapabilityProviding {
    var value: DeviceCapabilities
    var cameraResponse: CameraAuthorization = .authorized

    func capabilities() -> DeviceCapabilities { value }

    func requestCameraAccess() async -> CameraAuthorization { cameraResponse }
}
