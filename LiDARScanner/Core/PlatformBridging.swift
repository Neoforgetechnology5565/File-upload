import Foundation
import SceneKit
import ScanCore
import simd

// Lossless conversions between ScanCore's portable math types and Apple's
// simd / SceneKit types. Kept in one place so the rest of the app never
// hand-copies matrix columns.

extension Transform3D {
    init(_ matrix: simd_float4x4) {
        self.init(c0: matrix.columns.0, c1: matrix.columns.1, c2: matrix.columns.2, c3: matrix.columns.3)
    }

    var simdMatrix: simd_float4x4 {
        simd_float4x4(columns: (c0, c1, c2, c3))
    }
}

// SceneKit already provides `SCNVector3(_: SIMD3<Float>)`.
extension SCNVector3 {
    var vector: Vector3 {
        Vector3(Float(x), Float(y), Float(z))
    }
}

extension Array where Element == Vector3 {
    /// Tightly packed xyz float data (12 bytes/vertex) for GPU/Model I/O buffers.
    var packedFloatData: Data {
        var floats = [Float]()
        floats.reserveCapacity(count * 3)
        for v in self {
            floats.append(v.x)
            floats.append(v.y)
            floats.append(v.z)
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

extension Array where Element == SIMD3<UInt8> {
    /// Normalized RGB float data (12 bytes/vertex).
    var packedNormalizedColorData: Data {
        var floats = [Float]()
        floats.reserveCapacity(count * 3)
        for c in self {
            floats.append(Float(c.x) / 255)
            floats.append(Float(c.y) / 255)
            floats.append(Float(c.z) / 255)
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

extension Array where Element == UInt32 {
    var data: Data {
        withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
