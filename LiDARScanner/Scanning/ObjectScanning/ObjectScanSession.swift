import ARKit
import Foundation
import ScanCore

/// Live, measured values published to the scanning UI.
struct ObjectScanLiveStatus: Equatable, Sendable {
    var feedback: ScanFeedback = .ready
    /// Fused LiDAR points (voxels) captured so far.
    var pointCount: Int = 0
    var meshAnchorCount: Int = 0
    /// Total reconstructed surface area (m²), summed from ARMeshAnchor triangles.
    var meshSurfaceArea: Float = 0
    var captureDuration: TimeInterval = 0
    var pointBudgetReached = false
    var isMemoryLimited = false
}

/// The ARKit object/spatial scanning engine.
///
/// - Runs `ARWorldTrackingConfiguration` with LiDAR scene depth and scene
///   reconstruction (`ARMeshAnchor`).
/// - Receives all ARSession callbacks on a private serial queue so frame
///   processing never touches the main thread.
/// - Samples LiDAR depth at a fixed rate and fuses it into a voxel grid
///   (`PointCloudAccumulator` actor), bounded by a point budget and by
///   process memory headroom.
/// - Tracks mesh anchors and their real surface area for coverage feedback.
///
/// All mutable state below is confined to `queue`.
final class ObjectScanSession: NSObject, ARSessionDelegate, @unchecked Sendable {
    enum State: Equatable {
        case idle
        case previewing
        case capturing
        case paused
        case finished
    }

    let session: ARSession
    private let queue = DispatchQueue(label: "com.example.lidarscanner.object-scan", qos: .userInitiated)
    private let accumulator: PointCloudAccumulator
    private let preset: ObjectScanPreset
    private let samplingOptions: DepthSamplingOptions
    private let analyzer: ScanFeedbackAnalyzer
    private let capabilities: DeviceCapabilities

    /// Depth samples per second while capturing.
    private let sampleInterval: TimeInterval = 0.2
    private let statusInterval: TimeInterval = 0.1

    // Queue-confined state
    private var state: State = .idle
    private var meshAnchors: [UUID: ARMeshAnchor] = [:]
    private var anchorAreas: [UUID: Float] = [:]
    private var dirtyAnchors: Set<UUID> = []
    private var lastSampleTime: TimeInterval = 0
    private var lastAreaUpdate: TimeInterval = 0
    private var lastStatusTime: TimeInterval = 0
    private var lastDepthCheck: TimeInterval = 0
    private var lastMemoryCheck: TimeInterval = 0
    private var cachedCenterDepth: Float?
    private var lastPose: (time: TimeInterval, position: Vector3, forward: Vector3)?
    private var linearSpeed: Float = 0
    private var angularSpeed: Float = 0
    private var lastFrameTime: TimeInterval?
    private var isInterrupted = false
    private var status = ObjectScanLiveStatus()

    /// Delivered on the main actor.
    var onStatus: (@MainActor (ObjectScanLiveStatus) -> Void)?
    var onError: (@MainActor (AppError) -> Void)?

    init(session: ARSession, preset: ObjectScanPreset, density: PointDensity, capabilities: DeviceCapabilities) {
        self.session = session
        self.preset = preset
        self.capabilities = capabilities
        self.accumulator = PointCloudAccumulator(voxelSize: preset.voxelSize, maxPoints: preset.maxPoints)
        self.analyzer = ScanFeedbackAnalyzer(thresholds: preset.thresholds)
        self.samplingOptions = DepthSamplingOptions(
            stride: density.depthStride,
            minDepth: preset.thresholds.minimumDepth,
            maxDepth: preset.thresholds.maximumDepth,
            minimumConfidence: .high,
            includeColor: true
        )
        super.init()
        session.delegateQueue = queue
        session.delegate = self
    }

    // MARK: Configuration

    func makeConfiguration(reconstruct: Bool) -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = []
        configuration.environmentTexturing = .none
        if capabilities.supportsSmoothedSceneDepth {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        } else if capabilities.supportsSceneDepth {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        if reconstruct {
            configuration.sceneReconstruction = capabilities.supportsMeshClassification ? .meshWithClassification : .mesh
        }
        return configuration
    }

