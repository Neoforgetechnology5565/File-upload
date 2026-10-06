import SceneKit
import ScanCore
import UIKit

struct ViewerTapResult: Equatable {
    /// World-space coordinate on the scan surface (meters), if one was hit.
    var worldPoint: Vector3?
    /// Room element under the tap, if any.
    var elementID: UUID?
}

/// Imperative bridge between SwiftUI and the `SCNView`.
///
/// Owns the scene graph, camera framing, display toggles, measurement
/// annotations and picking. View models talk to this controller; they never
/// touch SceneKit directly.
@MainActor
final class SceneViewerController: NSObject {
    private(set) weak var view: SCNView?
    private var content: SceneContent?
    private var geometry: ScanGeometry?
    private let annotationRoot = SCNNode()
    private var highlightedElementID: UUID?
    private let fieldOfView: Float = 55

    private(set) var displayMode: ViewerDisplayMode = .mesh
    private(set) var isWireframe = false

    var onTap: ((ViewerTapResult) -> Void)?
    /// When true, taps pick surface points; otherwise taps select elements.
    var pickingEnabled = true

    func attach(_ view: SCNView) {
        self.view = view
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        view.preferredFramesPerSecond = 60
        view.backgroundColor = UIColor.secondarySystemBackground
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        view.addGestureRecognizer(tap)
        if let content { install(content) }
    }

    func load(_ geometry: ScanGeometry) {
        self.geometry = geometry
        let content = SceneBuilder.makeScene(for: geometry)
        self.content = content
        displayMode = content.meshNode != nil || !content.roomNodes.isEmpty ? .mesh : .points
        install(content)
    }

    var availableDisplayModes: [ViewerDisplayMode] {
        guard let content else { return [] }
        let hasSurface = content.meshNode != nil || !content.roomNodes.isEmpty
        let hasPoints = content.pointsNode != nil
        switch (hasSurface, hasPoints) {
        case (true, true): return [.mesh, .points, .both]
        case (true, false): return [.mesh]
        case (false, true): return [.points]
        default: return []
        }
    }

    private func install(_ content: SceneContent) {
        guard let view else { return }
        annotationRoot.removeFromParentNode()
        content.scene.rootNode.addChildNode(annotationRoot)
        view.scene = content.scene
        applyDisplayMode()
        applyWireframe()
        resetCamera()
    }

    // MARK: Display

    func setDisplayMode(_ mode: ViewerDisplayMode) {
        displayMode = mode
        applyDisplayMode()
    }

    func setWireframe(_ enabled: Bool) {
        isWireframe = enabled
        applyWireframe()
    }

    private func applyDisplayMode() {
        guard let content else { return }
        let showSurface = displayMode != .points
        let showPoints = displayMode != .mesh || (content.meshNode == nil && content.roomNodes.isEmpty)
        content.meshNode?.isHidden = !showSurface
        content.roomNodes.values.forEach { $0.isHidden = !showSurface }
        content.pointsNode?.isHidden = !showPoints
        view?.setNeedsDisplay()
    }

    private func applyWireframe() {
        guard let content else { return }
        let fill: SCNFillMode = isWireframe ? .lines : .fill
        content.meshNode?.geometry?.materials.forEach { $0.fillMode = fill }
        content.roomNodes.values.forEach { node in node.geometry?.materials.forEach { $0.fillMode = fill } }
        view?.setNeedsDisplay()
    }

    // MARK: Camera

    /// Frames the whole model from the default 3/4 view.
    func resetCamera() {
        frame(direction: Vector3(0.5, 0.65, 1))
    }

    /// Frames the whole model, keeping the current viewing direction.
    func fitModel() {
        guard let pov = view?.pointOfView, let bounds = content?.bounds else { return resetCamera() }
        frame(direction: pov.simdWorldPosition - bounds.center)
    }

    private func frame(direction: Vector3) {
        guard let view, let content, let bounds = content.bounds else { return }
        let framing = SceneBuilder.framingCamera(for: bounds, direction: direction, fieldOfView: fieldOfView)
        let cameraNode: SCNNode
        if let existing = content.scene.rootNode.childNode(withName: "viewer-camera", recursively: false) {
            cameraNode = existing
        } else {
            cameraNode = SCNNode()
            cameraNode.name = "viewer-camera"
            cameraNode.camera = SCNCamera()
            content.scene.rootNode.addChildNode(cameraNode)
        }
        cameraNode.camera?.fieldOfView = CGFloat(fieldOfView)
        cameraNode.camera?.zNear = Double(max(framing.distance * 0.005, 0.001))
        cameraNode.camera?.zFar = Double(framing.distance * 20)
        cameraNode.simdPosition = framing.position
        cameraNode.simdLook(at: framing.target)
        view.pointOfView = cameraNode
        view.defaultCameraController.target = SCNVector3(framing.target)
        view.setNeedsDisplay()
    }

    // MARK: Annotations

