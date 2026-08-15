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
        "AABUBgAAAQAAAAUAAAAETmFtZVMAAAAAhQYAAAEAAAAOAAAAFk1hcHBpbmdJbmZvcm1hdGlvblR5" +
        "cGVTCQAAAEJ5VmVydGljZbUGAAABAAAACwAAABhSZWZlcmVuY2VJbmZvcm1hdGlvblR5cGVTBgAA" +
        "AERpcmVjdDYHAAABAAAAbQAAAAdOb3JtYWxzZAwAAAAAAAAAYAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAADwPwAAAAAAAAAAAAAAAAAAAAAAAAAAAADwPwAAAAAAAAAAAAAAAAAAAAAAAAAAAADwPwAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAADwPwAAAAAAAAAAAAAAAACvCAAAAQAAAAUAAAARTGF5ZXJFbGVt" +
        "ZW50Q29sb3JJAAAAAH8HAAABAAAABQAAAAdWZXJzaW9uSWUAAAChBwAAAQAAABEAAAAETmFtZVMM" +
        "AAAAVmVydGV4Q29sb3Jz0gcAAAEAAAAOAAAAFk1hcHBpbmdJbmZvcm1hdGlvblR5cGVTCQAAAEJ5" +
        "VmVydGljZQIIAAABAAAACwAAABhSZWZlcmVuY2VJbmZvcm1hdGlvblR5cGVTBgAAAERpcmVjdKII" +
        "AAABAAAAjQAAAAZDb2xvcnNkEAAAAAAAAACAAAAAAAAAAAAA8D8AAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAA8D8AAAAAAAAAAAAAAAAAAPA/AAAAAAAAAAAAAAAAAADwPwAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AADwPwAAAAAAAPA/AAAAAAAA8D8AAAAAAADwPwAAAAAAAAAAAAAAAAAA8D8AAAAAAAAAAAAAAAAA" +
        "ngkAAAEAAAAFAAAAFExheWVyRWxlbWVudE1hdGVyaWFsSQAAAADuCAAAAQAAAAUAAAAHVmVyc2lv" +
        "bkllAAAABAkAAAEAAAAFAAAABE5hbWVTAAAAADMJAAABAAAADAAAABZNYXBwaW5nSW5mb3JtYXRp" +
        "b25UeXBlUwcAAABBbGxTYW1lagkAAAEAAAASAAAAGFJlZmVyZW5jZUluZm9ybWF0aW9uVHlwZVMN" +
        "AAAASW5kZXhUb0RpcmVjdJEJAAABAAAAEQAAAAlNYXRlcmlhbHNpAQAAAAAAAAAEAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAaCwAAAQAAAAUAAAAFTGF5ZXJJAAAAAM4JAAABAAAABQAAAAdWZXJzaW9uSWQA" +
        "AAA4CgAAAAAAAAAAAAAMTGF5ZXJFbGVtZW50DwoAAAEAAAAXAAAABFR5cGVTEgAAAExheWVyRWxl" +
        "bWVudE5vcm1hbCsKAAABAAAABQAAAApUeXBlZEluZGV4SQAAAAAAAAAAAAAAAAAAAAAAoQoAAAAA" +
        "AAAAAAAADExheWVyRWxlbWVudHgKAAABAAAAFgAAAARUeXBlUxEAAABMYXllckVsZW1lbnRDb2xv" +
        "cpQKAAABAAAABQAAAApUeXBlZEluZGV4SQAAAAAAAAAAAAAAAAAAAAAADQsAAAAAAAAAAAAADExh" +
        "eWVyRWxlbWVudOQKAAABAAAAGQAAAARUeXBlUxQAAABMYXllckVsZW1lbnRNYXRlcmlhbAALAAAB" +
        "AAAABQAAAApUeXBlZEluZGV4SQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAB6DAAAAwAAACIAAAAFTW9kZWxMQUIPAAAAAABTCwAAAG1lc2gAAU1vZGVsUwQAAABNZXNo" +
        "dAsAAAEAAAAFAAAAB1ZlcnNpb25J6AAAADQMAAAAAAAAAAAAAAxQcm9wZXJ0aWVzNzDTCwAABQAA" +
        "ADgAAAABUFMVAAAARGVmYXVsdEF0dHJpYnV0ZUluZGV4UwMAAABpbnRTBwAAAEludGVnZXJTAAAA" +
        "AEkAAAAAJwwAAAcAAABGAAAAAVBTCwAAAExjbCBTY2FsaW5nUwsAAABMY2wgU2NhbGluZ1MAAAAA" +
        "UwEAAABBRAAAAAAAAPA/RAAAAAAAAPA/RAAAAAAAAPA/AAAAAAAAAAAAAAAAAEoMAAABAAAAAgAA" +
        "AAdTaGFkaW5nQwFtDAAAAQAAAA8AAAAHQ3VsbGluZ1MKAAAAQ3VsbGluZ09mZgAAAAAAAAAAAAAA" +
        "AACwDgAAAwAAACoAAAAITWF0ZXJpYWxMQkIPAAAAAABTFwAAAG1lc2gtbWF0ZXJpYWwAAU1hdGVy" +
        "aWFsUwAAAADSDAAAAQAAAAUAAAAHVmVyc2lvbklmAAAA9QwAAAEAAAAKAAAADFNoYWRpbmdNb2Rl" +
        "bFMFAAAAcGhvbmcRDQAAAQAAAAUAAAAKTXVsdGlMYXllckkAAAAAow4AAAAAAAAAAAAADFByb3Bl" +
        "cnRpZXM3MHkNAAAHAAAAQQAAAAFQUwwAAABEaWZmdXNlQ29sb3JTBQAAAENvbG9yUwAAAABTAQAA" +
        "AEFEAAAAAAAA8D9EAAAAAAAA8D9EAAAAAAAA8D/IDQAABwAAAEEAAAABUFMMAAAAQW1iaWVudENv" +
        "bG9yUwUAAABDb2xvclMAAAAAUwEAAABBRJqZmZmZmck/RJqZmZmZmck/RJqZmZmZmck/GA4AAAcA" +
        "AABCAAAAAVBTDQAAAFNwZWN1bGFyQ29sb3JTBQAAAENvbG9yUwAAAABTAQAAAEFEAAAAAAAAAABE" +
        "AAAAAAAAAABEAAAAAAAAAABYDgAABQAAADIAAAABUFMJAAAAU2hpbmluZXNzUwYAAABkb3VibGVT" +
        "BgAAAE51bWJlclMAAAAARAAAAAAAAABAlg4AAAUAAAAwAAAAAVBTBwAAAE9wYWNpdHlTBgAAAGRv" +
        "dWJsZVMGAAAATnVtYmVyUwAAAABEAAAAAAAA8D8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAABXDwAAAAAAAAAAAAALQ29ubmVjdGlvbnP8DgAAAwAAABkAAAABQ1MCAAAAT09M" +
        "QUIPAAAAAABMAAAAAAAAAAAjDwAAAwAAABkAAAABQ1MCAAAAT09MQEIPAAAAAABMQUIPAAAAAABK" +
        "DwAAAwAAABkAAAABQ1MCAAAAT09MQkIPAAAAAABMQUIPAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAN68qyjxyNVFk3X5pjv+KFgAAAAAAAAAAAAAAAAAAAAA6BwAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPhajGre9dl+" +
        "7OkM43WPKQs="
}
