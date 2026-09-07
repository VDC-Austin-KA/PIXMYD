import Foundation
import XCTest
import simd
@testable import PIXMYD

/// The hand-placement path: the four-degree-of-freedom fit that puts a model in
/// a room from one anchor upwards, and the frame conversion that gets a survey
/// point into the AR model's coordinates in the first place.
///
/// Portable, so it runs on Linux CI — which matters more here than usual,
/// because every one of these is a way to be wrong by a whole building without
/// anything looking wrong on screen.
final class ArHandPlacementTests: XCTestCase {

    // MARK: - The fit

    /// The whole promise: a model turned and moved by known amounts is
    /// recovered exactly, from marks that carry no error.
    func testAKnownTurnAndShiftIsRecovered() throws {
        let truthYaw = 0.7
        let truthShift = SIMD3<Double>(4, 1.5, -2)
        let modelPoints = [
            SIMD3<Double>(0, 0, 0),
            SIMD3<Double>(6, 0, 0),
            SIMD3<Double>(0, 3, 5),
        ]
        let anchors = modelPoints.enumerated().map { index, p in
            ArHandAnchor(pointId: "P\(index)",
                         model: p,
                         world: ArHandPlacement.rotateY(p, truthYaw) + truthShift)
        }

        let fit = try XCTUnwrap(ArHandPlacement.solve(anchors: anchors))
        XCTAssertEqual(fit.yaw, truthYaw, accuracy: 1e-9)
        XCTAssertEqual(fit.translation.x, truthShift.x, accuracy: 1e-9)
        XCTAssertEqual(fit.translation.y, truthShift.y, accuracy: 1e-9)
        XCTAssertEqual(fit.translation.z, truthShift.z, accuracy: 1e-9)
        XCTAssertEqual(fit.maxError, 0, accuracy: 1e-9)
    }

    /// One anchor pins the model without pretending to know its heading. The
    /// screen has to draw something after the first tap, or nobody gets to a
    /// second one.
    func testOneAnchorPinsWithoutInventingAHeading() throws {
        let anchor = ArHandAnchor(pointId: "P001",
                                  model: SIMD3<Double>(2, 0, 1),
                                  world: SIMD3<Double>(10, 0, 10))

        let fit = try XCTUnwrap(ArHandPlacement.solve(anchors: [anchor], headingHint: 1.2))
        XCTAssertEqual(fit.yaw, 1.2, accuracy: 1e-12)

        // Whatever the heading, the anchored point lands where it was tapped.
        let placed = fit.apply(anchor.model)
        XCTAssertEqual(placed.x, anchor.world.x, accuracy: 1e-9)
        XCTAssertEqual(placed.y, anchor.world.y, accuracy: 1e-9)
        XCTAssertEqual(placed.z, anchor.world.z, accuracy: 1e-9)

        XCTAssertNil(ArHandPlacement.solve(anchors: []))
    }

    /// Marks stacked in one vertical line say nothing about heading. That is a
    /// fact about the marks, not a failure, so the operator's own heading
    /// survives rather than being snapped to an arbitrary one.
    func testAVerticalStackLeavesTheHeadingAlone() throws {
        let anchors = [0.0, 1.0, 2.0].enumerated().map { index, height in
            ArHandAnchor(pointId: "P\(index)",
                         model: SIMD3<Double>(0, height, 0),
                         world: SIMD3<Double>(5, height, 7))
        }
        let fit = try XCTUnwrap(ArHandPlacement.solve(anchors: anchors, headingHint: -0.4))
        XCTAssertEqual(fit.yaw, -0.4, accuracy: 1e-12)
    }

    /// A nudge turns the model where it stands. Turning about the world origin
    /// instead would fling a building across the site for a small correction.
    func testANudgeTurnsAboutTheAnchorsAndNotTheOrigin() throws {
        let anchor = ArHandAnchor(pointId: "P001",
                                  model: SIMD3<Double>(0, 0, 0),
                                  world: SIMD3<Double>(30, 0, 40))
        let fit = try XCTUnwrap(ArHandPlacement.solve(anchors: [anchor]))

        let turned = fit.nudged(yaw: 0.3, by: SIMD3<Double>(repeating: 0))
        let stillThere = turned.apply(anchor.model)
        XCTAssertEqual(stillThere.x, 30, accuracy: 1e-9)
        XCTAssertEqual(stillThere.z, 40, accuracy: 1e-9)

        // And the fit's own numbers are untouched by an opinion.
        XCTAssertEqual(turned.residuals, fit.residuals)
    }

