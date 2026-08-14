import Foundation

/// Compact binary serialisation of a fused result, so a project can be
/// processed once and viewed or exported again without re-fusing.
///
/// Layout is explicit little-endian with a magic and a version, because this
/// file may outlive the app that wrote it — the whole point is that a scan is
/// stored as plain files nobody needs this build to read.
///
/// v1:
/// ```
/// magic  "PIXMESH" (7 bytes)
/// u8     version = 1
/// u8     flags            bit0 normals, bit1 colors, bit2 uvs, bit3 texture,
///                         bit4 points, bit5 pointColors
/// u32    vertexCount
/// u32    indexCount
/// u32    pointCount
/// f32x3  positions[vertexCount]
/// f32x3  normals[vertexCount]     (flag 0)
/// u8x3   colors[vertexCount]      (flag 1)
/// f32x2  uvs[vertexCount]         (flag 2)
/// u32    texWidth, texHeight
/// u32    texLen                  (flag 3)
/// u8     texMimeLen
/// u8     texMime[texMimeLen]
/// u8     texData[texLen]
/// u32    indices[indexCount]
/// f32x3  points[pointCount]       (flag 4)
/// u8x3   pointColors[pointCount]  (flag 5)
/// ```
enum MeshArchive {
    static let magic: [UInt8] = [0x50, 0x49, 0x58, 0x4D, 0x45, 0x53, 0x48]
    static let version: UInt8 = 1

    struct Flags: OptionSet {
        let rawValue: UInt8
        static let normals = Flags(rawValue: 1 << 0)
        static let colors = Flags(rawValue: 1 << 1)
        static let uvs = Flags(rawValue: 1 << 2)
        static let texture = Flags(rawValue: 1 << 3)
        static let points = Flags(rawValue: 1 << 4)
        static let pointColors = Flags(rawValue: 1 << 5)
    }

    enum Error: Swift.Error {
        case badMagic
        case unsupportedVersion(UInt8)
        case truncated
    }

    // MARK: - Encode

    static func encode(
        mesh: TsdfVolume.Mesh,
        points: TsdfVolume.PointCloud?
    ) -> Data {
        var flags = Flags()
        if mesh.normals != nil { flags.insert(.normals) }
        if mesh.colors != nil { flags.insert(.colors) }
        if mesh.uvs != nil { flags.insert(.uvs) }
        if mesh.texture != nil { flags.insert(.texture) }
        if points != nil { flags.insert(.points) }
        if points?.colors != nil { flags.insert(.pointColors) }

        var out = Writer()
        out.bytes(magic)
        out.u8(version)
        out.u8(flags.rawValue)
        out.u32(UInt32(mesh.positions.count))
        out.u32(UInt32(mesh.indices.count))
        out.u32(UInt32(points?.positions.count ?? 0))

        for p in mesh.positions { out.vec3(p) }
        if let normals = mesh.normals {
            for n in normals { out.vec3(n) }
        }
        if let colors = mesh.colors {
            for c in colors { out.u8(c.x); out.u8(c.y); out.u8(c.z) }
        }
        if let uvs = mesh.uvs {
            for uv in uvs { out.f32(uv.x); out.f32(uv.y) }
        }
        if let texture = mesh.texture {
            out.u32(UInt32(texture.width))
            out.u32(UInt32(texture.height))
            out.u32(UInt32(texture.data.count))
            let mime = Array(texture.mimeType.utf8)
            out.u8(UInt8(mime.count))
            out.bytes(mime)
            out.bytes(texture.data)
        }
        for i in mesh.indices { out.u32(i) }

        if let points {
            for p in points.positions { out.vec3(p) }
            if let colors = points.colors {
                for c in colors { out.u8(c.x); out.u8(c.y); out.u8(c.z) }
            }
        }
        return out.data
    }

    // MARK: - Decode

