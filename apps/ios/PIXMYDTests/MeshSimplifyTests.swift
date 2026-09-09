import Foundation
import XCTest
import simd
@testable import PIXMYD

/// An icosphere, subdivided. A real test subject rather than a synthetic grid:
/// it is closed, manifold, has uniform triangle density, and — crucially — its
/// exact shape is known, so decimation error can be measured rather than
/// eyeballed.
private func icosphere(subdivisions: Int, radius: Float = 1) -> TsdfVolume.Mesh {
    let t = (1 + Float(5).squareRoot()) / 2
    var positions: [SIMD3<Float>] = [
        SIMD3(-1, t, 0), SIMD3(1, t, 0), SIMD3(-1, -t, 0), SIMD3(1, -t, 0),
        SIMD3(0, -1, t), SIMD3(0, 1, t), SIMD3(0, -1, -t), SIMD3(0, 1, -t),
        SIMD3(t, 0, -1), SIMD3(t, 0, 1), SIMD3(-t, 0, -1), SIMD3(-t, 0, 1),
    ].map { simd_normalize($0) * radius }

    var indices: [UInt32] = [
        0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11,
        1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
        3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9,
        4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
    ]

    for _ in 0..<subdivisions {
        var midpoints: [UInt64: UInt32] = [:]
        var next: [UInt32] = []

        func midpoint(_ a: UInt32, _ b: UInt32) -> UInt32 {
            let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
            if let cached = midpoints[key] { return cached }
            let p = simd_normalize((positions[Int(a)] + positions[Int(b)]) / 2) * radius
            positions.append(p)
            let index = UInt32(positions.count - 1)
            midpoints[key] = index
            return index
        }

        for i in stride(from: 0, to: indices.count, by: 3) {
            let a = indices[i], b = indices[i + 1], c = indices[i + 2]
            let ab = midpoint(a, b), bc = midpoint(b, c), ca = midpoint(c, a)
            next += [a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca]
        }
        indices = next
    }

    return TsdfVolume.Mesh(positions: positions, normals: nil, indices: indices, colors: nil)
}

/// An axis-aligned box as 12 triangles. Six exactly flat faces, so a decimator
/// that understands planes should be able to reduce it to almost nothing
/// without moving a single corner.
private func box(size: Float, at centre: SIMD3<Float> = .zero) -> TsdfVolume.Mesh {
    let h = size / 2
    let positions: [SIMD3<Float>] = [
        SIMD3(-h, -h, -h), SIMD3(h, -h, -h), SIMD3(h, h, -h), SIMD3(-h, h, -h),
        SIMD3(-h, -h, h), SIMD3(h, -h, h), SIMD3(h, h, h), SIMD3(-h, h, h),
    ].map { $0 + centre }
    let indices: [UInt32] = [
        0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7,
        0, 1, 5, 0, 5, 4, 2, 3, 7, 2, 7, 6,
        0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5,
    ]
    return TsdfVolume.Mesh(positions: positions, normals: nil, indices: indices, colors: nil)
}

/// Merge meshes, offsetting the second's indices.
private func combine(_ meshes: [TsdfVolume.Mesh]) -> TsdfVolume.Mesh {
    var positions: [SIMD3<Float>] = []
    var indices: [UInt32] = []
    for mesh in meshes {
        let base = UInt32(positions.count)
        positions += mesh.positions
        indices += mesh.indices.map { $0 + base }
    }
    return TsdfVolume.Mesh(positions: positions, normals: nil, indices: indices, colors: nil)
}

private func openEdgeCount(_ mesh: TsdfVolume.Mesh) -> Int {
    var use: [Int64: Int] = [:]
    for i in stride(from: 0, to: mesh.indices.count, by: 3) {
        let v = [mesh.indices[i], mesh.indices[i + 1], mesh.indices[i + 2]]
        for k in 0..<3 {
            let a = min(v[k], v[(k + 1) % 3]), b = max(v[k], v[(k + 1) % 3])
            use[Int64(a) << 32 | Int64(b), default: 0] += 1
        }
    }
    return use.values.filter { $0 != 2 }.count
}

private func signedVolume(_ mesh: TsdfVolume.Mesh) -> Double {
    var total = 0.0
    for i in stride(from: 0, to: mesh.indices.count, by: 3) {
        let a = SIMD3<Double>(mesh.positions[Int(mesh.indices[i])])
        let b = SIMD3<Double>(mesh.positions[Int(mesh.indices[i + 1])])
        let c = SIMD3<Double>(mesh.positions[Int(mesh.indices[i + 2])])
        total += simd_dot(a, simd_cross(b, c)) / 6
    }
    return total
}

