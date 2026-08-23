import Foundation
import simd

/// Rigid registration: putting a capture in the right place, and stating how
/// wrong it is.
///
/// A direct port of `packages/geo/src/registration.ts`, kept in step
/// deliberately: `docs/contracts/capture.md` and `docs/contracts/ar-model.md`
/// both require `solveRigidTransform`'s numbers to match whichever side of the
/// suite re-solves them, so this file follows the TypeScript line for line
/// rather than reaching for a different (if more "Swifty") formulation.
///
/// The method is Horn's closed-form absolute orientation via unit quaternions
/// (Horn, JOSA A 4(4), 1987). Given N >= 3 non-collinear correspondences it
/// returns the rotation and translation minimising squared residual, with no
/// iteration and no local minima.
///
/// Scale is estimated but **off by default**, deliberately. A survey control
/// network and a LiDAR capture are both metric and true; if solving for scale
/// improves the fit, the improvement is almost certainly absorbing tracking
/// drift rather than correcting a real unit error — which hides the very error
/// the user needs to see. Turn it on to diagnose a unit mismatch at ingest,
/// and turn it back off. See `docs/contracts/capture.md`.
///
/// This file only uses `Foundation` and `simd` (the real one on Apple
/// platforms, `Compat/simd/Simd.swift`'s shim on Linux), by construction: it
/// is part of the pure-arithmetic subset `apps/ios/Package.swift` compiles,
/// so `swift test` covers it on Linux CI. It deliberately does not use
/// `simd_quatd`/`simd_quatf` — the shim does not provide a double-precision
/// quaternion type, so `Quat` below is a small hand-rolled struct that behaves
/// identically on both platforms.

/// A control pair: a surveyed position in project coordinates, and the same
/// point as measured in the capture's own frame. Both in metres.
struct ControlPair {
    /// Surveyed position in project coordinates, metres.
    var project: SIMD3<Double>
    /// The same point as measured in the capture's own frame, metres.
    var observed: SIMD3<Double>
    var id: String?
    /// 1-sigma survey accuracy, metres. Weights the solve when present.
    var sigma: Double?

    init(project: SIMD3<Double>, observed: SIMD3<Double>, id: String? = nil, sigma: Double? = nil) {
        self.project = project
        self.observed = observed
        self.id = id
        self.sigma = sigma
    }
}

struct Residual {
    var id: String?
    var error: Double
    /// Component residuals, useful for spotting a systematic axis problem.
    var delta: SIMD3<Double>
}

struct RigidSolution {
    var rotation: Quat
    var translation: SIMD3<Double>
    var scale: Double
    /// Column-major 4x4 (16 elements) taking observed coordinates to project
    /// coordinates, matching the glTF/TS convention: `matrix[c*4+r]` is row
    /// `r` of column `c`.
    var matrix: [Double]
    var rmsError: Double
    var maxError: Double
    var residuals: [Residual]
    var pairCount: Int
    /// The input pairs, so leave-one-out diagnostics can refit without them.
    var pairs: [ControlPair]
    /// True when the vertical was held from gravity rather than fitted. The
    /// consumer shows this: a two-point fit and a six-point fit are not the
    /// same claim, and the RMS alone does not say which one it is.
    var verticalHeld: Bool = false
}

struct SolveOptions {
    /// Default false. See the module note.
    var estimateScale: Bool
    /// Weight each pair by 1/sigma^2 when sigma is present. Default true.
    var useWeights: Bool

    init(estimateScale: Bool = false, useWeights: Bool = true) {
        self.estimateScale = estimateScale
        self.useWeights = useWeights
    }
}

/// Errors `solveRigidTransform` throws. Messages match the TypeScript
/// implementation's wording, since UI copy and field guidance were written
/// against them.
enum RegistrationError: Error, CustomStringConvertible, Equatable {
    case tooFewPairs(count: Int)
    case degenerateControl
    case tooFewPairsForGravity(count: Int)
    case verticalBaseline

    var description: String {
        switch self {
        case .tooFewPairs(let count):
            return "need at least 3 control pairs, got \(count). Three determines the " +
                "transform; six is the practical minimum for detecting a bad point."
        case .degenerateControl:
            return "control points are collinear or coincident — a rigid transform is not " +
                "determined. Spread control across at least three non-collinear positions, " +
                "and prefer points that differ in height."
        case .tooFewPairsForGravity(let count):
            return "holding the vertical fixed still needs at least 2 control points, got " +
                "\(count). One point fixes where the scan sits and nothing about which way " +
                "it faces."
        case .verticalBaseline:
            return "these control points sit in a vertical line, so holding the vertical " +
                "leaves the heading undetermined. Locate a point somewhere else on the floor."
        }
    }
}