    // MARK: Commands (callable from any thread)

    /// Starts tracking and depth for the camera preview, without capturing.
    func startPreview() {
        queue.async { [self] in
            guard capabilities.canScanObjects else {
                publishError(.lidarUnavailable)
                return
            }
            state = .previewing
            session.run(makeConfiguration(reconstruct: false), options: [.resetTracking, .removeExistingAnchors])
        }
    }

    /// Enables scene reconstruction and depth fusion.
    func startCapture() {
        queue.async { [self] in
            guard state == .previewing || state == .idle else { return }
            state = .capturing
            lastSampleTime = 0
            session.run(makeConfiguration(reconstruct: true))
        }
    }

    func pause() {
        queue.async { [self] in
            guard state == .capturing else { return }
            state = .paused
            session.pause()
            status.feedback = .paused
            publishStatus(force: true)
        }
    }

    /// Resumes with the same configuration and no reset options, so tracking
    /// relocalizes against the existing map and anchors are preserved.
    func resume() {
        queue.async { [self] in
            guard state == .paused else { return }
            state = .capturing
            lastFrameTime = nil
            lastPose = nil
            session.run(makeConfiguration(reconstruct: true))
        }
    }

    /// Discards everything captured so far and returns to preview.
    func reset() {
        queue.async { [self] in
            meshAnchors.removeAll()
            anchorAreas.removeAll()
            dirtyAnchors.removeAll()
            lastPose = nil
            lastFrameTime = nil
            status = ObjectScanLiveStatus()
            state = .previewing
            session.run(makeConfiguration(reconstruct: false), options: [.resetTracking, .removeExistingAnchors])
            Task { await accumulator.reset() }
            publishStatus(force: true)
        }
    }

    /// Stops capture and returns everything captured.
    func finish() async -> ObjectCaptureResult {
        let snapshot: (mesh: TriangleMesh, anchorCount: Int, duration: TimeInterval) = await withCheckedContinuation { continuation in
            queue.async { [self] in
                state = .finished
                let anchors = Array(meshAnchors.values)
                let mesh = MeshAnchorExtractor.extract(anchors)
                session.pause()
                continuation.resume(returning: (mesh, anchors.count, status.captureDuration))
            }
        }
        let grid = await accumulator.snapshotGrid()
        return ObjectCaptureResult(
            rawMesh: snapshot.mesh,
            grid: grid,
            meshAnchorCount: snapshot.anchorCount,
            captureDuration: snapshot.duration,
            preset: preset
        )
    }

    func stop() {
        queue.async { [self] in
            state = .finished
            session.pause()
        }
    }

    /// Called on memory warnings: keep what we have, stop adding samples.
    func handleMemoryPressure() {
        queue.async { [self] in
            status.isMemoryLimited = true
            Task { await accumulator.setAcceptingSamples(false) }
            publishStatus(force: true)
        }
    }

    // MARK: ARSessionDelegate (delegate queue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = frame.timestamp
        let frameDelta = lastFrameTime.map { now - $0 } ?? 0
        lastFrameTime = now

        updateMotion(frame: frame, now: now)
        if now - lastDepthCheck >= 0.25 {
            lastDepthCheck = now
            cachedCenterDepth = DepthPointSampler.medianCenterDepth(frame: frame)
        }

        let observation = FrameObservation(
            tracking: Self.condition(frame.camera.trackingState),
            linearSpeed: linearSpeed,
            angularSpeed: angularSpeed,
            medianCenterDepth: cachedCenterDepth
        )
        let hasData = status.pointCount > 0 || !meshAnchors.isEmpty
        var feedback = analyzer.feedback(for: observation, hasCapturedData: hasData && state == .capturing)
        if isInterrupted { feedback = .interrupted }

        if now - lastMemoryCheck >= 1 {
            lastMemoryCheck = now
            if MemoryMonitor.isLowForCapture, !status.isMemoryLimited {
                Log.scanning.warning("Low memory headroom; stopping depth accumulation")
                status.isMemoryLimited = true
                Task { await accumulator.setAcceptingSamples(false) }
            }
        }
        if state == .capturing, status.isMemoryLimited || status.pointBudgetReached {
            // Both mean "nothing more can be stored" — the user should finish.
            feedback = .memoryLimitReached
        }

