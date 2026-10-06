import Foundation

/// Triangle-mesh cleanup and simplification.
///
/// ARKit scene reconstruction delivers the environment as many independent
/// `ARMeshAnchor` chunks whose border vertices are duplicated and which can
/// contain tiny floating fragments. These operations turn that into a single
/// welded, reasonably sized mesh suitable for viewing and export.
public enum MeshCleanup {
    // MARK: Vertex clustering (welding & decimation)

    /// Merges all vertices that fall into the same cubic cell of `cellSize`
    /// meters. With a tiny cell (≈1–2 mm) this welds duplicate seam vertices;
    /// with a larger cell it performs vertex-clustering decimation.
    /// Triangles that collapse are removed.
    public static func vertexClustering(_ mesh: TriangleMesh, cellSize: Float) throws -> TriangleMesh {
        guard !mesh.isEmpty, cellSize > 0 else { return mesh }
        var lookup: [VoxelKey: UInt32] = [:]
        lookup.reserveCapacity(mesh.vertexCount / 2)
        var positionSums: [Vector3] = []
        var normalSums: [Vector3] = []
        var colorSums: [SIMD3<Float>] = []
        var counts: [Float] = []
        var remap = [UInt32](repeating: UInt32.max, count: mesh.vertexCount)
        let hasNormals = mesh.normals != nil
        let hasColors = mesh.colors != nil

        for i in 0..<mesh.vertexCount {
            if i % 100_000 == 0 { try Task.checkCancellation() }
            let p = mesh.positions[i]
            guard let key = VoxelKey(position: p, voxelSize: cellSize) else { continue }
            let cluster: UInt32
            if let existing = lookup[key] {
                cluster = existing
                positionSums[Int(cluster)] += p
                counts[Int(cluster)] += 1
                if hasNormals { normalSums[Int(cluster)] += mesh.normals![i] }
                if hasColors {
                    let c = mesh.colors![i]
                    colorSums[Int(cluster)] += SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z))
                }
            } else {
                cluster = UInt32(counts.count)
                lookup[key] = cluster
                positionSums.append(p)
                counts.append(1)
                if hasNormals { normalSums.append(mesh.normals![i]) }
                if hasColors {
                    let c = mesh.colors![i]
                    colorSums.append(SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z)))
                }
            }
            remap[i] = cluster
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(mesh.indices.count)
        var face = 0
        while face + 2 < mesh.indices.count {
            let a = remap[Int(mesh.indices[face])]
            let b = remap[Int(mesh.indices[face + 1])]
            let c = remap[Int(mesh.indices[face + 2])]
            face += 3
            guard a != UInt32.max, b != UInt32.max, c != UInt32.max,
                  a != b, b != c, a != c else { continue }
            indices.append(contentsOf: [a, b, c])
        }

        let positions = zip(positionSums, counts).map { $0 / $1 }
        let normals: [Vector3]? = hasNormals ? normalSums.map { n in
            let unit = n.normalized
            return unit == .zero ? Vector3(0, 1, 0) : unit
        } : nil
        let colors: [SIMD3<UInt8>]? = hasColors ? zip(colorSums, counts).map { sum, count in
            let c = sum / count
            return SIMD3<UInt8>(UInt8(clamping: Int(c.x.rounded())), UInt8(clamping: Int(c.y.rounded())), UInt8(clamping: Int(c.z.rounded())))
        } : nil
        return removeUnreferencedVertices(TriangleMesh(positions: positions, normals: normals, colors: colors, indices: indices))
    }

    /// Repeatedly increases the clustering cell size until the mesh has at
    /// most `maxTriangles` triangles (or the iteration limit is reached).
    public static func decimate(
        _ mesh: TriangleMesh,
        maxTriangles: Int,
        initialCellSize: Float,
        maxIterations: Int = 8
    ) throws -> TriangleMesh {
        guard mesh.triangleCount > maxTriangles, maxTriangles > 0 else { return mesh }
        var cell = max(initialCellSize, 0.001)
        var result = mesh
        for _ in 0..<maxIterations {
            try Task.checkCancellation()
            result = try vertexClustering(mesh, cellSize: cell)
            if result.triangleCount <= maxTriangles { break }
            cell *= 1.5
        }
        return result
    }

    // MARK: Topological cleanup

    /// Removes triangles with repeated indices or an area below `minArea` m².
    public static func removeDegenerateTriangles(_ mesh: TriangleMesh, minArea: Float = 1e-8) -> TriangleMesh {
        var indices: [UInt32] = []
        indices.reserveCapacity(mesh.indices.count)
        for face in 0..<mesh.triangleCount {
            let base = face * 3
            let a = mesh.indices[base], b = mesh.indices[base + 1], c = mesh.indices[base + 2]
            guard a != b, b != c, a != c else { continue }
            let (pa, pb, pc) = mesh.triangle(face)
            guard GeometryMath.triangleArea(pa, pb, pc) >= minArea else { continue }
            indices.append(contentsOf: [a, b, c])
        }
        var result = mesh
        result.indices = indices
        return removeUnreferencedVertices(result)
    }

    /// Drops vertices not referenced by any triangle and compacts attributes.
    public static func removeUnreferencedVertices(_ mesh: TriangleMesh) -> TriangleMesh {
        var newIndex = [UInt32](repeating: UInt32.max, count: mesh.vertexCount)
        var order: [Int] = []
        order.reserveCapacity(mesh.vertexCount)
        for index in mesh.indices where newIndex[Int(index)] == UInt32.max {
            newIndex[Int(index)] = UInt32(order.count)
            order.append(Int(index))
        }
        if order.count == mesh.vertexCount, order.enumerated().allSatisfy({ $0.offset == $0.element }) {
            return mesh
        }
        return TriangleMesh(
            positions: order.map { mesh.positions[$0] },
            normals: mesh.normals.map { n in order.map { n[$0] } },
            colors: mesh.colors.map { c in order.map { c[$0] } },
            indices: mesh.indices.map { newIndex[Int($0)] }
        )
    }

    /// Removes connected components (sharing vertices) with fewer than
    /// `minTriangles` triangles — typically floating reconstruction noise.
    public static func removeSmallComponents(_ mesh: TriangleMesh, minTriangles: Int) throws -> TriangleMesh {
        guard minTriangles > 1, mesh.triangleCount > 0 else { return mesh }
        var parent = Array(0..<mesh.vertexCount)

        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root { root = parent[root] }
            var node = x
            while parent[node] != root {
                let next = parent[node]
                parent[node] = root
                node = next
            }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        for face in 0..<mesh.triangleCount {
            if face % 100_000 == 0 { try Task.checkCancellation() }
            let base = face * 3
            let a = Int(mesh.indices[base]), b = Int(mesh.indices[base + 1]), c = Int(mesh.indices[base + 2])
            union(a, b)
            union(a, c)
        }

        var triangleCounts: [Int: Int] = [:]
        var faceRoots = [Int](repeating: 0, count: mesh.triangleCount)
        for face in 0..<mesh.triangleCount {
            let root = find(Int(mesh.indices[face * 3]))
            faceRoots[face] = root
            triangleCounts[root, default: 0] += 1
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(mesh.indices.count)
        for face in 0..<mesh.triangleCount where (triangleCounts[faceRoots[face]] ?? 0) >= minTriangles {
            let base = face * 3
            indices.append(contentsOf: mesh.indices[base..<(base + 3)])
        }
        var result = mesh
        result.indices = indices
        return removeUnreferencedVertices(result)
    }

    // MARK: Normals

    /// Area-weighted smooth vertex normals.
    public static func computeVertexNormals(_ mesh: TriangleMesh) -> [Vector3] {
        var normals = [Vector3](repeating: .zero, count: mesh.vertexCount)
        for face in 0..<mesh.triangleCount {
            let base = face * 3
            let ia = Int(mesh.indices[base]), ib = Int(mesh.indices[base + 1]), ic = Int(mesh.indices[base + 2])
            let n = GeometryMath.faceNormal(mesh.positions[ia], mesh.positions[ib], mesh.positions[ic])
            normals[ia] += n
            normals[ib] += n
            normals[ic] += n
        }
        return normals.map { n in
            let unit = n.normalized
            return unit == .zero ? Vector3(0, 1, 0) : unit
        }
    }

    public static func withVertexNormals(_ mesh: TriangleMesh) -> TriangleMesh {
        guard mesh.normals == nil else { return mesh }
        var result = mesh
        result.normals = computeVertexNormals(mesh)
        return result
    }
}

public enum MeshStatistics {
    /// Total surface area in m².
    public static func surfaceArea(_ mesh: TriangleMesh) -> Float {
        var area: Float = 0
        for face in 0..<mesh.triangleCount {
            let (a, b, c) = mesh.triangle(face)
            area += GeometryMath.triangleArea(a, b, c)
        }
        return area
    }
}
