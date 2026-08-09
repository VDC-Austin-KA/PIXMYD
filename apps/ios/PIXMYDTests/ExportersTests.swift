import Foundation
import XCTest
@testable import PIXMYD

/// Reads the fields these tests need back out of the written files.
///
/// Deliberately a separate, dumber implementation than the writers: parsing
/// with shared helpers would mean a writer bug and a reader bug could cancel
/// out. Everything here reads the bytes at their documented offsets.
private struct Bytes {
    let data: Data

    init(_ url: URL) throws { data = try Data(contentsOf: url) }

    func u8(_ offset: Int) -> UInt8 { data[data.startIndex + offset] }

    func u16(_ offset: Int) -> UInt16 {
        UInt16(u8(offset)) | UInt16(u8(offset + 1)) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in (0..<4).reversed() { value = value << 8 | UInt32(u8(offset + i)) }
        return value
    }

    func i32(_ offset: Int) -> Int32 { Int32(bitPattern: u32(offset)) }

    func f32(_ offset: Int) -> Float { Float(bitPattern: u32(offset)) }

    func f64(_ offset: Int) -> Double {
        var value: UInt64 = 0
        for i in (0..<8).reversed() { value = value << 8 | UInt64(u8(offset + i)) }
        return Double(bitPattern: value)
    }

    func ascii(_ offset: Int, _ count: Int) -> String {
        String(decoding: data[(data.startIndex + offset)..<(data.startIndex + offset + count)], as: UTF8.self)
    }
}

final class ExportersTests: XCTestCase {

    private var directory = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pixmyd-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    // MARK: - PLY

    func testPointCloudPlyHeaderAndPayloadAgree() throws {
        let positions: [SIMD3<Double>] = [
            SIMD3(1, 2, 3), SIMD3(-4.5, 0.25, 6), SIMD3(0, 0, 0),
        ]
        let colors: [SIMD3<UInt8>] = [SIMD3(255, 0, 0), SIMD3(0, 255, 0), SIMD3(0, 0, 255)]
        let file = url("cloud.ply")
        try Exporters.writePointCloudPly(positions: positions, colors: colors, to: file)

        let bytes = try Bytes(file)
        let text = String(decoding: bytes.data, as: UTF8.self)
        let headerEnd = try XCTUnwrap(text.range(of: "end_header\n"))
        let headerLength = text.distance(from: text.startIndex, to: headerEnd.upperBound)

        XCTAssertTrue(text.hasPrefix("ply\nformat binary_little_endian 1.0\n"))
        XCTAssertTrue(text.contains("element vertex 3\n"))

        // The count in the header and the number of records that actually
        // follow it must match. A header claiming more vertices than the file
        // contains is the classic PLY bug: most viewers read past the end and
        // render garbage rather than reporting an error.
        let stride = 3 * 4 + 3
        XCTAssertEqual(bytes.data.count - headerLength, positions.count * stride)

        for (index, expected) in positions.enumerated() {
            let base = headerLength + index * stride
            XCTAssertEqual(bytes.f32(base), Float(expected.x))
            XCTAssertEqual(bytes.f32(base + 4), Float(expected.y))
            XCTAssertEqual(bytes.f32(base + 8), Float(expected.z))
            XCTAssertEqual(bytes.u8(base + 12), colors[index].x)
            XCTAssertEqual(bytes.u8(base + 13), colors[index].y)
            XCTAssertEqual(bytes.u8(base + 14), colors[index].z)
        }
    }

    func testPointCloudPlyWithoutColorsOmitsTheProperties() throws {
        let file = url("plain.ply")
        try Exporters.writePointCloudPly(positions: [SIMD3(1, 1, 1)], colors: nil, to: file)
        let text = String(decoding: try Bytes(file).data, as: UTF8.self)
        XCTAssertFalse(text.contains("property uchar red"))
        XCTAssertEqual(try Bytes(file).data.count, text.range(of: "end_header\n").map { text.distance(from: text.startIndex, to: $0.upperBound) }! + 12)
    }

