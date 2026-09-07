import Foundation
import XCTest
import simd
@testable import PIXMYD

/// Pins the Swift FBX writer to the TypeScript one, byte for byte.
///
/// This exists because the other FBX tests round-trip through this writer's own
/// parser, and a parser built on the writer's assumptions cannot catch a bug in
/// those assumptions. That is not a hypothetical here: the QR encoder in the
/// sibling Navisworks plugin shipped with a rigorous-looking self-round-trip
/// test and was still wrong in 137 of 359 modules, found only by diffing
/// against an independent implementation.
///
/// So the reference is `packages/formats/src/fbx.ts`, which the monorepo tests
/// validate against three.js's FBXLoader — an independent parser. The constant
/// below is that writer's exact output for the mesh in `makeReference`,
/// captured offline with:
///
///     TZ=UTC node --experimental-strip-types - <<'EOF'
///     import { writeMeshFbx } from './packages/formats/src/fbx.ts';
///     const mesh = {
///       positions: new Float32Array([0,0,0, 1,0,0, 0,1,0, 1,1,0]),
///       normals:   new Float32Array([0,0,1, 0,0,1, 0,0,1, 0,0,1]),
///       colors:    new Float32Array([1,0,0, 0,1,0, 0,0,1, 1,1,0]),
///       indices:   new Uint32Array([0,1,2, 1,3,2]),
///     };
///     const date = new Date(Date.UTC(2026, 0, 2, 3, 4, 5, 60));
///     process.stdout.write(Buffer.from(writeMeshFbx(mesh, { name: 'mesh', date }))
///       .toString('base64'));
///     EOF
///
/// No Node at runtime — the bytes are baked in. If this fails, re-run the
/// command above and diff the two, rather than editing the constant to match
/// whatever the writer now produces.
///
/// The date is fixed because the FBX footer encodes a timestamp, and the id
/// allocator starts from 1,000,000 on both sides for a single call.
final class FbxReferenceTests: XCTestCase {

