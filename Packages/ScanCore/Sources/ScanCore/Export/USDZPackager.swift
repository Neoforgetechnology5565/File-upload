import Foundation

/// CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320) as required by ZIP.
public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// Builds USDZ packages per the Pixar/Apple USDZ specification:
/// an uncompressed ("stored") ZIP archive, whose first entry is the root USD
/// layer, with every file's data aligned to a 64-byte boundary.
public enum USDZPackager {
    public struct Entry: Sendable {
        public var path: String
        public var data: Data

        public init(path: String, data: Data) {
            self.path = path
            self.data = data
        }
    }

    public enum PackagingError: Error, Equatable, LocalizedError {
        case noEntries
        case rootLayerMustBeUSD(String)
        case tooLarge
        case invalidPath(String)

        public var errorDescription: String? {
            switch self {
            case .noEntries: return "A USDZ package needs at least one file."
            case .rootLayerMustBeUSD(let path): return "The first USDZ entry must be a USD layer (got \(path))."
            case .tooLarge: return "The USDZ package exceeds the 4 GB ZIP limit."
            case .invalidPath(let path): return "Invalid USDZ entry path: \(path)"
            }
        }
    }

    public static let alignment = 64
    public static let usdExtensions: Set<String> = ["usda", "usdc", "usd"]
    /// Extra-field header id used for alignment padding (same as Pixar's usdzip).
    static let paddingFieldID: UInt16 = 0x1986

    public static func package(_ entries: [Entry]) throws -> Data {
        guard let first = entries.first else { throw PackagingError.noEntries }
        let ext = (first.path as NSString).pathExtension.lowercased()
        guard usdExtensions.contains(ext) else { throw PackagingError.rootLayerMustBeUSD(first.path) }

        var writer = BinaryWriter(reservingCapacity: entries.reduce(0) { $0 + $1.data.count + 160 } + 22)
        var central = BinaryWriter()
        // DOS date 1980-01-01 00:00 keeps output deterministic.
        let dosTime: UInt16 = 0
        let dosDate: UInt16 = 0x0021

        for entry in entries {
            guard !entry.path.isEmpty, !entry.path.hasPrefix("/"), !entry.path.contains("..") else {
                throw PackagingError.invalidPath(entry.path)
            }
            let name = Array(entry.path.utf8)
            let headerOffset = writer.bytes.count
            guard headerOffset < Int(UInt32.max), entry.data.count < Int(UInt32.max) else {
                throw PackagingError.tooLarge
            }
            let crc = CRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)

            // Compute padding so the file data starts on a 64-byte boundary.
            let unpaddedDataOffset = headerOffset + 30 + name.count
            var padding = (alignment - (unpaddedDataOffset % alignment)) % alignment
            if padding > 0 && padding < 4 { padding += alignment } // extra field needs a 4-byte header

            // Local file header
            writer.write(UInt32(0x0403_4B50))
            writer.write(UInt16(20))      // version needed
            writer.write(UInt16(0))       // flags
            writer.write(UInt16(0))       // compression: stored
            writer.write(dosTime)
            writer.write(dosDate)
            writer.write(crc)
            writer.write(size)            // compressed size
            writer.write(size)            // uncompressed size
            writer.write(UInt16(name.count))
            writer.write(UInt16(padding))
            writer.write(name)
            if padding > 0 {
                writer.write(paddingFieldID)
                writer.write(UInt16(padding - 4))
                writer.write([UInt8](repeating: 0, count: padding - 4))
            }
            writer.write(entry.data)

            // Central directory record
            central.write(UInt32(0x0201_4B50))
            central.write(UInt16(20))     // version made by
            central.write(UInt16(20))     // version needed
            central.write(UInt16(0))
            central.write(UInt16(0))
            central.write(dosTime)
            central.write(dosDate)
            central.write(crc)
            central.write(size)
            central.write(size)
            central.write(UInt16(name.count))
            central.write(UInt16(0))      // extra length
            central.write(UInt16(0))      // comment length
            central.write(UInt16(0))      // disk number
            central.write(UInt16(0))      // internal attributes
            central.write(UInt32(0))      // external attributes
            central.write(UInt32(headerOffset))
            central.write(name)
        }

        let centralOffset = writer.bytes.count
        guard centralOffset + central.bytes.count < Int(UInt32.max), entries.count < Int(UInt16.max) else {
            throw PackagingError.tooLarge
        }
        writer.write(central.bytes)

        // End of central directory
        writer.write(UInt32(0x0605_4B50))
        writer.write(UInt16(0))
        writer.write(UInt16(0))
        writer.write(UInt16(entries.count))
        writer.write(UInt16(entries.count))
        writer.write(UInt32(central.bytes.count))
        writer.write(UInt32(centralOffset))
        writer.write(UInt16(0))
        return writer.data
    }
}
