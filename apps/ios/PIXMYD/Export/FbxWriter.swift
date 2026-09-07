import Foundation

/// Autodesk FBX binary writer (version 7400), plus the minimal reader the
/// tests use to prove the bytes are self-consistent.
///
/// FBX is proprietary and has no published specification. This is a port of
/// `packages/formats/src/fbx.ts`, which follows the reverse-engineered layout
/// that Blender, Assimp and three.js all agree on and is validated in the
/// monorepo tests by feeding the bytes through three.js's own FBXLoader — an
/// independent parser, and the only meaningful correctness check available
/// without the Autodesk SDK. The two writers must not drift: whatever the TS
/// one learned about a parser it tripped over, this one needs too.
///
/// Layout, for the record:
///
///   header     27 bytes: "Kaydara FBX Binary  \0" + 0x1A 0x00 + uint32 version
///   node       uint32 endOffset, uint32 numProperties, uint32 propertyListLen,
///              uint8 nameLen, name, properties..., children..., NULL record
///   NULL       13 zero bytes (4+4+4+1), present only when a node has children
///   footer     16-byte code, pad to 16, 20 zeros, uint32 version, 120 zeros,
///              16-byte extension magic
///
/// Version 7500 widens the first three node header fields to uint64. This
/// writer stays on 7400 deliberately: it is universally supported, keeps
/// offsets in uint32, and nothing here produces files near the 2 GB point
/// where 7500 matters.
enum FbxWriter {

    static let version: UInt32 = 7400
    static let headerMagic = "Kaydara FBX Binary  "

    /// Fixed constant that terminates every FBX file.
    static let footerExtension: [UInt8] = [
        0xf8, 0x5a, 0x8c, 0x6a, 0xde, 0xf5, 0xd9, 0x7e,
        0xec, 0xe9, 0x0c, 0xe3, 0x75, 0x8f, 0x29, 0x0b,
    ]

    /// Seed for the footer code. Importers do not verify it; written for fidelity.
    private static let footerSourceId: [UInt8] = [
        0x58, 0xab, 0xa9, 0xf0, 0x6c, 0xa2, 0xd8, 0x3f,
        0x4d, 0x47, 0x49, 0xa3, 0xb4, 0xb2, 0xe7, 0x3d,
    ]

    private static let footerKey: [UInt8] = [
        0xe2, 0x4f, 0x7b, 0x5f, 0xcd, 0xe4, 0xc8, 0x6d,
        0xdb, 0xd8, 0xfb, 0xd7, 0x40, 0x58, 0xc6, 0x78,
    ]

    // MARK: - Node model

    enum Property {
        case bool(Bool)
        case i16(Int16)
        case i32(Int32)
        case f32(Float)
        case f64(Double)
        case i64(Int64)
        case str(String)
        case raw([UInt8])
        case f32a([Float])
        case f64a([Double])
        case i32a([Int32])
        case i64a([Int64])
    }

    struct Node {
        var name: String
        var props: [Property]
        var children: [Node]

        init(_ name: String, props: [Property] = [], children: [Node] = []) {
            self.name = name
            self.props = props
            self.children = children
        }
    }

    /// Shorthand constructors, because building the tree by hand is otherwise unreadable.
    enum P {
        static func bool(_ v: Bool) -> Property { .bool(v) }
        static func i16(_ v: Int16) -> Property { .i16(v) }
        static func i32(_ v: Int32) -> Property { .i32(v) }
        static func f32(_ v: Float) -> Property { .f32(v) }
        static func f64(_ v: Double) -> Property { .f64(v) }
        static func i64(_ v: Int64) -> Property { .i64(v) }
        static func str(_ v: String) -> Property { .str(v) }
        static func raw(_ v: [UInt8]) -> Property { .raw(v) }
        static func f32a(_ v: [Float]) -> Property { .f32a(v) }
        static func f64a(_ v: [Double]) -> Property { .f64a(v) }
        static func i32a(_ v: [Int32]) -> Property { .i32a(v) }
        static func i64a(_ v: [Int64]) -> Property { .i64a(v) }
    }

    /// Object names in *binary* FBX are stored `Name\0\x01Class`, the reverse
    /// of the ASCII form `Class::Name`. Parsers truncate the string at the NUL,
    /// so getting this backwards yields objects that load but are named
    /// "Geometry".
    private static func objectName(_ name: String, className: String) -> String {
        "\(name)\u{0}\u{1}\(className)"
    }

    // MARK: - Serialization

    private struct Buffer {
        var data = Data()

        var length: Int { data.count }

