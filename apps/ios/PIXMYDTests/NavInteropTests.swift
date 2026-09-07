import Foundation
import XCTest
import simd
@testable import PIXMYD

/// Tests for the PIXMYD-Nav interop layer.
///
/// The fixtures below are not invented: they are the exact shapes
/// `PIXMYD-Nav/Core/Points/PointSet.cs` and `Core/Ar/ArModelSet.cs` write,
/// including the details that look like bugs and are not — `grid` fields as
/// empty strings rather than nulls, `viewpoint` omitted entirely before a
/// photo has been captured, and `ar-model.json` carrying `modelId` where the
/// contract document says `bundleId`.
///
/// Testing against the producer's real output rather than against the contract
/// prose is deliberate. The prose is the agreement; the bytes are what has to
/// parse on a phone in a basement.
final class NavInteropTests: XCTestCase {

    // MARK: - Fixtures

    /// A `points.json` exactly as the shipping plugin writes one: no grid
    /// system loaded, one point photographed and one not.
    private let pluginPointsJson = """
    {
      "contractVersion": "1.0",
      "setId": "b7f3c2e1-1111-2222-3333-444444444444",
      "setName": "L01 Column Marks",
      "createdUtc": "2026-08-13T14:02:11.000Z",
      "provenance": {
        "navex:sourceDocument": "TowerA.nwd",
        "navex:sourceUnits": "Feet",
        "navex:targetUnits": "Meters",
        "navex:upAxis": "Z",
        "navex:originMode": "ModelMin",
        "navex:appliedOffset": [ -1204.5, 883.2, 0.0 ],
        "navex:offsetNote": "Add appliedOffset to exported coordinates to return to source world coordinates.",
        "navex:exportedUtc": "2026-08-13T14:02:11.000Z"
      },
      "points": [
        {
          "id": "P001",
          "label": "Col C-4 base",
          "position": [ 12.4, 8.15, 0.0 ],
          "grid": { "intersection": "", "level": "", "offset": [ 0, 0, 0 ], "distance": 0 },
          "viewpoint": {
            "image": "P001_photo.png",
            "thumbMono": "P001_photo_mono.png",
            "camera": {
              "position": [ 18.2, 14.7, 1.7 ],
              "lookAt": [ 12.4, 8.15, 0.9 ],
              "upVector": [ 0, 0, 1 ],
              "fovDegrees": 45.0
            }
          },
          "qrPayload": "pixmy://p/b7f3c2e1/P001"
        },
        {
          "id": "P002",
          "label": "Col D-4 base",
          "position": [ 20.4, 8.15, 0.0 ],
          "grid": { "intersection": "", "level": "", "offset": [ 0, 0, 0 ], "distance": 0 },
          "qrPayload": "pixmy://p/b7f3c2e1/P002"
        }
      ]
    }
    """

    private func makePointSet() throws -> NavPointSet {
        try NavPointSet.decode(Data(pluginPointsJson.utf8))
    }