/// Unit quaternion, stored (x, y, z, w) to match the TypeScript `Quat` layout
/// (also the glTF convention).
///
/// Not `simd_quatf`/`simd_quatd`: the former is single precision (this solver
/// needs double, the way the TS side uses `number`), and the Linux shim does
/// not define the latter. A hand-rolled struct means the same code compiles
/// and behaves identically on both platforms.
struct Quat: Equatable {
    var x: Double
    var y: Double
    var z: Double
    var w: Double

    static let identity = Quat(x: 0, y: 0, z: 0, w: 1)

    /// Build from an axis and an angle in radians, matching `quat.fromAxisAngle`.
    static func fromAxisAngle(_ axis: SIMD3<Double>, _ radians: Double) -> Quat {
        let n = simd_normalize(axis)
        let h = radians / 2
        let s = sin(h)
        return Quat(x: n.x * s, y: n.y * s, z: n.z * s, w: cos(h))
    }

    func normalized() -> Quat {
        let l = (x * x + y * y + z * z + w * w).squareRoot()
        if l < 1e-12 { return .identity }
        return Quat(x: x / l, y: y / l, z: z / l, w: w / l)
    }

    /// Rotate a vector by this (assumed unit) quaternion.
    /// `t = 2 * (qv x p); p' = p + qw*t + qv x t`
    func rotate(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let tx = 2 * (y * p.z - z * p.y)
        let ty = 2 * (z * p.x - x * p.z)
        let tz = 2 * (x * p.y - y * p.x)
        return SIMD3<Double>(
            p.x + w * tx + (y * tz - z * ty),
            p.y + w * ty + (z * tx - x * tz),
            p.z + w * tz + (x * ty - y * tx)
        )
    }
}

// MARK: - Internal helpers

private func weightedCentroid(_ points: [SIMD3<Double>], _ weights: [Double]) -> SIMD3<Double> {
    var total = 0.0
    var c = SIMD3<Double>(0, 0, 0)
    for i in 0..<points.count {
        let w = weights[i]
        c += points[i] * w
        total += w
    }
    return c / total
}

/// Are these points collinear or coincident? A rigid transform is not
/// determined by such a set, and the solve would return an arbitrary rotation
/// about the line.
private func isDegenerate(_ centred: [SIMD3<Double>]) -> Bool {
    var maxLen = 0.0
    var axis = SIMD3<Double>(0, 0, 0)
    for p in centred {
        let l = simd_length(p)
        if l > maxLen {
            maxLen = l
            axis = p
        }
    }
    if maxLen < 1e-9 { return true } // all coincident

    let unit = simd_normalize(axis)
    var maxPerp = 0.0
    for p in centred {
        let along = simd_dot(p, unit)
        let perp = simd_length(p - unit * along)
        if perp > maxPerp { maxPerp = perp }
    }
    // Perpendicular spread under 0.1% of the longest baseline is collinear
    // for any practical purpose.
    return maxPerp < maxLen * 1e-3
}

/// Largest eigenvector of a symmetric 4x4 (row-major, 16 elements), by power
/// iteration with a shift.
///
/// Horn's N matrix has its largest eigenvalue corresponding to the optimal
/// rotation quaternion. Shifting by the trace guarantees the dominant
/// eigenvalue is the one power iteration finds, even when the true largest is
/// negative.
private func largestEigenvector4(_ N: [Double]) -> Quat {
    var trace = 0.0
    for i in 0..<4 { trace += abs(N[i * 5]) }
    let shift = trace + 1
    var M = N
    for i in 0..<4 { M[i * 5] += shift }

    // Start away from any axis so a symmetric matrix cannot leave us on an
    // eigenvector of the wrong eigenvalue.
    var v = [0.5, 0.5, 0.5, 0.5]
    for _ in 0..<200 {
        var next = [0.0, 0.0, 0.0, 0.0]
        for r in 0..<4 {
            var sum = 0.0
            for c in 0..<4 { sum += M[r * 4 + c] * v[c] }
            next[r] = sum
        }
        let norm = (next[0] * next[0] + next[1] * next[1] + next[2] * next[2] + next[3] * next[3]).squareRoot()
        if norm < 1e-300 { break }
        for i in 0..<4 { next[i] /= norm }
        var delta = 0.0
        for i in 0..<4 { delta += abs(next[i] - v[i]) }
        v = next
        if delta < 1e-15 { break }
    }
    // Horn's quaternion is (w, x, y, z); this codebase stores (x, y, z, w).
    return Quat(x: v[1], y: v[2], z: v[3], w: v[0]).normalized()
}

