import Foundation
import XCTest
import simd
@testable import PIXMYD

/// Points placed on the phone, and the solve that two of them are enough for.
///
/// The registration vectors here are the same ones
/// `PIXMYD-Nav/tools/writer-tests/AlignmentTests.cs` uses. Two implementations
/// of one closed form can only stay honest against the same numbers, and this
/// is the arithmetic that decides where a scan lands — a sign error in it
/// produces a placement that looks plausible on screen and is wrong on site.
final class FieldPointTests: XCTestCase {

    // MARK: - The two-point solve

    /// Two column marks, a known heading and a known shift. The solve has to
    /// return exactly what was applied; anything less than exact here is a sign
    /// error, not a tolerance question.
    func testTwoPointsRecoverAKnownTransform() throws {
        let observed = [
            SIMD3<Double>(0.0, 1.2, 0.0),
            SIMD3<Double>(5.1, 1.2, -3.87),
        ]
        let heading = 0.9773844                       // 56 degrees
        let shift = SIMD3<Double>(104.25, -58.5, 12.4)

        var pairs: [ControlPair] = []
        for (index, o) in observed.enumerated() {
            pairs.append(ControlPair(
                project: applyKnown(o, heading: heading, shift: shift),
                observed: o,
                id: "P00\(index + 1)"))
        }

        let solved = try solveGravityConstrained(
            pairs, projectUp: GravityFrame.up(forAxis: "Z"))

        XCTAssertTrue(solved.verticalHeld)
        XCTAssertEqual(solved.pairCount, 2)
        XCTAssertEqual(solved.rmsError, 0, accuracy: 1e-9)
        XCTAssertEqual(solved.scale, 1.0, accuracy: 1e-12)

        // The transform has to map the observations onto the project
        // coordinates, not merely have a small residual.
        for pair in pairs {
            let mapped = applyTransform(
                rotation: solved.rotation,
                translation: solved.translation,
                scale: solved.scale,
                pair.observed)
            XCTAssertEqual(mapped.x, pair.project.x, accuracy: 1e-9)
            XCTAssertEqual(mapped.y, pair.project.y, accuracy: 1e-9)
            XCTAssertEqual(mapped.z, pair.project.z, accuracy: 1e-9)
        }
    }

    func testOnePointAndAVerticalBaselineAreBothRefused() {
        let one = [ControlPair(project: SIMD3<Double>(1, 2, 3), observed: SIMD3<Double>(0, 0, 0))]
        XCTAssertThrowsError(try solveGravityConstrained(one)) { error in
            guard case RegistrationError.tooFewPairsForGravity = error else {
                return XCTFail("expected tooFewPairsForGravity, got \(error)")
            }
        }

        // Two points stacked vertically: nothing constrains the heading, and an
        // arbitrary answer is worse than a refusal.
        let stacked = [
            ControlPair(project: SIMD3<Double>(10, 20, 0), observed: SIMD3<Double>(0, 0, 0)),
            ControlPair(project: SIMD3<Double>(10, 20, 3), observed: SIMD3<Double>(0, 3, 0)),
        ]
        XCTAssertThrowsError(
            try solveGravityConstrained(stacked, projectUp: GravityFrame.up(forAxis: "Z"))
        ) { error in
            guard case RegistrationError.verticalBaseline = error else {
                return XCTFail("expected verticalBaseline, got \(error)")
            }
            XCTAssertTrue("\(error)".contains("floor"), "the refusal must say what to do about it")
        }
    }

    /// On control that is level and clean, holding the vertical must land in
    /// the same place Horn's unconstrained solve does. If the two disagree on
    /// easy data, one of them has a convention wrong.
    func testTheTwoSolversAgreeOnCleanControl() throws {
        let observed = [
            SIMD3<Double>(0.0, 0.0, 0.0),
            SIMD3<Double>(8.2, 0.0, -1.5),
            SIMD3<Double>(3.1, 0.0, -7.4),
            SIMD3<Double>(9.6, 2.7, -6.1),
        ]
        let heading = -1.2217305                      // -70 degrees
        let shift = SIMD3<Double>(-12.0, 340.5, 61.25)

        var pairs: [ControlPair] = []
        for (index, o) in observed.enumerated() {
            pairs.append(ControlPair(
                project: applyKnown(o, heading: heading, shift: shift),
                observed: o,
                id: "P\(index)"))
        }

        let constrained = try solveGravityConstrained(
            pairs, projectUp: GravityFrame.up(forAxis: "Z"))
        let horn = try solveRigidTransform(pairs)

        XCTAssertEqual(constrained.rmsError, 0, accuracy: 1e-9)
        XCTAssertEqual(horn.rmsError, 0, accuracy: 1e-6)
        for i in 0..<16 {
            XCTAssertEqual(constrained.matrix[i], horn.matrix[i], accuracy: 1e-6,
                           "the two solvers disagree at element \(i)")
        }
    }

