import Foundation

public enum ExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case usdz
    case obj
    case ply

    public var id: String { rawValue }

    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .usdz: return "USDZ"
        case .obj: return "OBJ"
        case .ply: return "PLY"
        }
    }

    public var summary: String {
        switch self {
        case .usdz: return "Apple AR Quick Look, Reality Composer, most 3D tools."
        case .obj: return "Universal mesh format with normals and materials."
        case .ply: return "Point cloud / mesh with XYZ, RGB and normals."
        }
    }

    /// Uniform Type Identifier string (kept as a string so ScanCore does not
    /// depend on UniformTypeIdentifiers).
    public var utTypeIdentifier: String {
        switch self {
        case .usdz: return "com.pixar.universal-scene-description-mobile"
        case .obj: return "public.geometry-definition-format"
        case .ply: return "public.polygon-file-format"
        }
    }
}

public enum ExportError: Error, Equatable, LocalizedError {
    case nothingToExport(ExportFormat)
    case unsupported(format: ExportFormat, reason: String)
    case validationFailed(format: ExportFormat, reason: String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .nothingToExport(let format):
            return "This scan has no geometry that can be exported as \(format.displayName)."
        case let .unsupported(format, reason):
            return "\(format.displayName) export is not available: \(reason)"
        case let .validationFailed(format, reason):
            return "The generated \(format.displayName) file failed validation: \(reason)"
        case .writeFailed(let reason):
            return "The export file could not be written: \(reason)"
        }
    }
}

/// What a PLY export should contain.
public enum PLYContent: String, CaseIterable, Sendable {
    /// Prefer the point cloud; fall back to mesh vertices+faces.
    case automatic
    case pointCloud
    case mesh
}
