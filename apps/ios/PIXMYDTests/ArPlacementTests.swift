import Foundation
import XCTest
import simd
@testable import PIXMYD

/// The three pieces that let a phone place things with no workstation in the
/// loop: a set it authored itself, a `.glb` it has to read without SceneKit's
/// help, and the four-degree-of-freedom fit that puts a model in a room.
///
/// All portable, so this runs on Linux CI where the arithmetic can be wrong in
/// ways nobody would notice by looking at a phone screen.
final class ArPlacementTests: XCTestCase {

    // MARK: - Points the phone places for itself

    func testALocalSetDeclaresItsOwnFrameAndMetres() {
        let set = NavPointSet.local(
            setId: "local-1", name: "Placed on site",
            device: "iPhone", createdUtc: "2026-08-23T10:00:00Z")

        // The flag PIXMYD-Nav's reader checks to know these are not model
        // coordinates. Without it the plugin would read AR positions as
        // surveyed ones and place a scan a building away.
        XCTAssertTrue(set.isCaptureFrame)
        XCTAssertEqual(set.provenance.frame, "capture")
        XCTAssertTrue(set.provenance.isMetric)
        XCTAssertEqual(set.provenance.upAxis, "Y")
        XCTAssertTrue(set.points.isEmpty)
    }

    func testIdsCountUpAndSurviveADeletion() {
        var set = NavPointSet.local(
            setId: "local-1", name: "x", device: "y", createdUtc: "z")
        XCTAssertEqual(set.nextLocalPointId, "P001")

        set = set.addingLocalPoint(at: SIMD3<Double>(1, 0, 0))
        set = set.addingLocalPoint(at: SIMD3<Double>(2, 0, 0))
        set = set.addingLocalPoint(at: SIMD3<Double>(3, 0, 0))
        XCTAssertEqual(set.points.map(\.id), ["P001", "P002", "P003"])

        // Removing the middle one must not hand P002 out again: the id is on a
        // printed page and in somebody's notes by then.
        set = set.removingPoint(id: "P002")
        XCTAssertEqual(set.nextLocalPointId, "P004")
        XCTAssertEqual(set.addingLocalPoint(at: SIMD3<Double>(4, 0, 0)).points.last?.id, "P004")
    }

