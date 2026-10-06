import SceneKit
import SwiftUI

/// SwiftUI wrapper for the SceneKit scan viewer. All behavior lives in
/// `SceneViewerController`; this view only hosts the `SCNView`.
struct ScanSceneView: UIViewRepresentable {
    let controller: SceneViewerController

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.accessibilityLabel = "3D scan viewer"
        view.accessibilityHint = "Drag to rotate, pinch to zoom, two-finger drag to pan."
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    static func dismantleUIView(_ uiView: SCNView, coordinator: ()) {
        uiView.scene = nil
    }
}
