import Foundation
import ScanCore
import SwiftData

/// SwiftData entity for a scan.
///
/// Frequently queried fields are real columns (name, dates, type, status,
/// owner, sync state). The full domain `Scan` (device info, statistics,
/// measurements, exports, file manifest, metadata) is stored as a JSON
/// payload, which keeps the schema stable while the domain model evolves.
/// Column values always take precedence over the payload when decoding.
@Model
final class ScanRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var typeRaw: String
    var statusRaw: String
    var syncStateRaw: String
    var ownerID: String?
    var payload: Data
    var payloadVersion: Int

    init(scan: Scan, payload: Data) {
        id = scan.id
        name = scan.name
        createdAt = scan.createdAt
        updatedAt = scan.updatedAt
        typeRaw = scan.type.rawValue
        statusRaw = scan.status.rawValue
        syncStateRaw = scan.syncState.rawValue
        ownerID = scan.ownerID
        self.payload = payload
        payloadVersion = ScanRecordCoding.currentPayloadVersion
    }

    func update(from scan: Scan, payload: Data) {
        name = scan.name
        createdAt = scan.createdAt
        updatedAt = scan.updatedAt
        typeRaw = scan.type.rawValue
        statusRaw = scan.status.rawValue
        syncStateRaw = scan.syncState.rawValue
        ownerID = scan.ownerID
        self.payload = payload
        payloadVersion = ScanRecordCoding.currentPayloadVersion
    }

    func toDomain() throws -> Scan {
        var scan = try ScanRecordCoding.decode(payload)
        scan.id = id
        scan.name = name
        scan.createdAt = createdAt
        scan.updatedAt = updatedAt
        if let type = ScanType(rawValue: typeRaw) { scan.type = type }
        if let status = ProcessingStatus(rawValue: statusRaw) { scan.status = status }
        if let sync = SyncState(rawValue: syncStateRaw) { scan.syncState = sync }
        scan.ownerID = ownerID
        return scan
    }
}

/// JSON coding for the `ScanRecord.payload` column.
enum ScanRecordCoding {
    static let currentPayloadVersion = 1

    static func encode(_ scan: Scan) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(scan)
    }

    static func decode(_ data: Data) throws -> Scan {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Scan.self, from: data)
    }
}