    /// The point of the constraint: when one observation is out in the
    /// vertical, an unconstrained solve tilts the whole scan to absorb it and
    /// the constrained one does not. The larger number is the honest one.
    func testHoldingTheVerticalReportsABlunderHornAbsorbs() throws {
        let observed = [
            SIMD3<Double>(0.0, 0.0, 0.0),
            SIMD3<Double>(9.0, 0.0, 0.0),
            SIMD3<Double>(0.0, 0.0, -9.0),
        ]
        var pairs: [ControlPair] = []
        for (index, o) in observed.enumerated() {
            pairs.append(ControlPair(
                project: applyKnown(o, heading: 0, shift: SIMD3<Double>(0, 0, 0)),
                observed: o,
                id: "P\(index)"))
        }
        // Push one observation 80 mm up: a bad aim on a ceiling mark.
        pairs[2] = ControlPair(project: pairs[2].project,
                               observed: SIMD3<Double>(0.0, 0.08, -9.0),
                               id: pairs[2].id)

        let constrained = try solveGravityConstrained(
            pairs, projectUp: GravityFrame.up(forAxis: "Z"))
        let horn = try solveRigidTransform(pairs)

        XCTAssertGreaterThan(constrained.rmsError, horn.rmsError)

        // And the model's vertical must come out of the solve untouched.
        let up = constrained.rotation.rotate(GravityFrame.captureUp)
        XCTAssertEqual(up.x, 0, accuracy: 1e-9)
        XCTAssertEqual(up.y, 0, accuracy: 1e-9)
        XCTAssertEqual(up.z, 1, accuracy: 1e-9)
    }

    func testSolveBestAvailablePicksTheMethodTheDataSupports() throws {
        var three: [ControlPair] = []
        for i in 0..<3 {
            let across: Double = Double(i) * 4
            let along: Double = Double(i * i)
            three.append(ControlPair(
                project: SIMD3<Double>(across, along, 0),
                observed: SIMD3<Double>(across, 0, -along),
                id: "P\(i)"))
        }
        XCTAssertFalse(try solveBestAvailable(three, projectUp: GravityFrame.up(forAxis: "Z")).verticalHeld)
        XCTAssertTrue(try solveBestAvailable(three,
                                             projectUp: GravityFrame.up(forAxis: "Z"),
                                             forceGravity: true).verticalHeld)
        XCTAssertTrue(try solveBestAvailable(Array(three.prefix(2)),
                                             projectUp: GravityFrame.up(forAxis: "Z")).verticalHeld)
    }

    // MARK: - The set

    func testIdsAreNumberedFromTheHighestNotFromTheCount() {
        var set = FieldPointSet()
        XCTAssertEqual(set.nextId(), "P001")

        _ = set.place(at: SIMD3<Double>(0, 0, 0), source: .mesh, range: 1)
        _ = set.place(at: SIMD3<Double>(1, 0, 0), source: .mesh, range: 1)
        _ = set.place(at: SIMD3<Double>(2, 0, 0), source: .mesh, range: 1)
        XCTAssertEqual(set.points.map(\.id), ["P001", "P002", "P003"])

        // Deleting P002 must not make the next point P003 as well: a number
        // that has been written on a wall is spent.
        set.remove(id: "P002")
        XCTAssertEqual(set.nextId(), "P004")
    }

    func testBaselineIsTheWidestSeparationNotTheFirstPair() {
        var set = FieldPointSet()
        _ = set.place(at: SIMD3<Double>(0, 0, 0), source: .mesh, range: 1)
        _ = set.place(at: SIMD3<Double>(0, 0, 1), source: .mesh, range: 1)
        XCTAssertEqual(set.baselineMetres, 1, accuracy: 1e-9)

        // The widest separation is P001–P003, not the pair that was placed
        // first and not the last one added.
        _ = set.place(at: SIMD3<Double>(0, 0, 12), source: .mesh, range: 1)
        XCTAssertEqual(set.baselineMetres, 12, accuracy: 1e-9)

        XCTAssertEqual(FieldPointSet().baselineMetres, 0)
    }

