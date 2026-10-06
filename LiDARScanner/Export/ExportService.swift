import Foundation
import ScanCore

struct ExportOptions: Equatable, Sendable {
    var plyEncoding: PLYWriter.Encoding = .binaryLittleEndian
    var plyContent: PLYContent = .automatic
    var objIncludeVertexColors: Bool = true
}

struct ExportArtifact: Equatable, Sendable {
    var format: ExportFormat
    /// Main file (.usdz / .obj / .ply).
    var primaryURL: URL
    /// Companion files (e.g. the OBJ's .mtl).
    var additionalURLs: [URL]
    var byteCount: Int64
    var note: String?

    var shareURLs: [URL] { [primaryURL] + additionalURLs }
}

enum ExportAvailability: Equatable, Sendable {
    case available(String)
    case unavailable(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var detail: String {
        switch self {
        case .available(let text), .unavailable(let text): return text
        }
    }
}

protocol ExportService: Sendable {
    func availability(of format: ExportFormat, for scan: Scan, geometry: ScanGeometry) -> ExportAvailability
    func export(
        scan: Scan,
        geometry: ScanGeometry,
        format: ExportFormat,
        options: ExportOptions,
        roomUSDZURL: URL?,
        to directory: URL
    ) async throws -> ExportArtifact
}

/// Real converters for every format — no file is ever "renamed" into another
/// format, and every output is structurally validated before it is returned.
final class DefaultExportService: ExportService, @unchecked Sendable {
    private let usdzExporter: USDZExporting

    init(usdzExporter: USDZExporting = ModelIOUSDZExporter()) {
        self.usdzExporter = usdzExporter
    }

    func availability(of format: ExportFormat, for scan: Scan, geometry: ScanGeometry) -> ExportAvailability {
        switch format {
        case .ply:
            if geometry.hasPointCloud {
                let extras = [geometry.pointCloud?.hasColors == true ? "RGB" : nil, geometry.pointCloud?.hasNormals == true ? "normals" : nil].compactMap { $0 }
                return .available(extras.isEmpty ? "Point cloud (XYZ)" : "Point cloud (XYZ, \(extras.joined(separator: ", ")))")
            }
            if geometry.hasMesh { return .available("Mesh vertices, normals and faces") }
            return .unavailable("No geometry")
        case .obj:
            if geometry.hasMesh { return .available("Mesh with normals and materials") }
            if geometry.hasPointCloud { return .available("Vertices only (point cloud has no faces)") }
            return .unavailable("No geometry")
        case .usdz:
            if scan.type == .room { return .available("RoomPlan parametric model") }
            if geometry.hasMesh { return .available("Mesh with materials") }
            if geometry.hasPointCloud { return .available("Point cloud (UsdGeomPoints)") }
            return .unavailable("No geometry")
        }
    }

    func export(
        scan: Scan,
        geometry: ScanGeometry,
        format: ExportFormat,
        options: ExportOptions,
        roomUSDZURL: URL?,
        to directory: URL
    ) async throws -> ExportArtifact {
        let baseName = DefaultExportService.fileBaseName(for: scan)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let exporter = usdzExporter

        return try await Task.detached(priority: .userInitiated) {
            do {
                switch format {
                case .ply:
                    return try DefaultExportService.exportPLY(geometry: geometry, options: options, baseName: baseName, directory: directory)
                case .obj:
                    return try DefaultExportService.exportOBJ(geometry: geometry, options: options, baseName: baseName, directory: directory)
                case .usdz:
                    return try DefaultExportService.exportUSDZ(geometry: geometry, roomUSDZURL: roomUSDZURL, exporter: exporter, baseName: baseName, directory: directory)
                }
            } catch let error as ExportError {
                throw error
            } catch {
                throw ExportError.writeFailed(error.localizedDescription)
            }
        }.value
    }

    // MARK: Format implementations