    static func decode(_ data: Data) throws -> (mesh: TsdfVolume.Mesh, points: TsdfVolume.PointCloud?) {
        var reader = Reader(data)
        for expected in magic {
            guard try reader.u8() == expected else { throw Error.badMagic }
        }
        let version = try reader.u8()
        guard version == Self.version else { throw Error.unsupportedVersion(version) }
        let flags = Flags(rawValue: try reader.u8())
        let vertexCount = Int(try reader.u32())
        let indexCount = Int(try reader.u32())
        let pointCount = Int(try reader.u32())

        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(vertexCount)
        for _ in 0..<vertexCount { positions.append(try reader.vec3()) }

        var normals: [SIMD3<Float>]?
        if flags.contains(.normals) {
            var values: [SIMD3<Float>] = []
            values.reserveCapacity(vertexCount)
            for _ in 0..<vertexCount { values.append(try reader.vec3()) }
            normals = values
        }

        var colors: [SIMD3<UInt8>]?
        if flags.contains(.colors) {
            var values: [SIMD3<UInt8>] = []
            values.reserveCapacity(vertexCount)
            for _ in 0..<vertexCount {
                values.append(SIMD3(try reader.u8(), try reader.u8(), try reader.u8()))
            }
            colors = values
        }

        var uvs: [SIMD2<Float>]?
        if flags.contains(.uvs) {
            var values: [SIMD2<Float>] = []
            values.reserveCapacity(vertexCount)
            for _ in 0..<vertexCount {
                values.append(SIMD2(try reader.f32(), try reader.f32()))
            }
            uvs = values
        }

        var texture: TsdfVolume.TextureImage?
        if flags.contains(.texture) {
            let width = Int(try reader.u32())
            let height = Int(try reader.u32())
            let len = Int(try reader.u32())
            let mimeLen = Int(try reader.u8())
            let mime = String(decoding: try reader.bytes(mimeLen), as: UTF8.self)
            let data = try reader.bytes(len)
            texture = TsdfVolume.TextureImage(
                width: width, height: height, mimeType: mime, data: data
            )
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(indexCount)
        for _ in 0..<indexCount { indices.append(try reader.u32()) }

        var cloud: TsdfVolume.PointCloud?
        if flags.contains(.points) {
            var pointPositions: [SIMD3<Float>] = []
            pointPositions.reserveCapacity(pointCount)
            for _ in 0..<pointCount { pointPositions.append(try reader.vec3()) }

            var pointColors: [SIMD3<UInt8>]?
            if flags.contains(.pointColors) {
                var values: [SIMD3<UInt8>] = []
                values.reserveCapacity(pointCount)
                for _ in 0..<pointCount {
                    values.append(SIMD3(try reader.u8(), try reader.u8(), try reader.u8()))
                }
                pointColors = values
            }
            cloud = TsdfVolume.PointCloud(positions: pointPositions, colors: pointColors)
        }

        let mesh = TsdfVolume.Mesh(
            positions: positions,
            normals: normals,
            indices: indices,
            colors: colors,
            uvs: uvs,
            texture: texture
        )
        return (mesh, cloud)
    }

    // MARK: - Writers / readers

    private struct Writer {
        var data = Data()

        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func bytes(_ values: [UInt8]) { data.append(contentsOf: values) }
        mutating func f32(_ v: Float) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
        mutating func u32(_ v: UInt32) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        mutating func vec3(_ v: SIMD3<Float>) { f32(v.x); f32(v.y); f32(v.z) }
    }

    private struct Reader {
        let data: [UInt8]
        var offset = 0

        init(_ data: Data) { self.data = [UInt8](data) }

        mutating func u8() throws -> UInt8 {
            guard offset < data.count else { throw Error.truncated }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard offset + count <= data.count else { throw Error.truncated }
            defer { offset += count }
            return Array(data[offset..<(offset + count)])
        }

        mutating func f32() throws -> Float {
            let raw = try bytes(4)
            return raw.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        }

        mutating func u32() throws -> UInt32 {
            let raw = try bytes(4)
            return raw.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }

        mutating func vec3() throws -> SIMD3<Float> {
            SIMD3(try f32(), try f32(), try f32())
        }
    }
}