    func testMeshPlyFacesAreLengthPrefixed() throws {
        let positions: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
        let file = url("mesh.ply")
        try Exporters.writeMeshPly(positions: positions, normals: nil, indices: [0, 1, 2], to: file)

        let bytes = try Bytes(file)
        let text = String(decoding: bytes.data, as: UTF8.self)
        XCTAssertTrue(text.contains("element face 1\n"))
        XCTAssertTrue(text.contains("property list uchar uint vertex_indices\n"))

        let headerEnd = try XCTUnwrap(text.range(of: "end_header\n"))
        let base = text.distance(from: text.startIndex, to: headerEnd.upperBound) + positions.count * 12
        // Each face is a uchar count followed by that many uint32 indices.
        XCTAssertEqual(bytes.u8(base), 3)
        XCTAssertEqual(bytes.u32(base + 1), 0)
        XCTAssertEqual(bytes.u32(base + 5), 1)
        XCTAssertEqual(bytes.u32(base + 9), 2)
        XCTAssertEqual(bytes.data.count, base + 13)
    }

    // MARK: - OBJ

    func testObjIndicesAreOneBased() throws {
        let file = url("mesh.obj")
        try Exporters.writeObj(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            normals: nil,
            indices: [0, 1, 2],
            to: file
        )
        let text = try String(contentsOf: file, encoding: .utf8)
        // OBJ is 1-based. A 0 in a face line is not an off-by-one that shifts
        // the mesh; it is invalid, and most loaders reject the whole file.
        XCTAssertTrue(text.contains("\nf 1 2 3\n"))
        XCTAssertFalse(text.contains("f 0"))
    }

    func testObjWithNormalsUsesTheDoubleSlashForm() throws {
        let file = url("normals.obj")
        try Exporters.writeObj(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
            indices: [0, 1, 2],
            to: file
        )
        let text = try String(contentsOf: file, encoding: .utf8)
        // v//vn, not v/vt/vn — there are no texture coordinates, and writing
        // "1/1/1" would make loaders look for a vt that does not exist.
        XCTAssertTrue(text.contains("\nf 1//1 2//2 3//3\n"))
        XCTAssertEqual(text.components(separatedBy: "\nvn ").count - 1, 3)
    }

    // MARK: - GLB

    func testGlbContainerStructure() throws {
        let file = url("mesh.glb")
        try Exporters.writeGlb(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            normals: nil,
            indices: [0, 1, 2],
            to: file
        )

        let bytes = try Bytes(file)
        XCTAssertEqual(bytes.ascii(0, 4), "glTF")
        XCTAssertEqual(bytes.u32(4), 2)
        // The header's total length must equal the file size, or viewers that
        // trust it will truncate the binary chunk.
        XCTAssertEqual(Int(bytes.u32(8)), bytes.data.count)

        let jsonLength = Int(bytes.u32(12))
        XCTAssertEqual(bytes.ascii(16, 4), "JSON")
        XCTAssertEqual(jsonLength % 4, 0, "chunk lengths must be 4-byte aligned")

        let binHeader = 20 + jsonLength
        XCTAssertEqual(bytes.u8(binHeader + 4), 0x42) // 'B' of "BIN\0"
        XCTAssertEqual(bytes.u8(binHeader + 7), 0x00)
        XCTAssertEqual(binHeader + 8 + Int(bytes.u32(binHeader)), bytes.data.count)

        let json = try JSONSerialization.jsonObject(
            with: bytes.data.subdata(in: (20)..<(20 + jsonLength))
        ) as? [String: Any]
        let gltf = try XCTUnwrap(json)
        XCTAssertEqual((gltf["asset"] as? [String: Any])?["version"] as? String, "2.0")

        // Every accessor of an index buffer must declare an integer component
        // type; a float here loads as a blank mesh in most viewers.
        let accessors = try XCTUnwrap(gltf["accessors"] as? [[String: Any]])
        let indexAccessor = try XCTUnwrap(accessors.first { $0["type"] as? String == "SCALAR" })
        XCTAssertEqual(indexAccessor["componentType"] as? Int, 5125) // UNSIGNED_INT
        XCTAssertEqual(indexAccessor["count"] as? Int, 3)

        // POSITION accessors are required by the spec to carry min and max.
        let positionAccessor = try XCTUnwrap(accessors.first { $0["type"] as? String == "VEC3" })
        XCTAssertEqual(positionAccessor["min"] as? [Double], [0, 0, 0])
        XCTAssertEqual(positionAccessor["max"] as? [Double], [1, 1, 0])
    }

    // MARK: - LAS

