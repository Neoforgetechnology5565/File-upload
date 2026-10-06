import Foundation

/// Structural validation of exported files. Every export is validated before
/// it is offered to the user so that invalid files are never shared.
public enum ExportValidator {
    public struct PLYInfo: Equatable, Sendable {
        public var format: String
        public var vertexCount: Int
        public var faceCount: Int
        public var properties: [String]
        public var headerLength: Int
    }

    public struct OBJInfo: Equatable, Sendable {
        public var vertexCount: Int
        public var normalCount: Int
        public var faceCount: Int
    }

    public struct USDZInfo: Equatable, Sendable {
        public var entryPaths: [String]
    }

    // MARK: PLY

    public static func validatePLY(_ data: Data) throws -> PLYInfo {
        func fail(_ reason: String) -> ExportError { .validationFailed(format: .ply, reason: reason) }

        let marker = Array("end_header\n".utf8)
        let bytes = [UInt8](data.prefix(64 * 1024))
        guard let markerRange = firstRange(of: marker, in: bytes) else { throw fail("missing end_header") }
        let headerLength = markerRange.upperBound
        guard let header = String(bytes: bytes[0..<headerLength], encoding: .ascii) else { throw fail("header is not ASCII") }
        let lines = header.split(separator: "\n").map(String.init)
        guard lines.first == "ply" else { throw fail("missing 'ply' magic") }

        var format = ""
        var vertexCount = -1
        var faceCount = 0
        var properties: [String] = []
        var currentElement = ""
        var vertexStride = 0

        for line in lines.dropFirst() {
            let parts = line.split(separator: " ").map(String.init)
            guard let keyword = parts.first else { continue }
            switch keyword {
            case "format":
                guard parts.count >= 2 else { throw fail("bad format line") }
                format = parts[1]
            case "element":
                guard parts.count == 3, let count = Int(parts[2]), count >= 0 else { throw fail("bad element line") }
                currentElement = parts[1]
                if currentElement == "vertex" { vertexCount = count }
                if currentElement == "face" { faceCount = count }
            case "property":
                if currentElement == "vertex" {
                    guard parts.count == 3 else { throw fail("unsupported vertex property") }
                    properties.append(parts[2])
                    switch parts[1] {
                    case "float", "float32", "int", "uint", "int32", "uint32": vertexStride += 4
                    case "uchar", "uint8", "char", "int8": vertexStride += 1
                    case "double", "float64": vertexStride += 8
                    case "short", "ushort", "int16", "uint16": vertexStride += 2
                    default: throw fail("unknown property type \(parts[1])")
                    }
                }
            default:
                continue
            }
        }
        guard vertexCount >= 0 else { throw fail("missing vertex element") }
        guard ["x", "y", "z"].allSatisfy({ properties.contains($0) }) else { throw fail("missing x/y/z properties") }

        switch format {
        case "binary_little_endian":
            // Faces written by PLYWriter are triangles: 1 + 3*4 bytes each.
            let expected = headerLength + vertexCount * vertexStride + faceCount * 13
            guard data.count == expected else {
                throw fail("size \(data.count) does not match expected \(expected)")
            }
        case "ascii":
            guard let body = String(data: data.dropFirst(headerLength), encoding: .utf8) else { throw fail("body is not UTF-8") }
            let rows = body.split(separator: "\n", omittingEmptySubsequences: true)
            guard rows.count == vertexCount + faceCount else {
                throw fail("expected \(vertexCount + faceCount) rows, found \(rows.count)")
            }
        default:
            throw fail("unsupported format \(format)")
        }
        return PLYInfo(format: format, vertexCount: vertexCount, faceCount: faceCount, properties: properties, headerLength: headerLength)
    }

    // MARK: OBJ