final class MeshSimplifyTests: XCTestCase {

    // MARK: - Noise removal

    func testTinyFragmentsAreDroppedAndRealGeometryIsKept() {
        // A 3 m wall-sized box, plus two specks of the size LiDAR noise
        // actually produces, well away from it.
        let scene = combine([
            box(size: 3.0),
            box(size: 0.02, at: SIMD3(5, 0, 0)),
            box(size: 0.03, at: SIMD3(0, 5, 0)),
        ])
        XCTAssertEqual(scene.indices.count / 3, 36)

        let cleaned = MeshSimplify.removeNoiseComponents(scene, minimumExtent: 0.10)

        // Only the big box survives, and it survives whole.
        XCTAssertEqual(cleaned.indices.count / 3, 12)
        XCTAssertEqual(cleaned.positions.count, 8)
        for p in cleaned.positions {
            XCTAssertLessThan(simd_length(p), 3.0, "a speck was kept, or the box was moved")
        }
    }

    func testAGenuineSmallObjectNextToNothingIsNotDeleted() {
        // Scanning a single 8 cm part is a legitimate use. The threshold is
        // meant for rooms, and applying it blindly would return an empty file
        // and look like a crash.
        let small = box(size: 0.08)
        let cleaned = MeshSimplify.removeNoiseComponents(small, minimumExtent: 0.10)
        XCTAssertEqual(cleaned.indices.count / 3, 12, "the entire subject was deleted as noise")
    }

    func testTriangleCountAloneWouldHaveKeptAThinSheet() {
        // The case the old triangle-count rule got wrong: a broad, flat,
        // physically tiny artefact — a glint off glazing — with plenty of
        // triangles. Extent catches it; a count of 8 would not have.
        var sheet = TsdfVolume.Mesh(positions: [], normals: nil, indices: [], colors: nil)
        for i in 0..<20 {
            let x = Float(i) * 0.002
            sheet.positions += [SIMD3(x, 0, 0), SIMD3(x + 0.002, 0, 0), SIMD3(x, 0.002, 0)]
            let base = UInt32(i * 3)
            sheet.indices += [base, base + 1, base + 2]
        }
        XCTAssertGreaterThan(sheet.indices.count / 3, 8)

        let cleaned = MeshSimplify.removeNoiseComponents(
            combine([box(size: 3.0), sheet]), minimumExtent: 0.10
        )
        XCTAssertEqual(cleaned.indices.count / 3, 12)
    }

    func testRemovalRenumbersWithoutDanglingIndices() {
        let cleaned = MeshSimplify.removeNoiseComponents(
            combine([box(size: 3.0), box(size: 0.01, at: SIMD3(9, 9, 9))]),
            minimumExtent: 0.10
        )
        for index in cleaned.indices {
            XCTAssertLessThan(Int(index), cleaned.positions.count, "index past the vertex array")
        }
    }

    // MARK: - Decimation

    func testFlatFacesCollapseAlmostCompletely() {
        // A box is six planes. Every interior edge lies in a plane, so
        // collapsing it costs zero quadric error and the decimator should be
        // able to strip it right down while leaving the corners exactly where
        // they are — that is the property that keeps a wall looking like a wall.
        let simplified = MeshSimplify.simplify(box(size: 2.0), targetTriangles: 12)
        XCTAssertLessThanOrEqual(simplified.indices.count / 3, 12)

        for p in simplified.positions {
            XCTAssertEqual(abs(p.x), 1.0, accuracy: 1e-4)
            XCTAssertEqual(abs(p.y), 1.0, accuracy: 1e-4)
            XCTAssertEqual(abs(p.z), 1.0, accuracy: 1e-4)
        }
    }