/// Compose translation * rotation * uniform-scale into a column-major 4x4,
/// matching `mat4.compose(translation, rotation, [scale, scale, scale])`.
private func composeMatrix(translation: SIMD3<Double>, rotation: Quat, scale: Double) -> [Double] {
    let q = rotation.normalized()
    let x = q.x, y = q.y, z = q.z, w = q.w
    let x2 = x + x, y2 = y + y, z2 = z + z
    let xx = x * x2, xy = x * y2, xz = x * z2
    let yy = y * y2, yz = y * z2, zz = z * z2
    let wx = w * x2, wy = w * y2, wz = w * z2
    let r0 = 1 - (yy + zz), r1 = xy + wz, r2 = xz - wy
    let r3 = xy - wz, r4 = 1 - (xx + zz), r5 = yz + wx
    let r6 = xz + wy, r7 = yz - wx, r8 = 1 - (xx + yy)
    return [
        r0 * scale, r1 * scale, r2 * scale, 0,
        r3 * scale, r4 * scale, r5 * scale, 0,
        r6 * scale, r7 * scale, r8 * scale, 0,
        translation.x, translation.y, translation.z, 1,
    ]
}

// MARK: - Solve

func solveRigidTransform(_ pairs: [ControlPair], options: SolveOptions = SolveOptions()) throws -> RigidSolution {
    let estimateScale = options.estimateScale
    let useWeights = options.useWeights

    if pairs.count < 3 {
        throw RegistrationError.tooFewPairs(count: pairs.count)
    }

    let src = pairs.map { $0.observed }
    let dst = pairs.map { $0.project }
    let weights = pairs.map { p -> Double in
        if useWeights, let sigma = p.sigma, sigma > 0 {
            return 1 / (sigma * sigma)
        }
        return 1
    }

    let cSrc = weightedCentroid(src, weights)
    let cDst = weightedCentroid(dst, weights)
    let pSrc = src.map { $0 - cSrc }
    let pDst = dst.map { $0 - cDst }

    if isDegenerate(pSrc) || isDegenerate(pDst) {
        throw RegistrationError.degenerateControl
    }

    // Weighted 3x3 cross-covariance, row-major.
    var M = [Double](repeating: 0, count: 9)
    for i in 0..<pSrc.count {
        let s = pSrc[i], d = pDst[i], w = weights[i]
        let sArr = [s.x, s.y, s.z]
        let dArr = [d.x, d.y, d.z]
        for r in 0..<3 {
            for c in 0..<3 {
                M[r * 3 + c] += w * sArr[r] * dArr[c]
            }
        }
    }
    let Sxx = M[0], Sxy = M[1], Sxz = M[2]
    let Syx = M[3], Syy = M[4], Syz = M[5]
    let Szx = M[6], Szy = M[7], Szz = M[8]

    // Horn's symmetric 4x4, in (w, x, y, z) ordering.
    let N: [Double] = [
        Sxx + Syy + Szz, Syz - Szy, Szx - Sxz, Sxy - Syx,
        Syz - Szy, Sxx - Syy - Szz, Sxy + Syx, Szx + Sxz,
        Szx - Sxz, Sxy + Syx, -Sxx + Syy - Szz, Syz + Szy,
        Sxy - Syx, Szx + Sxz, Syz + Szy, -Sxx - Syy + Szz,
    ]

    let rotation = largestEigenvector4(N)

    var scale = 1.0
    if estimateScale {
        var num = 0.0
        var den = 0.0
        for i in 0..<pSrc.count {
            num += weights[i] * simd_dot(pDst[i], rotation.rotate(pSrc[i]))
            den += weights[i] * simd_dot(pSrc[i], pSrc[i])
        }
        if den > 0 { scale = num / den }
    }

    let translation = cDst - rotation.rotate(cSrc) * scale

    var residuals: [Residual] = []
    residuals.reserveCapacity(pairs.count)
    for i in 0..<pairs.count {
        let mapped = applyTransform(rotation: rotation, translation: translation, scale: scale, src[i])
        let delta = mapped - dst[i]
        residuals.append(Residual(id: pairs[i].id, error: simd_length(delta), delta: delta))
    }

    var sumSq = 0.0
    var maxError = 0.0
    for r in residuals {
        sumSq += r.error * r.error
        if r.error > maxError { maxError = r.error }
    }

    return RigidSolution(
        rotation: rotation,
        translation: translation,
        scale: scale,
        matrix: composeMatrix(translation: translation, rotation: rotation, scale: scale),
        rmsError: (sumSq / Double(residuals.count)).squareRoot(),
        maxError: maxError,
        residuals: residuals,
        pairCount: pairs.count,
        pairs: pairs
    )
}

