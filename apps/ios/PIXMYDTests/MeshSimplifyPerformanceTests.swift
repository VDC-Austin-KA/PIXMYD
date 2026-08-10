import Foundation
import XCTest
import simd
@testable import PIXMYD

/// A guard against the decimator going quadratic again.
///
/// The first working version of `simplify` re-sorted its candidate queue and
/// rescanned the whole index buffer on every collapse. It passed every
/// correctness test in `MeshSimplifyTests` and took 15 seconds on 5,000
/// triangles — which is hours on the meshes a room scan actually produces, and
/// is the difference between a feature and a hang. Correctness tests cannot see
/// that; only a test with a clock can.
final class MeshSimplifyPerformanceTests: XCTestCase {

    /// A grid of quads, subdivided into triangles. Cheap to build at size and,
    /// being mostly planar, representative of the thing decimation exists for:
    /// walls, slabs and ceilings that cost thousands of triangles to say
    /// "flat".
    private func grid(side: Int) -> TsdfVolume.Mesh {
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity((side + 1) * (side + 1))
        for y in 0...side {
            for x in 0...side {
                // A gentle bulge, so it is not so perfectly planar that every
                // collapse is free and the queue never does any real work.
                let fx = Float(x) / Float(side), fy = Float(y) / Float(side)
                positions.append(SIMD3(fx * 4, fy * 4, sin(fx * 3) * cos(fy * 3) * 0.15))
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(side * side * 6)
        for y in 0..<side {
            for x in 0..<side {
                let a = UInt32(y * (side + 1) + x)
                let b = a + 1
                let c = a + UInt32(side + 1)
                let d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        return TsdfVolume.Mesh(positions: positions, normals: nil, indices: indices, colors: nil)
    }

    func testDecimatesALargeMeshInReasonableTime() {
        // 80,000 triangles: a small room at 25 mm voxels. A phone is slower
        // than this machine, but the bound is loose enough that the only way to
        // fail it is a complexity regression, not a constant factor.
        let mesh = grid(side: 200)
        XCTAssertEqual(mesh.indices.count / 3, 80_000)

        let started = Date()
        let simplified = MeshSimplify.simplify(mesh, targetTriangles: 8_000)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThanOrEqual(simplified.indices.count / 3, 8_100)
        XCTAssertLessThan(elapsed, 25, "decimation took \(elapsed)s — complexity regression")

        // Shape survived: every vertex still lies on the original surface.
        var worst: Float = 0
        for p in simplified.positions {
            let expected = sin(p.x / 4 * 3) * cos(p.y / 4 * 3) * 0.15
            worst = max(worst, abs(p.z - expected))
        }
        XCTAssertLessThan(worst, 0.05, "surface drifted \(worst) m")
    }

    /// Doubling the triangle count must not quadruple the time.
    ///
    /// This is the shape of the bug, stated directly. Absolute timings vary
    /// with the machine and cannot be asserted on; the growth rate is the thing
    /// that was wrong, and it is machine-independent.
    func testCostGrowsRoughlyLinearly() {
        func timeToHalve(side: Int) -> TimeInterval {
            let mesh = grid(side: side)
            let target = mesh.indices.count / 6
            let started = Date()
            _ = MeshSimplify.simplify(mesh, targetTriangles: target)
            return Date().timeIntervalSince(started)
        }

        let small = timeToHalve(side: 70)    // 9,800 triangles
        let large = timeToHalve(side: 140)   // 39,200 triangles, 4x the work

        // Linear would be 4x, quadratic 16x. Anything under 10 means the
        // per-collapse work is still local. The old version was ~50x here.
        let ratio = large / max(small, 0.001)
        XCTAssertLessThan(ratio, 10, "scaling ratio \(ratio) suggests superlinear cost")
    }
}