    func testDecimatedSphereKeepsItsShape() {
        let sphere = icosphere(subdivisions: 4)          // 5120 triangles
        let before = sphere.indices.count / 3
        XCTAssertEqual(before, 5120)

        let target = before / 8
        let simplified = MeshSimplify.simplify(sphere, targetTriangles: target)

        // Roughly the requested reduction. Not exact: a collapse removes two
        // triangles at a time and some are refused for flipping or manifoldness.
        XCTAssertLessThanOrEqual(simplified.indices.count / 3, target + 32)
        XCTAssertGreaterThan(simplified.indices.count / 3, 0)

        // Still on the sphere. This is the number that matters — an eighth of
        // the triangles is worthless if the surface has drifted.
        var worst: Float = 0
        for p in simplified.positions { worst = max(worst, abs(simd_length(p) - 1)) }
        XCTAssertLessThan(worst, 0.05, "surface drifted \(worst) from the sphere")

        // Volume is preserved, so it has not been shrunk or inflated.
        let volume = signedVolume(simplified)
        XCTAssertEqual(volume, 4.0 / 3.0 * Double.pi, accuracy: 0.4)
        XCTAssertGreaterThan(volume, 0, "winding inverted")
    }

    func testDecimationKeepsTheMeshClosed() {
        // An exporter downstream will happily write a cracked mesh, and it will
        // look fine until someone tries to take a volume off it.
        let simplified = MeshSimplify.simplify(icosphere(subdivisions: 3), targetTriangles: 200)
        XCTAssertEqual(openEdgeCount(simplified), 0, "decimation opened holes in a closed mesh")
    }

    func testNoDegenerateOrDanglingTriangles() {
        let simplified = MeshSimplify.simplify(icosphere(subdivisions: 3), targetTriangles: 150)
        for i in stride(from: 0, to: simplified.indices.count, by: 3) {
            let a = simplified.indices[i], b = simplified.indices[i + 1], c = simplified.indices[i + 2]
            XCTAssertFalse(a == b || b == c || a == c, "degenerate triangle survived")
            for index in [a, b, c] {
                XCTAssertLessThan(Int(index), simplified.positions.count)
            }
        }
    }

    func testColoursSurviveDecimation() {
        var sphere = icosphere(subdivisions: 3)
        sphere.colors = sphere.positions.map { p in
            SIMD3<UInt8>(UInt8((p.x + 1) * 127), UInt8((p.y + 1) * 127), 200)
        }
        let simplified = MeshSimplify.simplify(sphere, targetTriangles: 200)

        XCTAssertEqual(simplified.colors?.count, simplified.positions.count)
        // Blue was constant across every vertex, so averaging must leave it
        // there. If channels were being mixed or overflowing it would not be.
        for colour in simplified.colors ?? [] {
            XCTAssertEqual(colour.z, 200)
        }
    }

    func testAskingForMoreTrianglesThanExistIsANoOp() {
        let sphere = icosphere(subdivisions: 2)
        let simplified = MeshSimplify.simplify(sphere, targetTriangles: 99_999)
        XCTAssertEqual(simplified.indices.count, sphere.indices.count)
    }

    func testEmptyMeshIsHandled() {
        let empty = TsdfVolume.Mesh(positions: [], normals: nil, indices: [], colors: nil)
        XCTAssertTrue(MeshSimplify.simplify(empty, targetTriangles: 10).indices.isEmpty)
        XCTAssertTrue(MeshSimplify.removeNoiseComponents(empty, minimumExtent: 0.1).indices.isEmpty)
    }

    func testMaximumErrorStopsDecimationEarly() {
        // With a tight error budget the sphere should refuse to reduce all the
        // way, because collapsing a curved surface always costs something.
        let sphere = icosphere(subdivisions: 3)
        let simplified = MeshSimplify.simplify(
            sphere, targetTriangles: 20, maximumError: 1e-9
        )
        XCTAssertGreaterThan(
            simplified.indices.count / 3, 20,
            "collapses ran past the error budget"
        )
    }
}

// MARK: - Block decimation

/// Decimation runs a block of mesh at a time so that peak memory is set by the
/// block size rather than by the size of the scan — without that, a fine-detail
/// room wanted 2.2 GB and the phone killed the app.
///
/// The risk it introduces is entirely at the seams: two blocks decimated
/// independently must still agree, vertex for vertex, along the boundary they
/// share. A seam that does not weld produces a mesh that looks correct in a
/// viewer, because the two sides are in exactly the right places, and is
/// cracked the moment anything downstream asks it to enclose a volume. So these
/// tests check watertightness rather than appearance.
final class MeshSimplifyBlockTests: XCTestCase {

    /// Small enough to force the sphere below into several blocks.
    private let blockLimit = 2_000