    /// The file has to come back through the plugin's own reader shape, since
    /// "Seed phone points" parses it as an ordinary `points.json`.
    func testALocalSetRoundTripsThroughItsOwnJson() throws {
        var set = NavPointSet.local(
            setId: "local-1", name: "Placed on site",
            device: "iPhone15,2", createdUtc: "2026-08-23T10:00:00Z")
        set = set.addingLocalPoint(at: SIMD3<Double>(1.5, -0.25, 3))

        let data = try set.renderJson()
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(root["contractVersion"] as? String, "1.0")
        let provenance = try XCTUnwrap(root["provenance"] as? [String: Any])
        XCTAssertEqual(provenance["pixmyd:frame"] as? String, "capture")
        XCTAssertEqual(provenance["navex:targetUnits"] as? String, "Meters")

        let points = try XCTUnwrap(root["points"] as? [[String: Any]])
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0]["id"] as? String, "P001")
        XCTAssertEqual(points[0]["position"] as? [Double], [1.5, -0.25, 3])

        let decoded = try NavPointSet.decode(data)
        XCTAssertEqual(decoded, set)
    }

    /// An export that never set target units used to say "" and the phone
    /// called it wrong. The contract fixes metres, so silence is metres.
    func testSilenceAboutUnitsMeansMetres() {
        XCTAssertTrue(NavProvenance(sourceDocument: "a", sourceUnits: "", targetUnits: "").isMetric)
        XCTAssertTrue(NavProvenance(sourceDocument: "a", sourceUnits: "", targetUnits: "Meters").isMetric)
        XCTAssertFalse(NavProvenance(sourceDocument: "a", sourceUnits: "", targetUnits: "Feet").isMetric)
    }

    // MARK: - Placing a model in a room

    /// The whole promise of the solver: a model turned and moved by known
    /// amounts is recovered exactly, from marks that carry no error.
    func testAKnownTurnAndShiftIsRecovered() throws {
        let truthYaw = 0.7
        let truthShift = SIMD3<Double>(4, 1.5, -2)
        let modelPoints = [
            SIMD3<Double>(0, 0, 0),
            SIMD3<Double>(6, 0, 0),
            SIMD3<Double>(0, 3, 5),
        ]
        let anchors = modelPoints.enumerated().map { index, p in
            ArAnchor(
                pointId: "P\(index)",
                model: p,
                world: ArPlacement.rotateY(p, truthYaw) + truthShift)
        }

        let fit = try XCTUnwrap(ArPlacement.solve(anchors: anchors))
        XCTAssertEqual(fit.yaw, truthYaw, accuracy: 1e-9)
        XCTAssertEqual(fit.translation.x, truthShift.x, accuracy: 1e-9)
        XCTAssertEqual(fit.translation.y, truthShift.y, accuracy: 1e-9)
        XCTAssertEqual(fit.translation.z, truthShift.z, accuracy: 1e-9)
        XCTAssertEqual(fit.maxError, 0, accuracy: 1e-9)
    }

    /// One anchor pins the model without pretending to know its heading. The
    /// screen has to draw something after the first tap or nobody gets to a
    /// second one.
    func testOneAnchorPinsWithoutInventingAHeading() throws {
        let anchor = ArAnchor(
            pointId: "P001",
            model: SIMD3<Double>(2, 0, 1),
            world: SIMD3<Double>(10, 0, 10))

        let fit = try XCTUnwrap(ArPlacement.solve(anchors: [anchor], headingHint: 1.2))
        XCTAssertEqual(fit.yaw, 1.2, accuracy: 1e-12)

        // Whatever the heading, the anchored point lands where it was tapped.
        let placed = fit.apply(anchor.model)
        XCTAssertEqual(placed.x, anchor.world.x, accuracy: 1e-9)
        XCTAssertEqual(placed.y, anchor.world.y, accuracy: 1e-9)
        XCTAssertEqual(placed.z, anchor.world.z, accuracy: 1e-9)

        XCTAssertNil(ArPlacement.solve(anchors: []))
    }

    /// Marks stacked in one vertical line say nothing about heading. That is a
    /// fact about the marks, so the operator's own heading is kept rather than
    /// snapped to an arbitrary one.
    func testAVerticalStackLeavesTheHeadingAlone() throws {
        let anchors = [0.0, 1.0, 2.0].enumerated().map { index, height in
            ArAnchor(
                pointId: "P\(index)",
                model: SIMD3<Double>(0, height, 0),
                world: SIMD3<Double>(5, height, 7))
        }
        let fit = try XCTUnwrap(ArPlacement.solve(anchors: anchors, headingHint: -0.4))
        XCTAssertEqual(fit.yaw, -0.4, accuracy: 1e-12)
    }

    /// A nudge turns the model where it stands. Turning about the world origin
    /// instead would fling a building across the site for a small correction.
    func testANudgeTurnsAboutTheAnchorsAndNotTheOrigin() throws {
        let anchor = ArAnchor(
            pointId: "P001",
            model: SIMD3<Double>(0, 0, 0),
            world: SIMD3<Double>(30, 0, 40))
        let fit = try XCTUnwrap(ArPlacement.solve(anchors: [anchor]))

        let turned = fit.nudged(yaw: 0.3, by: SIMD3<Double>(repeating: 0))
        let stillThere = turned.apply(anchor.model)
        XCTAssertEqual(stillThere.x, 30, accuracy: 1e-9)
        XCTAssertEqual(stillThere.z, 40, accuracy: 1e-9)

        // And the fit's own numbers are untouched by an opinion.
        XCTAssertEqual(turned.residuals, fit.residuals)
    }

    // MARK: - Reading a .glb

    func testAMinimalGlbIsRead() throws {
        let positions: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0),
        ]
        let indices: [UInt32] = [0, 1, 2]
        let mesh = try GlbReader.read(Self.makeGlb(positions: positions, indices: indices))

        XCTAssertEqual(mesh.positions, positions)
        XCTAssertEqual(mesh.indices, indices)
        XCTAssertEqual(mesh.triangleCount, 1)
        XCTAssertNil(mesh.normals)
        let bounds = try XCTUnwrap(mesh.bounds)
        XCTAssertEqual(bounds.min, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(bounds.max, SIMD3<Float>(1, 1, 0))
    }

    /// The failures a field user can actually hit: something that is not a
    /// GLB, and a download that stopped early. Both have to name themselves.
    func testBadFilesAreNamedRatherThanDrawnAsNothing() {
        XCTAssertThrowsError(try GlbReader.read(Data("not a model at all".utf8))) { error in
            XCTAssertEqual(error as? GlbReadError, .notGlb)
        }

        let whole = Self.makeGlb(
            positions: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)],
            indices: [0, 1, 2])
        let cut = whole.prefix(whole.count - 8)
        XCTAssertThrowsError(try GlbReader.read(Data(cut)))
    }

    /// An index past the end of the vertex list would be a GPU crash later, so
    /// it is refused here where the message can still say why.
    func testAnIndexPastTheEndIsRefused() {
        let data = Self.makeGlb(
            positions: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)],
            indices: [0, 1, 9])
        XCTAssertThrowsError(try GlbReader.read(data))
    }

    // MARK: - Crossing from points.json into the AR model's frame

    /// The offset is in the source document's frame and the turn happens after
    /// it. Doing them the other way round looks nearly right and lands the
    /// model a building's height out.
    func testASurveyPointCrossesIntoTheModelFrame() throws {
        let set = NavPointSet(
            setId: "s", setName: "s",
            provenance: NavProvenance(
                sourceDocument: "TowerA.nwd", sourceUnits: "Meters",
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

    // MARK: - A GLB, built the way the plugin builds one

    /// Positions, indices, one mesh, one buffer — `GlbWriter.cs`'s whole
    /// output, assembled here so the reader is tested against the shape it
    /// will actually be handed.
    private static func makeGlb(positions: [SIMD3<Float>], indices: [UInt32]) -> Data {
        var binary = Data()
        for p in positions {
            for value in [p.x, p.y, p.z] {
                withUnsafeBytes(of: value.bitPattern.littleEndian) { binary.append(contentsOf: $0) }
            }
        }
        let positionLength = binary.count
        for index in indices {
            withUnsafeBytes(of: index.littleEndian) { binary.append(contentsOf: $0) }
        }
        let indexLength = binary.count - positionLength

        let json: [String: Any] = [
            "asset": ["version": "2.0"],
            "meshes": [["primitives": [[
                "attributes": ["POSITION": 0],
                "indices": 1,
                "mode": 4,
            ]]]],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": positions.count, "type": "VEC3"],
                ["bufferView": 1, "componentType": 5125, "count": indices.count, "type": "SCALAR"],
            ],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": positionLength],
                ["buffer": 0, "byteOffset": positionLength, "byteLength": indexLength],
            ],
            "buffers": [["byteLength": binary.count]],
        ]
        var jsonData = try! JSONSerialization.data(withJSONObject: json)
        // Both chunks are padded to four bytes, JSON with spaces and the buffer
        // with zeroes, exactly as the spec requires and the writer does.
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }
        while binary.count % 4 != 0 { binary.append(0) }

        var out = Data()
        func u32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        u32(0x4674_6C67)
        u32(2)
        u32(UInt32(12 + 8 + jsonData.count + 8 + binary.count))
        u32(UInt32(jsonData.count))
        u32(0x4E4F_534A)
        out.append(jsonData)
        u32(UInt32(binary.count))
        u32(0x004E_4942)
        out.append(binary)
        return out
    }
}
