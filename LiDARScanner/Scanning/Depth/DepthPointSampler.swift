import ARKit
import CoreVideo
import Foundation
import ScanCore

struct DepthSamplingOptions: Sendable {
    /// Pixel stride in the LiDAR depth map (typically 256×192).
    var stride: Int
    var minDepth: Float
    var maxDepth: Float
    /// Samples below this ARKit confidence are discarded.
    var minimumConfidence: ARConfidenceLevel
    var includeColor: Bool
}

/// Converts one ARFrame's LiDAR depth map into world-space points.
///
/// Called synchronously on the ARSession delegate queue: it reads the pixel
/// buffers while the frame is alive and returns copied values, so the ARFrame
/// is never retained (retaining frames stalls ARKit's buffer pool).
///
/// Unprojection: ARKit intrinsics are given for `capturedImage` resolution,
/// so each depth pixel is first scaled to image coordinates, then
///   x = (u − cx)·d / fx,  y = (v − cy)·d / fy
/// and converted from image axes (y down, looking +z) to ARKit camera axes
/// (y up, looking −z) before applying `camera.transform`.
enum DepthPointSampler {
    static func sample(frame: ARFrame, options: DepthSamplingOptions) -> PointBatch? {
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let depthMap = depthData.depthMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)

        // Confidence map (UInt8 per pixel, same resolution as depth).
        let confidenceMap = depthData.confidenceMap
        var confidenceBase: UnsafeMutableRawPointer?
        var confidenceRowBytes = 0
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap)
            confidenceRowBytes = CVPixelBufferGetBytesPerRow(confidenceMap)
        }
        defer {
            if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        }

        // Camera image (YCbCr 4:2:0 bi-planar full range) for per-point color.
        let image = frame.capturedImage
        let imageFormat = CVPixelBufferGetPixelFormatType(image)
        let colorAvailable = options.includeColor
            && CVPixelBufferGetPlaneCount(image) >= 2
            && (imageFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || imageFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        if colorAvailable { CVPixelBufferLockBaseAddress(image, .readOnly) }
        defer { if colorAvailable { CVPixelBufferUnlockBaseAddress(image, .readOnly) } }
        let lumaBase = colorAvailable ? CVPixelBufferGetBaseAddressOfPlane(image, 0) : nil
        let chromaBase = colorAvailable ? CVPixelBufferGetBaseAddressOfPlane(image, 1) : nil
        let lumaRowBytes = colorAvailable ? CVPixelBufferGetBytesPerRowOfPlane(image, 0) : 0
        let chromaRowBytes = colorAvailable ? CVPixelBufferGetBytesPerRowOfPlane(image, 1) : 0
        let imageWidth = CVPixelBufferGetWidthOfPlane(image, 0)
        let imageHeight = CVPixelBufferGetHeightOfPlane(image, 0)
        let isVideoRange = imageFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y
        let resolution = frame.camera.imageResolution
        let scaleX = Float(resolution.width) / Float(depthWidth)
        let scaleY = Float(resolution.height) / Float(depthHeight)
        let cameraToWorld = Transform3D(frame.camera.transform)
        let minConfidence = UInt8(options.minimumConfidence.rawValue)
        let step = max(1, options.stride)

        var positions: [Vector3] = []
        var colors: [SIMD3<UInt8>] = []
        let capacity = (depthWidth / step + 1) * (depthHeight / step + 1)
        positions.reserveCapacity(capacity)
        if colorAvailable { colors.reserveCapacity(capacity) }

        var y = step / 2
        while y < depthHeight {
            let depthRow = depthBase.advanced(by: y * depthRowBytes)
            let confidenceRow = confidenceBase?.advanced(by: y * confidenceRowBytes)
            var x = step / 2
            while x < depthWidth {
                defer { x += step }
                let depth = depthRow.load(fromByteOffset: x * MemoryLayout<Float32>.stride, as: Float32.self)
                guard depth.isFinite, depth >= options.minDepth, depth <= options.maxDepth else { continue }
                if let confidenceRow {
                    let confidence = confidenceRow.load(fromByteOffset: x, as: UInt8.self)
                    guard confidence >= minConfidence else { continue }
                }
                let u = (Float(x) + 0.5) * scaleX
                let v = (Float(y) + 0.5) * scaleY
                let local = Vector3((u - cx) * depth / fx, -(v - cy) * depth / fy, -depth)
                positions.append(cameraToWorld.transformPoint(local))

                if colorAvailable, let lumaBase, let chromaBase {
                    let ix = min(Int(u), imageWidth - 1)
                    let iy = min(Int(v), imageHeight - 1)
                    let luma = lumaBase.load(fromByteOffset: iy * lumaRowBytes + ix, as: UInt8.self)
                    let chromaOffset = (iy / 2) * chromaRowBytes + (ix / 2) * 2
                    let cb = chromaBase.load(fromByteOffset: chromaOffset, as: UInt8.self)
                    let cr = chromaBase.load(fromByteOffset: chromaOffset + 1, as: UInt8.self)
                    colors.append(ycbcrToRGB(y: luma, cb: cb, cr: cr, videoRange: isVideoRange))
                }
            }
            y += step
        }
        guard !positions.isEmpty else { return nil }
        return PointBatch(positions: positions, colors: colorAvailable ? colors : nil)
    }

    /// Median depth (meters) of the central 30% of the depth map — used for
    /// "move closer / move back" guidance. Returns nil if no valid samples.
    static func medianCenterDepth(frame: ARFrame) -> Float? {
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let depthMap = depthData.depthMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)

        var samples: [Float] = []
        samples.reserveCapacity(256)
        let x0 = Int(Float(width) * 0.35), x1 = Int(Float(width) * 0.65)
        let y0 = Int(Float(height) * 0.35), y1 = Int(Float(height) * 0.65)
        for y in Swift.stride(from: y0, to: y1, by: 4) {
            let row = base.advanced(by: y * rowBytes)
            for x in Swift.stride(from: x0, to: x1, by: 4) {
                let d = row.load(fromByteOffset: x * MemoryLayout<Float32>.stride, as: Float32.self)
                if d.isFinite, d > 0 { samples.append(d) }
            }
        }
        return GeometryMath.median(samples)
    }

    /// ITU-R BT.601 YCbCr → RGB (the matrix ARKit's capturedImage uses).
    @inline(__always)
    static func ycbcrToRGB(y: UInt8, cb: UInt8, cr: UInt8, videoRange: Bool) -> SIMD3<UInt8> {
        var luma = Float(y)
        if videoRange { luma = (luma - 16) * (255.0 / 219.0) }
        let blueDiff = Float(cb) - 128
        let redDiff = Float(cr) - 128
        let r = luma + 1.402 * redDiff
        let g = luma - 0.344136 * blueDiff - 0.714136 * redDiff
        let b = luma + 1.772 * blueDiff
        return SIMD3(
            UInt8(clamping: Int(r.rounded())),
            UInt8(clamping: Int(g.rounded())),
            UInt8(clamping: Int(b.rounded()))
        )
    }
}
