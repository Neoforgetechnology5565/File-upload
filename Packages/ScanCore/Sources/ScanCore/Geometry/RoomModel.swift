import Foundation

/// Structural element kinds produced by the RoomPlan pipeline.
public enum RoomElementKind: String, Codable, CaseIterable, Sendable {
    case wall
    case door
    case window
    case opening
    case floor
    case object

    public var displayName: String {
        switch self {
        case .wall: return "Wall"
        case .door: return "Door"
        case .window: return "Window"
        case .opening: return "Opening"
        case .floor: return "Floor"
        case .object: return "Object"
        }
    }

    /// RGB used for the viewer and for exported materials.
    public var displayColor: SIMD3<UInt8> {
        switch self {
        case .wall: return SIMD3(214, 214, 219)
        case .door: return SIMD3(166, 118, 76)
        case .window: return SIMD3(116, 184, 232)
        case .opening: return SIMD3(255, 196, 66)
        case .floor: return SIMD3(150, 150, 155)
        case .object: return SIMD3(88, 130, 214)
        }
    }
}

/// A single RoomPlan surface or object, stored independently of RoomPlan types
/// so it can be persisted, viewed, measured and exported on any platform.
///
/// Conventions (matching RoomPlan):
/// - `dimensions` = (width, height, depth) in meters. Surfaces (walls, doors,
///   windows, openings, floors) are planar and report depth == 0.
/// - `transform` places the element's center in world space. Surfaces lie in
///   their local XY plane.
public struct RoomElement: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: RoomElementKind
    /// Human readable category, e.g. "Wall", "Door (open)", "Table".
    public var category: String
    public var dimensions: Vector3
    public var transform: Transform3D
    /// RoomPlan confidence ("high", "medium", "low").
    public var confidence: String
    public var parentID: UUID?

    public init(
        id: UUID = UUID(),
        kind: RoomElementKind,
        category: String,
        dimensions: Vector3,
        transform: Transform3D,
        confidence: String,
        parentID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.category = category
        self.dimensions = dimensions
        self.transform = transform
        self.confidence = confidence
        self.parentID = parentID
    }

    public var isSurface: Bool { kind != .object }

    /// World-space corners of the element's oriented box.
    public var worldCorners: [Vector3] {
        let half = dimensions * 0.5
        var corners: [Vector3] = []
        corners.reserveCapacity(8)
        for sx in [-1, 1] as [Float] {
            for sy in [-1, 1] as [Float] {
                for sz in [-1, 1] as [Float] {
                    corners.append(transform.transformPoint(Vector3(half.x * sx, half.y * sy, half.z * sz)))
                }
            }
        }
        return corners
    }
}

/// Summary values derived from RoomPlan geometry. All values are computed
/// from detected elements; nothing is estimated beyond what was captured.
public struct RoomSummary: Codable, Equatable, Sendable {
    public var wallCount: Int
    public var doorCount: Int
    public var windowCount: Int
    public var openingCount: Int
    public var objectCount: Int
    /// Sum of detected wall widths (meters).
    public var totalWallLength: Float
    /// Tallest detected wall (meters).
    public var maxWallHeight: Float
    /// Axis-aligned extent of all walls in world X/Z (meters). This is an
    /// approximate footprint of the captured structure, not a floor area.
    public var footprintExtent: SIMD2<Float>?
    /// Object counts keyed by category name.
    public var objectCategories: [String: Int]
}

public struct RoomModel: Codable, Equatable, Sendable {
    public var elements: [RoomElement]

    public init(elements: [RoomElement] = []) {
        self.elements = elements
    }

    public func items(of kind: RoomElementKind) -> [RoomElement] {
        elements.filter { $0.kind == kind }
    }

    public var boundingBox: BoundingBox? {
        BoundingBox(points: elements.flatMap(\.worldCorners))
    }

    public var summary: RoomSummary {
        let walls = items(of: .wall)
        let objects = items(of: .object)
        var categories: [String: Int] = [:]
        for object in objects {
            categories[object.category, default: 0] += 1
        }
        let wallBox = BoundingBox(points: walls.flatMap(\.worldCorners))
        return RoomSummary(
            wallCount: walls.count,
            doorCount: items(of: .door).count,
            windowCount: items(of: .window).count,
            openingCount: items(of: .opening).count,
            objectCount: objects.count,
            totalWallLength: walls.reduce(0) { $0 + $1.dimensions.x },
            maxWallHeight: walls.map(\.dimensions.y).max() ?? 0,
            footprintExtent: wallBox.map { SIMD2($0.size.x, $0.size.z) },
            objectCategories: categories
        )
    }
}
