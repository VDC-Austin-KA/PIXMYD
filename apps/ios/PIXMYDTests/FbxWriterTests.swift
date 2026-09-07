import Foundation
import XCTest
@testable import PIXMYD

/// FBX is proprietary and has no published specification, so these tests check
/// what can be checked without the Autodesk SDK: the header and footer layout,
/// the bytes that come back out of the writer's own parser (whose offset
/// walking is itself the real check — every endOffset has to land exactly on
/// the next node), and the geometry the parser recovers. The TypeScript twin
/// of this writer is additionally validated against three.js's FBXLoader in
/// the monorepo tests; this Swift port must not drift from it.
final class FbxWriterTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pixmyd-fbx-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Two triangles sharing an edge, with a normal and a colour per vertex.
    private let positions: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0),
    ]
    private let normals: [SIMD3<Float>] = [
        SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1),
    ]
    private let colors: [SIMD3<UInt8>] = [
        SIMD3(255, 0, 0), SIMD3(0, 255, 0), SIMD3(0, 0, 255), SIMD3(255, 255, 0),
    ]
    private let indices: [UInt32] = [0, 1, 2, 1, 3, 2]

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    // MARK: - File structure

    func testHeaderMagicVersionAndFooterExtension() throws {
        let file = url("mesh.fbx")
        try FbxWriter.writeMesh(positions: positions, normals: nil, colors: nil, indices: [0, 1, 2], to: file)
        let bytes = try Data(contentsOf: file)

        // Header: 20-byte magic, three sentinel bytes, then the version.
        XCTAssertEqual(
            String(decoding: bytes[bytes.startIndex..<(bytes.startIndex + 20)], as: UTF8.self),
            "Kaydara FBX Binary  "
        )
        XCTAssertEqual(bytes[bytes.startIndex + 20], 0x00)
        XCTAssertEqual(bytes[bytes.startIndex + 21], 0x1A)
        XCTAssertEqual(bytes[bytes.startIndex + 22], 0x00)
        XCTAssertEqual(leU32(bytes, 23), 7400)

        // Every FBX file ends with the fixed extension magic; a parser uses it
        // to find the footer, so losing it makes the file unreadable.
        XCTAssertEqual([UInt8](bytes.suffix(16)), FbxWriter.footerExtension)
    }

    func testParserWalksTheWholeDocument() throws {
        let file = url("mesh.fbx")
        try FbxWriter.writeMesh(
            positions: positions, normals: normals, colors: colors,
            indices: indices, to: file
        )
        let nodes = try FbxWriter.parse(try Data(contentsOf: file))
        // Walking this far without a thrown offset mismatch is the check:
        // every endOffset must land exactly on the next node's first byte.
        XCTAssertEqual(
            nodes.map(\.name),
            // The same sections, in the same order, as an FBX written by
            // Autodesk's own SDK. That list is the spec as far as a black-box
            // reader is concerned.
            ["FBXHeaderExtension", "FileId", "CreationTime", "Creator", "GlobalSettings",
             "Documents", "References", "Definitions", "Objects", "Connections", "Takes"]
        )

        // Blender and three.js load a file with none of the following, which is
        // exactly why it is asserted here: the permissive parsers are the ones
        // that are easy to test against, and Navisworks is not one of them.
        let header = try XCTUnwrap(FbxWriter.findNode(nodes, named: "FBXHeaderExtension"))
        let stamp = try XCTUnwrap(header.children.first { $0.name == "CreationTimeStamp" })
        XCTAssertEqual(
            stamp.children.map(\.name),
            ["Version", "Year", "Month", "Day", "Hour", "Minute", "Second", "Millisecond"]
        )

        XCTAssertEqual(
            header.children.first { $0.name == "FBXHeaderVersion" }?.props[0] as? Int32, 1004)
        XCTAssertNotNil(header.children.first { $0.name == "SceneInfo" })

        // FileId is the source id encrypted once with the creation stamp, and
        // the footer code is that same value two encryptions further on.
        // Sixteen bytes that are not all zero is the cheap end of asserting
        // they are one chain.
        let id = try XCTUnwrap(FbxWriter.findNode(nodes, named: "FileId")?.props[0] as? [UInt8])
        XCTAssertEqual(id.count, 16)
        XCTAssertTrue(id.contains { $0 != 0 }, "FileId is not blank")
        let created = try XCTUnwrap(
            FbxWriter.findNode(nodes, named: "CreationTime")?.props[0] as? String)
        XCTAssertEqual(created.count, 23, "YYYY-MM-DD HH:MM:SS:mmm")

        let document = try XCTUnwrap(FbxWriter.findNode(nodes, named: "Document"))
        XCTAssertEqual(document.props[1] as? String, "Scene")
        XCTAssertEqual(
            document.children.first { $0.name == "RootNode" }?.props[0] as? Int64, 0)

        // The count is the object total including GlobalSettings — not the
        // number of ObjectType entries, and not the number of Objects children.
        let definitions = try XCTUnwrap(FbxWriter.findNode(nodes, named: "Definitions"))
        XCTAssertEqual(
            definitions.children.filter { $0.name == "ObjectType" }
                .compactMap { $0.props.first as? String },
            ["GlobalSettings", "Geometry", "Model", "Material"]
        )
        XCTAssertEqual(
            definitions.children.first { $0.name == "Count" }?.props[0] as? Int32, 4)
    }

    func testParseRejectsTruncatedData() throws {
        let file = url("mesh.fbx")
        try FbxWriter.writeMesh(positions: positions, normals: nil, colors: nil, indices: [0, 1, 2], to: file)
        let bytes = try Data(contentsOf: file)

        let whole = try FbxWriter.parse(bytes)
        let wholeNames = whole.map(\.name)
        let wholeVertices = try XCTUnwrap(
            FbxWriter.findNode(whole, named: "Vertices")?.props[0] as? [Double])

        // Cut at many points rather than one. Where the halfway byte falls is a
        // fact about the node layout, not about truncation, so a test that cuts
        // once starts passing — or failing — for the wrong reason the moment a
        // section is added.
        //
        // The invariant is not "every prefix throws". A cut inside the trailing
        // footer leaves the node list complete, and a walk that terminates at
        // its own NULL record cannot see past it to know bytes are missing;
        // that is the format, not a defect. What must never happen is a prefix
        // that parses into a document presenting as whole while missing part of
        // the mesh. So: parse, or be complete.
        let step = max(1, bytes.count / 128)
        for cut in stride(from: 27, to: bytes.count, by: step) {
            let nodes: [FbxWriter.ParsedNode]
            do {
                nodes = try FbxWriter.parse(bytes.prefix(cut))
            } catch {
                continue    // the expected outcome, and what most cuts do
            }
            XCTAssertEqual(
                nodes.map(\.name), wholeNames,
                "a \(cut)-byte prefix of \(bytes.count) parsed into a partial document"
            )
            XCTAssertEqual(
                FbxWriter.findNode(nodes, named: "Vertices")?.props[0] as? [Double],
                wholeVertices,
                "a \(cut)-byte prefix parsed but its mesh is not the whole mesh"
            )
        }
    }

    // MARK: - Geometry

    func testVerticesAreScaledToCentimetres() throws {
        let file = url("mesh.fbx")
        try FbxWriter.writeMesh(positions: positions, normals: nil, colors: nil, indices: indices, to: file)
        let nodes = try FbxWriter.parse(try Data(contentsOf: file))
        let vertices = try XCTUnwrap(FbxWriter.findNode(nodes, named: "Vertices")?.props[0] as? [Double])
        XCTAssertEqual(vertices.count, positions.count * 3)
        // FBX's native unit is the centimetre and most importers treat raw
        // values as such, so a 1 m mesh must arrive as 100 FBX units.
        XCTAssertEqual(vertices[0], 0)
        XCTAssertEqual(vertices[3], 100)
        XCTAssertEqual(vertices[7], 100)
    }

    func testMetreUnitsWriteRawValues() throws {
        let file = url("mesh.fbx")
        try FbxWriter.writeMesh(
            positions: positions, normals: nil, colors: nil, indices: indices,
            options: FbxWriter.WriteOptions(units: .m), to: file
        )
        let nodes = try FbxWriter.parse(try Data(contentsOf: file))
        let vertices = try XCTUnwrap(FbxWriter.findNode(nodes, named: "Vertices")?.props[0] as? [Double])
        XCTAssertEqual(vertices[3], 1)
        XCTAssertEqual(vertices[7], 1)
    }

    func testLastCornerOfEachPolygonIsBitwiseNegated() throws {
        let file = url("mesh.fbx")
        try FbxWriter.writeMesh(positions: positions, normals: nil, colors: nil, indices: indices, to: file)
        let nodes = try FbxWriter.parse(try Data(contentsOf: file))
        let polygon = try XCTUnwrap(FbxWriter.findNode(nodes, named: "PolygonVertexIndex")?.props[0] as? [Int32])
        XCTAssertEqual(polygon.count, indices.count)
        XCTAssertEqual(polygon[0], 0)
        XCTAssertEqual(polygon[1], 1)
        XCTAssertEqual(polygon[2], ~2)
        XCTAssertEqual(polygon[3], 1)
        XCTAssertEqual(polygon[4], 3)
        XCTAssertEqual(polygon[5], ~2)
    }

    func testNormalsRoundTrip() throws {
        let file = url("mesh.fbx")
        try FbxWriter.writeMesh(positions: positions, normals: normals, colors: nil, indices: indices, to: file)
        let nodes = try FbxWriter.parse(try Data(contentsOf: file))
        let layer = try XCTUnwrap(FbxWriter.findNode(nodes, named: "LayerElementNormal"))
        let values = try XCTUnwrap(
            layer.children.first { $0.name == "Normals" }?.props[0] as? [Double]
        )
        XCTAssertEqual(values.count, positions.count * 3)
        XCTAssertEqual(values[2], 1)  // first normal is (0,0,1)
    }

    func testColoursCarryAlphaOfOne() throws {
        let file = url("mesh.fbx")
        try FbxWriter.writeMesh(positions: positions, normals: nil, colors: colors, indices: indices, to: file)
        let nodes = try FbxWriter.parse(try Data(contentsOf: file))
        let layer = try XCTUnwrap(FbxWriter.findNode(nodes, named: "LayerElementColor"))
        let values = try XCTUnwrap(layer.children.first { $0.name == "Colors" }?.props[0] as? [Double])
        XCTAssertEqual(values.count, positions.count * 4)
        XCTAssertEqual(values[0], 1, accuracy: 0.0001)  // red 255 -> 1.0
        XCTAssertEqual(values[3], 1, accuracy: 0.0001)  // alpha
    }

    // MARK: - UVs

    func testUvLayerIsOneSamplePerPolygonCornerWithVFlip() throws {
        let polygonUvs: [SIMD2<Float>] = [
            SIMD2(0.25, 0.25), SIMD2(0.25, 0.25), SIMD2(0.25, 0.25),
            SIMD2(0.75, 0.25), SIMD2(0.75, 0.25), SIMD2(0.75, 0.25),
        ]
        let file = url("uv.fbx")
        try FbxWriter.writeMesh(
            positions: positions, normals: nil, colors: nil, indices: indices,
            polygonUvs: polygonUvs, to: file
        )
        let nodes = try FbxWriter.parse(try Data(contentsOf: file))
        let layer = try XCTUnwrap(FbxWriter.findNode(nodes, named: "LayerElementUV"))
        XCTAssertEqual(
            try XCTUnwrap(layer.children.first { $0.name == "MappingInformationType" }?.props[0] as? String),
            "ByPolygonVertex"
        )
        XCTAssertEqual(
            try XCTUnwrap(layer.children.first { $0.name == "ReferenceInformationType" }?.props[0] as? String),
            "IndexToDirect"
        )
        let uv = try XCTUnwrap(layer.children.first { $0.name == "UV" }?.props[0] as? [Double])
        XCTAssertEqual(uv.count, polygonUvs.count * 2)
        // Image-space V points down; FBX's V points up, so V is flipped.
        XCTAssertEqual(uv[0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(uv[1], 0.75, accuracy: 0.0001)

        let uvIndex = try XCTUnwrap(layer.children.first { $0.name == "UVIndex" }?.props[0] as? [Int32])
        XCTAssertEqual(uvIndex, [0, 1, 2, 3, 4, 5])
    }

    // MARK: - Texture embedding

    func testTextureIsEmbeddedAndConnected() throws {
        // A real baked atlas, so the embedded bytes are a real PNG.
        let atlas = try XCTUnwrap(ColorAtlasBaker.bake(colors: colors, indices: indices, vertexCount: 4))
        let file = url("textured.fbx")
        try FbxWriter.writeMesh(
            positions: positions, normals: nil, colors: colors, indices: indices,
            polygonUvs: ColorAtlasBaker.polygonUvs(of: atlas, for: indices),
            texture: atlas.texture, to: file
        )
        let nodes = try FbxWriter.parse(try Data(contentsOf: file))

        // The Video node's Content is a raw byte-array property holding the
        // image file verbatim. Base64 is the ASCII-FBX convention; writing it
        // into a binary file yields a valid-looking document whose embedded
        // image is a run of base64 characters, so the mesh imports untextured
        // and nothing says why.
        let content = try XCTUnwrap(FbxWriter.findNode(nodes, named: "Content")?.props[0] as? [UInt8])
        XCTAssertEqual(
            Array(content.prefix(8)),
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
            "the embedded bytes must be a PNG"
        )
        XCTAssertEqual(content, atlas.texture.data, "the whole PNG must be embedded, byte for byte")

        // And it must not be text: a base64 payload would decode as ASCII.
        XCTAssertFalse(
            content.allSatisfy { $0 < 0x80 },
            "Content looks like text, which means it was written as base64 again"
        )

        // A Texture node exists, named as a Texture object. The object name
        // falls back to the URL's stem.
        let texture = try XCTUnwrap(FbxWriter.findNode(nodes, named: "Texture"))
        XCTAssertEqual(
            try XCTUnwrap(texture.props[1] as? String),
            "textured.png\u{0}\u{1}Texture",
            "binary FBX object names are Name\\0\\x01Class"
        )

        // The texture is wired to the material's diffuse slot, and the video
        // to the texture.
        let connections = try XCTUnwrap(FbxWriter.findNode(nodes, named: "Connections")?.children)
        XCTAssertEqual(connections.count, 5)
        let propertyLinks = connections.filter { $0.props.first as? String == "OP" }
        XCTAssertEqual(propertyLinks.count, 1)
        XCTAssertEqual(propertyLinks.first?.props.last as? String, "DiffuseColor")

        // Direction, not just presence. An FBX connection reads
        // (source, destination) with the source as the child, so the image
        // feeds the texture and the texture feeds the material. Written the
        // other way round the file still parses everywhere and simply arrives
        // untextured, which is exactly how this shipped.
        let videoId = try XCTUnwrap(
            FbxWriter.findNode(nodes, named: "Video")?.props[0] as? Int64)
        let textureId = try XCTUnwrap(texture.props[0] as? Int64)
        let materialId = try XCTUnwrap(
            FbxWriter.findNode(nodes, named: "Material")?.props[0] as? Int64)

        let videoLink = try XCTUnwrap(connections.first {
            $0.props.first as? String == "OO" && $0.props[1] as? Int64 == videoId
        })
        XCTAssertEqual(
            videoLink.props[2] as? Int64, textureId,
            "the Video is the source and the Texture the destination"
        )
        XCTAssertEqual(propertyLinks.first?.props[1] as? Int64, textureId)
        XCTAssertEqual(propertyLinks.first?.props[2] as? Int64, materialId)

        // Definitions must declare the two extra object types it contains, on
        // top of the four a plain mesh already has.
        let definitions = try XCTUnwrap(FbxWriter.findNode(nodes, named: "Definitions"))
        let counts = definitions.children.filter { $0.name == "Count" }.compactMap { $0.props.first as? Int32 }
        XCTAssertEqual(counts.first, 6)
    }

    func testUntexturedMeshHasNoTextureNodes() throws {
        let file = url("plain.fbx")
        try FbxWriter.writeMesh(positions: positions, normals: nil, colors: nil, indices: indices, to: file)
        let nodes = try FbxWriter.parse(try Data(contentsOf: file))
        XCTAssertNil(FbxWriter.findNode(nodes, named: "Video"))
        XCTAssertNil(FbxWriter.findNode(nodes, named: "Content"))
        let connections = try XCTUnwrap(FbxWriter.findNode(nodes, named: "Connections")?.children)
        XCTAssertEqual(connections.count, 3)
    }

    // MARK: - Determinism

    func testFixedDateProducesByteIdenticalFiles() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = url("one.fbx")
        let second = url("two.fbx")
        // The object name falls back to the URL's stem when none is given, so
        // two differently-named files would differ by design; pin it to pin
        // the bytes.
        let options = FbxWriter.WriteOptions(name: "mesh", date: date)
        try FbxWriter.writeMesh(
            positions: positions, normals: nil, colors: colors, indices: indices,
            options: options, to: first
        )
        try FbxWriter.writeMesh(
            positions: positions, normals: nil, colors: colors, indices: indices,
            options: options, to: second
        )
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second))
    }

    // MARK: - Helpers

    private func leU32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        var value: UInt32 = 0
        for i in (0..<4).reversed() { value = value << 8 | UInt32(data[base + i]) }
        return value
    }
}
