import Foundation
import XCTest
@testable import PIXMYD

/// The colour atlas is the thing that makes a textured export honest: it turns
/// the per-vertex colours fusion produces into a texture every importer reads.
/// These tests decode the PNG the writer produced with a deliberately separate
/// implementation — chunk walk, CRC, zlib stored blocks, row reconstruction —
/// so a writer bug cannot cancel out with a test bug.
final class ColorAtlasTests: XCTestCase {

    // MARK: - PNG

    func testPngIsStructurallyValid() throws {
        // 2x2 RGB image with known pixels.
        let rgb: [UInt8] = [
            255, 0, 0,  0, 255, 0,
            0, 0, 255,  255, 255, 255,
        ]
        let png = try PngWriter.encodeRgb(width: 2, height: 2, rgb: rgb)
        let decoded = try decodePngRgb(Data(png))
        XCTAssertEqual(decoded.width, 2)
        XCTAssertEqual(decoded.height, 2)
        XCTAssertEqual(decoded.rgb, rgb)
    }

    func testPngRejectsBadInput() {
        XCTAssertThrowsError(try PngWriter.encodeRgb(width: 0, height: 1, rgb: []))
        XCTAssertThrowsError(try PngWriter.encodeRgb(width: 1, height: 1, rgb: [1, 2]))
    }

    // MARK: - Atlas

    func testBakeReturnsNilForColourlessMesh() throws {
        let atlas = try ColorAtlasBaker.bake(colors: nil, indices: [0, 1, 2], vertexCount: 3)
        XCTAssertNil(atlas)
    }

    func testBakeThrowsWhenThereAreNoTriangles() {
        XCTAssertThrowsError(try ColorAtlasBaker.bake(
            colors: [SIMD3<UInt8>(1, 2, 3)], indices: [], vertexCount: 1
        ))
    }

    func testBakeMakesOneTexelPerTriangleWithTheAveragedColour() throws {
        // Four vertices, two triangles, one shared edge.
        let colors: [SIMD3<UInt8>] = [
            SIMD3(10, 20, 30), SIMD3(40, 50, 60),
            SIMD3(70, 80, 90), SIMD3(200, 210, 220),
        ]
        let indices: [UInt32] = [0, 1, 2, 1, 3, 2]
        let atlas = try XCTUnwrap(ColorAtlasBaker.bake(colors: colors, indices: indices, vertexCount: 4))

        XCTAssertEqual(atlas.side, 2, "two triangles want a 2x2 atlas")
        XCTAssertEqual(atlas.triangleUvs.count, 2)

        let decoded = try decodePngRgb(Data(atlas.texture.data))
        XCTAssertEqual(decoded.width, 2)
        XCTAssertEqual(decoded.height, 2)

        // Texel 0 is the average of the first triangle's three corners.
        XCTAssertEqual(decoded.rgb[0], 40)   // (10+40+70) / 3
        XCTAssertEqual(decoded.rgb[1], 50)   // (20+50+80) / 3
        XCTAssertEqual(decoded.rgb[2], 60)   // (30+60+90) / 3
        // Texel 1 is the average of the second triangle's three corners.
        XCTAssertEqual(decoded.rgb[3], 103)  // (40+200+70) / 3
        XCTAssertEqual(decoded.rgb[4], 113)  // (50+210+80) / 3
        XCTAssertEqual(decoded.rgb[5], 123)  // (60+220+90) / 3

        // UVs sit at the exact centres of their texels in image space.
        XCTAssertEqual(atlas.triangleUvs[0], SIMD2<Float>(0.25, 0.25))
        XCTAssertEqual(atlas.triangleUvs[1], SIMD2<Float>(0.75, 0.25))
    }

    func testAtlasSideIsTheSmallestSquare() {
        XCTAssertEqual(ColorAtlasBaker.atlasSide(for: 0), 1)
        XCTAssertEqual(ColorAtlasBaker.atlasSide(for: 1), 1)
        XCTAssertEqual(ColorAtlasBaker.atlasSide(for: 2), 2)
        XCTAssertEqual(ColorAtlasBaker.atlasSide(for: 4), 2)
        XCTAssertEqual(ColorAtlasBaker.atlasSide(for: 5), 3)
        XCTAssertEqual(ColorAtlasBaker.atlasSide(for: 100), 10)
        XCTAssertEqual(ColorAtlasBaker.atlasSide(for: 10000), 100)
    }

