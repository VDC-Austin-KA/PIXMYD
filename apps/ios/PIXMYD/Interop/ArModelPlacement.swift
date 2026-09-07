import Foundation
import simd

// Where the exported model goes in the room.
//
// PIXMYD-Nav's AR export writes `ar-model.json` and, now that it can tessellate
// the document, `ar-model.glb` beside it. Drawing that over the real world is
// four coordinate frames deep, and every one of the joins is somewhere a scan
// can end up plausibly and precisely wrong:
//
//   1. **The GLB's own frame.** glTF fixes +Y as up and a Navisworks document
//      is almost always Z-up, so the writer turned the geometry on the way out.
//      That turn has to be undone before anything else means what it says.
//   2. **The AR bundle's origin shift.** The exporter moved the model so its
//      bounding box's minimum corner sits near zero, and recorded the shift.
//      Adding it back returns a coordinate to the source document's world.
//   3. **The point set's origin shift.** `points.json` carries its own, which
//      is usually zero and is not guaranteed to be. Subtracting it puts the
//      geometry in the frame the located points are expressed in.
//   4. **The registration.** The solve maps the capture's ARKit frame onto the
//      point frame; drawing needs the other direction.
//
// All four are here, in one function, in the portable half where `swift test`
// can check the composition against a point whose answer is known. A model
// drawn 90 degrees out is obvious; one drawn with two of these steps cancelling
// to something nearly right is the failure that gets built to.

enum ArModelPlacement {

    /// Everything needed to draw a bundle, or the reason it cannot be drawn.
    enum Readiness: Equatable {
        case ready(pointCount: Int, rmsError: Double)
        case noGeometry
        case noPointSet
        case notEnoughPoints(located: Int)
        case cannotSolve(String)

        var canDraw: Bool {
            if case .ready = self { return true }
            return false
        }

        /// One line to show the operator, in the terms the decision is made in.
        var summary: String {
            switch self {
            case let .ready(count, rms):
                let mm = Int((rms * 1000).rounded())
                return "Anchored on \(count) located point(s), \(mm) mm RMS. "
                     + "The overlay is only as good as that number."
            case .noGeometry:
                return "This bundle carries no geometry. Export it again from PIXMYD-Nav with "
                     + "\"Include model geometry\" ticked, and the model can be drawn over the room."
            case .noPointSet:
                return "This bundle has no point set, so there is nothing to anchor it to. "
                     + "Transfer the model and its points together."
            case let .notEnoughPoints(located):
                return located == 0
                    ? "No points located yet. Find two of the printed markers and record them, and "
                    + "the model can be drawn where it belongs."
                    : "One point located. It fixes where the model sits and nothing about which way "
                    + "it faces — find one more, well away from the first."
            case let .cannotSolve(reason):
                return reason
            }
        }
    }

    /// The transform taking a vertex out of `ar-model.glb` into the AR
    /// session's world frame, as a column-major 4x4.
    ///
    /// `solution` maps the capture frame onto the point set's frame, which is
    /// the direction the registration solves in. Drawing needs the inverse, and
    /// taking it rather than re-solving backwards is exact: a rigid transform's
    /// inverse is its transposed rotation and a negated, rotated translation.
    static func worldFromModel(
        solution: RigidSolution,
        pointsAppliedOffset: [Double],
        modelAppliedOffset: [Double],
        glbIsYUp: Bool = true
    ) -> [Double] {
        // Step 1: undo the writer's Z-up to Y-up turn, (x, y, z) -> (x, z, -y).
        // Its inverse is (x, y, z) -> (x, -z, y).
        let unturn: [Double] = glbIsYUp
            ? [1, 0, 0, 0,
               0, 0, 1, 0,
               0, -1, 0, 0,
               0, 0, 0, 1]
            : identity

        // Steps 2 and 3: back to source world, then into the point frame.
        let shift = subtract(modelAppliedOffset, pointsAppliedOffset)
        let intoPointFrame = translation(shift)

        // Step 4: the registration, inverted.
        let captureFromPoints = inverseRigid(solution)

        return multiply(captureFromPoints, multiply(intoPointFrame, unturn))
    }

    /// Whether a bundle can be drawn, and why not when it cannot.
    static func readiness(
        hasGeometry: Bool,
        pointSet: NavPointSet?,
        located: Int,
        solved: Result<CaptureSolution, Error>?
    ) -> Readiness {
        guard hasGeometry else { return .noGeometry }
        guard let pointSet, !pointSet.points.isEmpty else { return .noPointSet }
        guard located >= GravityFrame.minimumPairs else { return .notEnoughPoints(located: located) }

        switch solved {
        case let .success(solution)?:
            return .ready(pointCount: solution.solution.pairCount, rmsError: solution.solution.rmsError)
        case let .failure(error)?:
            return .cannotSolve("\(error)")
        case nil:
            return .notEnoughPoints(located: located)
        }
    }

    // MARK: - Small column-major 4x4 arithmetic
    //
    // Column-major with `m[c * 4 + r]`, matching `RigidSolution.matrix`, the
    // TypeScript suite and glTF. A second convention in a third file is how a
    // transpose gets in.

    static let identity: [Double] = [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    ]

    static func translation(_ v: SIMD3<Double>) -> [Double] {
        [1, 0, 0, 0,
         0, 1, 0, 0,
         0, 0, 1, 0,
         v.x, v.y, v.z, 1]
    }

    /// Applies `b` first, then `a`.
    static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        guard a.count == 16, b.count == 16 else { return identity }
        var out = [Double](repeating: 0, count: 16)
        for column in 0..<4 {
            for row in 0..<4 {
                var sum = 0.0
                for k in 0..<4 { sum += a[k * 4 + row] * b[column * 4 + k] }
                out[column * 4 + row] = sum
            }
        }
        return out
    }

    /// The inverse of a rigid transform, exactly: transposed rotation, and a
    /// translation rotated back and negated.
    static func inverseRigid(_ solution: RigidSolution) -> [Double] {
        let inverse = Quat(
            x: -solution.rotation.x,
            y: -solution.rotation.y,
            z: -solution.rotation.z,
            w: solution.rotation.w)
        let back = inverse.rotate(solution.translation)
        return compose(rotation: inverse, translation: -back)
    }

    static func compose(rotation: Quat, translation t: SIMD3<Double>) -> [Double] {
        let q = rotation.normalized()
        let x = q.x, y = q.y, z = q.z, w = q.w
        let x2 = x + x, y2 = y + y, z2 = z + z
        let xx = x * x2, xy = x * y2, xz = x * z2
        let yy = y * y2, yz = y * z2, zz = z * z2
        let wx = w * x2, wy = w * y2, wz = w * z2
        return [
            1 - (yy + zz), xy + wz, xz - wy, 0,
            xy - wz, 1 - (xx + zz), yz + wx, 0,
            xz + wy, yz - wx, 1 - (xx + yy), 0,
            t.x, t.y, t.z, 1,
        ]
    }

    static func apply(_ m: [Double], to p: SIMD3<Double>) -> SIMD3<Double> {
        guard m.count == 16 else { return p }
        return SIMD3<Double>(
            m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
            m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
            m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14])
    }

    private static func subtract(_ a: [Double], _ b: [Double]) -> SIMD3<Double> {
        vector(a) - vector(b)
    }

    private static func vector(_ v: [Double]) -> SIMD3<Double> {
        guard v.count >= 3 else { return SIMD3<Double>(0, 0, 0) }
        return SIMD3<Double>(v[0], v[1], v[2])
    }
}
