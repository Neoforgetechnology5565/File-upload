import Foundation

public enum ScanType: String, Codable, CaseIterable, Identifiable, Sendable {
    /// RoomPlan-based structural capture (walls, doors, windows, furniture).
    case room
    /// ARKit scene-reconstruction + LiDAR depth capture of objects or spaces.
    case object

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .room: return "Room Scan"
        case .object: return "Object / Spatial Scan"
        }
    }

    public var shortName: String {
        switch self {
        case .room: return "Room"
        case .object: return "Object"
        }
    }

    public var systemImage: String {
        switch self {
        case .room: return "house"
        case .object: return "cube"
        }
    }
}

public enum ProcessingStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case processing
    case completed
    case failed

    public var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .processing: return "Processing"
        case .completed: return "Ready"
        case .failed: return "Failed"
        }
    }
}

/// Cloud-sync state. Local-only until a `CloudSyncService` is configured.
public enum SyncState: String, Codable, CaseIterable, Sendable {
    case localOnly
    case pendingUpload
    case uploading
    case synced
    case failed
}

public struct DeviceInfo: Codable, Equatable, Sendable {
    /// Hardware identifier, e.g. "iPhone16,1".
    public var modelIdentifier: String
    public var systemName: String
    public var systemVersion: String
    public var hasLiDAR: Bool
    public var appVersion: String

    public init(modelIdentifier: String, systemName: String, systemVersion: String, hasLiDAR: Bool, appVersion: String) {
        self.modelIdentifier = modelIdentifier
        self.systemName = systemName
        self.systemVersion = systemVersion
        self.hasLiDAR = hasLiDAR
        self.appVersion = appVersion
    }

    public static let unknown = DeviceInfo(modelIdentifier: "unknown", systemName: "unknown", systemVersion: "0", hasLiDAR: false, appVersion: "0")
}

/// Relative paths (inside the scan's directory) of every file belonging to a scan.
public struct ScanFileManifest: Codable, Equatable, Sendable {
    public var geometryFile: String?
    public var thumbnailFile: String?
    /// RoomPlan USDZ produced by `CapturedRoom.export(to:)`.
    public var roomUSDZFile: String?
    /// RoomPlan `CapturedRoom` JSON (Codable), kept for future re-processing.
    public var capturedRoomFile: String?

    public init(geometryFile: String? = nil, thumbnailFile: String? = nil, roomUSDZFile: String? = nil, capturedRoomFile: String? = nil) {
        self.geometryFile = geometryFile
        self.thumbnailFile = thumbnailFile
        self.roomUSDZFile = roomUSDZFile
        self.capturedRoomFile = capturedRoomFile
    }

    public var allFiles: [String] {
        [geometryFile, thumbnailFile, roomUSDZFile, capturedRoomFile].compactMap { $0 }
    }

    public static let geometryFileName = "geometry.\(ScanGeometryCodec.fileExtension)"
    public static let thumbnailFileName = "thumbnail.jpg"
    public static let roomUSDZFileName = "room.usdz"
    public static let capturedRoomFileName = "captured-room.json"
}

public struct ExportRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var format: ExportFormat
    public var fileName: String
    public var byteCount: Int64
    public var exportedAt: Date

    public init(id: UUID = UUID(), format: ExportFormat, fileName: String, byteCount: Int64, exportedAt: Date = Date()) {
        self.id = id
        self.format = format
        self.fileName = fileName
        self.byteCount = byteCount
        self.exportedAt = exportedAt
    }
}

/// Values computed from the processed geometry. Optional values are only
/// present when they could actually be computed.
public struct ScanStatistics: Codable, Equatable, Sendable {
    public var pointCount: Int
    public var vertexCount: Int
    public var triangleCount: Int
    public var surfaceArea: Float?
    public var boundingBoxSize: Vector3?
    public var captureDuration: TimeInterval
    public var room: RoomSummary?

    public init(
        pointCount: Int = 0,
        vertexCount: Int = 0,
        triangleCount: Int = 0,
        surfaceArea: Float? = nil,
        boundingBoxSize: Vector3? = nil,
        captureDuration: TimeInterval = 0,
        room: RoomSummary? = nil
    ) {
        self.pointCount = pointCount
        self.vertexCount = vertexCount
        self.triangleCount = triangleCount
        self.surfaceArea = surfaceArea
        self.boundingBoxSize = boundingBoxSize
        self.captureDuration = captureDuration
        self.room = room
    }

