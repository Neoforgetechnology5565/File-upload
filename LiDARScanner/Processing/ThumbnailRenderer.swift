import Metal
import SceneKit
import ScanCore
import UIKit

protocol ThumbnailRendering: Sendable {
    /// JPEG data of an offscreen render of the scan, or nil if rendering is unavailable.
    @MainActor func renderThumbnail(for geometry: ScanGeometry, size: CGSize) -> Data?
}

/// Offscreen SceneKit renderer for history thumbnails.
struct SceneKitThumbnailRenderer: ThumbnailRendering {
    @MainActor
    func renderThumbnail(for geometry: ScanGeometry, size: CGSize = CGSize(width: 480, height: 480)) -> Data? {
        guard let device = MTLCreateSystemDefaultDevice(), let bounds = geometry.boundingBox else { return nil }
        // Keep thumbnail rendering cheap for very large clouds.
        var renderGeometry = geometry
        if let cloud = geometry.pointCloud, cloud.count > 200_000, geometry.mesh != nil {
            renderGeometry.pointCloud = nil
        }
        let content = SceneBuilder.makeScene(for: renderGeometry, pointSize: 2)
        content.scene.background.contents = UIColor(white: 0.12, alpha: 1)

        let camera = SCNCamera()
        camera.fieldOfView = 50
        let framing = SceneBuilder.framingCamera(for: bounds, direction: Vector3(0.6, 0.7, 1), fieldOfView: 50)
        camera.zNear = Double(max(framing.distance * 0.01, 0.001))
        camera.zFar = Double(framing.distance * 10)
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.simdPosition = framing.position
        cameraNode.simdLook(at: framing.target)
        content.scene.rootNode.addChildNode(cameraNode)

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = content.scene
        renderer.pointOfView = cameraNode
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        return image.jpegData(compressionQuality: 0.8)
    }
}
