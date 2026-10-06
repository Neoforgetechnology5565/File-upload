import Foundation
import RoomPlan
import ScanCore

/// A processed, not-yet-saved scan. Its files live in `stagingDirectory`
/// until `ScanLibraryService.save` commits them.
struct ProcessedScan: @unchecked Sendable {
    var scan: Scan
    var geometry: ScanGeometry
    var stagingDirectory: URL
}

protocol ScanProcessingService: Sendable {
    func process(
        _ capture: CaptureOutput,
        draft: ScanDraft,
        progress: @escaping @Sendable (ProcessingStep) -> Void
    ) async throws -> ProcessedScan
}

/// Turns raw capture output into the persisted scan representation:
///
/// Room:   CapturedRoomData → RoomBuilder → CapturedRoom → RoomModel
///         + Apple's parametric USDZ + CapturedRoom JSON
/// Object: ARMeshAnchor mesh + fused LiDAR samples → ObjectScanProcessingPipeline
///
/// Both then write `geometry.lsgeo` and a rendered thumbnail into a staging
/// directory. Heavy work runs off the main actor and honors cancellation.
final class DefaultScanProcessingService: ScanProcessingService, @unchecked Sendable {
    private let storage: StorageService
    private let thumbnailRenderer: ThumbnailRendering
    private let capabilityProvider: DeviceCapabilityProviding

    init(storage: StorageService, thumbnailRenderer: ThumbnailRendering, capabilityProvider: DeviceCapabilityProviding) {
        self.storage = storage
        self.thumbnailRenderer = thumbnailRenderer
        self.capabilityProvider = capabilityProvider
    }

    func process(
        _ capture: CaptureOutput,
        draft: ScanDraft,
        progress: @escaping @Sendable (ProcessingStep) -> Void
    ) async throws -> ProcessedScan {
        guard MemoryMonitor.canStartProcessing else { throw AppError.insufficientMemory }
        let staging = try storage.makeStagingDirectory()
        do {
            var files = ScanFileManifest()
            var metadata: [String: String] = [:]
            let geometry: ScanGeometry
            let duration: TimeInterval

            switch capture {
            case let .room(data, captureDuration):
                duration = captureDuration
                progress(.buildingRoomModel)
                let room = try await RoomScanProcessor.buildRoom(from: data)
                try Task.checkCancellation()
                let model = RoomModelConverter.convert(room)
                guard !model.elements.isEmpty else { throw AppError.noGeometryCaptured }
                geometry = ScanGeometry(room: model)

                progress(.exportingRoomModel)
                let usdzURL = staging.appendingPathComponent(ScanFileManifest.roomUSDZFileName)
                do {
                    try RoomScanProcessor.exportUSDZ(room, to: usdzURL)
                    files.roomUSDZFile = ScanFileManifest.roomUSDZFileName
                } catch {
                    // Not fatal: USDZ export falls back to our own exporter later.
                    Log.room.error("RoomPlan USDZ export failed: \(error.localizedDescription, privacy: .public)")
                }
                let roomJSON = try RoomScanProcessor.encode(room)
                try storage.write(roomJSON, to: staging.appendingPathComponent(ScanFileManifest.capturedRoomFileName))
                files.capturedRoomFile = ScanFileManifest.capturedRoomFileName
                metadata["roomplan.objects"] = "\(room.objects.count)"
                metadata["roomplan.walls"] = "\(room.walls.count)"

            case let .object(result):
                duration = result.captureDuration
                guard !result.rawMesh.isEmpty || result.grid.voxelCount > 0 else { throw AppError.noGeometryCaptured }
                let options = ObjectProcessingOptions.default(voxelSize: result.preset.voxelSize)
                let output = try ObjectScanProcessingPipeline.process(
                    rawMesh: result.rawMesh,
                    grid: result.grid,
                    options: options,
                    progress: progress
                )
                geometry = output.geometry
                metadata["capture.preset"] = result.preset.rawValue
                metadata["capture.meshAnchors"] = "\(result.meshAnchorCount)"
                metadata["processing.rawVoxels"] = "\(output.report.rawVoxelCount)"
                metadata["processing.rawTriangles"] = "\(output.report.rawTriangleCount)"
                metadata["processing.removedOutliers"] = "\(output.report.removedOutliers)"
            }

            guard !geometry.isEmpty else { throw AppError.noGeometryCaptured }
            try Task.checkCancellation()

            progress(.savingFiles)
            let encoded = try ScanGeometryCodec.encode(geometry)
            try storage.write(encoded, to: staging.appendingPathComponent(ScanFileManifest.geometryFileName))
            files.geometryFile = ScanFileManifest.geometryFileName

            progress(.renderingThumbnail)
            if let jpeg = await thumbnailRenderer.renderThumbnail(for: geometry, size: CGSize(width: 480, height: 480)) {
                try storage.write(jpeg, to: staging.appendingPathComponent(ScanFileManifest.thumbnailFileName))
                files.thumbnailFile = ScanFileManifest.thumbnailFileName
            }

            let hasLiDAR = capabilityProvider.capabilities().hasLiDAR
            let device = await SystemInfo.deviceInfo(hasLiDAR: hasLiDAR)
            let scan = Scan(
                name: draft.name,
                type: capture.scanType,
                status: .completed,
                device: device,
                files: files,
                statistics: ScanStatistics.make(from: geometry, captureDuration: duration),
                notes: draft.notes,
                metadata: metadata
            )
            return ProcessedScan(scan: scan, geometry: geometry, stagingDirectory: staging)
        } catch {
            storage.discardStaging(staging)
            Log.processing.error("Processing failed: \(error.localizedDescription, privacy: .public)")
            throw AppError.from(error)
        }
    }
}
