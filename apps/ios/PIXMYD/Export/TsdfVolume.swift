import Foundation
import simd

/// On-device TSDF fusion and surface extraction.
///
/// A direct port of `packages/recon/src/tsdf.ts` and `marching.ts`, kept in
/// step deliberately: the same capture processed on the phone and in the studio
/// has to produce the same geometry, or the two are not interchangeable and the
/// user has to care which one made the file.
///
/// The properties the TypeScript test suite pins down and this must preserve:
///
///  - Marching **tetrahedra**, not cubes. Six tetrahedra per cube, 16 sign
///    cases each, no ambiguous configurations, so the surface is manifold by
///    construction rather than by luck.
///  - Triangles are emitted in **reverse** table order so the surface winds
///    outward. Without it the mesh is inside out — invisible under two-sided
///    lighting and obvious the moment it reaches a tool that backface-culls.
///  - Unobserved voxels are **null, not far**. A cube with any unobserved
///    corner is skipped, so genuinely unseen regions stay open. An as-built
///    with an honest hole is a note to go back to site; one with an invented
///    lid is a measurement that was never taken.
final class TsdfVolume {

    struct Mesh {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]?
        var indices: [UInt32]
    }

    struct PointCloud {
        var positions: [SIMD3<Float>]
        var colors: [SIMD3<UInt8>]?
    }

    private static let blockSize = 8
    private static let blockVoxels = blockSize * blockSize * blockSize

    private final class Block {
        var sdf = [Float](repeating: 0, count: TsdfVolume.blockVoxels)
        var weight = [Float](repeating: 0, count: TsdfVolume.blockVoxels)
        var color = [SIMD3<Float>](repeating: .zero, count: TsdfVolume.blockVoxels)
        let origin: SIMD3<Int32>
        init(origin: SIMD3<Int32>) { self.origin = origin }
    }

    let voxelSize: Double
    let truncation: Double
    private let minDepth: Float
    private let maxDepth: Float
    private let minConfidence: UInt8

    private var blocks: [Int: Block] = [:]

    init(voxelSize: Double, truncation: Double? = nil,
         minDepth: Float = 0.15, maxDepth: Float = 5.0, minConfidence: UInt8 = 1) {
        self.voxelSize = voxelSize
        self.truncation = truncation ?? voxelSize * 3
        self.minDepth = minDepth
        self.maxDepth = maxDepth
        self.minConfidence = minConfidence
    }

    /// Pack block coordinates into an integer key. String keys would dominate
    /// the profile — this runs several times per voxel per frame.
    private static func key(_ b: SIMD3<Int32>) -> Int {
        let offset = 1 << 20
        return ((Int(b.x) + offset) * 2_097_152 + (Int(b.y) + offset)) * 2_097_152
            + (Int(b.z) + offset)
    }

    // MARK: - Integration

    func integrate(
        depth: [Float],
        confidence: [UInt8]?,
        width: Int,
        height: Int,
        camera: CameraModel.Pinhole,
        pose: Pose
    ) {
        let rotation = simd_quatf(
            ix: Float(pose.q[0]), iy: Float(pose.q[1]),
            iz: Float(pose.q[2]), r: Float(pose.q[3])
        )
        let translation = SIMD3<Float>(Float(pose.t[0]), Float(pose.t[1]), Float(pose.t[2]))

        let fx = Float(camera.fx), fy = Float(camera.fy)
        let cx = Float(camera.cx), cy = Float(camera.cy)
        let trunc = Float(truncation)
        let inverseVoxel = Float(1 / voxelSize)
        let step = Float(voxelSize) * 0.5
        let stepCount = Int((2 * trunc / step).rounded(.up))

        for py in 0..<height {
            for px in 0..<width {
                let i = py * width + px
                let d = depth[i]
                guard d > minDepth, d < maxDepth else { continue }
                if let confidence, confidence[i] < minConfidence { continue }

                // Camera-space surface point, computer-vision axes.
                let local = SIMD3<Float>(
                    (Float(px) + 0.5 - cx) * d / fx,
                    (Float(py) + 0.5 - cy) * d / fy,
                    d
                )
                let rayLength = simd_length(local)
                guard rayLength > 1e-6 else { continue }

                let worldSurface = rotation.act(local) + translation
                let worldRay = simd_normalize(worldSurface - translation)

                // Depth noise grows with range, so a reading at 4 m must not
                // outvote one at 0.5 m.
                let depthWeight = min(1, 1 / (d * d))
                let confidenceWeight = confidence.map { Float($0[i] + 1) / 3 } ?? 1
                let weight = depthWeight * confidenceWeight

                for s in 0...stepCount {
                    let along = -trunc + Float(s) * step
                    let p = worldSurface + worldRay * along
                    let voxel = SIMD3<Int32>(
                        Int32((p.x * inverseVoxel).rounded(.down)),
                        Int32((p.y * inverseVoxel).rounded(.down)),
                        Int32((p.z * inverseVoxel).rounded(.down))
                    )
                    let centre = SIMD3<Float>(
                        (Float(voxel.x) + 0.5) * Float(voxelSize),
                        (Float(voxel.y) + 0.5) * Float(voxelSize),
                        (Float(voxel.z) + 0.5) * Float(voxelSize)
                    )
                    // Signed distance along the viewing ray: positive in front
                    // of the surface, negative behind it.
                    let sdf = rayLength - simd_distance(centre, translation)
                    guard sdf >= -trunc else { continue }
                    update(voxel: voxel, sdf: max(-1, min(1, sdf / trunc)), weight: weight)
                }
            }
        }
    }

    private func update(voxel: SIMD3<Int32>, sdf: Float, weight: Float) {
        let block = SIMD3<Int32>(
            Int32((Double(voxel.x) / 8).rounded(.down)),
            Int32((Double(voxel.y) / 8).rounded(.down)),
            Int32((Double(voxel.z) / 8).rounded(.down))
        )
        let k = Self.key(block)
        let entry: Block
        if let existing = blocks[k] {
            entry = existing
        } else {
            entry = Block(origin: block)
            blocks[k] = entry
        }

        let local = voxel &- block &* 8
        let index = (Int(local.z) * Self.blockSize + Int(local.y)) * Self.blockSize + Int(local.x)

        let w0 = entry.weight[index]
        let w1 = w0 + weight
        // Curless & Levoy's incremental weighted average.
        entry.sdf[index] = (entry.sdf[index] * w0 + sdf * weight) / w1
        entry.weight[index] = w1
    }

    // MARK: - Sampling

    /// Returns nil where the voxel was never observed — which is different from
    /// "far from the surface", and the mesher relies on the distinction.
    private func sample(_ x: Int32, _ y: Int32, _ z: Int32) -> Float? {
        let block = SIMD3<Int32>(
            Int32((Double(x) / 8).rounded(.down)),
            Int32((Double(y) / 8).rounded(.down)),
            Int32((Double(z) / 8).rounded(.down))
        )
        guard let entry = blocks[Self.key(block)] else { return nil }
        let local = SIMD3<Int32>(x, y, z) &- block &* 8
        let index = (Int(local.z) * Self.blockSize + Int(local.y)) * Self.blockSize + Int(local.x)
        guard entry.weight[index] > 0 else { return nil }
        return entry.sdf[index]
    }

    private func voxelBounds() -> (min: SIMD3<Int32>, max: SIMD3<Int32>)? {
        guard !blocks.isEmpty else { return nil }
        var lo = SIMD3<Int32>(repeating: .max)
        var hi = SIMD3<Int32>(repeating: .min)
        for block in blocks.values {
            lo = simd_min(lo, block.origin &* 8)
            hi = simd_max(hi, block.origin &* 8 &+ SIMD3<Int32>(repeating: 7))
        }
        return (lo, hi)
    }

    // MARK: - Point extraction

    func extractPoints() -> PointCloud {
        guard let (lo, hi) = voxelBounds() else { return PointCloud(positions: [], colors: nil) }
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD3<UInt8>] = []

        for z in lo.z...hi.z {
            for y in lo.y...hi.y {
                for x in lo.x...hi.x {
                    guard let here = sample(x, y, z) else { continue }
                    for offset in [SIMD3<Int32>(1, 0, 0), SIMD3<Int32>(0, 1, 0), SIMD3<Int32>(0, 0, 1)] {
                        let n = SIMD3<Int32>(x, y, z) &+ offset
                        guard let next = sample(n.x, n.y, n.z) else { continue }
                        guard (here > 0) != (next > 0), here != next else { continue }
                        let t = here / (here - next)
                        positions.append(SIMD3<Float>(
                            (Float(x) + 0.5 + Float(offset.x) * t) * Float(voxelSize),
                            (Float(y) + 0.5 + Float(offset.y) * t) * Float(voxelSize),
                            (Float(z) + 0.5 + Float(offset.z) * t) * Float(voxelSize)
                        ))
                        colors.append(SIMD3<UInt8>(200, 200, 200))
                    }
                }
            }
        }
        return PointCloud(positions: positions, colors: colors.isEmpty ? nil : colors)
    }

    // MARK: - Surface extraction

    /// Cube corner offsets, in the order the tetrahedron table indexes.
    private static let cubeCorners: [SIMD3<Int32>] = [
        SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
        SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1),
    ]

    /// Six tetrahedra tiling the cube, every one sharing the 0-6 diagonal so
    /// neighbouring cubes agree on their shared faces and no cracks appear.
    private static let tetrahedra: [[Int]] = [
        [0, 5, 1, 6], [0, 1, 2, 6], [0, 2, 3, 6],
        [0, 3, 7, 6], [0, 7, 4, 6], [0, 4, 5, 6],
    ]

    private static let tetEdges: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 0), (0, 3), (1, 3), (2, 3),
    ]

    private static let tetTriangles: [[Int]] = [
        [], [0, 3, 2], [0, 1, 4], [1, 4, 2, 2, 4, 3],
        [1, 2, 5], [0, 3, 5, 0, 5, 1], [0, 2, 5, 0, 5, 4], [5, 4, 3],
        [3, 4, 5], [0, 4, 5, 0, 5, 2], [0, 1, 5, 0, 5, 3], [1, 5, 2],
        [2, 4, 1, 2, 3, 4], [0, 4, 1], [0, 2, 3], [],
    ]

    /// Samples this close to the isolevel are displaced, so a grid point never
    /// sits exactly on the surface. Coincident vertices there would collapse
    /// triangles to zero area and poison the area-weighted vertex normals.
    private static let isolevelEpsilon: Float = 1e-7

    func extractSurface(minComponentTriangles: Int = 24) -> Mesh {
        guard let (lo, hi) = voxelBounds() else {
            return Mesh(positions: [], normals: nil, indices: [])
        }

        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var vertexCache: [Int64: UInt32] = [:]
        let offset = Float(voxelSize) * 0.5

        func world(_ g: SIMD3<Int32>) -> SIMD3<Float> {
            SIMD3(
                Float(g.x) * Float(voxelSize) + offset,
                Float(g.y) * Float(voxelSize) + offset,
                Float(g.z) * Float(voxelSize) + offset
            )
        }

        /// Vertices are keyed by the grid edge they sit on, so the two
        /// tetrahedra sharing that edge produce one welded vertex rather than
        /// two coincident ones.
        func edgeVertex(_ a: SIMD3<Int32>, _ av: Float, _ b: SIMD3<Int32>, _ bv: Float) -> UInt32 {
            let swap = (a.x, a.y, a.z) > (b.x, b.y, b.z)
            let (p, pv, q, qv) = swap ? (b, bv, a, av) : (a, av, b, bv)

            // 20 bits per axis of the lower endpoint, plus the edge direction.
            let dx = Int64(q.x - p.x), dy = Int64(q.y - p.y), dz = Int64(q.z - p.z)
            let direction = dx * 9 + dy * 3 + dz
            let key = (((Int64(p.x) + 524288) << 21 | (Int64(p.y) + 524288)) << 21
                       | (Int64(p.z) + 524288)) << 5 | (direction + 13)

            if let cached = vertexCache[key] { return cached }

            let denominator = qv - pv
            let t = abs(denominator) < 1e-12 ? 0.5 : (0 - pv) / denominator
            let clamped = max(0, min(1, t))
            let pw = world(p), qw = world(q)
            positions.append(pw + (qw - pw) * clamped)

            let index = UInt32(positions.count - 1)
            vertexCache[key] = index
            return index
        }

        var cornerValues = [Float](repeating: 0, count: 8)
        var cornerGrid = [SIMD3<Int32>](repeating: .zero, count: 8)

        for z in lo.z..<hi.z {
            for y in lo.y..<hi.y {
                for x in lo.x..<hi.x {
                    var complete = true
                    for c in 0..<8 {
                        let g = SIMD3<Int32>(x, y, z) &+ Self.cubeCorners[c]
                        guard let sampled = sample(g.x, g.y, g.z) else {
                            complete = false
                            break
                        }
                        cornerGrid[c] = g
                        cornerValues[c] = abs(sampled) < Self.isolevelEpsilon
                            ? Self.isolevelEpsilon : sampled
                    }
                    guard complete else { continue }

                    for tet in Self.tetrahedra {
                        var mask = 0
                        for i in 0..<4 where cornerValues[tet[i]] < 0 { mask |= 1 << i }
                        let triangles = Self.tetTriangles[mask]
                        guard !triangles.isEmpty else { continue }

                        for t in stride(from: 0, to: triangles.count, by: 3) {
                            // Reverse order so the surface winds outward.
                            for k in stride(from: 2, through: 0, by: -1) {
                                let edge = Self.tetEdges[triangles[t + k]]
                                let a = tet[edge.0], b = tet[edge.1]
                                indices.append(edgeVertex(
                                    cornerGrid[a], cornerValues[a],
                                    cornerGrid[b], cornerValues[b]
                                ))
                            }
                        }
                    }
                }
            }
        }

        var mesh = Mesh(positions: positions, normals: nil, indices: indices)
        if minComponentTriangles > 0 {
            mesh = Self.removeSmallComponents(mesh, minTriangles: minComponentTriangles)
        }
        if !mesh.indices.isEmpty { mesh.normals = Self.vertexNormals(mesh) }
        return mesh
    }

    /// Area-weighted vertex normals. Not normalising the face cross product
    /// before accumulating gives area weighting for free, so a sliver triangle
    /// does not steer a vertex normal as much as a large one.
    private static func vertexNormals(_ mesh: Mesh) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: mesh.positions.count)
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = Int(mesh.indices[i]), b = Int(mesh.indices[i + 1]), c = Int(mesh.indices[i + 2])
            let n = simd_cross(mesh.positions[b] - mesh.positions[a],
                               mesh.positions[c] - mesh.positions[a])
            normals[a] += n
            normals[b] += n
            normals[c] += n
        }
        for i in normals.indices {
            let length = simd_length(normals[i])
            if length > 1e-20 { normals[i] /= length }
        }
        return normals
    }

    /// Drop connected components below a triangle count. Fusion leaves specks —
    /// a hand that passed through frame, a reflection off glazing — and they are
    /// always small and always disconnected from the real surface.
    private static func removeSmallComponents(_ mesh: Mesh, minTriangles: Int) -> Mesh {
        guard !mesh.indices.isEmpty else { return mesh }

        var parent = Array(0..<mesh.positions.count)
        func find(_ i: Int) -> Int {
            var root = i
            while parent[root] != root { root = parent[root] }
            var current = i
            while parent[current] != root {
                let next = parent[current]
                parent[current] = root
                current = next
            }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }

        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            union(Int(mesh.indices[i]), Int(mesh.indices[i + 1]))
            union(Int(mesh.indices[i + 1]), Int(mesh.indices[i + 2]))
        }

        var sizes: [Int: Int] = [:]
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            sizes[find(Int(mesh.indices[i])), default: 0] += 1
        }

        var remap: [UInt32: UInt32] = [:]
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            guard (sizes[find(Int(mesh.indices[i]))] ?? 0) >= minTriangles else { continue }
            for k in 0..<3 {
                let original = mesh.indices[i + k]
                if let mapped = remap[original] {
                    indices.append(mapped)
                } else {
                    positions.append(mesh.positions[Int(original)])
                    let mapped = UInt32(positions.count - 1)
                    remap[original] = mapped
                    indices.append(mapped)
                }
            }
        }
        return Mesh(positions: positions, normals: nil, indices: indices)
    }
}