    private func tempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("navinterop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Version gate

    func testMajorVersionIsParsedFromEveryFormAProducerMightWrite() {
        XCTAssertEqual(ContractVersion.major(of: "1.0"), 1)
        XCTAssertEqual(ContractVersion.major(of: "1"), 1)
        XCTAssertEqual(ContractVersion.major(of: "1.4.2"), 1)
        XCTAssertEqual(ContractVersion.major(of: "2.0"), 2)
        XCTAssertNil(ContractVersion.major(of: ""))
        XCTAssertNil(ContractVersion.major(of: "draft"))
    }

    /// A minor bump must stay readable — the contract says consumers check the
    /// major version only, so a producer adding an optional field cannot be
    /// allowed to lock this app out.
    func testAMinorVersionBumpIsStillReadable() throws {
        let bumped = pluginPointsJson.replacingOccurrences(
            of: "\"contractVersion\": \"1.0\"",
            with: "\"contractVersion\": \"1.7\""
        )
        let set = try NavPointSet.decode(Data(bumped.utf8))
        XCTAssertEqual(set.points.count, 2)
    }

    /// A major bump is refused with a line a user can act on, not a decode
    /// error about whichever field happened to change.
    func testAMajorVersionBumpIsRefusedWithAnActionableMessage() {
        let bumped = pluginPointsJson.replacingOccurrences(
            of: "\"contractVersion\": \"1.0\"",
            with: "\"contractVersion\": \"2.0\""
        )
        XCTAssertThrowsError(try NavPointSet.decode(Data(bumped.utf8))) { error in
            guard case let ContractError.unsupportedVersion(found, supported) = error else {
                return XCTFail("expected unsupportedVersion, got \(error)")
            }
            XCTAssertEqual(found, "2.0")
            XCTAssertEqual(supported, 1)
            XCTAssertTrue("\(error)".contains("2.0"))
        }
    }

    func testAFileWithNoContractVersionIsMalformedRatherThanAssumedCurrent() {
        let data = Data(#"{"setId":"x","points":[]}"#.utf8)
        XCTAssertThrowsError(try NavPointSet.decode(data)) { error in
            guard case ContractError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    // MARK: - points.json

    func testThePluginsRealPointsFileDecodesIncludingTheOmittedViewpoint() throws {
        let set = try makePointSet()

        XCTAssertEqual(set.setId, "b7f3c2e1-1111-2222-3333-444444444444")
        XCTAssertEqual(set.shortId, "b7f3c2e1")
        XCTAssertEqual(set.setName, "L01 Column Marks")
        XCTAssertEqual(set.points.count, 2)

        let photographed = try XCTUnwrap(set.point(id: "P001"))
        XCTAssertEqual(photographed.positionVector, SIMD3<Double>(12.4, 8.15, 0))
        XCTAssertEqual(photographed.viewpoint?.image, "P001_photo.png")
        XCTAssertEqual(photographed.viewpoint?.camera?.fovDegrees, 45)

        // The second point has no `viewpoint` key at all. That is the
        // producer's documented behaviour before a photo is captured, and a
        // point with no photo is still a usable point.
        let unphotographed = try XCTUnwrap(set.point(id: "P002"))
        XCTAssertNil(unphotographed.viewpoint)
    }

    /// A model with no grid system loaded is normal, not a failure. The empty
    /// strings must survive as empty strings and drive an empty state.
    func testAnUnloadedGridSystemRendersAsNoGridTextRatherThanAnError() throws {
        let set = try makePointSet()
        let point = try XCTUnwrap(set.point(id: "P001"))
        XCTAssertTrue(point.grid.isEmpty)
        XCTAssertNil(point.grid.summary)
    }

    func testGridSummaryReadsWellForEveryCombinationThatCanOccur() {
        XCTAssertEqual(NavGridRef(intersection: "C-4", level: "L01").summary, "L01 · C-4")
        XCTAssertEqual(NavGridRef(intersection: "C-4", level: "").summary, "C-4")
        XCTAssertEqual(NavGridRef(intersection: "", level: "L01").summary, "L01")
        XCTAssertNil(NavGridRef().summary)
    }

    /// An empty `points` array is explicitly valid: render an empty state, do
    /// not error.
    func testAnEmptyPointArrayIsValid() throws {
        let json = """
        {"contractVersion":"1.0","setId":"a","setName":"Empty",
         "provenance":{"navex:targetUnits":"Meters"},"points":[]}
        """
        let set = try NavPointSet.decode(Data(json.utf8))
        XCTAssertTrue(set.points.isEmpty)
    }

    func testAppliedOffsetReturnsACoordinateToModelWorldSpace() throws {
        let set = try makePointSet()
        let world = set.provenance.toSourceWorld([12.4, 8.15, 0])
        XCTAssertEqual(world[0], 12.4 - 1204.5, accuracy: 1e-9)
        XCTAssertEqual(world[1], 8.15 + 883.2, accuracy: 1e-9)
        XCTAssertEqual(world[2], 0, accuracy: 1e-9)
    }

    /// The contract fixes target units at metres. A file saying otherwise is a
    /// producer bug worth reporting rather than silently scaling by 3.28.
    func testNonMetricTargetUnitsAreDetectedRatherThanAssumed() throws {
        let set = try makePointSet()
        XCTAssertTrue(set.provenance.isMetric)

        let feet = pluginPointsJson.replacingOccurrences(
            of: "\"navex:targetUnits\": \"Meters\"",
            with: "\"navex:targetUnits\": \"Feet\""
        )
        let wrong = try NavPointSet.decode(Data(feet.utf8))
        XCTAssertFalse(wrong.provenance.isMetric)
    }

    // MARK: - ar-model.json

    /// The plugin writes `modelId` / `modelName` / `boundingBox` where
    /// `ar-model.md` specifies `bundleId` / `name` / `bounds`. Both spellings
    /// have to read, or the app parses none of the files that exist.
    func testTheShippedArModelSpellingDecodesAndReportsNoGeometry() throws {
        let json = """
        {
          "contractVersion": "1.0",
          "modelId": "9c1a44de-0000-0000-0000-000000000000",
          "modelName": "Tower A",
          "provenance": { "navex:targetUnits": "Meters", "navex:appliedOffset": [1,2,3] },
          "boundingBox": { "min": [0,0,0], "max": [40,25,4.2], "center": [20,12.5,2.1], "size": [40,25,4.2] },
          "camera": { "position": [1,2,3], "lookAt": [4,5,6], "upVector": [0,0,1], "fovDegrees": 45.0 },
          "image": "view.png",
          "thumbMono": "view_mono.png"
        }
        """
        let bundle = try NavArBundle.decode(Data(json.utf8))
        XCTAssertEqual(bundle.bundleId, "9c1a44de-0000-0000-0000-000000000000")
        XCTAssertEqual(bundle.shortId, "9c1a44de")
        XCTAssertEqual(bundle.name, "Tower A")
        XCTAssertEqual(bundle.bounds?.max, [40, 25, 4.2])

        // No `.glb` is written by the shipping plugin. That is a supported
        // state, not a parse failure — the bundle still says where the model
        // is and what it looked like from the export viewpoint.
        XCTAssertFalse(bundle.hasGeometry)
        XCTAssertTrue(bundle.anchorPointIds.isEmpty)
        XCTAssertNil(bundle.pointSetId)
    }

    /// And the documented spelling, for the day the producer catches up.
    func testTheContractArBundleSpellingAlsoDecodes() throws {
        let json = """
        {
          "contractVersion": "1.0",
          "bundleId": "9c1a44de-0000-0000-0000-000000000000",
          "name": "Tower A — L01 core",
          "pointSetId": "b7f3c2e1-1111-2222-3333-444444444444",
          "anchorPointIds": [ "P001", "P002", "P003" ],
          "bounds": { "min": [0,0,0], "max": [40,25,4.2], "paddingApplied": 0.5 },
          "geometry": { "file": "model.glb", "bytes": 8412663, "triangleCount": 214880 },
          "provenance": { "navex:targetUnits": "Meters" }
        }
        """
        let bundle = try NavArBundle.decode(Data(json.utf8), file: "ar-bundle.json")
        XCTAssertEqual(bundle.name, "Tower A — L01 core")
        XCTAssertEqual(bundle.anchorPointIds, ["P001", "P002", "P003"])
        XCTAssertEqual(bundle.bounds?.paddingApplied, 0.5)
        XCTAssertTrue(bundle.hasGeometry)
        XCTAssertEqual(bundle.geometry?.triangleCount, 214880)
    }

    // MARK: - QR payloads

    func testTheProducersOwnMarkerPayloadParses() {
        // This exact string is what PointSet.cs writes into every marker.
        let parsed = PixmyPayload.parse("pixmy://p/b7f3c2e1/P001")
        XCTAssertEqual(parsed, .point(setId8: "b7f3c2e1", pointId: "P001"))
        XCTAssertEqual(parsed?.encoded, "pixmy://p/b7f3c2e1/P001")
    }

    func testEveryPayloadInTheFixtureSetParsesBackToItsOwnPoint() throws {
        let set = try makePointSet()
        for point in set.points {
            let payload = try XCTUnwrap(PixmyPayload.parse(try XCTUnwrap(point.qrPayload)))
            guard case let .point(setId8, pointId) = payload else {
                return XCTFail("expected a point payload")
            }
            XCTAssertEqual(setId8, set.shortId)
            XCTAssertEqual(pointId, point.id)
        }
    }

    func testBundlePayloadParses() {
        XCTAssertEqual(PixmyPayload.parse("pixmy://m/9c1a44de"), .bundle(bundleId8: "9c1a44de"))
    }

    /// A camera pointed at a building site sees a lot of barcodes. None of
    /// these is an error worth showing the user.
    func testThingsThatAreNotOurPayloadsAreRejectedQuietly() {
        let notOurs = [
            "",
            "https://example.com/",
            "pixmy://",
            "pixmy://p/b7f3c2e1",              // no point id
            "pixmy://p/b7f3c2e1/P001/extra",   // too many segments
            "pixmy://p/notahexid/P001",        // set id is not hex
            "pixmy://p/b7f3c2e/P001",          // set id is 7 characters
            "pixmy://z/b7f3c2e1/P001",         // unknown kind
            "pixmy://m/9c1a44de/extra",
            "WIFI:S:site;T:WPA;P:hunter2;;",
        ]
        for text in notOurs {
            XCTAssertNil(PixmyPayload.parse(text), "should not have parsed: \(text)")
        }
    }

    func testTheSchemeIsMatchedCaseInsensitivelyBecauseSomeEncodersUppercase() {
        XCTAssertEqual(
            PixmyPayload.parse("PIXMY://P/B7F3C2E1/P001"),
            .point(setId8: "b7f3c2e1", pointId: "P001")
        )
    }

    // MARK: - Transfer tickets

    func testATransferTicketSurvivesTheHexPackingRoundTrip() throws {
        let ticket = try XCTUnwrap(
            TransferTicket(host: "192.168.1.100", port: 48080, token: "0123456789abcdef")
        )
        // 192.168.1.100 -> c0.a8.01.64, and 48080 -> 0xbbd0.
        XCTAssertEqual(ticket.endpointHex, "c0a80164bbd0")

        let parsed = PixmyPayload.parse(ticket.encoded)
        XCTAssertEqual(parsed, .transfer(ticket))

        guard case let .transfer(back) = try XCTUnwrap(parsed) else {
            return XCTFail("expected a transfer payload")
        }
        XCTAssertEqual(back.host, "192.168.1.100")
        XCTAssertEqual(back.port, 48080)
        XCTAssertEqual(back.token, "0123456789abcdef")
        XCTAssertEqual(back.baseURL?.absoluteString, "http://192.168.1.100:48080")
    }

    /// The whole reason the payload is packed hex rather than a readable URL.
    ///
    /// PIXMYD-Nav's QR encoder is byte mode, level M, versions 1-3: a hard
    /// ceiling of 42 bytes, and it throws rather than emit a malformed symbol.
    /// A dotted-quad and a decimal port would vary in length with the address,
    /// so a session that fits on one machine would fail to encode on the next.
    /// This asserts the payload is a fixed 39 bytes for any address at all.
    func testEveryTransferPayloadIsExactlyThirtyNineBytesAndFitsTheEncoder() throws {
        let addresses = [
            ("0.0.0.0", 1),
            ("10.0.0.1", 80),
            ("192.168.1.100", 48080),
            ("255.255.255.255", 65535),
            ("172.16.254.3", 8080),
        ]
        for (host, port) in addresses {
            let ticket = try XCTUnwrap(
                TransferTicket(host: host, port: port, token: "deadbeefcafef00d"),
                "\(host):\(port) should be a valid ticket"
            )
            XCTAssertEqual(
                ticket.encoded.utf8.count, 39,
                "payload for \(host):\(port) was \(ticket.encoded.utf8.count) bytes"
            )
            XCTAssertLessThanOrEqual(ticket.encoded.utf8.count, 42)
            XCTAssertEqual(PixmyPayload.parse(ticket.encoded), .transfer(ticket))
        }
    }

    func testMalformedTicketsAreRefusedRatherThanSilentlyRepaired() {
        XCTAssertNil(TransferTicket(host: "192.168.1", port: 48080, token: "0123456789abcdef"))
        XCTAssertNil(TransferTicket(host: "192.168.1.256", port: 48080, token: "0123456789abcdef"))
        XCTAssertNil(TransferTicket(host: "192.168.1.100", port: 0, token: "0123456789abcdef"))
        XCTAssertNil(TransferTicket(host: "192.168.1.100", port: 70000, token: "0123456789abcdef"))
        // A short token is a different capability, not a truncated one.
        XCTAssertNil(TransferTicket(host: "192.168.1.100", port: 48080, token: "0123abcd"))
        XCTAssertNil(TransferTicket(host: "192.168.1.100", port: 48080, token: "zzzzzzzzzzzzzzzz"))
        // Leading zeros mean someone is passing an octal literal and the two
        // ends have to agree byte for byte.
        XCTAssertNil(TransferTicket(host: "192.168.01.100", port: 48080, token: "0123456789abcdef"))

        XCTAssertNil(PixmyPayload.parse("pixmy://t/c0a80164bb/0123456789abcdef"))
        XCTAssertNil(PixmyPayload.parse("pixmy://t/c0a80164bbb0/short"))
    }

    // MARK: - Store

    func testAnImportedFolderResolvesAScannedMarkerWithNoNetwork() throws {
        let documents = try tempDirectory()
        let source = try tempDirectory()
        try Data(pluginPointsJson.utf8).write(to: source.appendingPathComponent("points.json"))
        try Data("png".utf8).write(to: source.appendingPathComponent("P001_photo.png"))

        let imported = try NavBundleStore.importFolder(at: source, into: documents)
        XCTAssertEqual(imported.id, "b7f3c2e1-1111-2222-3333-444444444444")
        XCTAssertEqual(imported.pointCount, 2)
        XCTAssertEqual(imported.displayName, "L01 Column Marks")

        let listed = NavBundleStore.list(in: documents)
        XCTAssertEqual(listed.bundles.count, 1)
        XCTAssertTrue(listed.problems.isEmpty)

        let payload = try XCTUnwrap(PixmyPayload.parse("pixmy://p/b7f3c2e1/P001"))
        let resolved = try NavBundleStore.resolve(point: payload, in: listed.bundles)
        XCTAssertEqual(resolved.point.id, "P001")
        XCTAssertEqual(resolved.point.label, "Col C-4 base")

        // The photo the marker references came across with it.
        XCTAssertNotNil(resolved.bundle.file(resolved.point.viewpoint?.image))
        // And one that did not is nil rather than a URL that fails later.
        XCTAssertNil(resolved.bundle.file("P002_photo.png"))
    }

    /// The contract's rule, made mechanical: a scanner that does not hold the
    /// set names the set it needs. There is no fetch path in the store to take
    /// instead.
    func testAnUnknownSetIsNamedRatherThanFetched() throws {
        let payload = try XCTUnwrap(PixmyPayload.parse("pixmy://p/aaaaaaaa/P001"))
        XCTAssertThrowsError(try NavBundleStore.resolve(point: payload, in: [])) { error in
            guard case let ContractError.unknownPointSet(setId) = error else {
                return XCTFail("expected unknownPointSet, got \(error)")
            }
            XCTAssertEqual(setId, "aaaaaaaa")
            XCTAssertTrue("\(error)".contains("aaaaaaaa"))
        }
    }

    func testAKnownSetMissingThePointSaysSo() throws {
        let documents = try tempDirectory()
        let source = try tempDirectory()
        try Data(pluginPointsJson.utf8).write(to: source.appendingPathComponent("points.json"))
        _ = try NavBundleStore.importFolder(at: source, into: documents)

        let payload = try XCTUnwrap(PixmyPayload.parse("pixmy://p/b7f3c2e1/P999"))
        let bundles = NavBundleStore.list(in: documents).bundles
        XCTAssertThrowsError(try NavBundleStore.resolve(point: payload, in: bundles)) { error in
            guard case let ContractError.unknownPoint(pointId, _) = error else {
                return XCTFail("expected unknownPoint, got \(error)")
            }
            XCTAssertEqual(pointId, "P999")
        }
    }

    func testAFolderThatIsNotAnExportLeavesNothingBehind() throws {
        let documents = try tempDirectory()
        let source = try tempDirectory()
        try Data("hello".utf8).write(to: source.appendingPathComponent("notes.txt"))

        XCTAssertThrowsError(try NavBundleStore.importFolder(at: source, into: documents))
        XCTAssertTrue(NavBundleStore.list(in: documents).bundles.isEmpty)
    }

    /// Re-importing replaces rather than merges: a re-export after moving a
    /// point must not leave the old photo behind next to the new coordinate.
    func testReimportingReplacesTheBundleRatherThanAccumulatingStaleFiles() throws {
        let documents = try tempDirectory()

        let first = try tempDirectory()
        try Data(pluginPointsJson.utf8).write(to: first.appendingPathComponent("points.json"))
        try Data("old".utf8).write(to: first.appendingPathComponent("P001_photo.png"))
        _ = try NavBundleStore.importFolder(at: first, into: documents)

        let second = try tempDirectory()
        try Data(pluginPointsJson.utf8).write(to: second.appendingPathComponent("points.json"))
        _ = try NavBundleStore.importFolder(at: second, into: documents)

        let bundles = NavBundleStore.list(in: documents).bundles
        XCTAssertEqual(bundles.count, 1)
        XCTAssertNil(bundles[0].file("P001_photo.png"), "the stale photo should be gone")
    }

    /// Bytes off a network are not more trusted than a folder off a thumb
    /// drive. A relative path that climbs out of the bundle is refused at the
    /// point of writing, not later at the point of reading.
    func testATransferCannotWriteOutsideItsOwnBundleDirectory() throws {
        let documents = try tempDirectory()
        let files: [String: Data] = [
            "points.json": Data(pluginPointsJson.utf8),
            "../escape.txt": Data("nope".utf8),
        ]
        XCTAssertThrowsError(try NavBundleStore.install(files: files, into: documents))
    }

    func testATransferOfWellFormedFilesLandsAsABundle() throws {
        let documents = try tempDirectory()
        let bundle = try NavBundleStore.install(
            files: [
                "points.json": Data(pluginPointsJson.utf8),
                "P001_photo.png": Data("png".utf8),
            ],
            into: documents
        )
        XCTAssertEqual(bundle.pointCount, 2)
        XCTAssertNotNil(bundle.file("P001_photo.png"))
    }

    /// A path that reads out of the bundle at render time is refused too, so a
    /// file written by some other route cannot be used to read the app's
    /// container.
    func testABundleRelativePathCannotEscapeAtReadTime() throws {
        let documents = try tempDirectory()
        let source = try tempDirectory()
        try Data(pluginPointsJson.utf8).write(to: source.appendingPathComponent("points.json"))
        let bundle = try NavBundleStore.importFolder(at: source, into: documents)

        XCTAssertNil(bundle.file("../../../etc/passwd"))
        XCTAssertNil(bundle.file(""))
        XCTAssertNil(bundle.file(nil))
    }

    // MARK: - capture.json

    /// Three correspondences taken against the fixture set, offset and rotated
    /// by a known transform so the solve has a checkable answer.
    private func makeCorrespondences() -> [CaptureCorrespondence] {
        // The capture frame is the point frame translated by (5, -2, 1).
        // A pure translation is not degenerate for Horn's method as long as
        // the points themselves are not collinear, and these are not.
        [
            CaptureCorrespondence(pointId: "P001", observed: SIMD3<Double>(12.4 + 5, 8.15 - 2, 0 + 1)),
            CaptureCorrespondence(pointId: "P002", observed: SIMD3<Double>(20.4 + 5, 8.15 - 2, 0 + 1)),
            CaptureCorrespondence(pointId: "P003", observed: SIMD3<Double>(12.4 + 5, 16.15 - 2, 0 + 1)),
        ]
    }

    /// The fixture set has two points; the third correspondence needs one to
    /// match, so this builds a three-point set from the same provenance.
    private func makeThreePointSet() throws -> NavPointSet {
        let base = try makePointSet()
        var points = base.points
        points.append(NavPoint(id: "P003", label: "Col C-5 base", position: [12.4, 16.15, 0]))
        return NavPointSet(
            setId: base.setId,
            setName: base.setName,
            provenance: base.provenance,
            points: points
        )
    }

    func testAKnownTranslationSolvesToZeroErrorAndAGradeOfLayout() throws {
        let set = try makeThreePointSet()
        let solved = try CaptureExport.solve(pointSet: set, correspondences: makeCorrespondences())

        XCTAssertEqual(solved.solution.rmsError, 0, accuracy: 1e-9)
        XCTAssertEqual(solved.solution.scale, 1.0, accuracy: 1e-12)
        XCTAssertEqual(solved.grade.band, .layout)
        XCTAssertTrue(solved.outlierPointIds.isEmpty)
    }

    /// Scale is fixed at 1.0 by the contract. A capture that is genuinely
    /// 2% small must show up as error, not be absorbed into a fitted scale.
    func testScaleStaysAtOneSoAMisScaledCaptureShowsUpAsError() throws {
        let set = try makeThreePointSet()
        let stretched = makeCorrespondences().map {
            CaptureCorrespondence(pointId: $0.pointId, observed: $0.observed * 1.02)
        }
        let solved = try CaptureExport.solve(pointSet: set, correspondences: stretched)
        XCTAssertEqual(solved.solution.scale, 1.0, accuracy: 1e-12)
        XCTAssertGreaterThan(solved.solution.rmsError, 0.01)
    }

    func testContractVersionIsTheFirstFieldInTheRenderedFile() throws {
        let set = try makeThreePointSet()
        let solved = try CaptureExport.solve(pointSet: set, correspondences: makeCorrespondences())
        let json = CaptureExport.render(
            CaptureExportRequest(
                captureId: "44e0b8a2-0000-0000-0000-000000000000",
                capturedUtc: Date(timeIntervalSince1970: 1_770_000_000),
                device: CaptureDevice(model: "iPhone 15 Pro", hasLidar: true),
                pointSet: set,
                correspondences: makeCorrespondences(),
                geometryBytes: 12_882_110
            ),
            solved: solved
        )

        let firstKeyLine = json
            .split(separator: "\n")
            .first { $0.contains("\":") }
        XCTAssertTrue(
            firstKeyLine?.contains("\"contractVersion\"") == true,
            "contractVersion must be the first field; got \(firstKeyLine ?? "")"
        )
    }

    func testTheRenderedCaptureCarriesEverythingTheConsumerHasToShow() throws {
        let set = try makeThreePointSet()
        let solved = try CaptureExport.solve(pointSet: set, correspondences: makeCorrespondences())
        let json = CaptureExport.render(
            CaptureExportRequest(
                captureId: "44e0b8a2-0000-0000-0000-000000000000",
                capturedUtc: Date(timeIntervalSince1970: 1_770_000_000),
                device: CaptureDevice(model: "iPhone 15 Pro", hasLidar: true),
                pointSet: set,
                correspondences: makeCorrespondences(),
                geometryBytes: 12_882_110
            ),
            solved: solved
        )

        // It has to be valid JSON before anything else is worth checking.
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let root = try XCTUnwrap(parsed)

        XCTAssertEqual(root["contractVersion"] as? String, "1.0")
        XCTAssertEqual(root["pointSetId"] as? String, set.setId)
        XCTAssertEqual(root["captureId"] as? String, "44e0b8a2-0000-0000-0000-000000000000")

        let solution = try XCTUnwrap(root["solution"] as? [String: Any])
        XCTAssertEqual((solution["matrix"] as? [Double])?.count, 16)
        XCTAssertEqual(solution["scale"] as? Double, 1.0)
        XCTAssertEqual(solution["accuracyGrade"] as? String, "layout")
        XCTAssertEqual((solution["outlierPointIds"] as? [String])?.isEmpty, true)

        // The raw observations ship alongside the solve so the consumer can
        // re-solve rather than trust a number it cannot check.
        let correspondences = try XCTUnwrap(root["correspondences"] as? [[String: Any]])
        XCTAssertEqual(correspondences.count, 3)
        XCTAssertEqual(correspondences[0]["pointId"] as? String, "P001")
        XCTAssertEqual((correspondences[0]["observed"] as? [Double]), [17.4, 6.15, 1.0])

        // The offset that gets the mesh back to model world coordinates comes
        // from the set the capture was taken against, not from a guess.
        let provenance = try XCTUnwrap(root["provenance"] as? [String: Any])
        XCTAssertEqual(provenance["navex:appliedOffset"] as? [Double], [-1204.5, 883.2, 0.0])
        XCTAssertEqual(provenance["navex:targetUnits"] as? String, "Meters")

        let geometry = try XCTUnwrap(root["geometry"] as? [String: Any])
        // FBX, not GLB: appending a file is the only way a Navisworks plugin
        // can put geometry into an open document, and Navisworks does not read
        // GLB. See CaptureUpload.
        XCTAssertEqual(geometry["file"] as? String, "capture.fbx")
        XCTAssertEqual(geometry["bytes"] as? Int, 12_882_110)
        // Which frame the mesh is in. Absent, a consumer assumes `capture`,
        // which is what every file written before this field existed contained.
        XCTAssertEqual(geometry["frame"] as? String, "capture")

        XCTAssertEqual(root["capturedUtc"] as? String, "2026-02-02T02:40:00.000Z")
    }

    /// "solution absent but correspondences present → offer to solve locally.
    /// This is the useful degraded mode, not an error."
    func testACaptureWithNoSolutionStillCarriesItsObservationsHome() throws {
        let set = try makeThreePointSet()
        let json = CaptureExport.render(
            CaptureExportRequest(
                device: CaptureDevice(model: "iPhone 15 Pro", hasLidar: true),
                pointSet: set,
                correspondences: Array(makeCorrespondences().prefix(2)),
                geometryBytes: 10
            ),
            solved: nil
        )
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertNil(root["solution"])
        XCTAssertEqual((root["correspondences"] as? [[String: Any]])?.count, 2)
    }

    /// Two points used to be refused. They are not any more: both frames know
    /// which way down is, so holding the vertical leaves heading and
    /// translation, which two points over-determine.
    ///
    /// This is the change that lets a crew who could reach two column marks
    /// send a scan home that lands where it belongs.
    func testTwoCorrespondencesSolveWithTheVerticalHeld() throws {
        let set = try makeThreePointSet()
        let pair = Array(makeCorrespondences().prefix(2))
        let solved = try CaptureExport.solve(pointSet: set, correspondences: pair)

        XCTAssertTrue(solved.solution.verticalHeld,
                      "two points must be solved with the vertical held, not with Horn's method")
        XCTAssertEqual(solved.solution.pairCount, 2)
        // The fixture's transform is a pure translation, which a constrained
        // solve recovers exactly.
        XCTAssertEqual(solved.solution.rmsError, 0, accuracy: 1e-9)
        // And no outliers are claimed: leave-one-out needs four points, and
        // inventing a verdict from two would be worse than having none.
        XCTAssertTrue(solved.outlierPointIds.isEmpty)
    }

    /// One point is still refused, and the solver's own message is surfaced
    /// rather than replaced. "One point fixes where the scan sits and nothing
    /// about which way it faces" is actionable; "registration failed" is not.
    func testOnePointIsRefusedWithTheSolversOwnMessage() throws {
        let set = try makeThreePointSet()
        let one = Array(makeCorrespondences().prefix(1))
        XCTAssertThrowsError(try CaptureExport.solve(pointSet: set, correspondences: one)) { error in
            guard case let RegistrationError.tooFewPairsForGravity(count) = error else {
                return XCTFail("expected tooFewPairsForGravity, got \(error)")
            }
            XCTAssertEqual(count, 1)
            XCTAssertTrue("\(error)".contains("which way it faces"))
        }
    }

    func testCorrespondencesForPointsNotInTheSetAreNamed() throws {
        let set = try makeThreePointSet()
        let wrong = [CaptureCorrespondence(pointId: "Q001", observed: SIMD3<Double>(0, 0, 0))]
        XCTAssertThrowsError(try CaptureExport.solve(pointSet: set, correspondences: wrong)) { error in
            guard case let CaptureExportError.unknownPointIds(ids) = error else {
                return XCTFail("expected unknownPointIds, got \(error)")
            }
            XCTAssertEqual(ids, ["Q001"])
        }
    }

    func testWritingProducesAFileNamedByTheContract() throws {
        let directory = try tempDirectory()
        let set = try makeThreePointSet()
        let url = try CaptureExport.write(
            CaptureExportRequest(
                device: CaptureDevice(model: "iPhone 15 Pro", hasLidar: true),
                pointSet: set,
                correspondences: makeCorrespondences(),
                geometryBytes: 1
            ),
            solved: try CaptureExport.solve(pointSet: set, correspondences: makeCorrespondences()),
            to: directory
        )
        XCTAssertEqual(url.lastPathComponent, "capture.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - JSON writer

    /// JSON has no NaN. Emitting one turns a single bad residual into a file
    /// the consumer cannot parse at all.
    func testNonFiniteNumbersNeverReachTheFile() {
        XCTAssertEqual(OrderedJson.number(.nan), "0")
        XCTAssertEqual(OrderedJson.number(.infinity), "0")
        XCTAssertEqual(OrderedJson.number(-.infinity), "0")
        XCTAssertEqual(OrderedJson.number(1), "1.0")
        XCTAssertEqual(OrderedJson.number(0.5), "0.5")
    }

    func testStringsAreEscapedSoALabelCannotBreakTheFile() {
        XCTAssertEqual(OrderedJson.escape("Col \"C-4\""), "Col \\\"C-4\\\"")
        XCTAssertEqual(OrderedJson.escape("a\\b"), "a\\\\b")
        XCTAssertEqual(OrderedJson.escape("line\nbreak"), "line\\nbreak")
    }

    func testALabelWithQuotesSurvivesTheRoundTrip() throws {
        let set = NavPointSet(
            setId: "abc",
            setName: "Set \"A\"\\B",
            provenance: NavProvenance(sourceDocument: "T\"A.nwd", sourceUnits: "Feet"),
            points: [NavPoint(id: "P001", label: "x", position: [0, 0, 0])]
        )
        let json = CaptureExport.render(
            CaptureExportRequest(
                device: CaptureDevice(model: "iPhone \"15\"", hasLidar: true),
                pointSet: set,
                correspondences: [],
                geometryBytes: 0
            ),
            solved: nil
        )
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let device = try XCTUnwrap(root["device"] as? [String: Any])
        XCTAssertEqual(device["model"] as? String, "iPhone \"15\"")
    }
}
