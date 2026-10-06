import Foundation

public enum ScanGeometryCodecError: Error, Equatable, LocalizedError {
    case invalidMagic
    case unsupportedVersion(UInt32)
    case corrupted(String)

    public var errorDescription: String? {
        switch self {
        case .invalidMagic: return "The scan geometry file is not a valid LiDAR Scanner geometry file."
        case .unsupportedVersion(let v): return "The scan geometry file version \(v) is not supported."
        case .corrupted(let reason): return "The scan geometry file is corrupted (\(reason))."
        }
    }
}

/// Compact binary on-disk format for `ScanGeometry` (`geometry.lsgeo`).
///
/// Layout (all little endian):
/// ```
/// magic "LSGE" | version u32 | sectionFlags u32
/// [pointCloud]  count u32 | attrFlags u32 | xyz f32*3*n | [nxyz f32*3*n] | [rgb u8*3*n]
/// [mesh]        vertexCount u32 | indexCount u32 | attrFlags u32 | xyz | [normals] | [rgb] | indices u32*m
/// [room]        jsonLength u32 | JSON(RoomModel)
/// ```
/// Raw arrays make loading large scans fast (one bulk copy per attribute)
/// while JSON keeps the small parametric room model evolvable.
public enum ScanGeometryCodec {
    public static let magic: [UInt8] = Array("LSGE".utf8)
    public static let currentVersion: UInt32 = 1
    public static let fileExtension = "lsgeo"

    private struct Section: OptionSet {
        let rawValue: UInt32
        static let pointCloud = Section(rawValue: 1 << 0)
        static let mesh = Section(rawValue: 1 << 1)
        static let room = Section(rawValue: 1 << 2)
    }

    private struct Attributes: OptionSet {
        let rawValue: UInt32
        static let normals = Attributes(rawValue: 1 << 0)
        static let colors = Attributes(rawValue: 1 << 1)
    }

    public static func encode(_ geometry: ScanGeometry) throws -> Data {
        try geometry.pointCloud?.validate()
        try geometry.mesh?.validate()

        var sections: Section = []
        if geometry.pointCloud != nil { sections.insert(.pointCloud) }
        if geometry.mesh != nil { sections.insert(.mesh) }
        if geometry.room != nil { sections.insert(.room) }

        let estimate = (geometry.pointCloud?.count ?? 0) * 27 + (geometry.mesh?.vertexCount ?? 0) * 27
            + (geometry.mesh?.indices.count ?? 0) * 4 + 64
        var writer = BinaryWriter(reservingCapacity: estimate)
        writer.write(magic)
        writer.write(currentVersion)
        writer.write(sections.rawValue)

        if let cloud = geometry.pointCloud {
            var attrs: Attributes = []
            if cloud.normals != nil { attrs.insert(.normals) }
            if cloud.colors != nil { attrs.insert(.colors) }
            writer.write(UInt32(cloud.count))
            writer.write(attrs.rawValue)
            writer.writePacked(cloud.positions)
            if let normals = cloud.normals { writer.writePacked(normals) }
            if let colors = cloud.colors { writer.writePacked(colors) }
        }

        if let mesh = geometry.mesh {
            var attrs: Attributes = []
            if mesh.normals != nil { attrs.insert(.normals) }
            if mesh.colors != nil { attrs.insert(.colors) }
            writer.write(UInt32(mesh.vertexCount))
            writer.write(UInt32(mesh.indices.count))
            writer.write(attrs.rawValue)
            writer.writePacked(mesh.positions)
            if let normals = mesh.normals { writer.writePacked(normals) }
            if let colors = mesh.colors { writer.writePacked(colors) }
            writer.writePacked(mesh.indices)
        }

        if let room = geometry.room {
            let json = try JSONEncoder().encode(room)
            writer.write(UInt32(json.count))
            writer.write(json)
        }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> ScanGeometry {
        var reader = BinaryReader(data: data)
        do {
            guard try reader.readBytes(4) == magic else { throw ScanGeometryCodecError.invalidMagic }
            let version = try reader.readUInt32()
            guard version == currentVersion else { throw ScanGeometryCodecError.unsupportedVersion(version) }
            let sections = Section(rawValue: try reader.readUInt32())
            var geometry = ScanGeometry()

            if sections.contains(.pointCloud) {
                let count = Int(try reader.readUInt32())
                let attrs = Attributes(rawValue: try reader.readUInt32())
                let positions = try reader.readPackedVectors(count: count)
                let normals = attrs.contains(.normals) ? try reader.readPackedVectors(count: count) : nil
                let colors = attrs.contains(.colors) ? try reader.readPackedColors(count: count) : nil
                geometry.pointCloud = PointCloud(positions: positions, colors: colors, normals: normals)
            }

            if sections.contains(.mesh) {
                let vertexCount = Int(try reader.readUInt32())
                let indexCount = Int(try reader.readUInt32())
                let attrs = Attributes(rawValue: try reader.readUInt32())
                let positions = try reader.readPackedVectors(count: vertexCount)
                let normals = attrs.contains(.normals) ? try reader.readPackedVectors(count: vertexCount) : nil
                let colors = attrs.contains(.colors) ? try reader.readPackedColors(count: vertexCount) : nil
                let indices = try reader.readUInt32Array(count: indexCount)
                let mesh = TriangleMesh(positions: positions, normals: normals, colors: colors, indices: indices)
                do {
                    try mesh.validate()
                } catch {
                    throw ScanGeometryCodecError.corrupted("invalid mesh: \(error.localizedDescription)")
                }
                geometry.mesh = mesh
            }

            if sections.contains(.room) {
                let length = Int(try reader.readUInt32())
                let json = try reader.readData(length)
                geometry.room = try JSONDecoder().decode(RoomModel.self, from: json)
            }
            return geometry
        } catch let error as ScanGeometryCodecError {
            throw error
        } catch let error as BinaryReaderError {
            throw ScanGeometryCodecError.corrupted("truncated data: \(error)")
        } catch let error as DecodingError {
            throw ScanGeometryCodecError.corrupted("room model: \(error)")
        }
    }

    public static func write(_ geometry: ScanGeometry, to url: URL) throws {
        let data = try encode(geometry)
        try data.write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> ScanGeometry {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try decode(data)
    }
}