    func testPolygonUvsRepeatEachTriangleUvForEveryCorner() throws {
        let colors: [SIMD3<UInt8>] = [SIMD3(1, 2, 3), SIMD3(4, 5, 6), SIMD3(7, 8, 9), SIMD3(10, 11, 12)]
        let indices: [UInt32] = [0, 1, 2, 1, 3, 2]
        let atlas = try XCTUnwrap(ColorAtlasBaker.bake(colors: colors, indices: indices, vertexCount: 4))
        let uvs = ColorAtlasBaker.polygonUvs(of: atlas, for: indices)
        XCTAssertEqual(uvs.count, 6)
        XCTAssertEqual(uvs[0], atlas.triangleUvs[0])
        XCTAssertEqual(uvs[1], atlas.triangleUvs[0])
        XCTAssertEqual(uvs[2], atlas.triangleUvs[0])
        XCTAssertEqual(uvs[3], atlas.triangleUvs[1])
        XCTAssertEqual(uvs[4], atlas.triangleUvs[1])
        XCTAssertEqual(uvs[5], atlas.triangleUvs[1])
    }

    // MARK: - Independent PNG decoder

    private struct DecodedPng {
        var width: Int
        var height: Int
        var rgb: [UInt8]
    }

    /// Reads a PNG back to pixels with none of the writer's code: verify the
    /// signature, walk the chunks recomputing every CRC, unroll the stored
    /// deflate blocks checking LEN/NLEN, and check the adler32.
    private func decodePngRgb(_ data: Data) throws -> DecodedPng {
        XCTAssertEqual(
            [UInt8](data.prefix(8)),
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
            "PNG signature"
        )

        var offset = 8
        var width = 0
        var height = 0
        var idat = Data()

        while offset + 12 <= data.count {
            let length = Int(beU32(data, offset))
            let type = String(decoding: data[(data.startIndex + offset + 4)..<(data.startIndex + offset + 8)], as: UTF8.self)
            let chunkData = data[(data.startIndex + offset + 8)..<(data.startIndex + offset + 8 + length)]

            // The CRC covers the four type bytes and the data.
            var crcInput = [UInt8](data[(data.startIndex + offset + 4)..<(data.startIndex + offset + 8 + length)])
            XCTAssertEqual(beU32(data, offset + 8 + length), crc32(crcInput), "CRC of \(type)")

            switch type {
            case "IHDR":
                width = Int(beU32(chunkData, 0))
                height = Int(beU32(chunkData, 4))
                XCTAssertEqual(chunkData[chunkData.startIndex + 8], 8)    // bit depth
                XCTAssertEqual(chunkData[chunkData.startIndex + 9], 2)    // colour type: RGB
                XCTAssertEqual(chunkData[chunkData.startIndex + 10], 0)   // deflate
                XCTAssertEqual(chunkData[chunkData.startIndex + 11], 0)   // no filter
                XCTAssertEqual(chunkData[chunkData.startIndex + 12], 0)   // no interlace
            case "IDAT":
                idat.append(contentsOf: chunkData)
            case "IEND":
                XCTAssertEqual(length, 0)
            default:
                XCTFail("unexpected chunk \(type)")
            }
            offset = offset + 8 + length + 4
        }
        XCTAssertEqual(offset, data.count, "chunks must exactly fill the file")

        // zlib stream: 0x78 0x01, stored blocks, adler32 trailer.
        XCTAssertEqual(idat[idat.startIndex], 0x78)
        XCTAssertEqual(idat[idat.startIndex + 1], 0x01)
        var raw = Data()
        var position = 2
        while position < idat.count - 4 {
            let header = idat[idat.startIndex + position]
            position += 1
            XCTAssertEqual((header >> 1) & 3, 0, "atlas PNG must use stored blocks")
            let length = Int(leU16(idat, position))
            let complement = Int(leU16(idat, position + 2))
            XCTAssertEqual(complement, 0xFFFF - length, "NLEN must be the ones complement of LEN")
            position += 4
            raw.append(contentsOf: idat[(idat.startIndex + position)..<(idat.startIndex + position + length)])
            position += length
            if header & 1 == 1 { break }
        }
        XCTAssertEqual(beU32(idat, idat.count - 4), adler32([UInt8](raw)))

        // One filter byte per scanline, then width*3 RGB bytes.
        XCTAssertEqual(raw.count, height * (1 + width * 3))
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for row in 0..<height {
            let rowStart = row * (1 + width * 3)
            XCTAssertEqual(raw[rowStart], 0, "filter type must be none")
            rgb.replaceSubrange(
                row * width * 3..<((row + 1) * width * 3),
                with: raw[(raw.startIndex + rowStart + 1)..<(raw.startIndex + rowStart + 1 + width * 3)]
            )
        }
        return DecodedPng(width: width, height: height, rgb: rgb)
    }

    // MARK: - Independent checksums

    private func beU32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16
            | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    }

    private func leU16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    /// Bit-by-bit CRC-32, so it cannot share a bug with the writer's table.
    private func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            c ^= UInt32(byte)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : (c >> 1)
            }
        }
        return c ^ 0xFFFF_FFFF
    }

    private func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}