        mutating func u8(_ v: UInt8) { data.append(v) }

        mutating func u16(_ v: UInt16) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }

        mutating func i16(_ v: Int16) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }

        mutating func u32(_ v: UInt32) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }

        mutating func i32(_ v: Int32) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }

        mutating func f32(_ v: Float) {
            withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }

        mutating func f64(_ v: Double) {
            withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }

        mutating func i64(_ v: Int64) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }

        mutating func ascii(_ s: String) {
            data.append(contentsOf: Array(s.utf8))
        }

        mutating func bytes(_ b: [UInt8]) {
            data.append(contentsOf: b)
        }

        mutating func fill(_ byte: UInt8, _ count: Int) {
            data.append(contentsOf: [UInt8](repeating: byte, count: count))
        }

        mutating func patchU32(at offset: Int, _ value: UInt32) {
            let bytes = withUnsafeBytes(of: value.littleEndian) { Array($0) }
            data.replaceSubrange(offset..<(offset + 4), with: bytes)
        }
    }

    private static func writeProperty(_ p: Property, to w: inout Buffer) {
        switch p {
        case .bool(let v):
            w.ascii("C"); w.u8(v ? 1 : 0)
        case .i16(let v):
            w.ascii("Y"); w.i16(v)
        case .i32(let v):
            w.ascii("I"); w.i32(v)
        case .f32(let v):
            w.ascii("F"); w.f32(v)
        case .f64(let v):
            w.ascii("D"); w.f64(v)
        case .i64(let v):
            w.ascii("L"); w.i64(v)
        case .str(let v):
            let bytes = Array(v.utf8)
            w.ascii("S"); w.u32(UInt32(bytes.count)); w.bytes(bytes)
        case .raw(let v):
            w.ascii("R"); w.u32(UInt32(v.count)); w.bytes(v)
        case .f32a(let v):
            w.ascii("f"); w.u32(UInt32(v.count)); w.u32(0); w.u32(UInt32(v.count * 4))
            for e in v { w.f32(e) }
        case .f64a(let v):
            w.ascii("d"); w.u32(UInt32(v.count)); w.u32(0); w.u32(UInt32(v.count * 8))
            for e in v { w.f64(e) }
        case .i32a(let v):
            w.ascii("i"); w.u32(UInt32(v.count)); w.u32(0); w.u32(UInt32(v.count * 4))
            for e in v { w.i32(e) }
        case .i64a(let v):
            w.ascii("l"); w.u32(UInt32(v.count)); w.u32(0); w.u32(UInt32(v.count * 8))
            for e in v { w.i64(e) }
        }
    }

    private static func writeNode(_ node: Node, to w: inout Buffer) {
        let nameBytes = Array(node.name.utf8)
        let props = node.props
        let children = node.children

        let endOffsetAt = w.length
        w.u32(0)  // endOffset, back-patched
        w.u32(UInt32(props.count))
        let propsLenAt = w.length
        w.u32(0)  // propertyListLen, back-patched
        w.u8(UInt8(nameBytes.count))
        w.bytes(nameBytes)

        let propsStart = w.length
        for p in props { writeProperty(p, to: &w) }
        w.patchU32(at: propsLenAt, UInt32(w.length - propsStart))

        if !children.isEmpty {
            for c in children { writeNode(c, to: &w) }
            // A node with children is terminated by a 13-byte NULL record. A
            // node without children must NOT have one — an extra sentinel
            // shifts every subsequent offset and the file parses as truncated.
            w.fill(0, 13)
        }

        w.patchU32(at: endOffsetAt, UInt32(w.length))
    }

    /// The XOR-with-carry cipher the footer code is built with.
    private static func encrypt(_ value: inout [UInt8], with key: [UInt8]) {
        var carry: UInt8 = 0x64
        for i in 0..<16 {
            value[i] = value[i] ^ (carry ^ key[i])
            carry = value[i]
        }
    }

    /// Milliseconds, rounded rather than truncated.
    ///
    /// `Date` is a `Double` of seconds, so a component that went in as exactly
    /// 60 ms can come back out as 59,999,999 ns. Truncating that gives 59 ms
    /// and a different footer stamp, which is how this drifted three bytes
    /// from the TypeScript writer the tests are pinned to.
    private static func millisecond(of c: DateComponents) -> Int {
        Int((Double(c.nanosecond ?? 0) / 1_000_000).rounded())
    }

    private static func footerCode(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents(
            [.second, .minute, .hour, .day, .month, .year, .nanosecond], from: date
        )
        let stamp = String(
            format: "%02d%02d%02d%02d%02d%04d%02d",
            c.second ?? 0,
            c.month ?? 1,
            c.hour ?? 0,
            c.day ?? 1,
            millisecond(of: c) / 10,
            c.year ?? 2000,
            c.minute ?? 0
        )
        let stampBytes = Array(stamp.utf8)
        var code = footerSourceId
        encrypt(&code, with: stampBytes)
        encrypt(&code, with: footerKey)
        encrypt(&code, with: stampBytes)
        return code
    }

    static func serialize(_ root: [Node], date: Date = Date()) -> Data {
        var w = Buffer()

        // --- header ---
        w.ascii(headerMagic)
        w.u8(0x00)
        w.u8(0x1a)
        w.u8(0x00)
        w.u32(version)

        for node in root { writeNode(node, to: &w) }
        // Top-level list is terminated by its own NULL record.
        w.fill(0, 13)

        // --- footer ---
        //
        // 160 bytes plus alignment padding:
        //   16  footer code
        //   1-16 padding to a 16-byte boundary (never zero — always at least
        //        one byte, exactly as the TS writer behaves)
        //   4   zeros
        //   4   version
        //   120 zeros
        //   16  extension magic
        //
        // The total size is load-bearing, not cosmetic. Parsers decide they
        // have reached the end of the node list by comparing the remaining
        // bytes against this fixed footer length; a footer even 16 bytes too
        // long leaves them convinced another node follows.
        w.bytes(footerCode(date))
        w.fill(0, 16 - (w.length % 16))
        w.fill(0, 4)
        w.u32(version)
        w.fill(0, 120)
        w.bytes(footerExtension)

        return w.data
    }

    // MARK: - Mesh document

    struct WriteOptions {
        var name: String?
        /// FBX's native unit is the centimetre, and importers that ignore
        /// `UnitScaleFactor` — which is most of them — treat raw values as
        /// centimetres. Writing centimetres by default means a 3 m wall
        /// arrives 3 m tall everywhere instead of 3 cm tall in half the tools.
        /// Choose 'm' only if the consumer is known to honour the header.
        var units: Units = .cm
        /// Rotate a Z-up source into FBX's Y-up convention.
        var zUpToYUp = false
        /// Fixed timestamp, so a test can produce byte-identical output.
        var date: Date?

        enum Units { case cm, m }
    }

    /// The scene document's id.
    ///
    /// A literal rather than an allocation: `Documents` is written before
    /// `Objects` and taking an id from the shared counter would renumber every
    /// object in the file, which the byte-for-byte reference test pins.
    private static let documentId: Int64 = 900_000

    /// The `CreationTimeStamp` block Autodesk's own reader looks for.
    ///
    /// Blender and three.js ignore it and load the file regardless, which is
    /// how a writer can omit it and appear to work everywhere that is easy to
    /// test against.
    private static func creationTimeStamp(_ date: Date) -> Node {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date
        )
        return Node("CreationTimeStamp", children: [
            Node("Version", props: [P.i32(1000)]),
            Node("Year", props: [P.i32(Int32(c.year ?? 2000))]),
            Node("Month", props: [P.i32(Int32(c.month ?? 1))]),
            Node("Day", props: [P.i32(Int32(c.day ?? 1))]),
            Node("Hour", props: [P.i32(Int32(c.hour ?? 0))]),
            Node("Minute", props: [P.i32(Int32(c.minute ?? 0))]),
            Node("Second", props: [P.i32(Int32(c.second ?? 0))]),
            Node("Millisecond", props: [P.i32(Int32(millisecond(of: c)))]),
        ])
    }

    private static func propInt(name: String, _ value: Int32) -> Node {
        Node("P",
             props: [P.str(name), P.str("int"), P.str("Integer"), P.str(""), P.i32(value)])
    }

    private static func propDouble(name: String, _ value: Double) -> Node {
        Node("P",
             props: [P.str(name), P.str("double"), P.str("Number"), P.str(""), P.f64(value)])
    }

    private static func propColor(name: String, _ r: Double, _ g: Double, _ b: Double) -> Node {
        Node("P",
             props: [P.str(name), P.str("Color"), P.str(""), P.str("A"),
                     P.f64(r), P.f64(g), P.f64(b)])
    }

    /// Write the mesh as one self-contained binary FBX.
    ///
    /// `polygonUvs` carries one texture coordinate per polygon corner — the
    /// shape FBX's `ByPolygonVertex` layers expect — and `texture` is written
    /// into the file itself (a Video node carrying the raw image bytes plus a
    /// Texture node connected to the material's diffuse slot), so the result is one
    /// file with the colour baked in, like the OBJ sidecars but without the
    /// sidecars.
    @discardableResult
    static func writeMesh(
        positions: [SIMD3<Float>],
        normals: [SIMD3<Float>]?,
        colors: [SIMD3<UInt8>]?,
        indices: [UInt32],
        polygonUvs: [SIMD2<Float>]? = nil,
        texture: TsdfVolume.TextureImage? = nil,
        options: WriteOptions = WriteOptions(),
        to url: URL
    ) throws -> URL {
        let name = options.name.flatMap { $0.isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent
        let scale: Double = options.units == .cm ? 100 : 1
        let vertexCount = positions.count
        let triangleCount = indices.count / 3

        // --- geometry arrays ---
        var vertices = [Double](repeating: 0, count: vertexCount * 3)
        for i in 0..<vertexCount {
            let x = Double(positions[i].x)
            let y = Double(positions[i].y)
            let z = Double(positions[i].z)
            if options.zUpToYUp {
                vertices[i * 3] = x * scale
                vertices[i * 3 + 1] = z * scale
                vertices[i * 3 + 2] = -y * scale
            } else {
                vertices[i * 3] = x * scale
                vertices[i * 3 + 1] = y * scale
                vertices[i * 3 + 2] = z * scale
            }
        }

        // FBX marks the last corner of each polygon by bitwise-negating its
        // index, which is how a flat array encodes variable-length faces.
        var polygonVertexIndex = [Int32](repeating: 0, count: indices.count)
        for f in 0..<triangleCount {
            polygonVertexIndex[f * 3] = Int32(indices[f * 3])
            polygonVertexIndex[f * 3 + 1] = Int32(indices[f * 3 + 1])
            polygonVertexIndex[f * 3 + 2] = ~Int32(indices[f * 3 + 2])
        }

        var geometryChildren: [Node] = [
            Node("Vertices", props: [P.f64a(vertices)]),
            Node("PolygonVertexIndex", props: [P.i32a(polygonVertexIndex)]),
            Node("GeometryVersion", props: [P.i32(124)]),
        ]

        var layerElements: [Node] = []

        if let normals {
            var normalValues = [Double](repeating: 0, count: vertexCount * 3)
            for i in 0..<vertexCount {
                let x = Double(normals[i].x)
                let y = Double(normals[i].y)
                let z = Double(normals[i].z)
                if options.zUpToYUp {
                    normalValues[i * 3] = x
                    normalValues[i * 3 + 1] = z
                    normalValues[i * 3 + 2] = -y
                } else {
                    normalValues[i * 3] = x
                    normalValues[i * 3 + 1] = y
                    normalValues[i * 3 + 2] = z
                }
            }
            geometryChildren.append(Node(
                "LayerElementNormal",
                props: [P.i32(0)],
                children: [
                    Node("Version", props: [P.i32(101)]),
                    Node("Name", props: [P.str("")]),
                    Node("MappingInformationType", props: [P.str("ByVertice")]),
                    Node("ReferenceInformationType", props: [P.str("Direct")]),
                    Node("Normals", props: [P.f64a(normalValues)]),
                ]
            ))
            layerElements.append(Node(
                "LayerElement",
                children: [
                    Node("Type", props: [P.str("LayerElementNormal")]),
                    Node("TypedIndex", props: [P.i32(0)]),
                ]
            ))
        }

        if let polygonUvs {
            let cornerCount = polygonUvs.count
            // One texture coordinate per polygon corner, each triangle
            // pointing at the centre of its texel. FBX's V axis points up,
            // image space points down, so V is flipped here.
            var uv = [Double](repeating: 0, count: cornerCount * 2)
            for i in 0..<cornerCount {
                uv[i * 2] = Double(polygonUvs[i].x)
                uv[i * 2 + 1] = 1 - Double(polygonUvs[i].y)
            }
            var uvIndex = [Int32](repeating: 0, count: cornerCount)
            for i in 0..<cornerCount { uvIndex[i] = Int32(i) }
            geometryChildren.append(Node(
                "LayerElementUV",
                props: [P.i32(0)],
                children: [
                    Node("Version", props: [P.i32(101)]),
                    Node("Name", props: [P.str("UVMap")]),
                    Node("MappingInformationType", props: [P.str("ByPolygonVertex")]),
                    Node("ReferenceInformationType", props: [P.str("IndexToDirect")]),
                    Node("UV", props: [P.f64a(uv)]),
                    Node("UVIndex", props: [P.i32a(uvIndex)]),
                ]
            ))
            layerElements.append(Node(
                "LayerElement",
                children: [
                    Node("Type", props: [P.str("LayerElementUV")]),
                    Node("TypedIndex", props: [P.i32(0)]),
                ]
            ))
        }

        if let colors {
            // FBX vertex colour carries alpha; scans have none, so it is
            // written as 1.
            var colorValues = [Double](repeating: 0, count: vertexCount * 4)
            for i in 0..<vertexCount {
                colorValues[i * 4] = Double(colors[i].x) / 255
                colorValues[i * 4 + 1] = Double(colors[i].y) / 255
                colorValues[i * 4 + 2] = Double(colors[i].z) / 255
                colorValues[i * 4 + 3] = 1
            }
            geometryChildren.append(Node(
                "LayerElementColor",
                props: [P.i32(0)],
                children: [
                    Node("Version", props: [P.i32(101)]),
                    Node("Name", props: [P.str("VertexColors")]),
                    Node("MappingInformationType", props: [P.str("ByVertice")]),
                    Node("ReferenceInformationType", props: [P.str("Direct")]),
                    Node("Colors", props: [P.f64a(colorValues)]),
                ]
            ))
            layerElements.append(Node(
                "LayerElement",
                children: [
                    Node("Type", props: [P.str("LayerElementColor")]),
                    Node("TypedIndex", props: [P.i32(0)]),
                ]
            ))
        }

        // Every polygon uses material 0.
        geometryChildren.append(Node(
            "LayerElementMaterial",
            props: [P.i32(0)],
            children: [
                Node("Version", props: [P.i32(101)]),
                Node("Name", props: [P.str("")]),
                Node("MappingInformationType", props: [P.str("AllSame")]),
                Node("ReferenceInformationType", props: [P.str("IndexToDirect")]),
                Node("Materials", props: [P.i32a([0])]),
            ]
        ))
        layerElements.append(Node(
            "LayerElement",
            children: [
                Node("Type", props: [P.str("LayerElementMaterial")]),
                Node("TypedIndex", props: [P.i32(0)]),
            ]
        ))

        geometryChildren.append(Node(
            "Layer",
            props: [P.i32(0)],
            children: [Node("Version", props: [P.i32(100)])] + layerElements
        ))

        // --- object ids ---
        var nextId: Int64 = 1_000_000
        func allocate() -> Int64 {
            defer { nextId += 1 }
            return nextId
        }

        let geometryId = allocate()
        let modelId = allocate()
        let materialId = allocate()

        var objectsChildren: [Node] = [
            Node(
                "Geometry",
                props: [P.i64(geometryId), P.str(objectName(name, className: "Geometry")), P.str("Mesh")],
                children: geometryChildren
            ),
            Node(
                "Model",
                props: [P.i64(modelId), P.str(objectName(name, className: "Model")), P.str("Mesh")],
                children: [
                    Node("Version", props: [P.i32(232)]),
                    Node("Properties70",
                         children: [
                            Node("P",
                                 props: [P.str("DefaultAttributeIndex"), P.str("int"),
                                         P.str("Integer"), P.str(""), P.i32(0)]),
                            Node("P",
                                 props: [P.str("Lcl Scaling"), P.str("Lcl Scaling"),
                                         P.str(""), P.str("A"), P.f64(1), P.f64(1), P.f64(1)]),
                         ]),
                    Node("Shading", props: [P.bool(true)]),
                    Node("Culling", props: [P.str("CullingOff")]),
                ]
            ),
            Node(
                "Material",
                props: [P.i64(materialId), P.str(objectName("\(name)-material", className: "Material")), P.str("")],
                children: [
                    Node("Version", props: [P.i32(102)]),
                    Node("ShadingModel", props: [P.str("phong")]),
                    Node("MultiLayer", props: [P.i32(0)]),
                    Node("Properties70",
                         children: [
                            propColor(name: "DiffuseColor", 1, 1, 1),
                            propColor(name: "AmbientColor", 0.2, 0.2, 0.2),
                            propColor(name: "SpecularColor", 0, 0, 0),
                            propDouble(name: "Shininess", 2),
                            propDouble(name: "Opacity", 1),
                         ]),
                ]
            ),
        ]

        var connections: [Node] = [
            // Model is parented to the scene root, which is always id 0.
            Node("C", props: [P.str("OO"), P.i64(modelId), P.i64(0)]),
            Node("C", props: [P.str("OO"), P.i64(geometryId), P.i64(modelId)]),
            Node("C", props: [P.str("OO"), P.i64(materialId), P.i64(modelId)]),
        ]

        // GlobalSettings counts as an object here, and the total has to
        // include it: readers size their object table from this number.
        var definitionCount: Int32 = 4
        var objectTypes: [Node] = [
            Node("ObjectType", props: [P.str("GlobalSettings")],
                 children: [Node("Count", props: [P.i32(1)])]),
            Node("ObjectType", props: [P.str("Geometry")],
                 children: [Node("Count", props: [P.i32(1)])]),
            Node("ObjectType", props: [P.str("Model")],
                 children: [Node("Count", props: [P.i32(1)])]),
            Node("ObjectType", props: [P.str("Material")],
                 children: [Node("Count", props: [P.i32(1)])]),
        ]

        if let texture {
            let textureName = "\(name).png"
            let videoId = allocate()
            let textureId = allocate()

            // An embedded texture is a Video node carrying the image file's
            // bytes, a Texture node that refers to it, and a connection from
            // the material's diffuse slot to the texture.
            //
            // `Content` is a raw byte-array property ('R'), not a string.
            // Base64 is the *ASCII* FBX convention, and writing it here
            // produces a file that parses cleanly and whose embedded image is
            // a run of base64 characters where a PNG should be — so the mesh
            // imports untextured and nothing reports why.
            objectsChildren.append(Node(
                "Video",
                props: [P.i64(videoId), P.str(objectName(textureName, className: "Video")), P.str("")],
                children: [
                    Node("Type", props: [P.str("Clip")]),
                    Node("Version", props: [P.i32(104)]),
                    Node("UseMipMap", props: [P.i32(0)]),
                    Node("Filename", props: [P.str(textureName)]),
                    Node("RelativeFilename", props: [P.str(textureName)]),
                    Node("Content", props: [P.raw(texture.data)]),
                ]
            ))
            objectsChildren.append(Node(
                "Texture",
                props: [P.i64(textureId), P.str(objectName(textureName, className: "Texture")), P.str("")],
                children: [
                    Node("Type", props: [P.str("TextureVideoClip")]),
                    Node("Version", props: [P.i32(101)]),
                    Node("TextureName", props: [P.str(textureName)]),
                    Node("Media", props: [P.str(textureName)]),
                    Node("FileName", props: [P.str(textureName)]),
                    Node("RelativeFilename", props: [P.str(textureName)]),
                    Node("ModelUVTranslation", props: [P.f64(0), P.f64(0)]),
                    Node("ModelUVScaling", props: [P.f64(1), P.f64(1)]),
                    Node("Texture_Alpha_Source", props: [P.str("None")]),
                    Node("Cropping", props: [P.i32(0), P.i32(0), P.i32(0), P.i32(0)]),
                ]
            ))
            // Video into Texture, not the other way round. An FBX connection
            // reads (source, destination) and the source is the child, so the
            // image feeds the texture. Inverted, every importer parses the file
            // happily and simply never associates the two -- which is a mesh
            // that arrives untextured with nothing anywhere reporting why.
            connections.append(Node("C", props: [P.str("OO"), P.i64(videoId), P.i64(textureId)]))
            connections.append(Node(
                "C",
                props: [P.str("OP"), P.i64(textureId), P.i64(materialId), P.str("DiffuseColor")]
            ))
            definitionCount = 6
            objectTypes.append(Node("ObjectType", props: [P.str("Video")],
                                    children: [Node("Count", props: [P.i32(1)])]))
            objectTypes.append(Node("ObjectType", props: [P.str("Texture")],
                                    children: [Node("Count", props: [P.i32(1)])]))
        }

        let stamped = options.date ?? Date()
        let root: [Node] = [
            Node("FBXHeaderExtension",
                 children: [
                     Node("FBXHeaderVersion", props: [P.i32(1003)]),
                     Node("FBXVersion", props: [P.i32(Int32(version))]),
                     creationTimeStamp(stamped),
                     Node("Creator", props: [P.str("PIXMYD")]),
                 ]),
            Node("Creator", props: [P.str("PIXMYD")]),
            Node("GlobalSettings",
                 children: [
                     Node("Version", props: [P.i32(1000)]),
                     Node("Properties70",
                          children: [
                             propInt(name: "UpAxis", 1),
                             propInt(name: "UpAxisSign", 1),
                             propInt(name: "FrontAxis", 2),
                             propInt(name: "FrontAxisSign", 1),
                             propInt(name: "CoordAxis", 0),
                             propInt(name: "CoordAxisSign", 1),
                             propInt(name: "OriginalUpAxis", 1),
                             propInt(name: "OriginalUpAxisSign", 1),
                             propDouble(name: "UnitScaleFactor", scale == 100 ? 1 : 100),
                             propDouble(name: "OriginalUnitScaleFactor", scale == 100 ? 1 : 100),
                          ]),
                 ]),
            // Every FBX a real tool writes carries a scene document and a
            // (usually empty) reference list between the settings and the
            // definitions. Omitting them costs nothing in the permissive
            // parsers and is one of the ways a file that opens fine in Blender
            // is refused by Autodesk's own reader.
            Node("Documents",
                 children: [
                     Node("Count", props: [P.i32(1)]),
                     Node("Document",
                          props: [P.i64(documentId), P.str("Scene"), P.str("Scene")],
                          children: [
                             Node("Properties70", children: [
                                Node("P", props: [
                                    P.str("SourceObject"), P.str("object"),
                                    P.str(""), P.str(""),
                                ]),
                                Node("P", props: [
                                    P.str("ActiveAnimStackName"), P.str("KString"),
                                    P.str(""), P.str(""), P.str(""),
                                ]),
                             ]),
                             Node("RootNode", props: [P.i64(0)]),
                          ]),
                 ]),
            Node("References"),
            Node("Definitions",
                 children: [
                     Node("Version", props: [P.i32(100)]),
                     Node("Count", props: [P.i32(definitionCount)]),
                 ] + objectTypes),
            Node("Objects", children: objectsChildren),
            Node("Connections", children: connections),
        ]

        try serialize(root, date: options.date ?? Date()).write(to: url)
        return url
    }

    // MARK: - Reading back, for tests

    struct ParsedNode {
        var name: String
        var props: [Any]
        var children: [ParsedNode]
    }

    enum ParseError: Error, CustomStringConvertible {
        case badMagic
        case uint64Offsets
        case truncated
        case badPropertyLength(node: String, declared: Int, consumed: Int)
        case badEndOffset(node: String, landed: Int, declared: Int)
        case compressedArrays
        case unknownPropertyType(String)

        var description: String {
            switch self {
            case .badMagic: "FBX: bad magic"
            case .uint64Offsets: "FBX: uint64 offsets (>=7500) not supported here"
            case .truncated: "FBX: file ended in the middle of a node"
            case let .badPropertyLength(node, declared, consumed):
                "FBX: node \"\(node)\" declared propertyListLen \(declared) but consumed \(consumed)"
            case let .badEndOffset(node, landed, declared):
                "FBX: node \"\(node)\" ended at \(landed), endOffset said \(declared)"
            case .compressedArrays: "FBX: compressed arrays not supported here"
            case let .unknownPropertyType(type): "FBX: unknown property type \"\(type)\""
            }
        }
    }

    /// A minimal reader, used to prove the writer's offsets are self-consistent.
    /// `parse` walking the whole tree without running off the end is a real
    /// check: every endOffset has to land exactly on the next node's first byte.
    static func parse(_ data: Data) throws -> [ParsedNode] {
        guard data.count >= 27 else { throw ParseError.truncated }
        let magic = String(decoding: data[data.startIndex..<(data.startIndex + 20)], as: UTF8.self)
        guard magic == headerMagic else { throw ParseError.badMagic }
        let fileVersion = leU32(data, 23)
        guard fileVersion < 7500 else { throw ParseError.uint64Offsets }

        var offset = 27
        var nodes: [ParsedNode] = []
        while true {
            guard let node = try readNode(data: data, offset: &offset) else { break }
            nodes.append(node)
        }
        return nodes
    }

    private static func readNode(data: Data, offset: inout Int) throws -> ParsedNode? {
        guard offset + 13 <= data.count else { throw ParseError.truncated }
        let endOffset = Int(leU32(data, offset))
        let numProps = Int(leU32(data, offset + 4))
        let propsLen = Int(leU32(data, offset + 8))
        let nameLen = Int(data[data.startIndex + offset + 12])
        if endOffset == 0 {
            offset += 13
            return nil
        }
        offset += 13
        guard offset + nameLen <= data.count else { throw ParseError.truncated }
        let name = String(
            decoding: data[data.startIndex + offset..<(data.startIndex + offset + nameLen)],
            as: UTF8.self
        )
        offset += nameLen

        let propsStart = offset
        var props: [Any] = []
        props.reserveCapacity(numProps)
        for _ in 0..<numProps {
            props.append(try readProperty(data: data, offset: &offset))
        }
        guard offset - propsStart == propsLen else {
            throw ParseError.badPropertyLength(
                node: name, declared: propsLen, consumed: offset - propsStart
            )
        }

        var children: [ParsedNode] = []
        while offset < endOffset {
            guard let child = try readNode(data: data, offset: &offset) else { break }
            children.append(child)
        }
        guard offset == endOffset else {
            throw ParseError.badEndOffset(node: name, landed: offset, declared: endOffset)
        }
        return ParsedNode(name: name, props: props, children: children)
    }

    private static func readProperty(data: Data, offset: inout Int) throws -> Any {
        guard offset < data.count else { throw ParseError.truncated }
        let type = String(decoding: data[data.startIndex + offset..<(data.startIndex + offset + 1)], as: UTF8.self)
        offset += 1

        // Every fixed-width read is bounds-checked before it happens. The
        // little-endian accessors index `data` directly, so without this a
        // truncated file is an out-of-bounds trap rather than the
        // `ParseError.truncated` this reader promises -- and a crash in a test
        // helper is a worse answer than a thrown error, because it takes the
        // whole run down instead of one assertion.
        func need(_ count: Int) throws {
            guard offset + count <= data.count else { throw ParseError.truncated }
        }

        switch type {
        case "C":
            try need(1)
            let value = data[data.startIndex + offset] != 0
            offset += 1
            return value
        case "Y":
            try need(2)
            let value = Int16(bitPattern: leU16(data, offset))
            offset += 2
            return value
        case "I":
            try need(4)
            let value = Int32(bitPattern: leU32(data, offset))
            offset += 4
            return value
        case "F":
            try need(4)
            let value = Float(bitPattern: leU32(data, offset))
            offset += 4
            return value
        case "D":
            try need(8)
            let value = Double(bitPattern: leU64(data, offset))
            offset += 8
            return value
        case "L":
            try need(8)
            let value = Int64(bitPattern: leU64(data, offset))
            offset += 8
            return value
        case "S", "R":
            try need(4)
            let length = Int(leU32(data, offset))
            offset += 4
            guard offset + length <= data.count else { throw ParseError.truncated }
            let bytes = [UInt8](data[data.startIndex + offset..<(data.startIndex + offset + length)])
            offset += length
            if type == "S" { return String(decoding: bytes, as: UTF8.self) }
            return bytes
        default:
            try need(12)
            let length = Int(leU32(data, offset))
            let encoding = leU32(data, offset + 4)
            let byteLength = Int(leU32(data, offset + 8))
            offset += 12
            guard encoding == 0 else { throw ParseError.compressedArrays }
            guard offset + byteLength <= data.count else { throw ParseError.truncated }

            let base = data.startIndex + offset
            switch type {
            case "f":
                var values = [Float]()
                values.reserveCapacity(length)
                for i in 0..<length {
                    values.append(Float(bitPattern: leU32(data, offset + i * 4)))
                }
                offset += byteLength
                return values
            case "d":
                var values = [Double]()
                values.reserveCapacity(length)
                for i in 0..<length {
                    values.append(Double(bitPattern: leU64(data, offset + i * 8)))
                }
                offset += byteLength
                return values
            case "i":
                var values = [Int32]()
                values.reserveCapacity(length)
                for i in 0..<length {
                    values.append(Int32(bitPattern: leU32(data, offset + i * 4)))
                }
                offset += byteLength
                return values
            case "l":
                var values = [Int64]()
                values.reserveCapacity(length)
                for i in 0..<length {
                    values.append(Int64(bitPattern: leU64(data, offset + i * 8)))
                }
                offset += byteLength
                return values
            case "b":
                let values = [UInt8](data[base..<(base + byteLength)])
                offset += byteLength
                return values
            default:
                throw ParseError.unknownPropertyType(type)
            }
        }
    }

    /// Depth-first search for the first node with a given name.
    static func findNode(_ nodes: [ParsedNode], named name: String) -> ParsedNode? {
        for node in nodes {
            if node.name == name { return node }
            if let found = findNode(node.children, named: name) { return found }
        }
        return nil
    }

    // MARK: - Little-endian accessors

    private static func leU16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    private static func leU32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        var value: UInt32 = 0
        for i in (0..<4).reversed() { value = value << 8 | UInt32(data[base + i]) }
        return value
    }

    private static func leU64(_ data: Data, _ offset: Int) -> UInt64 {
        let base = data.startIndex + offset
        var value: UInt64 = 0
        for i in (0..<8).reversed() { value = value << 8 | UInt64(data[base + i]) }
        return value
    }
}