    func testLasHeaderGeometryAndScaling() throws {
        // A deliberately awkward origin: this is roughly a Texas State Plane
        // northing in metres, far enough out that storing the coordinates as
        // float32 would quantise them to decimetres. LAS stores scaled int32
        // offsets from a float64 origin precisely so it does not have to.
        let origin = SIMD3<Double>(950_000, 4_180_000, 180)
        let positions: [SIMD3<Double>] = [
            SIMD3(0, 0, 0), SIMD3(1.234, -2.345, 3.456), SIMD3(-10, 10, 0.001),
        ]
        let file = url("cloud.las")
        try Exporters.writeLas(positions: positions, colors: nil, origin: origin, to: file)

        let bytes = try Bytes(file)
        XCTAssertEqual(bytes.ascii(0, 4), "LASF")
        XCTAssertEqual(bytes.u8(24), 1)          // version major
        XCTAssertEqual(bytes.u8(25), 4)          // version minor
        XCTAssertEqual(bytes.u16(105), 20)       // point record length, format 0
        XCTAssertEqual(bytes.u8(104), 0)         // point data format

        let headerSize = Int(bytes.u16(94))
        XCTAssertEqual(headerSize, 375, "LAS 1.4 headers are exactly 375 bytes")
        let dataOffset = Int(bytes.u32(96))
        XCTAssertEqual(dataOffset, headerSize)

        // Legacy point count is 32-bit at 107; 1.4 repeats it as 64-bit at 247.
        XCTAssertEqual(Int(bytes.u32(107)), positions.count)

        let scaleX = bytes.f64(131)
        let offsetX = bytes.f64(155)
        let offsetY = bytes.f64(163)
        let offsetZ = bytes.f64(171)
        XCTAssertEqual(scaleX, 0.001)

        // Round-trip every point through the header's scale and offset and
        // compare against world coordinates. Half a scale unit is the most a
        // correct writer can be out.
        for (index, local) in positions.enumerated() {
            let base = dataOffset + index * 20
            let x = Double(bytes.i32(base)) * scaleX + offsetX
            let y = Double(bytes.i32(base + 4)) * bytes.f64(139) + offsetY
            let z = Double(bytes.i32(base + 8)) * bytes.f64(147) + offsetZ
            let world = local + origin
            XCTAssertEqual(x, world.x, accuracy: 0.0005)
            XCTAssertEqual(y, world.y, accuracy: 0.0005)
            XCTAssertEqual(z, world.z, accuracy: 0.0005)
        }

        // The bounding box is in world coordinates, and it is what a GIS reads
        // to place the tile before it opens a single point.
        XCTAssertEqual(bytes.f64(179), origin.x + 1.234, accuracy: 1e-6)  // max x
        XCTAssertEqual(bytes.f64(187), origin.x - 10, accuracy: 1e-6)     // min x
    }

    func testLasWithColorsUsesFormatTwo() throws {
        let file = url("colored.las")
        try Exporters.writeLas(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 1, 1)],
            colors: [SIMD3(255, 128, 0), SIMD3(0, 0, 0)],
            origin: .zero,
            to: file
        )
        let bytes = try Bytes(file)
        XCTAssertEqual(bytes.u8(104), 2)     // point data format 2 = colour
        XCTAssertEqual(bytes.u16(105), 26)   // 20 bytes + three uint16 channels

        // LAS colour channels are 16-bit. Writing an 8-bit value straight in
        // makes every cloud render nearly black in software that scales to the
        // full 16-bit range.
        let dataOffset = Int(bytes.u32(96))
        XCTAssertEqual(bytes.u16(dataOffset + 20), 255 << 8 | 255)
    }

    func testLasWithNoPointsIsStillAValidFile() throws {
        let file = url("empty.las")
        try Exporters.writeLas(positions: [], colors: nil, origin: .zero, to: file)
        let bytes = try Bytes(file)
        XCTAssertEqual(bytes.ascii(0, 4), "LASF")
        XCTAssertEqual(Int(bytes.u32(107)), 0)
        // Not the ±greatestFiniteMagnitude the bounds are seeded with: those
        // serialise as ±1.8e308 and make a GIS zoom to the whole universe.
        XCTAssertEqual(bytes.f64(179), 0)
        XCTAssertEqual(bytes.f64(187), 0)
        XCTAssertEqual(bytes.data.count, Int(bytes.u32(96)))
    }

    // MARK: - Format catalogue

    func testEveryExportFormatHasADistinctExtension() {
        let extensions = ExportFormat.allCases.map(\.rawValue)
        XCTAssertEqual(Set(extensions).count, extensions.count)
        XCTAssertFalse(extensions.isEmpty)
    }
}
