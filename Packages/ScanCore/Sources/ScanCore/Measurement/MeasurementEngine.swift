import Foundation

/// A persisted measurement. Points are the actual world-space coordinates
/// picked on the scan geometry (meters).
public struct ScanMeasurement: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: MeasurementKind
    public var points: [Vector3]
    public var result: MeasurementResult
    public var label: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: MeasurementKind,
        points: [Vector3],
        result: MeasurementResult,
        label: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.points = points
        self.result = result
        self.label = label
        self.createdAt = createdAt
    }
}

/// Registry and entry point for measurement tools.
public struct MeasurementEngine: Sendable {
    private let tools: [MeasurementKind: any MeasurementTool]

    public init(tools: [any MeasurementTool] = MeasurementEngine.defaultTools) {
        var map: [MeasurementKind: any MeasurementTool] = [:]
        for tool in tools { map[tool.kind] = tool }
        self.tools = map
    }

    public static let defaultTools: [any MeasurementTool] = [
        DistanceTool(),
        HeightTool(),
        HorizontalDistanceTool(),
        PolygonAreaTool(),
        BoundingBoxTool()
    ]

    public var availableKinds: [MeasurementKind] {
        MeasurementKind.allCases.filter { tools[$0] != nil }
    }

    public func tool(for kind: MeasurementKind) -> (any MeasurementTool)? {
        tools[kind]
    }

    public func measure(
        _ kind: MeasurementKind,
        points: [Vector3],
        label: String? = nil
    ) throws -> ScanMeasurement {
        guard let tool = tools[kind] else { throw MeasurementError.degenerate }
        let result = try tool.compute(points)
        return ScanMeasurement(
            kind: kind,
            points: points,
            result: result,
            label: label ?? kind.displayName
        )
    }

    /// Overall axis-aligned dimensions of a scan, in world space.
    public func modelBounds(of geometry: ScanGeometry) throws -> ScanMeasurement {
        guard let box = geometry.boundingBox else { throw MeasurementError.degenerate }
        return ScanMeasurement(
            kind: .boundingBox,
            points: [box.min, box.max],
            result: .box(size: box.size),
            label: "Model bounds"
        )
    }
}

/// Picks the scan point closest to a view ray (used for point-cloud mode,
/// where triangle hit-testing is not possible).
public enum PointPicker {
    /// - Parameters:
    ///   - maxAngle: angular tolerance in radians around the ray.
    /// - Returns: index of the best point, preferring the smallest angular
    ///   error and, for near ties, the point closest to the viewer.
    public static func pick(
        positions: [Vector3],
        ray: Ray,
        maxAngle: Float = 0.01
    ) -> Int? {
        let tanLimit = tan(maxAngle)
        var best: (score: Float, t: Float, index: Int)?
        for (i, p) in positions.enumerated() {
            let t = ray.projectedParameter(of: p)
            guard t > 0 else { continue }
            let perpendicular = (p - ray.point(at: t)).length
            let angularError = perpendicular / t
            guard angularError <= tanLimit else { continue }
            // Quantize the score so the nearer point wins among similar candidates.
            let score = (angularError / tanLimit * 4).rounded(.down)
            if let current = best {
                if score < current.score || (score == current.score && t < current.t) {
                    best = (score, t, i)
                }
            } else {
                best = (score, t, i)
            }
        }
        return best?.index
    }
}