func applyTransform(rotation: Quat, translation: SIMD3<Double>, scale: Double, _ p: SIMD3<Double>) -> SIMD3<Double> {
    rotation.rotate(p) * scale + translation
}

// MARK: - Solve with the vertical held

/// Which way is up, in each of the two frames.
///
/// Named rather than inlined because the day something other than ARKit
/// produces a capture, there is one place to look — and because a hard-coded
/// `(0, 1, 0)` in the middle of a solver is indistinguishable from a bug.
enum GravityFrame {
    /// ARKit's world frame is gravity-aligned with +Y up, and every capture
    /// this app produces comes from ARKit.
    static let captureUp = SIMD3<Double>(0, 1, 0)

    /// The up vector for a contract up-axis string. Anything unrecognised is
    /// Z: that is what Navisworks documents use, and guessing Y for a typo
    /// would lay a whole scan on its side.
    static func up(forAxis axis: String) -> SIMD3<Double> {
        switch axis.trimmingCharacters(in: .whitespaces).uppercased() {
        case "Y": return SIMD3<Double>(0, 1, 0)
        case "X": return SIMD3<Double>(1, 0, 0)
        default:  return SIMD3<Double>(0, 0, 1)
        }
    }

    /// Two points determine heading and translation. One does not.
    static let minimumPairs = 2

    /// What a fit from this many points can and cannot tell you.
    ///
    /// Shown beside the RMS, because an RMS from two points is a number with
    /// no redundancy behind it: it is near zero by construction whether the
    /// points were right or wrong, and a user who reads "0 mm" without this
    /// line will trust it more than a 4 mm fit from six points that is the
    /// better answer.
    static func redundancyGuidance(pairCount: Int) -> String {
        if pairCount <= 2 {
            return "Two points fix the scan with the vertical held from gravity, but they leave "
                 + "no redundancy: the fit reports near-zero error whether the points are right "
                 + "or wrong. Locate a third to get an error you can believe."
        }
        if pairCount == 3 {
            return "Three points give one check on the fit. A blunder in any of them raises the "
                 + "error but cannot yet be told apart from the other two."
        }
        return "Four or more points leave enough redundancy for a bad one to be identified "
             + "rather than merely suspected."
    }
}