        if state == .capturing {
            if frameDelta > 0, frameDelta < 1 { status.captureDuration += frameDelta }

            if feedback.allowsCapture, !status.isMemoryLimited, !status.pointBudgetReached,
               now - lastSampleTime >= sampleInterval,
               let batch = DepthPointSampler.sample(frame: frame, options: samplingOptions) {
                lastSampleTime = now
                let accumulator = self.accumulator
                Task {
                    let stats = await accumulator.add(batch)
                    self.queue.async {
                        self.status.pointCount = stats.voxelCount
                        self.status.pointBudgetReached = stats.budgetReached
                    }
                }
            }

            if now - lastAreaUpdate >= 1, !dirtyAnchors.isEmpty {
                lastAreaUpdate = now
                for id in dirtyAnchors {
                    if let anchor = meshAnchors[id] {
                        anchorAreas[id] = MeshAnchorExtractor.surfaceArea(of: anchor)
                    }
                }
                dirtyAnchors.removeAll()
                status.meshSurfaceArea = anchorAreas.values.reduce(0, +)
            }
        }

        status.feedback = state == .paused ? .paused : feedback
        status.meshAnchorCount = meshAnchors.count
        publishStatus(force: false, now: now)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard state == .capturing else { return }
        for case let anchor as ARMeshAnchor in anchors {
            meshAnchors[anchor.identifier] = anchor
            dirtyAnchors.insert(anchor.identifier)
        }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard state == .capturing else { return }
        for case let anchor as ARMeshAnchor in anchors {
            meshAnchors[anchor.identifier] = anchor
            dirtyAnchors.insert(anchor.identifier)
        }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for case let anchor as ARMeshAnchor in anchors {
            meshAnchors[anchor.identifier] = nil
            anchorAreas[anchor.identifier] = nil
            dirtyAnchors.remove(anchor.identifier)
        }
        status.meshSurfaceArea = anchorAreas.values.reduce(0, +)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        Log.scanning.error("ARSession failed: \(error.localizedDescription, privacy: .public)")
        state = .finished
        publishError(AppError.from(error))
    }

    func sessionWasInterrupted(_ session: ARSession) {
        isInterrupted = true
        status.feedback = .interrupted
        publishStatus(force: true)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        isInterrupted = false
        lastPose = nil
        lastFrameTime = nil
    }

    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        true
    }

    // MARK: Helpers (delegate queue)

    private func updateMotion(frame: ARFrame, now: TimeInterval) {
        let transform = frame.camera.transform
        let position = Vector3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let forward = -Vector3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        guard let last = lastPose else {
            lastPose = (now, position, forward)
            return
        }
        let dt = Float(now - last.time)
        // Measure over ≥100 ms windows to suppress per-frame jitter.
        guard dt >= 0.1 else { return }
        linearSpeed = position.distance(to: last.position) / dt
        angularSpeed = ScanFeedbackAnalyzer.angleBetween(forward, last.forward) / dt
        lastPose = (now, position, forward)
    }

    private func publishStatus(force: Bool, now: TimeInterval = 0) {
        guard force || now - lastStatusTime >= statusInterval else { return }
        lastStatusTime = now
        let snapshot = status
        guard let handler = onStatus else { return }
        Task { @MainActor in handler(snapshot) }
    }

    private func publishError(_ error: AppError) {
        guard let handler = onError else { return }
        Task { @MainActor in handler(error) }
    }

    static func condition(_ state: ARCamera.TrackingState) -> TrackingCondition {
        switch state {
        case .notAvailable:
            return .notAvailable
        case .normal:
            return .normal
        case .limited(let reason):
            switch reason {
            case .initializing: return .initializing
            case .relocalizing: return .relocalizing
            case .excessiveMotion: return .excessiveMotion
            case .insufficientFeatures: return .insufficientFeatures
            @unknown default: return .limitedOther
            }
        }
    }
}
