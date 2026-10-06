import Foundation
import ModelIO
import ScanCore

enum USDZExportMethod: String, Sendable {
    /// Model I/O wrote the .usdz directly.
    case modelIODirect
    /// Model I/O wrote binary USD (.usdc), packaged by `USDZPackager`.
    case modelIOPackaged
    /// Our USDA writer (used for point clouds and when Model I/O cannot export USD).
    case usdaFallback
    /// Apple RoomPlan's native parametric USDZ.
    case roomPlan
}

protocol USDZExporting: Sendable {
    func exportUSDZ(geometry: ScanGeometry, to url: URL) throws -> USDZExportMethod
}

/// Produces a valid USDZ from scan geometry, trying the most compatible
/// encoder first and validating every result before accepting it:
///
/// 1. Model I/O → `.usdz` (if this OS can export USDZ directly)
/// 2. Model I/O → `.usdc` + spec-compliant USDZ packaging (64-byte aligned, stored)
/// 3. `USDAWriter` → `.usda` + USDZ packaging (also the path for point-cloud-only
///    scans, because Model I/O cannot author `UsdGeomPoints`)
struct ModelIOUSDZExporter: USDZExporting {
    func exportUSDZ(geometry: ScanGeometry, to url: URL) throws -> USDZExportMethod {
        let meshes = geometry.namedMeshes
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: url)

        if !meshes.isEmpty {
            let asset = makeAsset(meshes)

            if MDLAsset.canExportFileExtension("usdz") {
                do {
                    try asset.export(to: url)
                    let data = try Data(contentsOf: url)
                    _ = try ExportValidator.validateUSDZ(data)
                    return .modelIODirect
                } catch {
                    Log.export.notice("Model I/O direct USDZ export unusable: \(error.localizedDescription, privacy: .public)")
                    try? fileManager.removeItem(at: url)
                }
            }

            if MDLAsset.canExportFileExtension("usdc") {
                let temporary = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).usdc")
                defer { try? fileManager.removeItem(at: temporary) }
                do {
                    try asset.export(to: temporary)
                    let usdc = try Data(contentsOf: temporary)
                    let package = try USDZPackager.package([.init(path: "scan.usdc", data: usdc)])
                    _ = try ExportValidator.validateUSDZ(package)
                    try package.write(to: url, options: .atomic)
                    return .modelIOPackaged
                } catch {
                    Log.export.notice("Model I/O USDC export unusable: \(error.localizedDescription, privacy: .public)")
                    try? fileManager.removeItem(at: url)
                }
            }
        }

        let usda = try USDAWriter().makeUSDA(meshes: meshes, pointCloud: meshes.isEmpty ? geometry.pointCloud : nil)
        let package = try USDZPackager.package([.init(path: "scan.usda", data: Data(usda.utf8))])
        _ = try ExportValidator.validateUSDZ(package)
        try package.write(to: url, options: .atomic)
        return .usdaFallback
    }

    /// Builds a Model I/O asset with one `MDLMesh` per named mesh, each with
    /// position/normal/color vertex buffers, 32-bit triangle indices and a
    /// physically based material carrying the base color.
    func makeAsset(_ meshes: [NamedMesh]) -> MDLAsset {
        let asset = MDLAsset()
        asset.upAxis = SIMD3<Float>(0, 1, 0)
        let allocator = MDLMeshBufferDataAllocator()

        for named in meshes {
            let mesh = named.mesh
            let descriptor = MDLVertexDescriptor()
            var buffers: [MDLMeshBuffer] = []

            func addAttribute(_ name: String, data: Data) {
                let index = buffers.count
                buffers.append(allocator.newBuffer(with: data, type: .vertex))
                descriptor.attributes[index] = MDLVertexAttribute(name: name, format: .float3, offset: 0, bufferIndex: index)
                descriptor.layouts[index] = MDLVertexBufferLayout(stride: MemoryLayout<Float>.size * 3)
            }

            addAttribute(MDLVertexAttributePosition, data: mesh.positions.packedFloatData)
            addAttribute(MDLVertexAttributeNormal, data: (mesh.normals ?? MeshCleanup.computeVertexNormals(mesh)).packedFloatData)
            if let colors = mesh.colors {
                addAttribute(MDLVertexAttributeColor, data: colors.packedNormalizedColorData)
            }

            let material = MDLMaterial(name: named.materialName, scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())
            let color = SIMD3<Float>(Float(named.color.x) / 255, Float(named.color.y) / 255, Float(named.color.z) / 255)
            material.setProperty(MDLMaterialProperty(name: "baseColor", semantic: .baseColor, float3: color))
            material.setProperty(MDLMaterialProperty(name: "roughness", semantic: .roughness, float: 0.85))

            let indexBuffer = allocator.newBuffer(with: mesh.indices.data, type: .index)
            let submesh = MDLSubmesh(
                indexBuffer: indexBuffer,
                indexCount: mesh.indices.count,
                indexType: .uInt32,
                geometryType: .triangles,
                material: material
            )
            let mdlMesh = MDLMesh(vertexBuffers: buffers, vertexCount: mesh.vertexCount, descriptor: descriptor, submeshes: [submesh])
            mdlMesh.name = named.name
            asset.add(mdlMesh)
        }
        return asset
    }
}
