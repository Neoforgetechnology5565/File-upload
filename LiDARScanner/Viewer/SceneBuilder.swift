import Foundation
import SceneKit
import ScanCore
import UIKit

enum ViewerDisplayMode: String, CaseIterable, Identifiable {
    case mesh
    case points
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mesh: return "Mesh"
        case .points: return "Points"
        case .both: return "Both"
        }
    }
}

/// Node category masks used for hit testing.
enum SceneCategory {
    static let content = 1 << 1
    static let annotation = 1 << 2
}

/// SceneKit scene built from a `ScanGeometry`.
struct SceneContent {
    let scene: SCNScene
    let contentNode: SCNNode
    let meshNode: SCNNode?
    let pointsNode: SCNNode?
    let roomNodes: [UUID: SCNNode]
    let bounds: BoundingBox?
}

/// Builds SceneKit geometry directly from packed buffers (no per-vertex
/// object allocation), so scans with hundreds of thousands of vertices load
/// quickly and render on the GPU.
///
/// SceneKit is used for the viewer because it provides native point
/// primitives (for LiDAR point clouds), wireframe fill mode, built-in orbit /
/// pan / zoom camera control and precise world-space hit testing — features
/// RealityKit does not offer for arbitrary geometry on iOS 17.
enum SceneBuilder {
    static func makeScene(for geometry: ScanGeometry, pointSize: CGFloat = 3) -> SceneContent {
        let scene = SCNScene()
        let content = SCNNode()
        content.name = "content"
        scene.rootNode.addChildNode(content)

        var meshNode: SCNNode?
        if let mesh = geometry.mesh, !mesh.isEmpty {
            let node = SCNNode(geometry: meshGeometry(mesh))
            node.name = "scan-mesh"
            node.categoryBitMask = SceneCategory.content
            content.addChildNode(node)
            meshNode = node
        }

        var pointsNode: SCNNode?
        if let cloud = geometry.pointCloud, !cloud.isEmpty {
            let node = SCNNode(geometry: pointGeometry(cloud, pointSize: pointSize))
            node.name = "scan-points"
            node.categoryBitMask = SceneCategory.content
            content.addChildNode(node)
            pointsNode = node
        }

        var roomNodes: [UUID: SCNNode] = [:]
        if let room = geometry.room {
            for element in room.elements {
                let node = roomNode(for: element)
                content.addChildNode(node)
                roomNodes[element.id] = node
            }
        }

        addLighting(to: scene)
        return SceneContent(
            scene: scene,
            contentNode: content,
            meshNode: meshNode,
            pointsNode: pointsNode,
            roomNodes: roomNodes,
            bounds: geometry.boundingBox
        )
    }

    static func meshGeometry(_ mesh: TriangleMesh) -> SCNGeometry {
        var sources = [SCNGeometrySource(
            data: mesh.positions.packedFloatData,
            semantic: .vertex,
            vectorCount: mesh.vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        )]
        let normals = mesh.normals ?? MeshCleanup.computeVertexNormals(mesh)
        sources.append(SCNGeometrySource(
            data: normals.packedFloatData,
            semantic: .normal,
            vectorCount: normals.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        ))
        if let colors = mesh.colors {
            sources.append(colorSource(colors))
        }
        let element = SCNGeometryElement(
            data: mesh.indices.data,
            primitiveType: .triangles,
            primitiveCount: mesh.triangleCount,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = mesh.colors == nil ? UIColor(white: 0.82, alpha: 1) : UIColor.white
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }

    static func pointGeometry(_ cloud: PointCloud, pointSize: CGFloat) -> SCNGeometry {
        var sources = [SCNGeometrySource(
            data: cloud.positions.packedFloatData,
            semantic: .vertex,
            vectorCount: cloud.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        )]
        if let colors = cloud.colors {
            sources.append(colorSource(colors))
        }
        let indices = (0..<UInt32(cloud.count)).map { $0 }
        let element = SCNGeometryElement(
            data: indices.data,
            primitiveType: .point,
            primitiveCount: cloud.count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        element.pointSize = pointSize
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = pointSize * 2
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = cloud.colors == nil ? UIColor.systemTeal : UIColor.white
        geometry.materials = [material]
        return geometry
    }

    static func roomNode(for element: RoomElement) -> SCNNode {
        let size = RoomMeshBuilder.boxDimensions(for: element)
        let box = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0)
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color(element.kind.displayColor)
        material.roughness.contents = 0.9
        material.transparency = element.kind == .wall ? 0.92 : 1
        box.materials = [material]

        let node = SCNNode(geometry: box)
        node.simdTransform = element.transform.simdMatrix
        node.name = element.id.uuidString
        node.categoryBitMask = SceneCategory.content
        return node
    }

    static func color(_ rgb: SIMD3<UInt8>, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat(rgb.x) / 255, green: CGFloat(rgb.y) / 255, blue: CGFloat(rgb.z) / 255, alpha: alpha)
    }

    private static func colorSource(_ colors: [SIMD3<UInt8>]) -> SCNGeometrySource {
        SCNGeometrySource(
            data: colors.packedNormalizedColorData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        )
    }

    private static func addLighting(to scene: SCNScene) {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 350
        fill.eulerAngles = SCNVector3(Float.pi / 5, -Float.pi * 0.75, 0)
        scene.rootNode.addChildNode(fill)
    }

    /// Camera position that frames `bounds` from `direction`.
    static func framingCamera(for bounds: BoundingBox, direction: Vector3, fieldOfView: Float) -> (position: Vector3, target: Vector3, distance: Float) {
        let radius = max(bounds.diagonalLength * 0.5, 0.05)
        let halfFOV = fieldOfView * .pi / 180 / 2
        let distance = radius / sin(halfFOV) * 1.08
        let dir = direction.normalized == .zero ? Vector3(0.5, 0.6, 1).normalized : direction.normalized
        return (bounds.center + dir * distance, bounds.center, distance)
    }
}