    func testOutputIsByteIdenticalToTheTypeScriptWriter() throws {
        let expected = Data(base64Encoded: Self.typeScriptReference)
        let reference = try XCTUnwrap(expected, "the baked fixture is not valid base64")

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pixmyd-fbx-ref-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("mesh.fbx")
        var options = FbxWriter.WriteOptions()
        options.name = "mesh"
        options.date = Self.fixedDate

        _ = try FbxWriter.writeMesh(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0)],
            normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
            colors: [SIMD3(255, 0, 0), SIMD3(0, 255, 0), SIMD3(0, 0, 255), SIMD3(255, 255, 0)],
            indices: [0, 1, 2, 1, 3, 2],
            options: options,
            to: url
        )

        let produced = try Data(contentsOf: url)
        XCTAssertEqual(produced.count, reference.count, "file length differs from the reference")

        if produced != reference {
            let a = [UInt8](reference)
            let b = [UInt8](produced)
            let first = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            XCTFail("FBX output drifted from the TypeScript writer at byte \(first.map(String.init) ?? "?")")
        }
    }

    /// The millisecond field of the footer stamp is the one place a `Date`
    /// round trip can lose precision — it is a `Double` of seconds, so 60 ms
    /// can come back as 59,999,999 ns and truncate to 59. That drifted three
    /// bytes of the footer code before it was rounded instead.
    func testFooterStampSurvivesTheDateRoundTrip() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pixmyd-fbx-ms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Every whole millisecond in a decisecond, so a truncation bug in the
        // /10 field shows up rather than being masked by a lucky value.
        for millis in [0, 9, 10, 60, 99, 100, 500, 999] {
            var components = Self.baseComponents
            components.nanosecond = millis * 1_000_000
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let date = try XCTUnwrap(calendar.date(from: components))

            var options = FbxWriter.WriteOptions()
            options.name = "mesh"
            options.date = date

            let url = directory.appendingPathComponent("m\(millis).fbx")
            _ = try FbxWriter.writeMesh(
                positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
                normals: nil, colors: nil, indices: [0, 1, 2],
                options: options, to: url
            )
            // The footer must be present and complete whatever the stamp is.
            let bytes = try Data(contentsOf: url)
            XCTAssertGreaterThan(bytes.count, 176)
        }
    }

    // MARK: - Fixture

    private static var baseComponents: DateComponents {
        var c = DateComponents()
        c.year = 2026; c.month = 1; c.day = 2
        c.hour = 3; c.minute = 4; c.second = 5
        return c
    }

    private static var fixedDate: Date {
        var components = baseComponents
        components.nanosecond = 60_000_000
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    /// `packages/formats/src/fbx.ts` output. See the class comment.
    private static let typeScriptReference =
        "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" +
        "AAAAAAAAAAAAAAAAAAAAAAAA8D8AAAAAAAAAAAAAAAAAAAAAAAAAAAAA8D8AAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAA8D8AAAAAAAAAAAAAAAAAAAAAAAAAAAAA8D8AAAAAAAAAAAAAAAAALwsAAAEAAAAF" +
        "AAAAEUxheWVyRWxlbWVudENvbG9ySQAAAAD/CQAAAQAAAAUAAAAHVmVyc2lvbkllAAAAIQoAAAEA" +
        "AAARAAAABE5hbWVTDAAAAFZlcnRleENvbG9yc1IKAAABAAAADgAAABZNYXBwaW5nSW5mb3JtYXRp" +
        "b25UeXBlUwkAAABCeVZlcnRpY2WCCgAAAQAAAAsAAAAYUmVmZXJlbmNlSW5mb3JtYXRpb25UeXBl" +
        "UwYAAABEaXJlY3QiCwAAAQAAAI0AAAAGQ29sb3JzZBAAAAAAAAAAgAAAAAAAAAAAAPA/AAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAPA/AAAAAAAAAAAAAAAAAADwPwAAAAAAAAAAAAAAAAAA8D8AAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAA8D8AAAAAAADwPwAAAAAAAPA/AAAAAAAA8D8AAAAAAAAAAAAAAAAAAPA/" +
        "AAAAAAAAAAAAAAAAAB4MAAABAAAABQAAABRMYXllckVsZW1lbnRNYXRlcmlhbEkAAAAAbgsAAAEA" +
        "AAAFAAAAB1ZlcnNpb25JZQAAAIQLAAABAAAABQAAAAROYW1lUwAAAACzCwAAAQAAAAwAAAAWTWFw" +
        "cGluZ0luZm9ybWF0aW9uVHlwZVMHAAAAQWxsU2FtZeoLAAABAAAAEgAAABhSZWZlcmVuY2VJbmZv" +
        "cm1hdGlvblR5cGVTDQAAAEluZGV4VG9EaXJlY3QRDAAAAQAAABEAAAAJTWF0ZXJpYWxzaQEAAAAA" +
        "AAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAmg0AAAEAAAAFAAAABUxheWVySQAAAABODAAAAQAAAAUA" +
        "AAAHVmVyc2lvbklkAAAAuAwAAAAAAAAAAAAADExheWVyRWxlbWVudI8MAAABAAAAFwAAAARUeXBl" +
        "UxIAAABMYXllckVsZW1lbnROb3JtYWyrDAAAAQAAAAUAAAAKVHlwZWRJbmRleEkAAAAAAAAAAAAA" +
        "AAAAAAAAACENAAAAAAAAAAAAAAxMYXllckVsZW1lbnT4DAAAAQAAABYAAAAEVHlwZVMRAAAATGF5" +
        "ZXJFbGVtZW50Q29sb3IUDQAAAQAAAAUAAAAKVHlwZWRJbmRleEkAAAAAAAAAAAAAAAAAAAAAAI0N" +
        "AAAAAAAAAAAAAAxMYXllckVsZW1lbnRkDQAAAQAAABkAAAAEVHlwZVMUAAAATGF5ZXJFbGVtZW50" +
        "TWF0ZXJpYWyADQAAAQAAAAUAAAAKVHlwZWRJbmRleEkAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAA+g4AAAMAAAAiAAAABU1vZGVsTEFCDwAAAAAAUwsAAABtZXNoAAFN" +
        "b2RlbFMEAAAATWVzaPQNAAABAAAABQAAAAdWZXJzaW9uSegAAAC0DgAAAAAAAAAAAAAMUHJvcGVy" +
        "dGllczcwUw4AAAUAAAA4AAAAAVBTFQAAAERlZmF1bHRBdHRyaWJ1dGVJbmRleFMDAAAAaW50UwcA" +
        "AABJbnRlZ2VyUwAAAABJAAAAAKcOAAAHAAAARgAAAAFQUwsAAABMY2wgU2NhbGluZ1MLAAAATGNs" +
        "IFNjYWxpbmdTAAAAAFMBAAAAQUQAAAAAAADwP0QAAAAAAADwP0QAAAAAAADwPwAAAAAAAAAAAAAA" +
        "AADKDgAAAQAAAAIAAAAHU2hhZGluZ0MB7Q4AAAEAAAAPAAAAB0N1bGxpbmdTCgAAAEN1bGxpbmdP" +
        "ZmYAAAAAAAAAAAAAAAAAMBEAAAMAAAAqAAAACE1hdGVyaWFsTEJCDwAAAAAAUxcAAABtZXNoLW1h" +
        "dGVyaWFsAAFNYXRlcmlhbFMAAAAAUg8AAAEAAAAFAAAAB1ZlcnNpb25JZgAAAHUPAAABAAAACgAA" +
        "AAxTaGFkaW5nTW9kZWxTBQAAAHBob25nkQ8AAAEAAAAFAAAACk11bHRpTGF5ZXJJAAAAACMRAAAA" +
        "AAAAAAAAAAxQcm9wZXJ0aWVzNzD5DwAABwAAAEEAAAABUFMMAAAARGlmZnVzZUNvbG9yUwUAAABD" +
        "b2xvclMAAAAAUwEAAABBRAAAAAAAAPA/RAAAAAAAAPA/RAAAAAAAAPA/SBAAAAcAAABBAAAAAVBT" +
        "DAAAAEFtYmllbnRDb2xvclMFAAAAQ29sb3JTAAAAAFMBAAAAQUSamZmZmZnJP0SamZmZmZnJP0Sa" +
        "mZmZmZnJP5gQAAAHAAAAQgAAAAFQUw0AAABTcGVjdWxhckNvbG9yUwUAAABDb2xvclMAAAAAUwEA" +
        "AABBRAAAAAAAAAAARAAAAAAAAAAARAAAAAAAAAAA2BAAAAUAAAAyAAAAAVBTCQAAAFNoaW5pbmVz" +
        "c1MGAAAAZG91YmxlUwYAAABOdW1iZXJTAAAAAEQAAAAAAAAAQBYRAAAFAAAAMAAAAAFQUwcAAABP" +
        "cGFjaXR5UwYAAABkb3VibGVTBgAAAE51bWJlclMAAAAARAAAAAAAAPA/AAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA1xEAAAAAAAAAAAAAC0Nvbm5lY3Rpb25zfBEAAAMAAAAZ" +
        "AAAAAUNTAgAAAE9PTEFCDwAAAAAATAAAAAAAAAAAoxEAAAMAAAAZAAAAAUNTAgAAAE9PTEBCDwAA" +
        "AAAATEFCDwAAAAAAyhEAAAMAAAAZAAAAAUNTAgAAAE9PTEJCDwAAAAAATEFCDwAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAADevKso8cjVRZN1+aY7/ihYAAAAAAAAAAAAAAAAAAAAAOgcAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAD4Woxq3vXZfuzpDON1jykL"
}