    func testTwoPointsIsTheThresholdForRegistering() {
        var set = FieldPointSet()
        XCTAssertFalse(set.canRegister)
        _ = set.place(at: SIMD3<Double>(0, 0, 0), source: .mesh, range: 1)
        XCTAssertFalse(set.canRegister)
        _ = set.place(at: SIMD3<Double>(4, 0, 0), source: .mesh, range: 1)
        XCTAssertTrue(set.canRegister)
    }

    /// The readiness line is shown while the operator is still standing in the
    /// space, which is the only moment it can be acted on. It has to say
    /// something different for each state rather than one hedge for all of them.
    func testReadinessSaysSomethingDifferentAtEachStage() {
        var set = FieldPointSet()
        XCTAssertTrue(CaptureExport.registrationReadiness(set).contains("No points placed"))

        _ = set.place(at: SIMD3<Double>(0, 0, 0), source: .mesh, range: 1)
        XCTAssertTrue(CaptureExport.registrationReadiness(set).contains("which way it faces"))

        _ = set.place(at: SIMD3<Double>(6, 0, 0), source: .plane, range: 4)
        let two = CaptureExport.registrationReadiness(set)
        XCTAssertTrue(two.contains("no redundancy"))
        // An estimated point is called out: it is worth a decimetre and the
        // residual will not say so.
        XCTAssertTrue(two.contains("estimated surface"))

        _ = set.place(at: SIMD3<Double>(0, 0, 5), source: .mesh, range: 2)
        _ = set.place(at: SIMD3<Double>(6, 0, 5), source: .mesh, range: 2)
        XCTAssertTrue(CaptureExport.registrationReadiness(set).contains("identified"))
    }

    // MARK: - The contract file

