import Foundation
import simd

/// Edits a person makes to a scan before handing it over.
///
/// A scan of a room contains the room and also the doorway you walked in
/// through, the corridor beyond it, half a colleague, and whatever the sensor
/// caught over the parapet. None of that is a defect in the fusion — it was all
/// genuinely measured — but none of it belongs in the deliverable. Automatic
/// cleanup cannot make that call, because it is a question about intent rather
/// than about geometry.
///
/// All of this is deliberately plain arithmetic with no UI in it, so the
/// operations can be tested off an Apple device while the views cannot.
enum MeshEditing {

    /// An axis-aligned region, in the mesh's own coordinates (metres).
    struct Bounds: Equatable {
        var minimum: SIMD3<Float>
        var maximum: SIMD3<Float>

        var size: SIMD3<Float> { maximum - minimum }
        var centre: SIMD3<Float> { (minimum + maximum) / 2 }

        func contains(_ p: SIMD3<Float>) -> Bool {
            p.x >= minimum.x && p.x <= maximum.x
                && p.y >= minimum.y && p.y <= maximum.y
                && p.z >= minimum.z && p.z <= maximum.z
        }

        /// Grow by a margin on every side.
        func expanded(by margin: Float) -> Bounds {
            Bounds(
                minimum: minimum - SIMD3(repeating: margin),
                maximum: maximum + SIMD3(repeating: margin)
            )
        }
    }

    /// The mesh's extent, or nil when it has no geometry.
    static func bounds(of mesh: TsdfVolume.Mesh) -> Bounds? {
        guard !mesh.positions.isEmpty else { return nil }
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in mesh.positions {
            minimum = simd_min(minimum, p)
            maximum = simd_max(maximum, p)
        }
        return Bounds(minimum: minimum, maximum: maximum)
    }

    /// Keep only the geometry inside a box.
    ///
    /// A triangle is judged by its centroid rather than by all three vertices.
    /// Requiring every vertex inside nibbles a ragged, one-triangle-wide fringe
    /// off the crop plane — the boundary triangles each have a vertex just
    /// outside and all vanish — which reads as the crop having been placed
    /// slightly too tight. The centroid rule cuts where the user put the plane.
    ///
    /// Nothing is re-triangulated at the cut. That would give a clean planar
    /// edge, at the cost of inventing vertices that were never measured; for an
    /// as-built the honest ragged edge is the right answer.
    static func crop(_ mesh: TsdfVolume.Mesh, to bounds: Bounds) -> TsdfVolume.Mesh {
        MeshSimplify.compact(mesh) { triangle in
            let a = mesh.positions[Int(mesh.indices[triangle])]
            let b = mesh.positions[Int(mesh.indices[triangle + 1])]
            let c = mesh.positions[Int(mesh.indices[triangle + 2])]
            return bounds.contains((a + b + c) / 3)
        }
    }

    /// Drop everything *inside* a box, keeping the rest.
    ///
    /// The inverse of `crop`, and the one that removes a parked car or a person
    /// standing in shot without touching the walls behind them.
    static func erase(_ mesh: TsdfVolume.Mesh, within bounds: Bounds) -> TsdfVolume.Mesh {
        MeshSimplify.compact(mesh) { triangle in
            let a = mesh.positions[Int(mesh.indices[triangle])]
            let b = mesh.positions[Int(mesh.indices[triangle + 1])]
            let c = mesh.positions[Int(mesh.indices[triangle + 2])]
            return !bounds.contains((a + b + c) / 3)
        }
    }

    /// The vertex nearest a point, for turning a tap into a selection.
    ///
    /// Linear. At the triangle counts that reach the editor — post-decimation,
    /// tens of thousands — that is well under a frame, and a spatial index
    /// would be a structure to build, invalidate and get wrong.
    /// ponytail: linear scan, add a grid if the editor ever sees raw fusion output.
    static func nearestVertex(in mesh: TsdfVolume.Mesh, to point: SIMD3<Float>) -> Int? {
        guard !mesh.positions.isEmpty else { return nil }
        var best = Int.max
        var bestDistance = Float.greatestFiniteMagnitude
        for (index, p) in mesh.positions.enumerated() {
            let d = simd_distance(p, point)
            if d < bestDistance {
                bestDistance = d
                best = index
            }
        }
        return best == Int.max ? nil : best
    }

    /// Remove the connected piece containing a vertex.
    ///
    /// This is what "tap the floating blob and delete it" does. Connectivity is
    /// the same notion cleanup uses, so a piece the editor treats as one thing
    /// is a piece automatic cleanup would have treated as one thing.
    static func removeComponent(
        of mesh: TsdfVolume.Mesh,
        containing vertex: Int
    ) -> TsdfVolume.Mesh {
        guard mesh.positions.indices.contains(vertex) else { return mesh }
        let labels = MeshSimplify.connectedComponents(mesh)
        let doomed = labels[vertex]
        return MeshSimplify.compact(mesh) { triangle in
            labels[Int(mesh.indices[triangle])] != doomed
        }
    }

    /// Keep only the single largest connected piece, by triangle count.
    ///
    /// The blunt instrument for a scan that came out as one good room plus a
    /// scattering of junk. Distinct from extent-based noise removal: this keeps
    /// exactly one piece, so it will also throw away a genuinely separate object
    /// that was deliberately scanned. Offered as an explicit action rather than
    /// applied automatically for that reason.
    static func keepLargestComponent(_ mesh: TsdfVolume.Mesh) -> TsdfVolume.Mesh {
        guard !mesh.indices.isEmpty else { return mesh }
        let labels = MeshSimplify.connectedComponents(mesh)

        var counts: [Int: Int] = [:]
        for triangle in stride(from: 0, to: mesh.indices.count, by: 3) {
            counts[labels[Int(mesh.indices[triangle])], default: 0] += 1
        }
        guard let survivor = counts.max(by: { $0.value < $1.value })?.key else { return mesh }

        return MeshSimplify.compact(mesh) { triangle in
            labels[Int(mesh.indices[triangle])] == survivor
        }
    }

    /// How many separate pieces the mesh is in. Shown in the editor so the
    /// number of things to potentially delete is visible before hunting for
    /// them.
    static func componentCount(_ mesh: TsdfVolume.Mesh) -> Int {
        guard !mesh.indices.isEmpty else { return 0 }
        let labels = MeshSimplify.connectedComponents(mesh)
        var roots = Set<Int>()
        for triangle in stride(from: 0, to: mesh.indices.count, by: 3) {
            roots.insert(labels[Int(mesh.indices[triangle])])
        }
        return roots.count
    }
}
