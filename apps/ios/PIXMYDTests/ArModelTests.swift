import Foundation
import XCTest
import simd
@testable import PIXMYD

/// The AR model round trip: reading the geometry PIXMYD-Nav now exports, and
/// working out where to draw it.
///
/// The placement is four coordinate frames deep and every join is somewhere a
/// model can end up plausibly wrong. A model drawn 90 degrees out is obvious in
/// the viewfinder; one drawn with two of the steps cancelling to something
/// nearly right is the failure that gets built to. So the composition is
/// checked against a point whose answer is known by construction rather than by
/// looking at it.
final class ArModelTests: XCTestCase {

    // MARK: - Reading the geometry

    /// The reader is checked against this app's own writer. That is not a
    /// tautology: the writer's output is what the monorepo tests feed through
    /// three.js's loader, and it uses the same accessor kinds PIXMYD-Nav's
    /// writer does — float VEC3 positions and normals, unsigned-int scalar
    /// indices, one primitive in TRIANGLES mode.
    func testAGlbSurvivesTheRoundTrip() throws {
        let positions: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 2, 0), SIMD3(0, 2, 0),
        ]
        let normals: [SIMD3<Float>] = Array(repeating: SIMD3(0, 0, 1), count: 4)
        let colors: [SIMD3<UInt8>] = [
            SIMD3(255, 0, 0), SIMD3(0, 255, 0), SIMD3(0, 0, 255), SIMD3(9, 9, 9),
        ]
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3]

        let url = try temporaryFile("round-trip.glb")
        defer { try? FileManager.default.removeItem(at: url) }
        try Exporters.writeGlb(
            positions: positions, normals: normals, colors: colors, indices: indices, to: url)

        let mesh = try GlbReader.read(contentsOf: url)

        XCTAssertEqual(mesh.positions.count, 4)
        for i in 0..<4 {
            XCTAssertEqual(mesh.positions[i].x, positions[i].x, accuracy: 1e-6)
            XCTAssertEqual(mesh.positions[i].y, positions[i].y, accuracy: 1e-6)
            XCTAssertEqual(mesh.positions[i].z, positions[i].z, accuracy: 1e-6)
        }
        XCTAssertEqual(mesh.indices, indices)
        XCTAssertEqual(mesh.normals?.count, 4)
        XCTAssertEqual(mesh.colors?.first, SIMD3<UInt8>(255, 0, 0))
        XCTAssertEqual(mesh.colors?.last, SIMD3<UInt8>(9, 9, 9))
    }

    func testAGlbWithNoNormalsOrColoursIsStillReadable() throws {
        let url = try temporaryFile("bare.glb")
        defer { try? FileManager.default.removeItem(at: url) }
        try Exporters.writeGlb(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            normals: nil,
            colors: nil,
            indices: [0, 1, 2],
            to: url)

        let mesh = try GlbReader.read(contentsOf: url)
        XCTAssertEqual(mesh.positions.count, 3)
        XCTAssertNil(mesh.normals)
        XCTAssertNil(mesh.colors)
        XCTAssertEqual(mesh.indices, [0, 1, 2])
    }

    /// Every refusal names what it found. A reader that returns an empty mesh
    /// for a broken file produces a bundle that looks exported and is not.
    func testBrokenFilesAreRefusedWithSomethingReadable() throws {
        XCTAssertThrowsError(try GlbReader.read(Data([1, 2, 3, 4]))) { error in
            XCTAssertEqual(error as? GlbReadError, .notGlb)
        }

        let url = try temporaryFile("truncated.glb")
        defer { try? FileManager.default.removeItem(at: url) }
        try Exporters.writeGlb(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            normals: nil, colors: nil, indices: [0, 1, 2], to: url)

        // A transfer that stopped half way: the header still declares the
        // length the file was supposed to be.
        let whole = try Data(contentsOf: url)
        let half = whole.subdata(in: 0..<(whole.count / 2))
        XCTAssertThrowsError(try GlbReader.read(half)) { error in
            guard let read = error as? GlbReadError else { return XCTFail("\(error)") }
            XCTAssertTrue("\(read)".contains("did not complete") || "\(read)".contains("no mesh"),
                          "unhelpful message: \(read)")
        }

        // A version this reader does not speak is named rather than guessed at.
        var wrongVersion = whole
        wrongVersion.replaceSubrange(4..<8, with: [3, 0, 0, 0])
        XCTAssertThrowsError(try GlbReader.read(wrongVersion)) { error in
            XCTAssertEqual(error as? GlbReadError, .unsupportedVersion(3))
        }
    }

    // MARK: - Placing it

    /// The whole chain, end to end: take a control point, express it the way it
    /// would appear inside `ar-model.glb`, push it through the placement
    /// transform, and it has to land exactly where that point was observed in
    /// the room.
    ///
    /// This is the check that a wrong turn or a dropped offset cannot survive —
    /// each of the four steps moves the answer somewhere obvious on its own,
    /// and only the correct composition puts it back.
    func testAModelVertexLandsWhereItsPointWasObserved() throws {
        let pointsOffset: [Double] = [0, 0, 0]
        let modelOffset: [Double] = [100, 200, 5]

        // Two column marks, in the point set's frame (Z-up) and as observed in
        // the capture's frame (ARKit, Y-up).
        let observed = [
            SIMD3<Double>(0.0, 1.2, 0.0),
            SIMD3<Double>(5.1, 1.2, -3.87),
        ]
        let heading = 0.9773844
        let shift = SIMD3<Double>(104.25, -58.5, 12.4)

        var pairs: [ControlPair] = []
        for (index, o) in observed.enumerated() {
            pairs.append(ControlPair(
                project: projectFrom(o, heading: heading, shift: shift),
                observed: o,
                id: "P00\(index + 1)"))
        }

        let solution = try solveGravityConstrained(
            pairs, projectUp: GravityFrame.up(forAxis: "Z"))
        XCTAssertEqual(solution.rmsError, 0, accuracy: 1e-9)

        let placement = ArModelPlacement.worldFromModel(
            solution: solution,
            pointsAppliedOffset: pointsOffset,
            modelAppliedOffset: modelOffset)

        for pair in pairs {
            // The same point as it appears inside the GLB: shifted from the
            // point frame into the AR bundle's frame, then turned Z-up to Y-up
            // the way the exporter turns it.
            let inBundle = pair.project + vector(pointsOffset) - vector(modelOffset)
            let inGlb = SIMD3<Double>(inBundle.x, inBundle.z, -inBundle.y)

            let drawn = ArModelPlacement.apply(placement, to: inGlb)
            XCTAssertEqual(drawn.x, pair.observed.x, accuracy: 1e-8)
            XCTAssertEqual(drawn.y, pair.observed.y, accuracy: 1e-8)
            XCTAssertEqual(drawn.z, pair.observed.z, accuracy: 1e-8)
        }
    }

    func testTheInverseOfARigidSolveIsExact() throws {
        // The pairs have to be consistent with *some* rigid transform, or the
        // solve has residuals and no inverse can return the observations
        // exactly. Generated from a known one rather than typed out.
        let observed = [
            SIMD3<Double>(0, 0, 0),
            SIMD3<Double>(4, 0, 0),
            SIMD3<Double>(0, 0, -6),
        ]
        var pairs: [ControlPair] = []
        for (index, o) in observed.enumerated() {
            pairs.append(ControlPair(
                project: projectFrom(o, heading: 0.37, shift: SIMD3<Double>(10, 20, 30)),
                observed: o,
                id: "P\(index)"))
        }

        let solution = try solveGravityConstrained(pairs, projectUp: GravityFrame.up(forAxis: "Z"))
        XCTAssertEqual(solution.rmsError, 0, accuracy: 1e-9)
        let inverse = ArModelPlacement.inverseRigid(solution)

        for pair in pairs {
            let back = ArModelPlacement.apply(inverse, to: pair.project)
            XCTAssertEqual(back.x, pair.observed.x, accuracy: 1e-9)
            XCTAssertEqual(back.y, pair.observed.y, accuracy: 1e-9)
            XCTAssertEqual(back.z, pair.observed.z, accuracy: 1e-9)
        }
    }

    func testMultiplyAppliesTheRightOperandFirst() {
        let first = ArModelPlacement.translation(SIMD3<Double>(1, 0, 0))
        let then = ArModelPlacement.compose(
            rotation: Quat.fromAxisAngle(SIMD3<Double>(0, 0, 1), .pi / 2),
            translation: SIMD3<Double>(0, 0, 0))

        let composed = ArModelPlacement.multiply(then, first)
        let stepwise = ArModelPlacement.apply(then, to: ArModelPlacement.apply(first, to: .zero))
        let direct = ArModelPlacement.apply(composed, to: .zero)

        XCTAssertEqual(direct.x, stepwise.x, accuracy: 1e-12)
        XCTAssertEqual(direct.y, stepwise.y, accuracy: 1e-12)
        // Translating along +X and then turning a quarter turn about +Z lands
        // on +Y. The other order would land on +X.
        XCTAssertEqual(direct.x, 0, accuracy: 1e-12)
        XCTAssertEqual(direct.y, 1, accuracy: 1e-12)
    }

    // MARK: - What can and cannot be drawn

    func testReadinessNamesTheThingThatIsMissing() throws {
        let set = NavPointSet(
            setId: "abc", setName: "L01",
            provenance: NavProvenance(sourceDocument: "T.nwd", sourceUnits: "Meters"),
            points: [NavPoint(id: "P001", label: "", position: [0, 0, 0])])

        XCTAssertEqual(
            ArModelPlacement.readiness(hasGeometry: false, pointSet: set, located: 4, solved: nil),
            .noGeometry)
        XCTAssertEqual(
            ArModelPlacement.readiness(hasGeometry: true, pointSet: nil, located: 4, solved: nil),
            .noPointSet)
        XCTAssertEqual(
            ArModelPlacement.readiness(hasGeometry: true, pointSet: set, located: 1, solved: nil),
            .notEnoughPoints(located: 1))

        // The one-point message says what one point cannot do, which is the
        // part an operator can act on.
        let one = ArModelPlacement.Readiness.notEnoughPoints(located: 1)
        XCTAssertTrue(one.summary.contains("which way it faces"))
        XCTAssertFalse(one.canDraw)

        let ready = ArModelPlacement.Readiness.ready(pointCount: 4, rmsError: 0.0042)
        XCTAssertTrue(ready.canDraw)
        // The RMS travels with the claim: an overlay is only as good as its fit.
        XCTAssertTrue(ready.summary.contains("4 mm RMS"), ready.summary)
    }

    // MARK: - Helpers

    private func projectFrom(
        _ observed: SIMD3<Double>,
        heading: Double,
        shift: SIMD3<Double>
    ) -> SIMD3<Double> {
        let x = observed.x
        let y = -observed.z
        let z = observed.y
        let c: Double = cos(heading)
        let s: Double = sin(heading)
        return SIMD3<Double>(x * c - y * s + shift.x,
                             x * s + y * c + shift.y,
                             z + shift.z)
    }

    private func vector(_ v: [Double]) -> SIMD3<Double> {
        SIMD3<Double>(v[0], v[1], v[2])
    }

    private func temporaryFile(_ name: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ar-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }
}
