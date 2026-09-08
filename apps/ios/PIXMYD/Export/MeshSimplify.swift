import Foundation
import simd

/// Mesh cleanup: dropping noise, and cutting triangle count.
///
/// Marching tetrahedra emits a triangle per grid edge crossing, which means the
/// output is dense in proportion to *surface area*, not to detail. A flat
/// warehouse wall costs exactly as many triangles as an equal area of pipework.
/// At 25 mm voxels a single room comes out in the millions of triangles, and
/// almost all of them describe planes that three vertices would describe
/// exactly. That is the whole reason exports are enormous.
///
/// Two passes, in this order:
///
///  1. `removeNoiseComponents` drops disconnected specks.
///  2. `simplify` collapses edges under a quadric error metric.
///
/// Noise first, deliberately: decimation spends its triangle budget on whatever
/// is in the mesh, so simplifying before removing junk means the budget is
/// partly spent representing junk faithfully.
enum MeshSimplify {

    // MARK: - Connected components

    /// Label every vertex with the representative of the connected piece it
    /// belongs to. Two vertices share a label exactly when a path of triangle
    /// edges joins them.
    ///
    /// Shared by noise removal and by the editor's "delete this piece", so that
    /// what the editor deletes and what cleanup considers a fragment are the
    /// same notion of "piece" rather than two implementations that drift.
    static func connectedComponents(_ mesh: TsdfVolume.Mesh) -> [Int] {
        var parent = Array(0..<mesh.positions.count)

        func find(_ i: Int) -> Int {
            var root = i
            while parent[root] != root { root = parent[root] }
            // Path compression. Without it this is O(n) per lookup on a long
            // chain, and a wall is a very long chain.
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

        // Resolve every vertex once so callers get O(1) lookups afterwards.
        return (0..<mesh.positions.count).map { find($0) }
    }

    // MARK: - Noise removal

    /// A connected component and the space it occupies.
    private struct Component {
        var triangles = 0
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        var diagonal: Float {
            let span = maximum - minimum
            return (span.x * span.x + span.y * span.y + span.z * span.z).squareRoot()
        }
    }

    /// Drop components too small to be anything real.
    ///
    /// Triangle count alone — which is what this used to filter on — is the
    /// wrong measure, and wrong in both directions. A specular glint off glazing
    /// arrives as a broad, thin sheet with plenty of triangles and survives. A
    /// door handle genuinely captured at 25 mm is a couple of dozen fat
    /// triangles and gets deleted. Physical extent is the thing that actually
    /// separates noise from geometry: real building features are not 4 cm
    /// across, and sensor artefacts nearly always are.
    ///
    /// - Parameter minimumExtent: Bounding-box diagonal below which a component
    ///   is noise. Defaults to three voxels, floored at 100 mm — below three
    ///   voxels a component cannot be resolved as a shape anyway, and the floor
    ///   stops a fine-detail scan from keeping every speck.
    static func removeNoiseComponents(
        _ mesh: TsdfVolume.Mesh,
        minimumExtent: Float,
        minimumTriangles: Int = 8
    ) -> TsdfVolume.Mesh {
        guard !mesh.indices.isEmpty else { return mesh }

        let labels = connectedComponents(mesh)
        func find(_ i: Int) -> Int { labels[i] }

        // One pass to measure every component: triangle count and bounds
        // together, so this costs no more than counting did.
        var components: [Int: Component] = [:]
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let root = find(Int(mesh.indices[i]))
            var component = components[root] ?? Component()
            component.triangles += 1
            for k in 0..<3 {
                let p = mesh.positions[Int(mesh.indices[i + k])]
                component.minimum = simd_min(component.minimum, p)
                component.maximum = simd_max(component.maximum, p)
            }
            components[root] = component
        }

        // Never delete everything. A scan of one small object is entirely
        // legitimate and would otherwise vanish under a threshold meant for
        // rooms — returning an empty mesh because the subject was 8 cm across
        // is worse than returning a noisy one.
        let largest = components.values.max { $0.diagonal < $1.diagonal }
        let keepEverything = (largest?.diagonal ?? 0) < minimumExtent

        var keep = Set<Int>()
        for (root, component) in components {
            if keepEverything
                || (component.diagonal >= minimumExtent && component.triangles >= minimumTriangles) {
                keep.insert(root)
            }
        }

        return compact(mesh) { triangle in
            keep.contains(find(Int(mesh.indices[triangle])))
        }
    }