/// Register a capture with the vertical held fixed.
///
/// `solveRigidTransform` fits all six degrees of freedom, so it needs three
/// non-collinear pairs. On site that is the step that stops people: a crew has
/// two column marks they can reach and a third behind a stack of drywall, and
/// the app refuses.
///
/// It does not have to. Both frames already know which way down is — ARKit runs
/// gravity-aligned, and a model states its up axis — so fixing the vertical
/// removes roll and pitch and leaves four unknowns that two points
/// over-determine.
///
/// This is not a lower-quality answer. Gravity from an IMU is better
/// conditioned than roll and pitch fitted from three hand-aimed picks, and this
/// solve is often the right one at five points too. What two points cannot do
/// is tell you when one of them is wrong — see `GravityFrame
/// .redundancyGuidance`, which the UI shows verbatim.
///
/// Closed form, no iteration:
///
///   1. rotate the capture's up onto the model's, by the shortest arc
///   2. solve the one remaining angle about that axis:
///      `theta = atan2(sum w U·(a×b), sum w a·b)` over the horizontal
///      components, which is the exact weighted least-squares heading
///   3. translation from the weighted centroids
///
/// Mirrors `PIXMYD-Nav/Core/Capture/GravitySolve.cs` vector for vector, and
/// shares its test vectors so the two cannot drift.
func solveGravityConstrained(
    _ pairs: [ControlPair],
    captureUp: SIMD3<Double> = GravityFrame.captureUp,
    projectUp: SIMD3<Double> = SIMD3<Double>(0, 0, 1),
    options: SolveOptions = SolveOptions()
) throws -> RigidSolution {
    guard pairs.count >= GravityFrame.minimumPairs else {
        throw RegistrationError.tooFewPairsForGravity(count: pairs.count)
    }

    let up = normalisedOrZero(projectUp)
    let sourceUp = normalisedOrZero(captureUp)
    guard simd_length(up) > 0.5, simd_length(sourceUp) > 0.5 else {
        throw RegistrationError.degenerateControl
    }

    let weights = pairs.map { p -> Double in
        if options.useWeights, let sigma = p.sigma, sigma > 0 { return 1 / (sigma * sigma) }
        return 1
    }

    // 1. Level the capture. Everything after this happens in a frame whose
    //    vertical is already right.
    let levelling = Quat.shortestArc(from: sourceUp, to: up)
    let levelled = pairs.map { levelling.rotate($0.observed) }
    let targets = pairs.map { $0.project }

    let centreSource = weightedCentroid(levelled, weights)
    let centreTarget = weightedCentroid(targets, weights)

    // 2. Heading, in closed form, from the horizontal components only. The
    //    vertical components carry no information about a rotation around the
    //    vertical, and including them would let a height difference bias it.
    var numerator = 0.0
    var denominator = 0.0
    var horizontalWeight = 0.0
    for i in 0..<pairs.count {
        let a = horizontal(levelled[i] - centreSource, up)
        let b = horizontal(targets[i] - centreTarget, up)
        numerator += weights[i] * simd_dot(up, simd_cross(a, b))
        denominator += weights[i] * simd_dot(a, b)
        horizontalWeight += weights[i] * simd_length(a) * simd_length(b)
    }

    guard horizontalWeight > 1e-9 else {
        throw RegistrationError.verticalBaseline
    }

    let heading = Quat.fromAxisAngle(up, atan2(numerator, denominator))

    // 3. Compose. The levelling happens first, so it is the right-hand factor.
    let rotation = Quat.multiply(heading, levelling)
    let translation = centreTarget - heading.rotate(centreSource)

    // Scale stays at 1 whatever the options say: a capture and a model are both
    // metric, and a constrained solve exists to keep error visible rather than
    // to absorb it into another fitted parameter.
    let scale = 1.0

    var residuals: [Residual] = []
    residuals.reserveCapacity(pairs.count)
    var sumSq = 0.0
    var maxError = 0.0
    for pair in pairs {
        let mapped = applyTransform(
            rotation: rotation, translation: translation, scale: scale, pair.observed)
        let delta = mapped - pair.project
        let error = simd_length(delta)
        residuals.append(Residual(id: pair.id, error: error, delta: delta))
        sumSq += error * error
        if error > maxError { maxError = error }
    }

    return RigidSolution(
        rotation: rotation,
        translation: translation,
        scale: scale,
        matrix: composeMatrix(translation: translation, rotation: rotation, scale: scale),
        rmsError: (sumSq / Double(residuals.count)).squareRoot(),
        maxError: maxError,
        residuals: residuals,
        pairCount: pairs.count,
        pairs: pairs,
        verticalHeld: true
    )
}

/// Solve with whichever method the data supports.
///
/// Three or more pairs get Horn's unconstrained solve, which is what every
/// number in `docs/contracts/capture.md` has always meant. Two get the
/// gravity-constrained one. Below two there is nothing to do.
///
/// `forceGravity` is for the operator who knows better than the residuals:
/// three hand-aimed picks fit a tilt more readily than an IMU gets gravity
/// wrong, so holding the vertical is often the better answer even when Horn's
/// is available.
func solveBestAvailable(
    _ pairs: [ControlPair],
    captureUp: SIMD3<Double> = GravityFrame.captureUp,
    projectUp: SIMD3<Double> = SIMD3<Double>(0, 0, 1),
    forceGravity: Bool = false,
    options: SolveOptions = SolveOptions()
) throws -> RigidSolution {
    if forceGravity || pairs.count < 3 {
        return try solveGravityConstrained(
            pairs, captureUp: captureUp, projectUp: projectUp, options: options)
    }
    return try solveRigidTransform(pairs, options: options)
}

