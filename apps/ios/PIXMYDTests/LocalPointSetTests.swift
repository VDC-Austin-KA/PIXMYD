import Foundation
import XCTest
import simd
@testable import PIXMYD

/// Points the phone authored itself, with no workstation in the loop.
///
/// This is what is left of `ArPlacementTests` after the duplicate AR solver and
/// the duplicate `.glb` reader were removed: those tests are in
/// `ArHandPlacementTests` and `ArModelTests`, but nothing else covered a set
/// the phone wrote for itself, and `SiteStore` builds one on every field point.
///
/// Portable, so it runs on Linux CI where the arithmetic can be wrong in ways
/// nobody would notice by looking at a phone screen.
final class LocalPointSetTests: XCTestCase {

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
}