    /// Rebuild a mesh from the triangles a predicate keeps, dropping orphaned
    /// vertices and renumbering.
    static func compact(
        _ mesh: TsdfVolume.Mesh,
        keepTriangle: (Int) -> Bool
    ) -> TsdfVolume.Mesh {
        var remap = [Int32](repeating: -1, count: mesh.positions.count)
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD3<UInt8>] = []
        var indices: [UInt32] = []

        for triangle in stride(from: 0, to: mesh.indices.count, by: 3) {
            guard keepTriangle(triangle) else { continue }
            for k in 0..<3 {
                let original = Int(mesh.indices[triangle + k])
                if remap[original] < 0 {
                    remap[original] = Int32(positions.count)
                    positions.append(mesh.positions[original])
                    if let source = mesh.colors { colors.append(source[original]) }
                }
                indices.append(UInt32(remap[original]))
            }
        }

        return TsdfVolume.Mesh(
            positions: positions,
            // Normals are area-weighted from the faces, so any that survive
            // from the old mesh are wrong for the new one. The caller
            // recomputes them.
            normals: nil,
            indices: indices,
            colors: mesh.colors == nil ? nil : colors
        )
    }

    // MARK: - Quadric error decimation

    /// Symmetric 4x4 quadric, stored as the 10 distinct entries.
    ///
    /// Garland & Heckbert's insight is that the squared distance from a point to
    /// a plane is a quadratic form, so the total squared distance to a *set* of
    /// planes is just the sum of their forms — one 10-float matrix, however many
    /// planes it came from. Collapsing an edge adds the two endpoints' matrices.
    /// That is what makes this cheap enough to run on a phone: the cost of
    /// evaluating an edge never grows with how much has already been merged
    /// into it.
    private struct Quadric {
        var a = 0.0, b = 0.0, c = 0.0, d = 0.0
        var e = 0.0, f = 0.0, g = 0.0
        var h = 0.0, i = 0.0
        var j = 0.0

        /// Build from a plane nx + ny + nz + d = 0, weighted by triangle area.
        ///
        /// Area weighting matters: without it a mesh of many tiny triangles on a
        /// curved surface outvotes the few large ones describing the flat wall
        /// next to it, and the decimator eats the wall to preserve the noise.
        init(normal n: SIMD3<Double>, offset dd: Double, weight: Double) {
            a = n.x * n.x * weight; b = n.x * n.y * weight; c = n.x * n.z * weight
            d = n.x * dd * weight
            e = n.y * n.y * weight; f = n.y * n.z * weight; g = n.y * dd * weight
            h = n.z * n.z * weight; i = n.z * dd * weight
            j = dd * dd * weight
        }

        init() {}

        static func + (lhs: Quadric, rhs: Quadric) -> Quadric {
            var q = Quadric()
            q.a = lhs.a + rhs.a; q.b = lhs.b + rhs.b; q.c = lhs.c + rhs.c; q.d = lhs.d + rhs.d
            q.e = lhs.e + rhs.e; q.f = lhs.f + rhs.f; q.g = lhs.g + rhs.g
            q.h = lhs.h + rhs.h; q.i = lhs.i + rhs.i
            q.j = lhs.j + rhs.j
            return q
        }

        /// vᵀ Q v — the summed squared distance to every plane in this quadric.
        func error(at v: SIMD3<Double>) -> Double {
            a * v.x * v.x + 2 * b * v.x * v.y + 2 * c * v.x * v.z + 2 * d * v.x
                + e * v.y * v.y + 2 * f * v.y * v.z + 2 * g * v.y
                + h * v.z * v.z + 2 * i * v.z
                + j
        }

        /// The position minimising the error, by solving the 3x3 system
        /// A v = -b. Returns nil when A is singular, which happens exactly when
        /// the incident planes are parallel or collinear — a flat sheet or a
        /// straight crease, where there is no unique best point and the
        /// midpoint is as good as anything.
        func optimalPosition() -> SIMD3<Double>? {
            let det =
                a * (e * h - f * f) - b * (b * h - f * c) + c * (b * f - e * c)
            // Scaled against the matrix magnitude: a fixed epsilon is
            // meaningless when the units are metres in one scan and millimetres
            // in another.
            let scale = abs(a) + abs(e) + abs(h) + 1e-30
            guard abs(det) > 1e-12 * scale * scale * scale else { return nil }

            let inverseDet = 1 / det
            return SIMD3<Double>(
                -inverseDet * (d * (e * h - f * f) - g * (b * h - c * f) + i * (b * f - c * e)),
                -inverseDet * (a * (g * h - i * f) - b * (d * h - i * c) + c * (d * f - g * c)),
                -inverseDet * (a * (e * i - g * f) - b * (b * i - g * c) + d * (b * f - e * c))
            )
        }
    }

    /// A queued edge collapse.
    ///
    /// Twenty-four bytes, and deliberately so. This used to carry the target
    /// position as well, which made it sixty-four — and the heap holds one of
    /// these per queued edge plus every re-costed duplicate, so it is the
    /// largest single allocation in `simplify`. The target is recomputed from
    /// the quadrics when a candidate is actually accepted, which happens far
    /// less often than a candidate is queued.
    private struct Candidate: Comparable {
        var cost: Double
        var v0: Int32
        var v1: Int32
        /// Collapse count when this was queued, used to spot stale entries.
        var version: Int32

        static func < (lhs: Candidate, rhs: Candidate) -> Bool { lhs.cost < rhs.cost }
        static func == (lhs: Candidate, rhs: Candidate) -> Bool { lhs.cost == rhs.cost }
    }

    /// A binary min-heap. Swift's standard library has no priority queue and
    /// swift-collections is not worth a dependency for forty lines.
    ///
    /// The first version of this kept a sorted array and re-sorted after every
    /// collapse. That is O(n log n) per collapse, and on a 5,000-triangle sphere
    /// it took 15 seconds — which extrapolates to hours on the million-triangle
    /// meshes this actually has to handle. Nothing about the algorithm changed;
    /// only the bookkeeping around it.
    private struct Heap {
        private var items: [Candidate] = []

        var isEmpty: Bool { items.isEmpty }
        var count: Int { items.count }

        /// Drop every entry `keep` rejects, then restore the heap property.
        ///
        /// Rebuilding bottom-up is O(n); pushing the survivors back one at a
        /// time would be O(n log n) for the same result.
        mutating func compact(_ keep: (Candidate) -> Bool) {
            items.removeAll { !keep($0) }
            var node = items.count / 2 - 1
            while node >= 0 {
                siftDown(from: node)
                node -= 1
            }
        }

        private mutating func siftDown(from start: Int) {
            var parent = start
            while true {
                let left = parent * 2 + 1, right = left + 1
                var smallest = parent
                if left < items.count, items[left].cost < items[smallest].cost { smallest = left }
                if right < items.count, items[right].cost < items[smallest].cost { smallest = right }
                if smallest == parent { return }
                items.swapAt(parent, smallest)
                parent = smallest
            }
        }

        mutating func push(_ item: Candidate) {
            items.append(item)
            var child = items.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard items[child].cost < items[parent].cost else { break }
                items.swapAt(child, parent)
                child = parent
            }
        }

        mutating func pop() -> Candidate? {
            guard let first = items.first else { return nil }
            items[0] = items[items.count - 1]
            items.removeLast()
            siftDown(from: 0)
            return first
        }
    }

    /// Reduce a mesh to roughly `targetTriangles`, preserving shape.
    ///
    /// Edges are collapsed cheapest-first: the cost of collapsing an edge is how
    /// far the merged vertex ends up from all the planes that met at either end,
    /// so collapsing across a flat wall costs nothing and collapsing across the
    /// corner where two walls meet costs a lot. Planes disappear and creases
    /// survive, which is the correct priority for a building.
    ///
    /// Every step is local — the triangles touching one vertex, not the whole
    /// mesh — so the cost is proportional to the number of collapses, not to
    /// their product with the mesh size.
    ///
    /// ## Why this is tiled
    ///
    /// Decimation needs, per vertex, a quadric and an adjacency list, and per
    /// queued edge a heap entry. All three are proportional to the mesh, and at
    /// 12 mm voxels a single room is three and a half million triangles: run in
    /// one piece it wanted 2.2 GB, which is what crashed the phone on the fine
    /// preset. Nothing about that is fixable by making the structures smaller —
    /// it is linear in a quantity that grows with the size of the scan, so a
    /// large enough capture will always exceed whatever the device has.
    ///
    /// So the mesh is cut into spatial blocks and decimated a block at a time.
    /// Peak memory is then set by the block size, which is a constant, rather
    /// than by the scan, which is not. It costs a little quality along the block
    /// boundaries — see `decimate` — and it costs nothing in detail anywhere
    /// else: the same quadric error metric makes the same decisions inside each
    /// block as it would have made on the whole.
    ///
    /// - Parameter maximumError: Squared-distance budget, in metres squared, a
    ///   single collapse may cost before decimation stops. Leave it open to
    ///   decimate purely to a triangle target.
    /// - Parameter maximumBlockTriangles: How much mesh to hold in the
    ///   decimator at once. Larger means fewer seams and more memory; the
    ///   default is about 350 MB of working set at the peak.
    static func simplify(
        _ mesh: TsdfVolume.Mesh,
        targetTriangles: Int,
        maximumError: Double = .greatestFiniteMagnitude,
        maximumBlockTriangles: Int = 600_000
    ) -> TsdfVolume.Mesh {
        let total = mesh.indices.count / 3
        guard total > targetTriangles, targetTriangles > 0 else { return mesh }

        if total <= maximumBlockTriangles {
            let result = decimate(
                mesh, targetTriangles: targetTriangles, maximumError: maximumError, locked: nil
            )
            return compact(
                TsdfVolume.Mesh(
                    positions: result.positions.map { SIMD3<Float>($0) },
                    normals: nil, indices: result.indices, colors: result.colors
                )
            ) { _ in true }
        }

        // --- Cut into blocks ---
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in mesh.positions {
            minimum = simd_min(minimum, p)
            maximum = simd_max(maximum, p)
        }
        let extent = simd_max(maximum - minimum, SIMD3<Float>(repeating: 1e-6))

        /// Which block each triangle belongs to, by centroid. A triangle is
        /// indivisible: splitting one across a boundary would need a new vertex
        /// on the cut, and that vertex would have to be locked in both blocks,
        /// which is the thing being minimised.
        func assign(divisions: Int) -> (cells: [Int32], counts: [Int]) {
            let n = Int32(divisions)
            var cells = [Int32](repeating: 0, count: total)
            var counts = [Int](repeating: 0, count: divisions * divisions * divisions)
            for t in 0..<total {
                let base = t * 3
                let a = mesh.positions[Int(mesh.indices[base])]
                let b = mesh.positions[Int(mesh.indices[base + 1])]
                let c = mesh.positions[Int(mesh.indices[base + 2])]
                let centroid = (a + b + c) / 3
                let unit = (centroid - minimum) / extent
                var ix = Int32(unit.x * Float(divisions)), iy = Int32(unit.y * Float(divisions))
                var iz = Int32(unit.z * Float(divisions))
                ix = min(max(ix, 0), n - 1)
                iy = min(max(iy, 0), n - 1)
                iz = min(max(iz, 0), n - 1)
                let cell = (ix * n + iy) * n + iz
                cells[t] = cell
                counts[Int(cell)] += 1
            }
            return (cells, counts)
        }

        // Grow the grid until no block is over the limit. Surfaces are not
        // spread evenly through their bounding box — a room is a shell around
        // an empty middle — so the count that matters is the largest block, not
        // the average. Capped so a pathological mesh cannot subdivide forever.
        //
        // The first guess is sqrt rather than cbrt of the ratio because the
        // thing being divided is a surface, not a solid: a scan fills the shell
        // of its bounding box and leaves the middle empty, so the number of
        // occupied cells grows with the square of the divisions and not the
        // cube. Starting from 2 and counting up would mean several full passes
        // over eleven million triangles to arrive at the same answer.
        var divisions = max(2, Int((Double(total) / Double(maximumBlockTriangles)).squareRoot().rounded(.up)))
        var assignment = assign(divisions: divisions)
        while assignment.counts.max() ?? 0 > maximumBlockTriangles, divisions < 24 {
            divisions += 1
            assignment = assign(divisions: divisions)
        }
        let cells = assignment.cells

        // A vertex used by triangles in more than one block is on a seam.
        var firstCell = [Int32](repeating: -1, count: mesh.positions.count)
        var locked = [Bool](repeating: false, count: mesh.positions.count)
        for t in 0..<total {
            let cell = cells[t]
            for k in 0..<3 {
                let v = Int(mesh.indices[t * 3 + k])
                if firstCell[v] < 0 { firstCell[v] = cell }
                else if firstCell[v] != cell { locked[v] = true }
            }
        }
        firstCell = []

        // Triangles grouped by block, by counting sort — one pass, and no
        // per-block arrays to grow.
        let cellCount = assignment.counts.count
        var start = [Int](repeating: 0, count: cellCount + 1)
        for cell in 0..<cellCount { start[cell + 1] = start[cell] + assignment.counts[cell] }
        var cursor = start
        var order = [Int32](repeating: 0, count: total)
        for t in 0..<total {
            order[cursor[Int(cells[t])]] = Int32(t)
            cursor[Int(cells[t])] += 1
        }

        let keepRatio = Double(targetTriangles) / Double(total)

        var outPositions: [SIMD3<Float>] = []
        var outColors: [SIMD3<UInt8>] = []
        var outIndices: [UInt32] = []
        outIndices.reserveCapacity(targetTriangles * 3)
        /// Original vertex to output vertex. Shared across blocks, which is
        /// what welds a seam: both blocks reach the same locked vertex through
        /// the same entry, so they emit the same index for it.
        var outputIndex = [Int32](repeating: -1, count: mesh.positions.count)

        var localOf = [Int32](repeating: -1, count: mesh.positions.count)
        var localStamp = [Int32](repeating: -1, count: mesh.positions.count)

        for cell in 0..<cellCount where assignment.counts[cell] > 0 {
            let range = start[cell]..<start[cell + 1]

            // --- gather the block ---
            var blockPositions: [SIMD3<Float>] = []
            var blockColors: [SIMD3<UInt8>] = []
            var blockIndices: [UInt32] = []
            var blockLocked: [Bool] = []
            var originalOf: [Int32] = []
            blockIndices.reserveCapacity(range.count * 3)
            let stamp = Int32(cell)

            for slot in range {
                let t = Int(order[slot])
                for k in 0..<3 {
                    let v = Int(mesh.indices[t * 3 + k])
                    if localStamp[v] != stamp {
                        localStamp[v] = stamp
                        localOf[v] = Int32(blockPositions.count)
                        blockPositions.append(mesh.positions[v])
                        if let source = mesh.colors { blockColors.append(source[v]) }
                        blockLocked.append(locked[v])
                        originalOf.append(Int32(v))
                    }
                    blockIndices.append(UInt32(localOf[v]))
                }
            }

            let blockTriangles = range.count
            let blockTarget = max(1, Int((Double(blockTriangles) * keepRatio).rounded()))
            let block = TsdfVolume.Mesh(
                positions: blockPositions, normals: nil, indices: blockIndices,
                colors: mesh.colors == nil ? nil : blockColors
            )
            blockPositions = []
            blockColors = []
            blockIndices = []

            let reduced = decimate(
                block, targetTriangles: blockTarget, maximumError: maximumError,
                locked: blockLocked
            )

            // --- weld it back ---
            for i in stride(from: 0, to: reduced.indices.count, by: 3) {
                for k in 0..<3 {
                    let local = Int(reduced.indices[i + k])
                    let original = Int(originalOf[local])
                    if outputIndex[original] < 0 {
                        outputIndex[original] = Int32(outPositions.count)
                        outPositions.append(SIMD3<Float>(reduced.positions[local]))
                        if let source = reduced.colors { outColors.append(source[local]) }
                    }
                    outIndices.append(UInt32(outputIndex[original]))
                }
            }
        }

        return TsdfVolume.Mesh(
            positions: outPositions,
            // Area-weighted from the faces, so the caller recomputes them.
            normals: nil,
            indices: outIndices,
            colors: mesh.colors == nil ? nil : outColors
        )
    }

    /// Decimate one block of mesh, leaving `locked` vertices exactly where they
    /// are.
    ///
    /// Returns the vertex arrays unrenumbered — dead vertices are still in
    /// them, and `indices` still refers to the input numbering. The tiled
    /// driver needs that numbering to weld blocks back together, and
    /// renumbering here would throw away the only thing that identifies a
    /// vertex across two blocks.
    private static func decimate(
        _ mesh: TsdfVolume.Mesh,
        targetTriangles: Int,
        maximumError: Double,
        locked: [Bool]?
    ) -> (positions: [SIMD3<Double>], colors: [SIMD3<UInt8>]?, indices: [UInt32]) {
        var remaining = mesh.indices.count / 3

        let vertexCount = mesh.positions.count
        var positions = mesh.positions.map { SIMD3<Double>($0) }
        var colors = mesh.colors

        // Triangles as a flat array with a liveness flag, so a collapse never
        // has to compact the index buffer. Int32 rather than Int: at fine
        // detail this array has ten million entries, and the top half of every
        // one of them is zero.
        var corners = [Int32](repeating: 0, count: mesh.indices.count)
        for i in mesh.indices.indices { corners[i] = Int32(mesh.indices[i]) }
        var triangleAlive = [Bool](repeating: true, count: remaining)

        // --- Adjacency ---
        //
        // Corner slot `s` belongs to triangle `s / 3` and names vertex
        // `corners[s]`. The triangles touching a vertex are a singly-linked
        // list through those slots: `incidentHead[v]` is the first, and
        // `incidentNext[s]` the next slot naming the same vertex.
        //
        // This used to be `[Set<Int>]`, one Set per vertex, plus a second
        // `[Set<Int>]` of vertex neighbours. That is two heap allocations per
        // vertex — 3.6 million of them on a fine-detail room — and measured at
        // 12 mm voxels it was most of the 1.95 GB this function added to the
        // process, which is what ran the phone out of memory. Two flat arrays
        // hold the same information in 50 MB and allocate nothing per vertex.
        //
        // Neighbours are not stored at all. They are the other two corners of
        // the incident triangles, so keeping a second structure in step with
        // the first was bookkeeping for a fact already on hand.
        var incidentHead = [Int32](repeating: -1, count: vertexCount)
        var incidentNext = [Int32](repeating: -1, count: mesh.indices.count)
        var quadrics = [Quadric](repeating: Quadric(), count: vertexCount)

        for t in 0..<remaining {
            let base = t * 3
            let v0 = corners[base], v1 = corners[base + 1], v2 = corners[base + 2]
            for k in 0..<3 {
                let slot = Int32(base + k)
                let v = Int(corners[base + k])
                incidentNext[Int(slot)] = incidentHead[v]
                incidentHead[v] = slot
            }

            let p0 = positions[Int(v0)], p1 = positions[Int(v1)], p2 = positions[Int(v2)]
            let cross = simd_cross(p1 - p0, p2 - p0)
            let area = simd_length(cross) / 2
            guard area > 0 else { continue }
            let n = cross / (area * 2)
            let q = Quadric(normal: n, offset: -simd_dot(n, p0), weight: area)
            quadrics[Int(v0)] = quadrics[Int(v0)] + q
            quadrics[Int(v1)] = quadrics[Int(v1)] + q
            quadrics[Int(v2)] = quadrics[Int(v2)] + q
        }

        var alive = [Bool](repeating: true, count: vertexCount)
        var version = [Int32](repeating: 0, count: vertexCount)

        // Scratch for collecting a vertex's distinct neighbours without
        // allocating. `stamp` marks membership by epoch, so clearing it between
        // uses costs one increment rather than a pass over a million entries.
        var stamp = [Int32](repeating: -1, count: vertexCount)
        var epoch: Int32 = 0
        var gathered: [Int32] = []
        gathered.reserveCapacity(64)

        /// The distinct live neighbours of `v`, into `gathered`.
        func gatherNeighbours(of v: Int32) {
            epoch += 1
            gathered.removeAll(keepingCapacity: true)
            var previous: Int32 = -1
            var slot = incidentHead[Int(v)]
            while slot >= 0 {
                let next = incidentNext[Int(slot)]
                let t = Int(slot) / 3
                if triangleAlive[t] {
                    let base = t * 3
                    for k in 0..<3 {
                        let u = corners[base + k]
                        if u != v, stamp[Int(u)] != epoch {
                            stamp[Int(u)] = epoch
                            gathered.append(u)
                        }
                    }
                    previous = slot
                } else {
                    // A dead triangle never comes back, so its slot is unlinked
                    // the first time it is walked past. Without this the lists
                    // keep every slot they ever held and the walks get slower
                    // as decimation proceeds.
                    if previous < 0 { incidentHead[Int(v)] = next }
                    else { incidentNext[Int(previous)] = next }
                }
                slot = next
            }
        }

        /// Whether `v` and `u` share a triangle.
        func areNeighbours(_ v: Int32, _ u: Int32) -> Bool {
            var slot = incidentHead[Int(v)]
            while slot >= 0 {
                let t = Int(slot) / 3
                if triangleAlive[t] {
                    let base = t * 3
                    if corners[base] == u || corners[base + 1] == u || corners[base + 2] == u {
                        return true
                    }
                }
                slot = incidentNext[Int(slot)]
            }
            return false
        }

        /// The position a collapse of this edge would put the merged vertex at.
        func targetFor(_ v0: Int32, _ v1: Int32) -> SIMD3<Double> {
            let q = quadrics[Int(v0)] + quadrics[Int(v1)]
            let midpoint = (positions[Int(v0)] + positions[Int(v1)]) / 2
            // The optimal point can land far off the edge when the solve is
            // ill-conditioned. That reports a low error and produces a visible
            // spike, so it is rejected on distance rather than trusted.
            var target = q.optimalPosition() ?? midpoint
            let edgeLength = simd_length(positions[Int(v1)] - positions[Int(v0)])
            if simd_length(target - midpoint) > edgeLength * 2 { target = midpoint }
            return target
        }

        func evaluate(_ v0: Int32, _ v1: Int32) -> Candidate {
            let q = quadrics[Int(v0)] + quadrics[Int(v1)]
            return Candidate(
                cost: max(0, q.error(at: targetFor(v0, v1))),
                v0: v0, v1: v1,
                version: version[Int(v0)] + version[Int(v1)]
            )
        }

        var heap = Heap()
        for v0 in 0..<vertexCount {
            gatherNeighbours(of: Int32(v0))
            for v1 in gathered where v1 > Int32(v0) { heap.push(evaluate(Int32(v0), v1)) }
        }

        // The heap only ever grows: a stale entry is skipped on pop, and every
        // collapse pushes a fresh candidate per neighbour. Left alone it ends up
        // holding several times more dead entries than live ones. Compaction
        // drops them in one pass whenever it has doubled, which is amortised
        // linear and keeps the largest single allocation in this function
        // proportional to the mesh rather than to the number of collapses.
        var compactionWatermark = max(1 << 16, heap.count * 2)

        var neighboursOfV1: [Int32] = []
        neighboursOfV1.reserveCapacity(64)

        while remaining > targetTriangles, let candidate = heap.pop() {
            let (v0, v1) = (candidate.v0, candidate.v1)
            guard alive[Int(v0)], alive[Int(v1)], areNeighbours(v0, v1) else { continue }

            // A locked vertex sits on a tile boundary and is shared with the
            // block next door, which is decimated separately and cannot know
            // this one moved. Refusing the collapse outright — rather than
            // collapsing into it and pinning the target — keeps the two blocks
            // agreeing vertex for vertex, so the seam is watertight by
            // construction instead of by a tolerance. The cost is that a thin
            // band of full-resolution triangles survives along each boundary,
            // which is why the blocks are made as large as memory allows.
            if let locked, locked[Int(v0)] || locked[Int(v1)] { continue }

            // Lazy deletion: an endpoint moved since this was queued, so the
            // cost is stale. Re-cost it and put it back rather than removing
            // entries from the middle of the heap.
            guard candidate.version == version[Int(v0)] + version[Int(v1)] else {
                heap.push(evaluate(v0, v1))
                continue
            }
            // The cheapest remaining collapse costs more than the budget, so
            // every other one does too.
            if candidate.cost > maximumError { break }

            // Link condition: endpoints sharing more than the two vertices
            // opposite this edge would fold the surface into something
            // non-manifold — fine on screen, and a failure in anything
            // downstream that assumes a surface.
            gatherNeighbours(of: v1)
            neighboursOfV1.removeAll(keepingCapacity: true)
            neighboursOfV1.append(contentsOf: gathered)
            let v1Epoch = epoch
            var shared = 0
            gatherNeighbours(of: v0)
            for u in gathered where stampWas(u, v1Epoch, stamp) { shared += 1 }
            guard shared <= 2 else { continue }

            // The target is recomputed rather than carried in the heap. Storing
            // a position in every queued candidate made the struct 64 bytes
            // where 24 will do, and the heap is the largest allocation here.
            // Nothing it depends on has changed since the version check above,
            // so this is the same point that check was made against.
            let target = targetFor(v0, v1)

            // Flip check over the triangles touching v1 only. Scanning the
            // whole mesh here is what made the first version quadratic.
            var flips = false
            var slot = incidentHead[Int(v1)]
            while slot >= 0 {
                let t = Int(slot) / 3
                if triangleAlive[t] {
                    let base = t * 3
                    let ia = corners[base], ib = corners[base + 1], ic = corners[base + 2]
                    if ia != v0, ib != v0, ic != v0 {
                        let pa = positions[Int(ia)], pb = positions[Int(ib)], pc = positions[Int(ic)]
                        let before = simd_cross(pb - pa, pc - pa)
                        let a = ia == v1 ? target : pa
                        let b = ib == v1 ? target : pb
                        let c = ic == v1 ? target : pc
                        if simd_dot(before, simd_cross(b - a, c - a)) <= 0 { flips = true; break }
                    }
                }
                slot = incidentNext[Int(slot)]
            }
            if flips { continue }

            // --- Collapse v1 into v0 ---
            positions[Int(v0)] = target
            if colors != nil {
                let c0 = colors![Int(v0)], c1 = colors![Int(v1)]
                // Widen before adding: two channel values over 127 overflow a
                // UInt8 and wrap dark, which shows as black speckle on creases.
                colors![Int(v0)] = SIMD3<UInt8>(
                    UInt8((Int(c0.x) + Int(c1.x)) / 2),
                    UInt8((Int(c0.y) + Int(c1.y)) / 2),
                    UInt8((Int(c0.z) + Int(c1.z)) / 2)
                )
            }
            quadrics[Int(v0)] = quadrics[Int(v0)] + quadrics[Int(v1)]
            alive[Int(v1)] = false
            version[Int(v0)] += 1
            for u in neighboursOfV1 where u != v0 { version[Int(u)] += 1 }

            // Retarget v1's triangles onto v0, killing the two that shared the
            // collapsed edge, then splice v1's slot list onto v0's. The splice
            // is why the slots are a list rather than a set: merging two
            // vertices' triangles is a pointer change, not a rehash.
            var tail: Int32 = -1
            slot = incidentHead[Int(v1)]
            while slot >= 0 {
                let t = Int(slot) / 3
                if triangleAlive[t] {
                    let base = t * 3
                    let ia = corners[base], ib = corners[base + 1], ic = corners[base + 2]
                    if ia == v0 || ib == v0 || ic == v0 {
                        // Shared the collapsed edge, so it is now a sliver of
                        // zero area. These are exactly the two triangles the
                        // collapse is supposed to remove.
                        triangleAlive[t] = false
                        remaining -= 1
                    } else {
                        if ia == v1 { corners[base] = v0 }
                        if ib == v1 { corners[base + 1] = v0 }
                        if ic == v1 { corners[base + 2] = v0 }
                    }
                }
                tail = slot
                slot = incidentNext[Int(slot)]
            }
            if tail >= 0 {
                incidentNext[Int(tail)] = incidentHead[Int(v0)]
                incidentHead[Int(v0)] = incidentHead[Int(v1)]
            }
            incidentHead[Int(v1)] = -1

            gatherNeighbours(of: v0)
            for u in gathered where alive[Int(u)] {
                heap.push(evaluate(min(v0, u), max(v0, u)))
            }

            if heap.count > compactionWatermark {
                heap.compact { alive[Int($0.v0)] && alive[Int($0.v1)]
                    && $0.version == version[Int($0.v0)] + version[Int($0.v1)] }
                compactionWatermark = max(1 << 16, heap.count * 2)
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(remaining * 3)
        for t in 0..<triangleAlive.count where triangleAlive[t] {
            indices += [
                UInt32(corners[t * 3]), UInt32(corners[t * 3 + 1]), UInt32(corners[t * 3 + 2]),
            ]
        }
        return (positions, colors, indices)
    }

    /// Whether `gatherNeighbours` marked `v` during the epoch `mark`.
    ///
    /// Free function rather than a closure so the caller's `stamp` array is
    /// passed rather than captured — a nested function capturing it while the
    /// caller also mutates it is an exclusivity violation, and one the compiler
    /// only catches at runtime.
    private static func stampWas(_ v: Int32, _ mark: Int32, _ stamp: [Int32]) -> Bool {
        stamp[Int(v)] == mark
    }
}
