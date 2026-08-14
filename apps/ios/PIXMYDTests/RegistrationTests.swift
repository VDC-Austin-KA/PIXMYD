import Foundation
import XCTest
import simd
@testable import PIXMYD

/// Ported verbatim from `packages/geo/test/geo.test.ts`'s "Registration"
/// section: same inputs, same PRNG, same expected numbers. Matching numbers
/// against the known-good TypeScript implementation is the entire value of
/// porting this way, so nothing here is a fresh or weaker test vector.
final class RegistrationTests: XCTestCase {

    /// Build control pairs from a known transform, so the answer is checkable.
    /// A direct port of `syntheticControl` in `geo.test.ts`, including its
    /// linear congruential PRNG — the exact constants matter, because the
    /// noise added to each point has to be identical to the TS side's for the
    /// two suites to describe the same fixture.
    private func syntheticControl(
        rotation: Quat = Quat.fromAxisAngle(SIMD3<Double>(0.2, 1, 0.1), 0.4),
        translation: SIMD3<Double> = SIMD3<Double>(12.5, -3.25, 7),
        noise: Double = 0
    ) -> [ControlPair] {
        let observed: [SIMD3<Double>] = [
            SIMD3(0, 0, 0), SIMD3(10, 0, 0), SIMD3(0, 12, 0), SIMD3(0, 0, 4),
            SIMD3(10, 12, 4), SIMD3(5, 6, 2),
        ]
        var seed: Int64 = 42
        func rand() -> Double {
            seed = (seed * 1_103_515_245 + 12_345) & 0x7fff_ffff
            return (Double(seed) / Double(0x7fff_ffff) - 0.5) * 2
        }
        return observed.enumerated().map { i, o in
            let noiseVec = SIMD3<Double>(rand() * noise, rand() * noise, rand() * noise)
            let project = applyTransform(rotation: rotation, translation: translation, scale: 1, o) + noiseVec
            return ControlPair(project: project, observed: o, id: "CP\(i + 1)")
        }
    }

    func testHornSolveRecoversAKnownTransformExactlyFromCleanControl() throws {
        let rotation = Quat.fromAxisAngle(SIMD3<Double>(0.2, 1, 0.1), 0.4)
        let translation = SIMD3<Double>(12.5, -3.25, 7)
        let solution = try solveRigidTransform(syntheticControl(rotation: rotation, translation: translation))

        XCTAssertLessThan(solution.rmsError, 1e-9, "rms should be numerically zero")
        for p in [SIMD3<Double>(1, 2, 3), SIMD3<Double>(-5, 0, 8)] {
            let expected = applyTransform(rotation: rotation, translation: translation, scale: 1, p)
            let actual = applyTransform(
                rotation: solution.rotation, translation: solution.translation, scale: solution.scale, p
            )
            XCTAssertEqual(actual.x, expected.x, accuracy: 1e-8)
            XCTAssertEqual(actual.y, expected.y, accuracy: 1e-8)
            XCTAssertEqual(actual.z, expected.z, accuracy: 1e-8)
        }
        XCTAssertEqual(solution.scale, 1, "scale stays 1 unless asked for")
    }

    func testScaleIsNotEstimatedUnlessExplicitlyRequested() throws {
        let pairs = syntheticControl().map { p in
            ControlPair(project: p.project * 1.05, observed: p.observed, id: p.id, sigma: p.sigma) // a genuine 5% scale error
        }
        let fixed = try solveRigidTransform(pairs)
        XCTAssertEqual(fixed.scale, 1)
        XCTAssertGreaterThan(fixed.rmsError, 0.1, "the scale error must show up as residual, not be absorbed")

        let scaled = try solveRigidTransform(pairs, options: SolveOptions(estimateScale: true))
        XCTAssertEqual(scaled.scale, 1.05, accuracy: 1e-6)
        XCTAssertLessThan(scaled.rmsError, 1e-6, "with scale free, the fit is exact")
    }

    func testCollinearControlIsRefusedWithAnActionableMessage() {
        let pairs: [ControlPair] = (0..<4).map { i in
            ControlPair(
                project: SIMD3<Double>(Double(i) + 100, 50, 20),
                observed: SIMD3<Double>(Double(i), 0, 0),
                id: "L\(i)"
            )
        }
        XCTAssertThrowsError(try solveRigidTransform(pairs)) { error in
            guard let regErr = error as? RegistrationError else {
                return XCTFail("wrong error type")
            }
            XCTAssertTrue(regErr.description.contains("collinear or coincident"))
        }
    }

    func testFewerThanThreePairsIsRefused() {
        let pairs = Array(syntheticControl().prefix(2))
        XCTAssertThrowsError(try solveRigidTransform(pairs)) { error in
            guard let regErr = error as? RegistrationError else {
                return XCTFail("wrong error type")
            }
            XCTAssertTrue(regErr.description.contains("need at least 3 control pairs"))
        }
    }