    public static func validateOBJ(_ data: Data) throws -> OBJInfo {
        func fail(_ reason: String) -> ExportError { .validationFailed(format: .obj, reason: reason) }
        guard let text = String(data: data, encoding: .utf8) else { throw fail("file is not UTF-8") }
        var vertices = 0
        var normals = 0
        var faces = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("v ") {
                let parts = line.split(separator: " ")
                guard parts.count == 4 || parts.count == 7,
                      parts.dropFirst().allSatisfy({ Float($0) != nil }) else { throw fail("malformed vertex line") }
                vertices += 1
            } else if line.hasPrefix("vn ") {
                normals += 1
            } else if line.hasPrefix("f ") {
                let refs = line.split(separator: " ").dropFirst()
                guard refs.count >= 3 else { throw fail("face with fewer than 3 vertices") }
                for ref in refs {
                    let comps = ref.split(separator: "/", omittingEmptySubsequences: false)
                    guard let v = Int(comps[0]), v >= 1, v <= vertices else {
                        throw fail("face references undefined vertex \(ref)")
                    }
                    if comps.count == 3, !comps[2].isEmpty {
                        guard let n = Int(comps[2]), n >= 1, n <= normals else {
                            throw fail("face references undefined normal \(ref)")
                        }
                    }
                }
                faces += 1
            }
        }
        guard vertices > 0 else { throw fail("no vertices") }
        return OBJInfo(vertexCount: vertices, normalCount: normals, faceCount: faces)
    }

    // MARK: USDZ

    public static func validateUSDZ(_ data: Data) throws -> USDZInfo {
        func fail(_ reason: String) -> ExportError { .validationFailed(format: .usdz, reason: reason) }
        var reader = BinaryReader(data: data)
        var paths: [String] = []
        do {
            while reader.remaining >= 4 {
                let headerStart = reader.offset
                let signature = try reader.readUInt32()
                if signature == 0x0201_4B50 || signature == 0x0605_4B50 { break }
                guard signature == 0x0403_4B50 else { throw fail("invalid local file header at \(headerStart)") }
                _ = try reader.readUInt16()                 // version
                let flags = try reader.readUInt16()
                let compression = try reader.readUInt16()
                _ = try reader.readUInt16(); _ = try reader.readUInt16()
                let crc = try reader.readUInt32()
                let compressedSize = Int(try reader.readUInt32())
                let size = Int(try reader.readUInt32())
                let nameLength = Int(try reader.readUInt16())
                let extraLength = Int(try reader.readUInt16())
                guard flags & 0x08 == 0 else { throw fail("data descriptors are not allowed") }
                guard compression == 0, compressedSize == size else { throw fail("entries must be stored uncompressed") }
                let nameBytes = try reader.readBytes(nameLength)
                guard let name = String(bytes: nameBytes, encoding: .utf8) else { throw fail("invalid entry name") }
                _ = try reader.readBytes(extraLength)
                guard reader.offset % USDZPackager.alignment == 0 else {
                    throw fail("entry \(name) is not 64-byte aligned")
                }
                let payload = try reader.readData(size)
                guard CRC32.checksum(payload) == crc else { throw fail("CRC mismatch for \(name)") }
                if paths.isEmpty {
                    let ext = (name as NSString).pathExtension.lowercased()
                    guard USDZPackager.usdExtensions.contains(ext) else { throw fail("first entry \(name) is not a USD layer") }
                    if ext == "usdc" {
                        guard payload.prefix(8) == Data("PXR-USDC".utf8) else { throw fail("root layer is not a valid USDC file") }
                    } else if ext == "usda" {
                        guard payload.prefix(5) == Data("#usda".utf8) else { throw fail("root layer is not a valid USDA file") }
                    }
                }
                paths.append(name)
            }
        } catch let error as ExportError {
            throw error
        } catch {
            throw fail("truncated archive")
        }
        guard !paths.isEmpty else { throw fail("archive is empty") }
        return USDZInfo(entryPaths: paths)
    }

    // MARK: Helpers

    static func firstRange(of needle: [UInt8], in haystack: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if Array(haystack[start..<(start + needle.count)]) == needle {
                return start..<(start + needle.count)
            }
        }
        return nil
    }
}