    public static func make(from geometry: ScanGeometry, captureDuration: TimeInterval) -> ScanStatistics {
        let mesh = geometry.exportableMesh
        return ScanStatistics(
            pointCount: geometry.pointCloud?.count ?? 0,
            vertexCount: mesh?.vertexCount ?? 0,
            triangleCount: mesh?.triangleCount ?? 0,
            surfaceArea: geometry.mesh.map(MeshStatistics.surfaceArea),
            boundingBoxSize: geometry.boundingBox?.size,
            captureDuration: captureDuration,
            room: geometry.room?.summary
        )
    }
}

/// The domain model for a saved scan. Independent from SwiftData so the
/// repository implementation (local, cloud, in-memory) can change freely.
public struct Scan: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var type: ScanType
    public var status: ProcessingStatus
    public var device: DeviceInfo
    public var files: ScanFileManifest
    public var statistics: ScanStatistics
    public var measurements: [ScanMeasurement]
    public var exports: [ExportRecord]
    public var notes: String
    public var ownerID: String?
    public var syncState: SyncState
    /// Free-form key/value metadata (capture preset, processing report…).
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        type: ScanType,
        status: ProcessingStatus = .pending,
        device: DeviceInfo,
        files: ScanFileManifest = ScanFileManifest(),
        statistics: ScanStatistics = ScanStatistics(),
        measurements: [ScanMeasurement] = [],
        exports: [ExportRecord] = [],
        notes: String = "",
        ownerID: String? = nil,
        syncState: SyncState = .localOnly,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.type = type
        self.status = status
        self.device = device
        self.files = files
        self.statistics = statistics
        self.measurements = measurements
        self.exports = exports
        self.notes = notes
        self.ownerID = ownerID
        self.syncState = syncState
        self.metadata = metadata
    }

    public var isExported: Bool { !exports.isEmpty }

    public func lastExport(of format: ExportFormat) -> ExportRecord? {
        exports.filter { $0.format == format }.max { $0.exportedAt < $1.exportedAt }
    }
}

public enum ScanNameValidator {
    public static let maximumLength = 80

    public enum ValidationError: Error, Equatable, LocalizedError {
        case empty
        case tooLong(max: Int)

        public var errorDescription: String? {
            switch self {
            case .empty: return "Please enter a name for the scan."
            case .tooLong(let max): return "Scan names can be at most \(max) characters."
            }
        }
    }

    /// Returns the trimmed, validated name.
    public static func validate(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }
        guard trimmed.count <= maximumLength else { throw ValidationError.tooLong(max: maximumLength) }
        return trimmed
    }

    public static func defaultName(for type: ScanType, date: Date = Date(), locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(type.shortName) – \(formatter.string(from: date))"
    }
}

/// Sort orders supported by repositories.
public enum ScanSortOrder: String, CaseIterable, Identifiable, Sendable {
    case newestFirst
    case oldestFirst
    case nameAscending

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .newestFirst: return "Newest First"
        case .oldestFirst: return "Oldest First"
        case .nameAscending: return "Name"
        }
    }

    public func sort(_ scans: [Scan]) -> [Scan] {
        switch self {
        case .newestFirst: return scans.sorted { $0.createdAt > $1.createdAt }
        case .oldestFirst: return scans.sorted { $0.createdAt < $1.createdAt }
        case .nameAscending: return scans.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}

/// Filtering applied by history/search screens.
public struct ScanQuery: Equatable, Sendable {
    public var searchText: String
    public var type: ScanType?
    public var sortOrder: ScanSortOrder

    public init(searchText: String = "", type: ScanType? = nil, sortOrder: ScanSortOrder = .newestFirst) {
        self.searchText = searchText
        self.type = type
        self.sortOrder = sortOrder
    }

    public func matches(_ scan: Scan) -> Bool {
        if let type, scan.type != type { return false }
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return scan.name.localizedCaseInsensitiveContains(text) || scan.notes.localizedCaseInsensitiveContains(text)
        }
        return true
    }

    public func apply(to scans: [Scan]) -> [Scan] {
        sortOrder.sort(scans.filter(matches))
    }
}