    func testAKnockedMarkerIsFoundByTheOutlierTestAndInflatesRms() throws {
        let clean = syntheticControl(noise: 0.005)
        let cleanSolution = try solveRigidTransform(clean)
        XCTAssertLessThan(cleanSolution.rmsError, 0.02)

        // Knock one marker 300 mm, as if it had been bumped since it was shot.
        let knocked = clean.enumerated().map { i, p -> ControlPair in
            i == 2
                ? ControlPair(project: p.project + SIMD3<Double>(0.3, 0, 0), observed: p.observed, id: p.id, sigma: p.sigma)
                : p
        }
        let solution = try solveRigidTransform(knocked)
        XCTAssertGreaterThan(solution.rmsError, cleanSolution.rmsError * 5, "RMS must react to the bad point")

        let outliers = findOutliers(solution)
        XCTAssertGreaterThanOrEqual(outliers.count, 1, "the bad point must be flagged")
        XCTAssertEqual(outliers[0].id, "CP3", "and it must be the right one")
        // Leave-one-out is what actually catches it: the MAD z-score is masked
        // below the threshold because the fit smears the blunder across every
        // residual.
        XCTAssertGreaterThan(outliers[0].influence, 3, "influence should be decisive")
        XCTAssertLessThan(outliers[0].rmsWithout, solution.rmsError / 3, "RMS must collapse without it")
        XCTAssertTrue(outliers[0].reason.contains("Re-shoot or exclude"))
    }

    func testLeaveOneOutFindsABlunderThatTheMadZScoreAloneMasks() throws {
        // The exact case from the field notes: six points, one knocked 300 mm.
        // The culprit sits at a z-score under 3 — below any sensible MAD
        // threshold — while its neighbours are dragged up with it.
        let clean = syntheticControl(noise: 0.005)
        let knocked = clean.enumerated().map { i, p -> ControlPair in
            i == 2
                ? ControlPair(project: p.project + SIMD3<Double>(0.3, 0, 0), observed: p.observed, id: p.id, sigma: p.sigma)
                : p
        }
        let solution = try solveRigidTransform(knocked)

        let madOnly = findOutliers(solution, options: OutlierOptions(madThreshold: 3.5, influenceThreshold: .infinity))
        XCTAssertEqual(madOnly.count, 0, "MAD alone is masked here — this is the point")

        let both = findOutliers(solution)
        XCTAssertGreaterThanOrEqual(both.count, 1)
        XCTAssertEqual(both[0].id, "CP3")
    }

    func testOutlierDetectionDoesNotFlagAnythingWhenAllResidualsAreEqual() throws {
        let solution = try solveRigidTransform(syntheticControl())
        XCTAssertEqual(findOutliers(solution).count, 0, "a perfect fit has no outliers")
    }

    func testAccuracyGradingMapsResidualsOntoConstructionToleranceBands() {
        XCTAssertEqual(classifyAccuracy(0.002).band, .layout)
        XCTAssertEqual(classifyAccuracy(0.005).band, .penetrations)
        XCTAssertEqual(classifyAccuracy(0.008).band, .dimensionalControl)
        XCTAssertEqual(classifyAccuracy(0.030).band, .coordination)
        XCTAssertEqual(classifyAccuracy(0.200).band, .context)
        XCTAssertEqual(classifyAccuracy(1.5).band, .unusable)
        XCTAssertEqual(classifyAccuracy(Double.nan).band, .unusable)

        // Every band must carry guidance a crew can act on, not just a label.
        for rms in [0.002, 0.008, 0.03, 0.2, 5] {
            XCTAssertGreaterThan(classifyAccuracy(rms).guidance.count, 20)
        }
        XCTAssertTrue(classifyAccuracy(0.008).guidance.contains("Not a substitute for layout instruments"))
    }

    func testSurveySigmaWeightsTheSolveTowardTheBetterKnownPoints() throws {
        let pairs = syntheticControl(noise: 0)
        // Corrupt one point badly but declare it poorly known.
        let mixed = pairs.enumerated().map { i, p -> ControlPair in
            i == 4
                ? ControlPair(project: p.project + SIMD3<Double>(0.5, 0.5, 0.5), observed: p.observed, id: p.id, sigma: 1.0)
                : ControlPair(project: p.project, observed: p.observed, id: p.id, sigma: 0.002)
        }
        let weighted = try solveRigidTransform(mixed, options: SolveOptions(useWeights: true))
        let unweighted = try solveRigidTransform(mixed, options: SolveOptions(useWeights: false))

        func wellKnownRms(_ s: RigidSolution) -> Double {
            var sum = 0.0
            for (i, r) in s.residuals.enumerated() where i != 4 {
                sum += r.error * r.error
            }
            return (sum / 5).squareRoot()
        }
        // The well-known points should fit better when their weight is respected.
        XCTAssertLessThan(
            wellKnownRms(weighted), wellKnownRms(unweighted),
            "weighting must pull the fit toward the tight control"
        )
    }
}
