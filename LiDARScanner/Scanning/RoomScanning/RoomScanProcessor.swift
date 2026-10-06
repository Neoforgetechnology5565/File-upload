import Foundation
import RoomPlan
import ScanCore

/// Converts RoomPlan's `CapturedRoom` into the app's portable `RoomModel`.
enum RoomModelConverter {
    static func convert(_ room: CapturedRoom) -> RoomModel {
        var elements: [RoomElement] = []
        let surfaces = room.walls + room.doors + room.windows + room.openings + room.floors
        for surface in surfaces {
            let (kind, name) = classify(surface.category)
            elements.append(RoomElement(
                id: surface.identifier,
                kind: kind,
                category: name,
                dimensions: surface.dimensions,
                transform: Transform3D(surface.transform),
                confidence: confidenceName(surface.confidence),
                parentID: surface.parentIdentifier
            ))
        }
        for object in room.objects {
            elements.append(RoomElement(
                id: object.identifier,
                kind: .object,
                category: objectName(object.category),
                dimensions: object.dimensions,
                transform: Transform3D(object.transform),
                confidence: confidenceName(object.confidence),
                parentID: object.parentIdentifier
            ))
        }
        return RoomModel(elements: elements)
    }

    static func classify(_ category: CapturedRoom.Surface.Category) -> (RoomElementKind, String) {
        switch category {
        case .wall: return (.wall, "Wall")
        case .door(let isOpen): return (.door, isOpen ? "Door (open)" : "Door (closed)")
        case .window: return (.window, "Window")
        case .opening: return (.opening, "Opening")
        case .floor: return (.floor, "Floor")
        @unknown default: return (.wall, "Surface")
        }
    }

    /// RoomPlan object categories (table, chair, sofa, bed, storage, …) are
    /// enum cases; their case names are stable, human-readable identifiers.
    static func objectName(_ category: CapturedRoom.Object.Category) -> String {
        let raw = String(describing: category)
        // Split camelCase ("washerDryer" → "Washer Dryer").
        var words: [String] = []
        var current = ""
        for character in raw {
            if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func confidenceName(_ confidence: CapturedRoom.Confidence) -> String {
        switch confidence {
        case .high: return "high"
        case .medium: return "medium"
        case .low: return "low"
        @unknown default: return "unknown"
        }
    }
}

/// RoomPlan post-processing: final room assembly and native USDZ export.
enum RoomScanProcessor {
    /// Runs RoomPlan's `RoomBuilder` on the raw capture data. This is
    /// CPU/GPU-heavy and is awaited off the main actor.
    static func buildRoom(from data: CapturedRoomData) async throws -> CapturedRoom {
        let builder = RoomBuilder(options: [.beautifyObjects])
        return try await builder.capturedRoom(from: data)
    }

    /// Apple's parametric USDZ (walls/doors/windows/objects as categorized
    /// prims). This is the highest-fidelity USDZ for room scans and is what
    /// the USDZ export offers for rooms.
    static func exportUSDZ(_ room: CapturedRoom, to url: URL) throws {
        try room.export(to: url, exportOptions: .parametric)
    }

    /// `CapturedRoom` is `Codable`; storing it keeps the full RoomPlan result
    /// for future re-processing or multi-room merging (StructureBuilder).
    static func encode(_ room: CapturedRoom) throws -> Data {
        try JSONEncoder().encode(room)
    }

    static func instructionMessage(_ instruction: RoomCaptureSession.Instruction) -> String {
        switch instruction {
        case .normal: return "Tracking — keep scanning the room"
        case .moveCloseToWall: return "Move closer to the wall"
        case .moveAwayFromWall: return "Move away from the wall"
        case .slowDown: return "Move slowly"
        case .turnOnLight: return "Turn on more lights"
        case .lowTexture: return "Low tracking quality — aim at areas with more detail"
        @unknown default: return "Keep scanning"
        }
    }
}
