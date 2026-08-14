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

    private struct Candidate: Comparable {
        var cost: Double
        var v0: Int
        var v1: Int
        var target: SIMD3<Double>
        /// Collapse count when this was queued, used to spot stale entries.
        var version: Int

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

            var parent = 0
            while true {
                let left = parent * 2 + 1, right = left + 1
                var smallest = parent
                if left < items.count, items[left].cost < items[smallest].cost { smallest = left }
                if right < items.count, items[right].cost < items[smallest].cost { smallest = right }
                if smallest == parent { break }
                items.swapAt(parent, smallest)
                parent = smallest
            }
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
    /// - Parameter maximumError: Squared-distance budget, in metres squared, a
    ///   single collapse may cost before decimation stops. Leave it open to
    ///   decimate purely to a triangle target.
    static func simplify(
        _ mesh: TsdfVolume.Mesh,
        targetTriangles: Int,
        maximumError: Double = .greatestFiniteMagnitude
    ) -> TsdfVolume.Mesh {
        var remaining = mesh.indices.count / 3
        guard remaining > targetTriangles, targetTriangles > 0 else { return mesh }

        var positions = mesh.positions.map { SIMD3<Double>($0) }
        var colors = mesh.colors

        // Triangles as a flat array with a liveness flag, so a collapse never
        // has to compact the index buffer.
        var corners = [Int](repeating: 0, count: mesh.indices.count)
        for i in mesh.indices.indices { corners[i] = Int(mesh.indices[i]) }
        var triangleAlive = [Bool](repeating: true, count: remaining)

        var incident: [Set<Int>] = Array(repeating: [], count: positions.count)
        var neighbours: [Set<Int>] = Array(repeating: [], count: positions.count)
        var quadrics = [Quadric](repeating: Quadric(), count: positions.count)

        for t in 0..<remaining {
            let v = (corners[t * 3], corners[t * 3 + 1], corners[t * 3 + 2])
            let p0 = positions[v.0], p1 = positions[v.1], p2 = positions[v.2]
            let cross = simd_cross(p1 - p0, p2 - p0)
            let area = simd_length(cross) / 2

            for vertex in [v.0, v.1, v.2] { incident[vertex].insert(t) }
            neighbours[v.0].formUnion([v.1, v.2])
            neighbours[v.1].formUnion([v.0, v.2])
            neighbours[v.2].formUnion([v.0, v.1])

            guard area > 0 else { continue }
            let n = cross / (area * 2)
            let q = Quadric(normal: n, offset: -simd_dot(n, p0), weight: area)
            quadrics[v.0] = quadrics[v.0] + q
            quadrics[v.1] = quadrics[v.1] + q
            quadrics[v.2] = quadrics[v.2] + q
        }

        var alive = [Bool](repeating: true, count: positions.count)
        var version = [Int](repeating: 0, count: positions.count)

        func evaluate(_ v0: Int, _ v1: Int) -> Candidate {
            let q = quadrics[v0] + quadrics[v1]
            let midpoint = (positions[v0] + positions[v1]) / 2
            // The optimal point can land far off the edge when the solve is
            // ill-conditioned. That reports a low error and produces a visible
            // spike, so it is rejected on distance rather than trusted.
            var target = q.optimalPosition() ?? midpoint
            let edgeLength = simd_length(positions[v1] - positions[v0])
            if simd_length(target - midpoint) > edgeLength * 2 { target = midpoint }
            return Candidate(
                cost: max(0, q.error(at: target)),
                v0: v0, v1: v1,
                target: target,
                version: version[v0] + version[v1]
            )
        }

        var heap = Heap()
        for v0 in 0..<positions.count {
            for v1 in neighbours[v0] where v1 > v0 { heap.push(evaluate(v0, v1)) }
        }

        while remaining > targetTriangles, let candidate = heap.pop() {
            let (v0, v1) = (candidate.v0, candidate.v1)
            guard alive[v0], alive[v1], neighbours[v0].contains(v1) else { continue }

            // Lazy deletion: an endpoint moved since this was queued, so the
            // cost is stale. Re-cost it and put it back rather than removing
            // entries from the middle of the heap.
            guard candidate.version == version[v0] + version[v1] else {
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
            guard neighbours[v0].intersection(neighbours[v1]).count <= 2 else { continue }

            // Flip check over the triangles touching v1 only. Scanning the
            // whole mesh here is what made the first version quadratic.
            var flips = false
            for t in incident[v1] where triangleAlive[t] {
                let ia = corners[t * 3], ib = corners[t * 3 + 1], ic = corners[t * 3 + 2]
                if ia == v0 || ib == v0 || ic == v0 { continue }
                let before = simd_cross(positions[ib] - positions[ia], positions[ic] - positions[ia])
                let a = ia == v1 ? candidate.target : positions[ia]
                let b = ib == v1 ? candidate.target : positions[ib]
                let c = ic == v1 ? candidate.target : positions[ic]
                if simd_dot(before, simd_cross(b - a, c - a)) <= 0 { flips = true; break }
            }
            if flips { continue }

            // --- Collapse v1 into v0 ---
            positions[v0] = candidate.target
            if colors != nil {
                let c0 = colors![v0], c1 = colors![v1]
                // Widen before adding: two channel values over 127 overflow a
                // UInt8 and wrap dark, which shows as black speckle on creases.
                colors![v0] = SIMD3<UInt8>(
                    UInt8((Int(c0.x) + Int(c1.x)) / 2),
                    UInt8((Int(c0.y) + Int(c1.y)) / 2),
                    UInt8((Int(c0.z) + Int(c1.z)) / 2)
                )
            }
            quadrics[v0] = quadrics[v0] + quadrics[v1]
            alive[v1] = false
            version[v0] += 1

            for t in incident[v1] where triangleAlive[t] {
                let base = t * 3
                let ia = corners[base], ib = corners[base + 1], ic = corners[base + 2]
                if ia == v0 || ib == v0 || ic == v0 {
                    // Shared the collapsed edge, so it is now a sliver of zero
                    // area. These are exactly the two triangles the collapse is
                    // supposed to remove.
                    triangleAlive[t] = false
                    remaining -= 1
                    for vertex in [ia, ib, ic] where vertex != v1 { incident[vertex].remove(t) }
                    continue
                }
                if ia == v1 { corners[base] = v0 }
                if ib == v1 { corners[base + 1] = v0 }
                if ic == v1 { corners[base + 2] = v0 }
                incident[v0].insert(t)
            }
            incident[v1].removeAll()

            for neighbour in neighbours[v1] where neighbour != v0 {
                neighbours[neighbour].remove(v1)
                neighbours[neighbour].insert(v0)
                neighbours[v0].insert(neighbour)
                version[neighbour] += 1
            }
            neighbours[v0].remove(v1)
            neighbours[v1].removeAll()

            for neighbour in neighbours[v0] where alive[neighbour] {
                heap.push(evaluate(min(v0, neighbour), max(v0, neighbour)))
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(remaining * 3)
        for t in 0..<triangleAlive.count where triangleAlive[t] {
            indices += [
                UInt32(corners[t * 3]), UInt32(corners[t * 3 + 1]), UInt32(corners[t * 3 + 2]),
            ]
        }

        // Renumber, dropping vertices that were collapsed away.
        return compact(
            TsdfVolume.Mesh(
                positions: positions.map { SIMD3<Float>($0) },
                normals: nil,
                indices: indices,
                colors: colors
            )
        ) { _ in true }
    }
}