// MARK: - Vector helpers for the constrained solve

private func horizontal(_ v: SIMD3<Double>, _ up: SIMD3<Double>) -> SIMD3<Double> {
    v - up * simd_dot(v, up)
}

private func normalisedOrZero(_ v: SIMD3<Double>) -> SIMD3<Double> {
    let length = simd_length(v)
    return length < 1e-15 ? SIMD3<Double>(0, 0, 0) : v / length
}

extension Quat {
    /// The shortest rotation carrying one unit vector onto another.
    static func shortestArc(from: SIMD3<Double>, to: SIMD3<Double>) -> Quat {
        let a = normalisedOrZero(from)
        let b = normalisedOrZero(to)
        let cosine = simd_dot(a, b)

        // Opposed: every rotation through 180 degrees is equally short, so pick
        // one perpendicular axis deterministically rather than letting a
        // near-zero cross product choose it out of rounding noise.
        if cosine < -0.999999 {
            return Quat.fromAxisAngle(anyPerpendicular(a), .pi)
        }

        let axis = simd_cross(a, b)
        return Quat(x: axis.x, y: axis.y, z: axis.z, w: 1 + cosine).normalized()
    }

    /// Apply `b` first, then `a`.
    static func multiply(_ a: Quat, _ b: Quat) -> Quat {
        Quat(
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
        ).normalized()
    }
}