    /// The matrix has to agree with `apply`, because the screen draws through
    /// one and reasons through the other.
    func testTheMatrixAgreesWithApply() throws {
        let anchors = [
            ArHandAnchor(pointId: "A", model: SIMD3<Double>(1, 2, 3), world: SIMD3<Double>(9, 2, 1)),
            ArHandAnchor(pointId: "B", model: SIMD3<Double>(5, 2, 3), world: SIMD3<Double>(9, 2, 5)),
        ]
        let fit = try XCTUnwrap(ArHandPlacement.solve(anchors: anchors))
        let m = fit.matrix
        XCTAssertEqual(m.count, 16)

        for probe in [SIMD3<Double>(0, 0, 0), SIMD3<Double>(3, -1, 7), SIMD3<Double>(-2, 4, 0)] {
            let byApply = fit.apply(probe)
            // Column-major: m[c * 4 + r].
            let byMatrix = SIMD3<Double>(
                m[0] * probe.x + m[4] * probe.y + m[8] * probe.z + m[12],
                m[1] * probe.x + m[5] * probe.y + m[9] * probe.z + m[13],
                m[2] * probe.x + m[6] * probe.y + m[10] * probe.z + m[14])
            XCTAssertEqual(byMatrix.x, byApply.x, accuracy: 1e-9)
            XCTAssertEqual(byMatrix.y, byApply.y, accuracy: 1e-9)
            XCTAssertEqual(byMatrix.z, byApply.z, accuracy: 1e-9)
        }
    }

    // MARK: - Crossing frames

    /// The offset is in the source document's frame and the turn happens after
    /// it. Doing them the other way round looks nearly right and lands the
    /// model a building's height out.
    func testASurveyPointCrossesIntoTheModelFrame() throws {
        let set = NavPointSet(
            setId: "s", setName: "s",
            provenance: NavProvenance(sourceDocument: "TowerA.nwd",
                                      sourceUnits: "Meters",
                                      appliedOffset: [100, 200, 0]),
            points: [NavPoint(id: "P001", label: "", position: [1, 2, 3])])

        let json: [String: Any] = [
            "contractVersion": "1.0",
            "modelId": "m",
            "modelName": "TowerA",
            "provenance": [
                "navex:targetUnits": "Meters",
                "navex:upAxis": "Y",
                "navex:sourceUpAxis": "Z",
                "navex:appliedOffset": [10.0, 20.0, 0.0],
            ],
        ]
        let ar = try NavArBundle.decode(try JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(ar.provenance.turnedToYUp)

        // Source world (101, 202, 3), minus the AR offset (10, 20, 0) is
        // (91, 182, 3); the turn sends (x, y, z) to (x, z, -y).
        let placed = ar.modelFrame(of: set.points[0], in: set)
        XCTAssertEqual(placed.x, 91, accuracy: 1e-9)
        XCTAssertEqual(placed.y, 3, accuracy: 1e-9)
        XCTAssertEqual(placed.z, -182, accuracy: 1e-9)
    }

    /// A Y-up document was never turned, so the offset is all there is to undo.
    func testAYUpDocumentIsNotTurned() throws {
        let set = NavPointSet(
            setId: "s", setName: "s",
            provenance: NavProvenance(sourceDocument: "d", sourceUnits: "Meters",
                                      appliedOffset: [0, 0, 0]),
            points: [NavPoint(id: "P001", label: "", position: [1, 2, 3])])

        let json: [String: Any] = [
            "contractVersion": "1.0", "modelId": "m", "modelName": "n",
            "provenance": ["navex:upAxis": "Y", "navex:sourceUpAxis": "Y",
                           "navex:appliedOffset": [0.0, 0.0, 0.0]],
        ]
        let ar = try NavArBundle.decode(try JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(ar.provenance.turnedToYUp)

        let placed = ar.modelFrame(of: set.points[0], in: set)
        XCTAssertEqual(placed.y, 2, accuracy: 1e-9)
        XCTAssertEqual(placed.z, 3, accuracy: 1e-9)
    }

    // MARK: - Units

    /// An export that never set target units used to say "" and the phone
    /// called it wrong in front of the user. The contract fixes metres, so
    /// silence is metres.
    func testSilenceAboutUnitsMeansMetres() {
        XCTAssertTrue(NavProvenance(sourceDocument: "a", sourceUnits: "", targetUnits: "").isMetric)
        XCTAssertTrue(NavProvenance(sourceDocument: "a", sourceUnits: "", targetUnits: "Meters").isMetric)
        XCTAssertTrue(NavProvenance(sourceDocument: "a", sourceUnits: "", targetUnits: "m").isMetric)
        XCTAssertFalse(NavProvenance(sourceDocument: "a", sourceUnits: "", targetUnits: "Feet").isMetric)
    }

    /// Absent `sourceUpAxis` reads as Z, because Navisworks documents are Z-up
    /// unless someone has gone out of their way — and bundles exported before
    /// the field existed still have to place correctly.
    func testAnAbsentSourceUpAxisReadsAsZ() throws {
        let json: [String: Any] = [
            "contractVersion": "1.0", "modelId": "m", "modelName": "n",
            "provenance": ["navex:upAxis": "Y"],
        ]
        let ar = try NavArBundle.decode(try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(ar.provenance.sourceUpAxis, "")
        XCTAssertTrue(ar.provenance.turnedToYUp)
    }
}
