import Foundation

/// Little-endian binary writer with bulk array support. Used by the internal
/// geometry codec and the binary PLY exporter.
public struct BinaryWriter {
    public private(set) var bytes: [UInt8] = []

    public init(reservingCapacity capacity: Int = 0) {
        bytes.reserveCapacity(capacity)
    }

    public var data: Data { Data(bytes) }

    public mutating func write(_ value: UInt8) {
        bytes.append(value)
    }

    public mutating func write(_ value: UInt16) {
        let le = value.littleEndian
        withUnsafeBytes(of: le) { bytes.append(contentsOf: $0) }
    }

    public mutating func write(_ value: UInt32) {
        let le = value.littleEndian
        withUnsafeBytes(of: le) { bytes.append(contentsOf: $0) }
    }

    public mutating func write(_ value: UInt64) {
        let le = value.littleEndian
        withUnsafeBytes(of: le) { bytes.append(contentsOf: $0) }
    }

    public mutating func write(_ value: Float) {
        write(value.bitPattern)
    }

    public mutating func write(_ string: String) {
        bytes.append(contentsOf: Array(string.utf8))
    }

    public mutating func write(_ data: Data) {
        bytes.append(contentsOf: data)
    }

    public mutating func write(_ raw: [UInt8]) {
        bytes.append(contentsOf: raw)
    }

    /// Packed xyz floats (12 bytes per vector, no SIMD padding).
    public mutating func writePacked(_ vectors: [Vector3]) {
        var packed = [UInt32]()
        packed.reserveCapacity(vectors.count * 3)
        for v in vectors {
            packed.append(v.x.bitPattern.littleEndian)
            packed.append(v.y.bitPattern.littleEndian)
            packed.append(v.z.bitPattern.littleEndian)
        }
        packed.withUnsafeBytes { bytes.append(contentsOf: $0) }
    }

    /// Packed rgb bytes (3 bytes per color).
    public mutating func writePacked(_ colors: [SIMD3<UInt8>]) {
        bytes.reserveCapacity(bytes.count + colors.count * 3)
        for c in colors {
            bytes.append(c.x)
            bytes.append(c.y)
            bytes.append(c.z)
        }
    }

    public mutating func writePacked(_ values: [UInt32]) {
        let le = values.map(\.littleEndian)
        le.withUnsafeBytes { bytes.append(contentsOf: $0) }
    }
}

public enum BinaryReaderError: Error, Equatable {
    case unexpectedEndOfData(needed: Int, available: Int)
}

/// Bounds-checked little-endian reader. Never traps on malformed input.
public struct BinaryReader {
    private let data: Data
    public private(set) var offset: Int = 0

    public init(data: Data) {
        // Re-base so offsets are always zero based.
        self.data = Data(data)
    }

    public var remaining: Int { data.count - offset }

    private func ensure(_ count: Int) throws {
        guard count >= 0, count <= remaining else {
            throw BinaryReaderError.unexpectedEndOfData(needed: count, available: remaining)
        }
    }

    public mutating func readBytes(_ count: Int) throws -> [UInt8] {
        try ensure(count)
        let slice = data[offset..<(offset + count)]
        offset += count
        return Array(slice)
    }

    public mutating func readUInt8() throws -> UInt8 {
        try ensure(1)
        let value = data[offset]
        offset += 1
        return value
    }

    public mutating func readUInt16() throws -> UInt16 {
        let b = try readBytes(2)
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }

    public mutating func readUInt32() throws -> UInt32 {
        let b = try readBytes(4)
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    public mutating func readUInt64() throws -> UInt64 {
        let lo = UInt64(try readUInt32())
        let hi = UInt64(try readUInt32())
        return lo | (hi << 32)
    }

    public mutating func readFloat() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    public mutating func readData(_ count: Int) throws -> Data {
        try ensure(count)
        let slice = data[offset..<(offset + count)]
        offset += count
        return Data(slice)
    }

    public mutating func readUInt32Array(count: Int) throws -> [UInt32] {
        let byteCount = count.multipliedReportingOverflow(by: 4)
        guard !byteCount.overflow else {
            throw BinaryReaderError.unexpectedEndOfData(needed: Int.max, available: remaining)
        }
        try ensure(byteCount.partialValue)
        var result = [UInt32](repeating: 0, count: count)
        let start = offset
        result.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[start..<(start + byteCount.partialValue)]))
            }
        }
        offset += byteCount.partialValue
        return result.map { UInt32(littleEndian: $0) }
    }

    public mutating func readPackedVectors(count: Int) throws -> [Vector3] {
        let raw = try readUInt32Array(count: count * 3)
        var vectors = [Vector3]()
        vectors.reserveCapacity(count)
        var i = 0
        while i < raw.count {
            vectors.append(Vector3(
                Float(bitPattern: raw[i]),
                Float(bitPattern: raw[i + 1]),
                Float(bitPattern: raw[i + 2])
            ))
            i += 3
        }
        return vectors
    }

    public mutating func readPackedColors(count: Int) throws -> [SIMD3<UInt8>] {
        let raw = try readBytes(count * 3)
        var colors = [SIMD3<UInt8>]()
        colors.reserveCapacity(count)
        var i = 0
        while i < raw.count {
            colors.append(SIMD3(raw[i], raw[i + 1], raw[i + 2]))
            i += 3
        }
        return colors
    }
}