private func anyPerpendicular(_ v: SIMD3<Double>) -> SIMD3<Double> {
    // Cross with whichever axis this vector is least aligned to, so the result
    // is never near zero.
    let axis = abs(v.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
    return normalisedOrZero(simd_cross(v, axis))
}

// MARK: - Outliers

struct Outlier {
    var id: String?
    var index: Int
    /// This point's residual in the full solution, metres.
    var error: Double
    /// Robust z-score: how many MADs from the median residual.
    var score: Double
    /// RMS of the solution refitted without this point. A value far below the
    /// full-fit RMS is the strongest evidence available that this point is bad.
    var rmsWithout: Double
    /// fullRms / rmsWithout. Above ~3 means this one point dominates the fit.
    var influence: Double
    var reason: String
}

struct OutlierOptions {
    /// MAD z-score above which a residual is out of family.
    var madThreshold: Double
    /// Influence ratio above which a point is judged to dominate the fit.
    var influenceThreshold: Double
    var estimateScale: Bool

    init(madThreshold: Double = 3.5, influenceThreshold: Double = 3, estimateScale: Bool = false) {
        self.madThreshold = madThreshold
        self.influenceThreshold = influenceThreshold
        self.estimateScale = estimateScale
    }
}

/// Flag control points that do not belong.
///
/// Two tests, because neither is sufficient alone:
///
/// **Median/MAD z-score.** Robust to a single gross error in a way that
/// mean/stddev is not — one bad point inflates the standard deviation enough
/// to hide itself. The 1.4826 factor makes MAD a consistent estimator of
/// sigma for normal data, so the threshold reads as a z-score.
///
/// **Leave-one-out influence.** The MAD test still suffers *masking* on small
/// networks: a least-squares fit distributes one gross error across every
/// residual, so with six points a 300 mm blunder can leave the culprit at a
/// z-score of 2.9 while dragging its neighbours up with it. Refitting without
/// each point in turn measures its influence directly, and a bad point
/// announces itself unmistakably — the RMS collapses when it is removed.
func findOutliers(_ solution: RigidSolution, options: OutlierOptions = OutlierOptions()) -> [Outlier] {
    let madThreshold = options.madThreshold
    let influenceThreshold = options.influenceThreshold

    let errors = solution.residuals.map { $0.error }
    let sorted = errors.sorted()
    let median = sorted[sorted.count / 2]
    let deviations = errors.map { abs($0 - median) }.sorted()
    let mad = deviations[deviations.count / 2]

    let pairs = solution.pairs
    let canRefit = pairs.count >= 4

    var out: [Outlier] = []
    for i in 0..<errors.count {
        // All residuals identical means nothing stands out; dividing by a
        // zero MAD would instead make every point an outlier.
        let score = mad < 1e-12 ? 0 : abs(errors[i] - median) / (mad * 1.4826)

        var rmsWithout = solution.rmsError
        if canRefit {
            var remaining = pairs
            remaining.remove(at: i)
            if let refit = try? solveRigidTransform(
                remaining,
                options: SolveOptions(estimateScale: options.estimateScale)
            ) {
                rmsWithout = refit.rmsError
            } else {
                // Removing this point makes the remainder degenerate, which
                // means it is load-bearing geometry rather than a blunder.
                // Leave the RMS unchanged.
                rmsWithout = solution.rmsError
            }
        }
        let influence = rmsWithout > 1e-12 ? solution.rmsError / rmsWithout : 1

        let byMad = score > madThreshold
        let byInfluence = influence > influenceThreshold
        if !byMad && !byInfluence { continue }

        var reasons: [String] = []
        if byInfluence {
            let fromMm = Int((solution.rmsError * 1000).rounded())
            let toMm = Int((rmsWithout * 1000).rounded())
            reasons.append("removing it drops RMS from \(fromMm) mm to \(toMm) mm")
        }
        if byMad {
            reasons.append("residual is \(String(format: "%.1f", score)) MADs from the median")
        }

        out.append(Outlier(
            id: solution.residuals[i].id,
            index: i,
            error: errors[i],
            score: score,
            rmsWithout: rmsWithout,
            influence: influence,
            reason: "Re-shoot or exclude: \(reasons.joined(separator: "; "))."
        ))
    }

    // Most influential first — that is the one to check on the ground.
    return out.sorted {
        if $0.influence != $1.influence { return $0.influence > $1.influence }
        return $0.score > $1.score
    }
}

// MARK: - Accuracy grading

enum AccuracyBand: String, Equatable {
    case layout
    case penetrations
    case dimensionalControl = "dimensional-control"
    case coordination
    case context
    case unusable
}

struct AccuracyGrade {
    var band: AccuracyBand
    var rmsError: Double
    var label: String
    var guidance: String
}

/// Map an RMS residual onto the construction tolerance bands, with guidance
/// in the terms a crew uses.
///
/// These bands are the working tolerances from the field, not a statistical
/// convention: a number displayed without one is an unfinished measurement,
/// because a crew will build to whatever is on the screen.
func classifyAccuracy(_ rmsError: Double) -> AccuracyGrade {
    if !rmsError.isFinite || rmsError < 0 {
        return AccuracyGrade(
            band: .unusable,
            rmsError: rmsError,
            label: "No solution",
            guidance: "The registration did not solve. Do not use this positioning for anything."
        )
    }
    if rmsError <= 0.003 {
        return AccuracyGrade(
            band: .layout,
            rmsError: rmsError,
            label: "Layout",
            guidance: "Within structural and MEP point layout tolerance (~3 mm). Verify " +
                "against an instrument before laying out from it — this is a fit statistic, " +
                "not an independent check."
        )
    }
    if rmsError <= 0.006 {
        return AccuracyGrade(
            band: .penetrations,
            rmsError: rmsError,
            label: "Sleeves and penetrations",
            guidance: "Good enough to place sleeves and penetrations (~6 mm). Not for point layout."
        )
    }
    if rmsError <= 0.010 {
        return AccuracyGrade(
            band: .dimensionalControl,
            rmsError: rmsError,
            label: "Dimensional control",
            guidance: "Good enough to confirm installed work against the model (~10 mm). " +
                "Not a substitute for layout instruments."
        )
    }
    if rmsError <= 0.050 {
        return AccuracyGrade(
            band: .coordination,
            rmsError: rmsError,
            label: "Coordination",
            guidance: "Usable for clash checking and coordination (~25-50 mm). Do not measure " +
                "installed positions from it."
        )
    }
    if rmsError <= 0.250 {
        return AccuracyGrade(
            band: .context,
            rmsError: rmsError,
            label: "Context only",
            guidance: "Shows roughly what is where (~250 mm). Wayfinding and zone " +
                "identification only."
        )
    }
    let mm = Int((rmsError * 1000).rounded())
    return AccuracyGrade(
        band: .unusable,
        rmsError: rmsError,
        label: "Unusable",
        guidance: "RMS of \(mm) mm is past any construction use. Check for a wrong zone, " +
            "a wrong unit, or a mis-keyed control point."
    )
}