    func testPointsJsonIsTheSameShapeTheWorkstationWrites() throws {
        var set = FieldPointSet(
            setId: "9ab41f2c-1111-2222-3333-444444444444",
            setName: "Level 2 plant room",
            createdUtc: Date(timeIntervalSince1970: 1_770_000_000))
        _ = set.place(at: SIMD3<Double>(1.25, -0.5, 3), source: .mesh, range: 0.8, label: "Door reveal")
        _ = set.place(at: SIMD3<Double>(4.0, -0.5, 3), source: .plane, range: 5.2)

        let json = set.renderPointsJson(sourceDocument: "Plant room walk")

        // contractVersion first: every consumer probes it before committing to
        // the rest of the schema.
        let firstKey = json.split(separator: "\n").first { $0.contains("\":") }
        XCTAssertTrue(firstKey?.contains("\"contractVersion\"") == true,
                      "got \(firstKey ?? "")")

        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(root["contractVersion"] as? String, "1.0")
        XCTAssertEqual(root["setId"] as? String, set.setId)
        XCTAssertEqual(root["setName"] as? String, "Level 2 plant room")

        let provenance = try XCTUnwrap(root["provenance"] as? [String: Any])
        // These are ARKit coordinates, not model coordinates, and three fields
        // say so. A consumer that read them as model coordinates would place a
        // scan at the origin and be confidently wrong.
        XCTAssertEqual(provenance["navex:originMode"] as? String, "CaptureOrigin")
        XCTAssertEqual(provenance["navex:upAxis"] as? String, "Y")
        XCTAssertEqual(provenance["pixmyd:frame"] as? String, "capture")
        XCTAssertEqual(provenance["navex:appliedOffset"] as? [Double], [0, 0, 0])

        let points = try XCTUnwrap(root["points"] as? [[String: Any]])
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0]["id"] as? String, "P001")
        XCTAssertEqual(points[0]["label"] as? String, "Door reveal")
        XCTAssertEqual(points[0]["position"] as? [Double], [1.25, -0.5, 3])
        XCTAssertEqual(points[0]["qrPayload"] as? String, "pixmy://p/9ab41f2c/P001")
        XCTAssertEqual(points[0]["pixmyd:source"] as? String, "mesh")
        XCTAssertEqual(points[1]["pixmyd:source"] as? String, "plane")
        XCTAssertEqual(points[1]["pixmyd:rangeMetres"] as? Double, 5.2)

        // Empty strings, never nulls, when there is no grid — and a phone has
        // no grid system at all.
        let grid = try XCTUnwrap(points[0]["grid"] as? [String: Any])
        XCTAssertEqual(grid["intersection"] as? String, "")
        XCTAssertEqual(grid["level"] as? String, "")

        // And the plugin's own reader has to take it unchanged.
        let decoded = try NavPointSet.decode(Data(json.utf8))
        XCTAssertEqual(decoded.setId, set.setId)
        XCTAssertEqual(decoded.points.count, 2)
        XCTAssertEqual(decoded.point(id: "P002")?.positionVector, SIMD3<Double>(4.0, -0.5, 3))
    }

    func testTheSetSurvivesBeingWrittenToAProjectAndReadBack() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("field-points-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNil(FieldPointSet.load(in: directory), "an empty project has no points")

        var set = FieldPointSet(setName: "Riser 4")
        _ = set.place(at: SIMD3<Double>(0.1, 0.2, 0.3), source: .mesh, range: 1.5)
        _ = set.place(at: SIMD3<Double>(2.1, 0.2, 0.3), source: .plane, range: 3.0)
        try set.save(in: directory)

        let back = try XCTUnwrap(FieldPointSet.load(in: directory))
        XCTAssertEqual(back.setId, set.setId)
        XCTAssertEqual(back.setName, "Riser 4")
        XCTAssertEqual(back.points.count, 2)
        XCTAssertEqual(back.points[0].position, SIMD3<Double>(0.1, 0.2, 0.3))
        XCTAssertEqual(back.points[1].source, .plane)
        XCTAssertEqual(back.points[1].range, 3.0)
    }

    // MARK: - The capture that carries them

    func testACaptureWithNoNavSetNamesThePhonesOwnPoints() throws {
        var set = FieldPointSet(setId: "cafe1234-0000-0000-0000-000000000000")
        _ = set.place(at: SIMD3<Double>(0, 1.2, 0), source: .mesh, range: 1.1)
        _ = set.place(at: SIMD3<Double>(5.1, 1.2, -3.87), source: .mesh, range: 2.4)

        let json = CaptureExport.render(
            CaptureExportRequest(
                captureId: "44e0b8a2-0000-0000-0000-000000000000",
                capturedUtc: Date(timeIntervalSince1970: 1_770_000_000),
                device: CaptureDevice(model: "iPhone17,2", hasLidar: true),
                pointSet: nil,
                fieldPoints: set,
                correspondences: set.correspondences,
                geometryBytes: 4_194_304
            ),
            solved: nil)

        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        // A capture always names the points it was taken against, whichever end
        // placed them.
        XCTAssertEqual(root["pointSetId"] as? String, set.setId)
        XCTAssertNil(root["solution"], "there is no model frame here to solve into")
        XCTAssertEqual((root["correspondences"] as? [[String: Any]])?.count, 2)

        let fieldPoints = try XCTUnwrap(root["fieldPoints"] as? [String: Any])
        XCTAssertEqual(fieldPoints["file"] as? String, "points.json")
        XCTAssertEqual(fieldPoints["count"] as? Int, 2)
        XCTAssertEqual(fieldPoints["setId"] as? String, set.setId)

        let provenance = try XCTUnwrap(root["provenance"] as? [String: Any])
        XCTAssertEqual(provenance["navex:originMode"] as? String, "CaptureOrigin")
        XCTAssertEqual(provenance["navex:appliedOffset"] as? [Double], [0, 0, 0])
        // The capture's own up axis, as opposed to the model's. The consumer
        // needs both to hold the vertical during a two-point solve.
        XCTAssertEqual(provenance["pixmyd:captureUpAxis"] as? String, "Y")
    }

    // MARK: - Helpers

    /// Map an ARKit (Y-up) observation into a Z-up project frame, rotate about
    /// the vertical by `heading`, and shift. The inverse of what the solve has
    /// to work out.
    private func applyKnown(
        _ observed: SIMD3<Double>,
        heading: Double,
        shift: SIMD3<Double>
    ) -> SIMD3<Double> {
        // Y-up to Z-up is the shortest arc from (0,1,0) to (0,0,1): a +90
        // degree turn about X, taking (x, y, z) to (x, -z, y).
        let x = observed.x
        let y = -observed.z
        let z = observed.y

        let c: Double = cos(heading)
        let s: Double = sin(heading)
        return SIMD3<Double>(x * c - y * s + shift.x,
                             x * s + y * c + shift.y,
                             z + shift.z)
    }
}