    func showAnnotations(measurements: [ScanMeasurement], pending: [Vector3], highlighted: UUID? = nil) {
        annotationRoot.childNodes.forEach { $0.removeFromParentNode() }
        let scale = max((content?.bounds?.diagonalLength ?? 1) * 0.006, 0.003)
        for measurement in measurements {
            let color: UIColor = measurement.id == highlighted ? .systemOrange : .systemYellow
            addAnnotation(points: measurement.points, kind: measurement.kind, color: color, radius: scale)
        }
        if !pending.isEmpty {
            addAnnotation(points: pending, kind: nil, color: .systemPink, radius: scale)
        }
        view?.setNeedsDisplay()
    }

    private func addAnnotation(points: [Vector3], kind: MeasurementKind?, color: UIColor, radius: Float) {
        for point in points {
            let sphere = SCNSphere(radius: CGFloat(radius))
            sphere.firstMaterial?.diffuse.contents = color
            sphere.firstMaterial?.lightingModel = .constant
            sphere.firstMaterial?.readsFromDepthBuffer = false
            let node = SCNNode(geometry: sphere)
            node.simdPosition = point
            node.categoryBitMask = SceneCategory.annotation
            node.renderingOrder = 100
            annotationRoot.addChildNode(node)
        }
        for (a, b) in segments(points: points, kind: kind) {
            addSegment(from: a, to: b, color: color, radius: radius * 0.35)
        }
    }

    private func segments(points: [Vector3], kind: MeasurementKind?) -> [(Vector3, Vector3)] {
        guard points.count >= 2 else { return [] }
        switch kind {
        case .boundingBox:
            guard let box = BoundingBox(points: points) else { return [] }
            let c = box.corners
            let edges = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
            return edges.map { (c[$0.0], c[$0.1]) }
        case .height:
            let a = points[0], b = points[1]
            let corner = Vector3(a.x, b.y, a.z)
            return [(a, corner)]
        case .area:
            return (0..<points.count).map { (points[$0], points[($0 + 1) % points.count]) }
        default:
            return (0..<(points.count - 1)).map { (points[$0], points[$0 + 1]) }
        }
    }

    private func addSegment(from a: Vector3, to b: Vector3, color: UIColor, radius: Float) {
        let length = a.distance(to: b)
        guard length > 0.0001 else { return }
        let cylinder = SCNCylinder(radius: CGFloat(radius), height: CGFloat(length))
        cylinder.firstMaterial?.diffuse.contents = color
        cylinder.firstMaterial?.lightingModel = .constant
        cylinder.firstMaterial?.readsFromDepthBuffer = false
        let node = SCNNode(geometry: cylinder)
        node.simdPosition = (a + b) * 0.5
        node.simdLook(at: b, up: Vector3(0, 1, 0), localFront: Vector3(0, 1, 0))
        node.categoryBitMask = SceneCategory.annotation
        node.renderingOrder = 99
        annotationRoot.addChildNode(node)
    }

    // MARK: Selection

    func highlightElement(_ id: UUID?) {
        guard let content else { return }
        if let previous = highlightedElementID, let node = content.roomNodes[previous] {
            node.geometry?.firstMaterial?.emission.contents = UIColor.black
        }
        highlightedElementID = id
        if let id, let node = content.roomNodes[id] {
            node.geometry?.firstMaterial?.emission.contents = UIColor.systemBlue.withAlphaComponent(0.6)
        }
        view?.setNeedsDisplay()
    }

    // MARK: Picking

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let view, let content else { return }
        let location = recognizer.location(in: view)

        let surfaceVisible = displayMode != .points && (content.meshNode != nil || !content.roomNodes.isEmpty)
        if surfaceVisible {
            let hits = view.hitTest(location, options: [
                .searchMode: SCNHitTestSearchMode.closest.rawValue,
                .ignoreHiddenNodes: true,
                .categoryBitMask: SceneCategory.content
            ])
            if let hit = hits.first {
                let elementID = hit.node.name.flatMap(UUID.init(uuidString:))
                onTap?(ViewerTapResult(worldPoint: hit.simdWorldCoordinates, elementID: elementID))
                return
            }
        }

        // Point-cloud picking: nearest captured point to the view ray.
        guard displayMode != .mesh || content.meshNode == nil && content.roomNodes.isEmpty,
              let positions = geometry?.pointCloud?.positions, !positions.isEmpty else {
            onTap?(ViewerTapResult(worldPoint: nil, elementID: nil))
            return
        }
        let near = view.unprojectPoint(SCNVector3(Float(location.x), Float(location.y), 0)).vector
        let far = view.unprojectPoint(SCNVector3(Float(location.x), Float(location.y), 1)).vector
        guard let ray = Ray(from: near, through: far) else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let index = PointPicker.pick(positions: positions, ray: ray, maxAngle: 0.015)
            await MainActor.run {
                self?.onTap?(ViewerTapResult(worldPoint: index.map { positions[$0] }, elementID: nil))
            }
        }
    }
}
