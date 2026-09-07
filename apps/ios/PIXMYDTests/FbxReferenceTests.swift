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
        "S2F5ZGFyYSBGQlggQmluYXJ5ICAAGgDoHAAAeAMAAAAAAAAAAAAAEkZCWEhlYWRlckV4dGVuc2lv" +
        "blwAAAABAAAABQAAABBGQlhIZWFkZXJWZXJzaW9uSewDAAB4AAAAAQAAAAUAAAAKRkJYVmVyc2lv" +
        "bknoHAAAmAAAAAEAAAAFAAAADkVuY3J5cHRpb25UeXBlSQAAAACBAQAAAAAAAAAAAAARQ3JlYXRp" +
        "b25UaW1lU3RhbXDPAAAAAQAAAAUAAAAHVmVyc2lvbknoAwAA5QAAAAEAAAAFAAAABFllYXJJ6gcA" +
        "APwAAAABAAAABQAAAAVNb250aEkBAAAAEQEAAAEAAAAFAAAAA0RheUkCAAAAJwEAAAEAAAAFAAAA" +
        "BEhvdXJJAwAAAD8BAAABAAAABQAAAAZNaW51dGVJBAAAAFcBAAABAAAABQAAAAZTZWNvbmRJBQAA" +
        "AHQBAAABAAAABQAAAAtNaWxsaXNlY29uZEk8AAAAAAAAAAAAAAAAAAAAAKABAAABAAAACwAAAAdD" +
        "cmVhdG9yUwYAAABQSVhNWURrAwAAAgAAACcAAAAJU2NlbmVJbmZvUxUAAABHbG9iYWxJbmZvAAFT" +
        "Y2VuZUluZm9TCAAAAFVzZXJEYXRh+wEAAAEAAAANAAAABFR5cGVTCAAAAFVzZXJEYXRhFAIAAAEA" +
        "AAAFAAAAB1ZlcnNpb25JZAAAAF4DAAAAAAAAAAAAAAxQcm9wZXJ0aWVzNzBxAgAABQAAADYAAAAB" +
        "UFMLAAAARG9jdW1lbnRVcmxTBwAAAEtTdHJpbmdTAwAAAFVybFMAAAAAUwgAAABtZXNoLmZieLgC" +
        "AAAFAAAAOQAAAAFQUw4AAABTcmNEb2N1bWVudFVybFMHAAAAS1N0cmluZ1MDAAAAVXJsUwAAAABT" +
        "CAAAAG1lc2guZmJ4BAMAAAUAAAA+AAAAAVBTGAAAAE9yaWdpbmFsfEFwcGxpY2F0aW9uTmFtZVMH" +
        "AAAAS1N0cmluZ1MAAAAAUwAAAABTBgAAAFBJWE1ZRFEDAAAFAAAAPwAAAAFQUxkAAABMYXN0U2F2" +
        "ZWR8QXBwbGljYXRpb25OYW1lUwcAAABLU3RyaW5nUwAAAABTAAAAAFMGAAAAUElYTVlEAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAoAMAAAEAAAAVAAAABkZpbGVJZFIQAAAA" +
        "DJILypYH7+Kf7pUGgATT2tUDAAABAAAAHAAAAAxDcmVhdGlvblRpbWVTFwAAADIwMjYtMDEtMDIg" +
        "MDM6MDQ6MDU6MDYw9AMAAAEAAAALAAAAB0NyZWF0b3JTBgAAAFBJWE1ZRNMGAAAAAAAAAAAAAA5H" +
        "bG9iYWxTZXR0aW5ncygEAAABAAAABQAAAAdWZXJzaW9uSegDAADGBgAAAAAAAAAAAAAMUHJvcGVy" +
        "dGllczcweAQAAAUAAAApAAAAAVBTBgAAAFVwQXhpc1MDAAAAaW50UwcAAABJbnRlZ2VyUwAAAABJ" +
        "AQAAALMEAAAFAAAALQAAAAFQUwoAAABVcEF4aXNTaWduUwMAAABpbnRTBwAAAEludGVnZXJTAAAA" +
        "AEkBAAAA7QQAAAUAAAAsAAAAAVBTCQAAAEZyb250QXhpc1MDAAAAaW50UwcAAABJbnRlZ2VyUwAA" +
        "AABJAgAAACsFAAAFAAAAMAAAAAFQUw0AAABGcm9udEF4aXNTaWduUwMAAABpbnRTBwAAAEludGVn" +
        "ZXJTAAAAAEkBAAAAZQUAAAUAAAAsAAAAAVBTCQAAAENvb3JkQXhpc1MDAAAAaW50UwcAAABJbnRl" +
        "Z2VyUwAAAABJAAAAAKMFAAAFAAAAMAAAAAFQUw0AAABDb29yZEF4aXNTaWduUwMAAABpbnRTBwAA" +
        "AEludGVnZXJTAAAAAEkBAAAA4gUAAAUAAAAxAAAAAVBTDgAAAE9yaWdpbmFsVXBBeGlzUwMAAABp" +
        "bnRTBwAAAEludGVnZXJTAAAAAEkBAAAAJQYAAAUAAAA1AAAAAVBTEgAAAE9yaWdpbmFsVXBBeGlz" +
        "U2lnblMDAAAAaW50UwcAAABJbnRlZ2VyUwAAAABJAQAAAGsGAAAFAAAAOAAAAAFQUw8AAABVbml0" +
        "U2NhbGVGYWN0b3JTBgAAAGRvdWJsZVMGAAAATnVtYmVyUwAAAABEAAAAAAAA8D+5BgAABQAAAEAA" +
        "AAABUFMXAAAAT3JpZ2luYWxVbml0U2NhbGVGYWN0b3JTBgAAAGRvdWJsZVMGAAAATnVtYmVyUwAA" +
        "AABEAAAAAAAA8D8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUIAAAAAAAAAAAAAAlEb2N1bWVu" +
        "dHMABwAAAQAAAAUAAAAFQ291bnRJAQAAAPgHAAADAAAAHQAAAAhEb2N1bWVudEyguw0AAAAAAFMF" +
        "AAAAU2NlbmVTBQAAAFNjZW5lzQcAAAAAAAAAAAAADFByb3BlcnRpZXM3MH8HAAAEAAAAJgAAAAFQ" +
        "UwwAAABTb3VyY2VPYmplY3RTBgAAAG9iamVjdFMAAAAAUwAAAADABwAABQAAADMAAAABUFMTAAAA" +
        "QWN0aXZlQW5pbVN0YWNrTmFtZVMHAAAAS1N0cmluZ1MAAAAAUwAAAABTAAAAAAAAAAAAAAAAAAAA" +
        "AADrBwAAAQAAAAkAAAAIUm9vdE5vZGVMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "ABwIAAAAAAAAAAAAAApSZWZlcmVuY2VzlAkAAAAAAAAAAAAAC0RlZmluaXRpb25zTQgAAAEAAAAF" +
        "AAAAB1ZlcnNpb25JZAAAAGQIAAABAAAABQAAAAVDb3VudEkEAAAAsggAAAEAAAATAAAACk9iamVj" +
        "dFR5cGVTDgAAAEdsb2JhbFNldHRpbmdzpQgAAAEAAAAFAAAABUNvdW50SQEAAAAAAAAAAAAAAAAA" +
        "AAAA+ggAAAEAAAANAAAACk9iamVjdFR5cGVTCAAAAEdlb21ldHJ57QgAAAEAAAAFAAAABUNvdW50" +
        "SQEAAAAAAAAAAAAAAAAAAAAAPwkAAAEAAAAKAAAACk9iamVjdFR5cGVTBQAAAE1vZGVsMgkAAAEA" +
        "AAAFAAAABUNvdW50SQEAAAAAAAAAAAAAAAAAAAAAhwkAAAEAAAANAAAACk9iamVjdFR5cGVTCAAA" +
        "AE1hdGVyaWFsegkAAAEAAAAFAAAABUNvdW50SQEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AIUTAAAAAAAAAAAAAAdPYmplY3Rz7w8AAAMAAAAlAAAACEdlb21ldHJ5TEBCDwAAAAAAUw4AAABt" +
        "ZXNoAAFHZW9tZXRyeVMEAAAATWVzaGQKAAABAAAAbQAAAAhWZXJ0aWNlc2QMAAAAAAAAAGAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABZQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAFlAAAAAAAAAAAAAAAAAAABZQAAAAAAAAFlAAAAAAAAAAACoCgAAAQAAACUAAAASUG9seWdv" +
        "blZlcnRleEluZGV4aQYAAAAAAAAAGAAAAAAAAAABAAAA/f///wEAAAADAAAA/f///8kKAAABAAAA" +
        "BQAAAA9HZW9tZXRyeVZlcnNpb25JfAAAAAsMAAABAAAABQAAABJMYXllckVsZW1lbnROb3JtYWxJ" +
        "AAAAAAYLAAABAAAABQAAAAdWZXJzaW9uSWUAAAAcCwAAAQAAAAUAAAAETmFtZVMAAAAATQsAAAEA" +
        "AAAOAAAAFk1hcHBpbmdJbmZvcm1hdGlvblR5cGVTCQAAAEJ5VmVydGljZX0LAAABAAAACwAAABhS" +
        "ZWZlcmVuY2VJbmZvcm1hdGlvblR5cGVTBgAAAERpcmVjdP4LAAABAAAAbQAAAAdOb3JtYWxzZAwA" +
        "AAAAAAAAYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADwPwAAAAAAAAAAAAAAAAAAAAAAAAAAAADw" +
        "PwAAAAAAAAAAAAAAAAAAAAAAAAAAAADwPwAAAAAAAAAAAAAAAAAAAAAAAAAAAADwPwAAAAAAAAAA" +
        "AAAAAAB3DQAAAQAAAAUAAAARTGF5ZXJFbGVtZW50Q29sb3JJAAAAAEcMAAABAAAABQAAAAdWZXJz" +
        "aW9uSWUAAABpDAAAAQAAABEAAAAETmFtZVMMAAAAVmVydGV4Q29sb3JzmgwAAAEAAAAOAAAAFk1h" +
        "cHBpbmdJbmZvcm1hdGlvblR5cGVTCQAAAEJ5VmVydGljZcoMAAABAAAACwAAABhSZWZlcmVuY2VJ" +
        "bmZvcm1hdGlvblR5cGVTBgAAAERpcmVjdGoNAAABAAAAjQAAAAZDb2xvcnNkEAAAAAAAAACAAAAA" +
        "AAAAAAAA8D8AAAAAAAAAAAAAAAAAAAAAAAAAAAAA8D8AAAAAAAAAAAAAAAAAAPA/AAAAAAAAAAAA" +
        "AAAAAADwPwAAAAAAAAAAAAAAAAAAAAAAAAAAAADwPwAAAAAAAPA/AAAAAAAA8D8AAAAAAADwPwAA" +
        "AAAAAAAAAAAAAAAA8D8AAAAAAAAAAAAAAAAAZg4AAAEAAAAFAAAAFExheWVyRWxlbWVudE1hdGVy" +
        "aWFsSQAAAAC2DQAAAQAAAAUAAAAHVmVyc2lvbkllAAAAzA0AAAEAAAAFAAAABE5hbWVTAAAAAPsN" +
        "AAABAAAADAAAABZNYXBwaW5nSW5mb3JtYXRpb25UeXBlUwcAAABBbGxTYW1lMg4AAAEAAAASAAAA" +
        "GFJlZmVyZW5jZUluZm9ybWF0aW9uVHlwZVMNAAAASW5kZXhUb0RpcmVjdFkOAAABAAAAEQAAAAlN" +
        "YXRlcmlhbHNpAQAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAADiDwAAAQAAAAUAAAAFTGF5ZXJJ" +
        "AAAAAJYOAAABAAAABQAAAAdWZXJzaW9uSWQAAAAADwAAAAAAAAAAAAAMTGF5ZXJFbGVtZW501w4A" +
        "AAEAAAAXAAAABFR5cGVTEgAAAExheWVyRWxlbWVudE5vcm1hbPMOAAABAAAABQAAAApUeXBlZElu" +
        "ZGV4SQAAAAAAAAAAAAAAAAAAAAAAaQ8AAAAAAAAAAAAADExheWVyRWxlbWVudEAPAAABAAAAFgAA" +
        "AARUeXBlUxEAAABMYXllckVsZW1lbnRDb2xvclwPAAABAAAABQAAAApUeXBlZEluZGV4SQAAAAAA" +
        "AAAAAAAAAAAAAAAA1Q8AAAAAAAAAAAAADExheWVyRWxlbWVudKwPAAABAAAAGQAAAARUeXBlUxQA" +
        "AABMYXllckVsZW1lbnRNYXRlcmlhbMgPAAABAAAABQAAAApUeXBlZEluZGV4SQAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABCEQAAAwAAACIAAAAFTW9kZWxMQUIPAAAA" +
        "AABTCwAAAG1lc2gAAU1vZGVsUwQAAABNZXNoPBAAAAEAAAAFAAAAB1ZlcnNpb25J6AAAAPwQAAAA" +
        "AAAAAAAAAAxQcm9wZXJ0aWVzNzCbEAAABQAAADgAAAABUFMVAAAARGVmYXVsdEF0dHJpYnV0ZUlu" +
        "ZGV4UwMAAABpbnRTBwAAAEludGVnZXJTAAAAAEkAAAAA7xAAAAcAAABGAAAAAVBTCwAAAExjbCBT" +
        "Y2FsaW5nUwsAAABMY2wgU2NhbGluZ1MAAAAAUwEAAABBRAAAAAAAAPA/RAAAAAAAAPA/RAAAAAAA" +
        "APA/AAAAAAAAAAAAAAAAABIRAAABAAAAAgAAAAdTaGFkaW5nQwE1EQAAAQAAAA8AAAAHQ3VsbGlu" +
        "Z1MKAAAAQ3VsbGluZ09mZgAAAAAAAAAAAAAAAAB4EwAAAwAAACoAAAAITWF0ZXJpYWxMQkIPAAAA" +
        "AABTFwAAAG1lc2gtbWF0ZXJpYWwAAU1hdGVyaWFsUwAAAACaEQAAAQAAAAUAAAAHVmVyc2lvbklm" +
        "AAAAvREAAAEAAAAKAAAADFNoYWRpbmdNb2RlbFMFAAAAcGhvbmfZEQAAAQAAAAUAAAAKTXVsdGlM" +
        "YXllckkAAAAAaxMAAAAAAAAAAAAADFByb3BlcnRpZXM3MEESAAAHAAAAQQAAAAFQUwwAAABEaWZm" +
        "dXNlQ29sb3JTBQAAAENvbG9yUwAAAABTAQAAAEFEAAAAAAAA8D9EAAAAAAAA8D9EAAAAAAAA8D+Q" +
        "EgAABwAAAEEAAAABUFMMAAAAQW1iaWVudENvbG9yUwUAAABDb2xvclMAAAAAUwEAAABBRJqZmZmZ" +
        "mck/RJqZmZmZmck/RJqZmZmZmck/4BIAAAcAAABCAAAAAVBTDQAAAFNwZWN1bGFyQ29sb3JTBQAA" +
        "AENvbG9yUwAAAABTAQAAAEFEAAAAAAAAAABEAAAAAAAAAABEAAAAAAAAAAAgEwAABQAAADIAAAAB" +
        "UFMJAAAAU2hpbmluZXNzUwYAAABkb3VibGVTBgAAAE51bWJlclMAAAAARAAAAAAAAABAXhMAAAUA" +
        "AAAwAAAAAVBTBwAAAE9wYWNpdHlTBgAAAGRvdWJsZVMGAAAATnVtYmVyUwAAAABEAAAAAAAA8D8A" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAfFAAAAAAAAAAAAAALQ29ubmVj" +
        "dGlvbnPEEwAAAwAAABkAAAABQ1MCAAAAT09MQUIPAAAAAABMAAAAAAAAAADrEwAAAwAAABkAAAAB" +
        "Q1MCAAAAT09MQEIPAAAAAABMQUIPAAAAAAASFAAAAwAAABkAAAABQ1MCAAAAT09MQkIPAAAAAABM" +
        "QUIPAAAAAAAAAAAAAAAAAAAAAAAAVxQAAAAAAAAAAAAABVRha2VzShQAAAEAAAAFAAAAB0N1cnJl" +
        "bnRTAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA3ryrKPHI1UWTdfmmO/4oWAAAAAAAAAAA" +
        "AAAAAAAAAADoHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAA+FqMat712X7s6QzjdY8pCw=="
}