    static func exportPLY(geometry: ScanGeometry, options: ExportOptions, baseName: String, directory: URL) throws -> ExportArtifact {
        let writer = PLYWriter(encoding: options.plyEncoding)
        let data: Data
        let description: String
        switch options.plyContent {
        case .pointCloud:
            guard let cloud = geometry.pointCloud, !cloud.isEmpty else { throw ExportError.nothingToExport(.ply) }
            data = try writer.data(for: cloud)
            description = "Point cloud"
        case .mesh:
            guard let mesh = geometry.exportableMesh else { throw ExportError.nothingToExport(.ply) }
            data = try writer.data(for: mesh)
            description = "Mesh"
        case .automatic:
            if let cloud = geometry.pointCloud, !cloud.isEmpty {
                data = try writer.data(for: cloud)
                description = "Point cloud"
            } else if let mesh = geometry.exportableMesh {
                data = try writer.data(for: mesh)
                description = "Mesh"
            } else {
                throw ExportError.nothingToExport(.ply)
            }
        }
        let info = try ExportValidator.validatePLY(data)
        let url = directory.appendingPathComponent("\(baseName).ply")
        try data.write(to: url, options: .atomic)
        return ExportArtifact(
            format: .ply,
            primaryURL: url,
            additionalURLs: [],
            byteCount: Int64(data.count),
            note: "\(description): \(info.vertexCount) vertices\(info.faceCount > 0 ? ", \(info.faceCount) faces" : "") · \(info.properties.joined(separator: " "))"
        )
    }

    static func exportOBJ(geometry: ScanGeometry, options: ExportOptions, baseName: String, directory: URL) throws -> ExportArtifact {
        let writer = OBJWriter(includeVertexColors: options.objIncludeVertexColors)
        let output: OBJWriter.Output
        var note: String
        if !geometry.namedMeshes.isEmpty {
            output = try writer.makeOutput(groups: geometry.namedMeshes, baseName: baseName)
            note = "Mesh"
        } else if let cloud = geometry.pointCloud, !cloud.isEmpty {
            output = try writer.makePointCloudOutput(cloud, baseName: baseName)
            note = "Point cloud as OBJ vertices (no faces)"
        } else {
            throw ExportError.nothingToExport(.obj)
        }
        let info = try ExportValidator.validateOBJ(output.obj)
        note += ": \(info.vertexCount) vertices, \(info.faceCount) faces"

        let objURL = directory.appendingPathComponent("\(baseName).obj")
        let mtlURL = directory.appendingPathComponent(output.mtlFileName)
        try output.obj.write(to: objURL, options: .atomic)
        try output.mtl.write(to: mtlURL, options: .atomic)
        return ExportArtifact(
            format: .obj,
            primaryURL: objURL,
            additionalURLs: [mtlURL],
            byteCount: Int64(output.obj.count + output.mtl.count),
            note: note
        )
    }

    static func exportUSDZ(geometry: ScanGeometry, roomUSDZURL: URL?, exporter: USDZExporting, baseName: String, directory: URL) throws -> ExportArtifact {
        let url = directory.appendingPathComponent("\(baseName).usdz")
        try? FileManager.default.removeItem(at: url)

        // Rooms: prefer Apple's RoomPlan USDZ when it exists and validates.
        if let roomUSDZURL, FileManager.default.fileExists(atPath: roomUSDZURL.path) {
            do {
                let data = try Data(contentsOf: roomUSDZURL)
                _ = try ExportValidator.validateUSDZ(data)
                try data.write(to: url, options: .atomic)
                return ExportArtifact(format: .usdz, primaryURL: url, additionalURLs: [], byteCount: Int64(data.count), note: "RoomPlan parametric USDZ")
            } catch {
                Log.export.notice("RoomPlan USDZ not usable, regenerating: \(error.localizedDescription, privacy: .public)")
            }
        }

        let method = try exporter.exportUSDZ(geometry: geometry, to: url)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let note: String
        switch method {
        case .modelIODirect, .modelIOPackaged: note = "USD mesh (Model I/O)"
        case .usdaFallback: note = "USD (ASCII) package"
        case .roomPlan: note = "RoomPlan parametric USDZ"
        }
        return ExportArtifact(format: .usdz, primaryURL: url, additionalURLs: [], byteCount: size, note: note)
    }

    /// File-system-safe base name derived from the scan name.
    static func fileBaseName(for scan: Scan) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = String(scan.name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
        return cleaned.isEmpty ? "scan" : String(cleaned.prefix(60))
    }
}