    func testBlockedDecimationLeavesTheMeshClosed() {
        let sphere = icosphere(subdivisions: 4)
        XCTAssertGreaterThan(sphere.indices.count / 3, blockLimit * 2, "test subject too small to tile")

        let simplified = MeshSimplify.simplify(
            sphere, targetTriangles: 2_000, maximumBlockTriangles: blockLimit
        )

        // An unwelded seam shows up here and nowhere else: both blocks put a
        // vertex in the same place, but under different indices, so every edge
        // along the boundary is used once by each side instead of twice by one.
        XCTAssertEqual(
            openEdgeCount(simplified), 0,
            "decimating in blocks opened the seams between them"
        )
    }

    func testBlockedDecimationKeepsTheShapeAndTheWinding() {
        let sphere = icosphere(subdivisions: 4)
        let simplified = MeshSimplify.simplify(
            sphere, targetTriangles: 3_000, maximumBlockTriangles: blockLimit
        )

        for position in simplified.positions {
            XCTAssertEqual(Double(simd_length(position)), 1.0, accuracy: 0.05)
        }

        // Positive, so the triangles still wind outward. Blocks are gathered
        // and welded in an order that has nothing to do with the original, and
        // an index reversed on the way through would be invisible until
        // something backface-culls it.
        let volume = signedVolume(simplified)
        let expected = 4.0 / 3.0 * Double.pi
        XCTAssertGreaterThan(volume, 0, "blocked decimation inverted the winding")
        XCTAssertEqual(volume, expected, accuracy: expected * 0.15)
    }

    func testBlockedDecimationHitsRoughlyTheSameTargetAsOnePiece() {
        let sphere = icosphere(subdivisions: 4)
        let target = 2_500

        let whole = MeshSimplify.simplify(sphere, targetTriangles: target)
        let blocked = MeshSimplify.simplify(
            sphere, targetTriangles: target, maximumBlockTriangles: blockLimit
        )

        // Seam locking stops an edge touching a boundary from ever collapsing,
        // which pushes the count up; per-block targets round independently,
        // which can pull it a little under. What is being tested is that
        // neither effect is large — if seam locking cost a real fraction of the
        // budget, the setting would be trading away the detail it exists to
        // protect.
        let wholeCount = whole.indices.count / 3
        let blockedCount = blocked.indices.count / 3
        XCTAssertEqual(
            Double(blockedCount), Double(wholeCount), accuracy: Double(wholeCount) * 0.6,
            "seam locking kept \(blockedCount) triangles against \(wholeCount) in one piece"
        )
    }

    func testBlockedDecimationProducesNoDegenerateOrDanglingTriangles() {
        let simplified = MeshSimplify.simplify(
            icosphere(subdivisions: 4), targetTriangles: 1_500, maximumBlockTriangles: blockLimit
        )
        for i in stride(from: 0, to: simplified.indices.count, by: 3) {
            let a = simplified.indices[i], b = simplified.indices[i + 1], c = simplified.indices[i + 2]
            XCTAssertFalse(a == b || b == c || a == c, "degenerate triangle survived")
            for index in [a, b, c] { XCTAssertLessThan(Int(index), simplified.positions.count) }
        }
        // Every vertex emitted is referenced; welding must not leave orphans
        // behind for the exporters to write out as unused rows.
        var used = Set<UInt32>()
        for index in simplified.indices { used.insert(index) }
        XCTAssertEqual(used.count, simplified.positions.count)
    }

    func testColoursSurviveBlockedDecimation() {
        var sphere = icosphere(subdivisions: 4)
        sphere.colors = sphere.positions.map { p in
            SIMD3<UInt8>(
                UInt8((p.x * 0.5 + 0.5) * 255), UInt8((p.y * 0.5 + 0.5) * 255), 128
            )
        }
        let simplified = MeshSimplify.simplify(
            sphere, targetTriangles: 2_000, maximumBlockTriangles: blockLimit
        )
        XCTAssertEqual(simplified.colors?.count, simplified.positions.count)
    }

    func testAMeshUnderTheBlockLimitTakesTheOnePiecePath() {
        // The blocked path is only worth its seams on a mesh too big to hold,
        // and the two paths must agree exactly below the threshold or the same
        // capture would decimate differently depending on an internal constant.
        let sphere = icosphere(subdivisions: 2)
        let a = MeshSimplify.simplify(sphere, targetTriangles: 100)
        let b = MeshSimplify.simplify(
            sphere, targetTriangles: 100, maximumBlockTriangles: 1_000_000
        )
        XCTAssertEqual(a.positions.count, b.positions.count)
        XCTAssertEqual(a.indices, b.indices)
    }
}
