import ARKit
import Foundation
import ScanCore

/// Reads `ARMeshAnchor` geometry (Metal buffers) into the portable
/// `TriangleMesh` representation in world space.
enum MeshAnchorExtractor {
    static func extract(_ anchor: ARMeshAnchor) -> TriangleMesh {
        let geometry = anchor.geometry
        let transform = Transform3D(anchor.transform)

        let positions = readVectors(geometry.vertices).map(transform.transformPoint)
        let normalSource = geometry.normals
        let normals: [Vector3]? = normalSource.count == geometry.vertices.count
            ? readVectors(normalSource).map { transform.transformDirection($0).normalized }
            : nil
        let indices = readIndices(geometry.faces)
        let mesh = TriangleMesh(positions: positions, normals: normals, colors: nil, indices: indices)
        do {
            try mesh.validate()
            return mesh
        } catch {
            Log.scanning.error("Discarding invalid mesh anchor: \(error.localizedDescription, privacy: .public)")
            return .empty
        }
    }

    static func extract(_ anchors: [ARMeshAnchor]) -> TriangleMesh {
        TriangleMesh.merged(anchors.map { extract($0) })
    }

    /// Surface area (m²) computed directly from the anchor buffers.
    static func surfaceArea(of anchor: ARMeshAnchor) -> Float {
        let geometry = anchor.geometry
        let vertices = readVectors(geometry.vertices)
        let indices = readIndices(geometry.faces)
        var area: Float = 0
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            if a < vertices.count, b < vertices.count, c < vertices.count {
                area += GeometryMath.triangleArea(vertices[a], vertices[b], vertices[c])
            }
            i += 3
        }
        return area
    }

    private static func readVectors(_ source: ARGeometrySource) -> [Vector3] {
        guard source.format == .float3, source.componentsPerVector == 3 else { return [] }
        let base = source.buffer.contents().advanced(by: source.offset)
        var result = [Vector3]()
        result.reserveCapacity(source.count)
        for i in 0..<source.count {
            let pointer = base.advanced(by: i * source.stride)
            result.append(Vector3(
                pointer.load(as: Float.self),
                pointer.load(fromByteOffset: 4, as: Float.self),
                pointer.load(fromByteOffset: 8, as: Float.self)
            ))
        }
        return result
    }

    private static func readIndices(_ element: ARGeometryElement) -> [UInt32] {
        guard element.primitiveType == .triangle, element.indexCountPerPrimitive == 3 else { return [] }
        let count = element.count * 3
        let base = element.buffer.contents()
        var result = [UInt32]()
        result.reserveCapacity(count)
        switch element.bytesPerIndex {
        case 4:
            for i in 0..<count { result.append(base.load(fromByteOffset: i * 4, as: UInt32.self)) }
        case 2:
            for i in 0..<count { result.append(UInt32(base.load(fromByteOffset: i * 2, as: UInt16.self))) }
        default:
            return []
        }
        return result
    }
}
