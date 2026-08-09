import Foundation
import XCTest
import simd
@testable import PIXMYD

/// The bundle schema is a contract between this app and the web studio, so what
/// is tested here is the *JSON*, not the Swift values. A round trip through
/// Codable proves Swift agrees with itself; it proves nothing about whether
/// `packages/core/src/bundle.ts` can read the file.
final class CaptureBundleTests: XCTestCase {

    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Camera models

    func testCameraModelEncodesAsABareTaggedObject() throws {
        // Swift's default enum encoding would nest this as {"pinhole": {...}}.
        // The TypeScript side is a discriminated union on `model`, so the
        // wrapper has to be gone and the tag has to be present.
        let camera = CameraModel.pinhole(.init(
            width: 1920, height: 1440,
            fx: 1450.5, fy: 1450.5, cx: 960, cy: 720,
            k1: -0.02, k2: 0.001, k3: nil, p1: nil, p2: nil
        ))
        let object = try json(camera)

        XCTAssertNil(object["pinhole"], "enum case name leaked into the JSON")
        XCTAssertEqual(object["model"] as? String, "pinhole")
        XCTAssertEqual(object["width"] as? Int, 1920)
        XCTAssertEqual(object["fx"] as? Double, 1450.5)
        XCTAssertEqual(object["k1"] as? Double, -0.02)
        // Absent rather than null: the TypeScript treats the coefficient as
        // unknown, and `null` would decode to 0 in a loose reader.
        XCTAssertNil(object["k3"])
    }

    func testEveryCameraModelRoundTripsThroughItsTag() throws {
        let models: [CameraModel] = [
            .pinhole(.init(width: 4, height: 3, fx: 1, fy: 1, cx: 2, cy: 1.5)),
            .fisheye(.init(width: 4, height: 4, fx: 1, fy: 1, cx: 2, cy: 2, k1: 0.1)),
            .equirect(.init(width: 8, height: 4, hfov: 360, vfov: 180)),
        ]
        for model in models {
            let data = try JSONEncoder().encode(model)
            XCTAssertEqual(try JSONDecoder().decode(CameraModel.self, from: data), model)
        }
    }

    func testUnknownCameraModelIsRejected() {
        let data = Data(#"{"model":"orthographic","width":4,"height":4}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CameraModel.self, from: data)) { error in
            // Silently defaulting to pinhole would reconstruct the scene with
            // the wrong projection and never say so.
            XCTAssertTrue(error is DecodingError)
        }
    }

    // MARK: - Pose

    func testPoseStoresQuaternionXyzwAndTranslationInMetres() throws {
        // 90 degrees about +Y. Written out by hand so the test does not depend
        // on the same quaternion helper the app uses.
        let halfRoot2 = Float(2).squareRoot() / 2
        let pose = Pose(
            translation: SIMD3<Float>(1.5, -2.25, 3),
            rotation: simd_quatf(ix: 0, iy: halfRoot2, iz: 0, r: halfRoot2)
        )

        XCTAssertEqual(pose.t, [1.5, -2.25, 3])
        // [x, y, z, w] — glTF's order and the studio's. Apple's `vector`
        // property is also xyzw, but `simd_quatf(ix:iy:iz:r:)` takes the real
        // part last while most textbooks write it first, which is exactly the
        // kind of mismatch that yields a mirrored scan.
        XCTAssertEqual(pose.q.count, 4)
        XCTAssertEqual(pose.q[0], 0, accuracy: 1e-7)
        XCTAssertEqual(pose.q[1], Double(halfRoot2), accuracy: 1e-7)
        XCTAssertEqual(pose.q[2], 0, accuracy: 1e-7)
        XCTAssertEqual(pose.q[3], Double(halfRoot2), accuracy: 1e-7)

        let object = try json(pose)
        XCTAssertNotNil(object["t"])
        XCTAssertNotNil(object["q"])
    }

    // MARK: - Fix quality

    func testFixQualityRawValuesMatchTheGgaTable() throws {
        // These integers are NMEA's, not ours, and renumbering them would
        // silently reclassify every archived capture.
        XCTAssertEqual(FixQuality.invalid.rawValue, 0)
        XCTAssertEqual(FixQuality.singlePoint.rawValue, 1)
        XCTAssertEqual(FixQuality.dgps.rawValue, 2)
        XCTAssertEqual(FixQuality.rtkFixed.rawValue, 4)
        XCTAssertEqual(FixQuality.rtkFloat.rawValue, 5)

        // Encoded as the bare integer, so a GnssFix reads identically here and
        // in the studio.
        let data = try JSONEncoder().encode(FixQuality.rtkFixed)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "4")
    }

    func testOnlyAnIntegerFixIsSurveyGrade() {
        for quality in [FixQuality.invalid, .singlePoint, .dgps, .pps,
                        .rtkFloat, .deadReckoning, .manual, .simulation] {
            XCTAssertFalse(quality.isSurveyGrade, "\(quality.label) must not claim survey grade")
        }
        XCTAssertTrue(FixQuality.rtkFixed.isSurveyGrade)
    }

    // MARK: - Manifest

    func testManifestRoundTrips() throws {
        let manifest = CaptureManifest(
            formatVersion: BundleFormat.version,
            id: "0F5C0E3A",
            name: "Bay 4 slab",
            startedAt: "2026-08-09T14:03:11Z",
            device: DeviceInfo(
                kind: "ios", model: "iPhone16,2", os: "26.0",
                producer: "PIXMYD", hasMetricDepth: true, gnssReceiver: nil
            ),
            cameras: [.pinhole(.init(width: 1920, height: 1440, fx: 1450, fy: 1450, cx: 960, cy: 720))],
            crs: CrsBlock(
                code: "EPSG:2277",
                name: "NAD83 / Texas Central (ftUS)",
                // Never "feet": the US survey foot and the international foot
                // differ by 2 ppm, which at a Texas northing is 27 feet.
                unit: "ftUS",
                metresPerUnit: 1200.0 / 3937.0,
                origin: [3_000_000, 10_000_000, 0],
                verticalDatum: "NAVD88",
                geoidModel: "GEOID18"
            ),
            toProject: nil,
            frameCount: 412,
            bounds: .init(min: [-4, -2, 0], max: [6, 9, 3]),
            notes: nil
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(CaptureManifest.self, from: data)

        XCTAssertEqual(decoded.formatVersion, 1)
        XCTAssertEqual(decoded.frameCount, 412)
        XCTAssertEqual(decoded.crs, manifest.crs)
        XCTAssertEqual(decoded.cameras, manifest.cameras)

        // The unit conversion is exact in the survey-foot definition, and the
        // stored factor has to be that ratio rather than a rounded 0.3048006.
        XCTAssertEqual(try XCTUnwrap(decoded.crs?.metresPerUnit), 1200.0 / 3937.0, accuracy: 1e-15)

        let object = try json(manifest)
        XCTAssertEqual(object["formatVersion"] as? Int, 1)
        XCTAssertNil(object["notes"], "nil fields must be omitted, not null")
    }

    func testControlPointRolesAreDistinct() throws {
        // A checkpoint that solves as a GCP is not a check on anything — the
        // residual it reports is the residual of a point the solve already fit.
        let gcp = ControlPoint(id: "CP1", project: [1, 2, 3], observed: nil, role: .gcp)
        let check = ControlPoint(id: "CP2", project: [4, 5, 6], observed: nil, role: .checkpoint)
        XCTAssertNotEqual(gcp.role, check.role)

        let data = try JSONEncoder().encode([gcp, check])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"gcp\""))
        XCTAssertTrue(text.contains("\"checkpoint\""))
    }
}
