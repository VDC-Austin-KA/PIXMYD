import Foundation
import simd

// Reading a GLB back.
//
// This app has written glTF binary since the beginning and has never read one.
// It has to now, because PIXMYD-Nav's AR model export finally carries geometry:
// the model bundle used to be a bounding box, a camera and a photograph, and
// this app's own decoder said so out loud — "a bundle with no geometry is still
// worth showing. It just cannot be drawn over the world." This is what makes it
// drawable.
//
// ## A deliberately small subset
//
// Not a glTF loader. It reads the exact shape the two writers in this suite
// produce — one mesh, one primitive, float positions, optional normals and
// vertex colours, and an index buffer — and refuses everything else with a line
// naming what it found. That is the honest boundary: a partial glTF reader that
// silently ignores a node transform, a second primitive or a sparse accessor
// would draw a model that is subtly in the wrong place, which is the one
// failure this suite exists to prevent.
//
// External `.bin` files and `data:` URIs are refused for the same reason a
// scanned QR payload is never fetched: a bundle is a folder the user brought
// here, and anything it references that is not in it is not available in a
// basement.
//
// In `portableSources`: all parsing and arithmetic, and `swift test` covers it
// by round-tripping `Exporters.writeGlb`.

enum GlbReadError: Error, CustomStringConvertible, Equatable {
    case notGlb
    case unsupportedVersion(UInt32)
    case truncated(String)
    case missing(String)
    case unsupported(String)

    var description: String {
        switch self {
        case .notGlb:
            return "This file does not start with the glTF binary magic, so it is not a .glb."
        case let .unsupportedVersion(version):
            return "This is glTF binary version \(version); this app reads version 2."
        case let .truncated(what):
            return "The file ends part way through \(what), so the transfer did not complete."
        case let .missing(what):
            return "This .glb has no \(what), so there is no geometry to draw."
        case let .unsupported(what):
            return "This .glb uses \(what), which this reader does not handle. "
                 + "It reads the shape PIXMYD and PIXMYD-Nav write and refuses the rest rather "
                 + "than drawing a model that is subtly in the wrong place."
        }
    }
}

enum GlbReader {
    // "glTF", "JSON" and "BIN\0" as little-endian words, which is how the
    // header stores them.
    private static let magic: UInt32 = 0x4654_6C67
    private static let jsonChunk: UInt32 = 0x4E4F_534A
    private static let binaryChunk: UInt32 = 0x004E_4942

    private static let componentFloat = 5126
    private static let componentUnsignedInt = 5125
    private static let componentUnsignedShort = 5123
    private static let componentUnsignedByte = 5121

    /// Parse the first primitive of the first mesh.
    static func read(_ data: Data) throws -> TsdfVolume.Mesh {
        let (json, binary) = try chunks(of: data)

        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw GlbReadError.truncated("the JSON chunk")
        }

        guard let meshes = root["meshes"] as? [[String: Any]], let mesh = meshes.first else {
            throw GlbReadError.missing("mesh")
        }
        guard let primitives = mesh["primitives"] as? [[String: Any]],
              let primitive = primitives.first else {
            throw GlbReadError.missing("mesh primitive")
        }
        // Mode 4 is TRIANGLES and is the default when absent. A strip or a fan
        // would need a different index walk, and reading one as triangles makes
        // a mesh of correct-looking rubbish.
        let mode = primitive["mode"] as? Int ?? 4
        guard mode == 4 else { throw GlbReadError.unsupported("primitive mode \(mode)") }

        guard let attributes = primitive["attributes"] as? [String: Any],
              let positionIndex = attributes["POSITION"] as? Int else {
            throw GlbReadError.missing("POSITION attribute")
        }

        let accessors = root["accessors"] as? [[String: Any]] ?? []
        let views = root["bufferViews"] as? [[String: Any]] ?? []

        let positions = try vectors(
            accessor: positionIndex, accessors: accessors, views: views, binary: binary,
            named: "POSITION")

        var normals: [SIMD3<Float>]?
        if let index = attributes["NORMAL"] as? Int {
            let read = try vectors(
                accessor: index, accessors: accessors, views: views, binary: binary, named: "NORMAL")
            // A normal per vertex or nothing: a short array would silently
            // shade the wrong triangles.
            normals = read.count == positions.count ? read : nil
        }

        var colors: [SIMD3<UInt8>]?
        if let index = attributes["COLOR_0"] as? Int {
            colors = try? bytes(
                accessor: index, accessors: accessors, views: views, binary: binary)
            if colors?.count != positions.count { colors = nil }
        }

        var indices: [UInt32]
        if let index = primitive["indices"] as? Int {
            indices = try scalars(
                accessor: index, accessors: accessors, views: views, binary: binary)
        } else {
            // A non-indexed primitive is every three vertices in order.
            indices = (0..<UInt32(positions.count)).map { $0 }
        }

        // An index past the end of the vertex array crashes a renderer rather
        // than drawing wrongly, so it is caught here where the message can say
        // what happened.
        if let worst = indices.max(), Int(worst) >= positions.count {
            throw GlbReadError.truncated(
                "the vertex data — an index refers to vertex \(worst) of \(positions.count)")
        }
        if indices.count % 3 != 0 {
            indices.removeLast(indices.count % 3)
        }

        return TsdfVolume.Mesh(
            positions: positions,
            normals: normals,
            indices: indices,
            colors: colors,
            uvs: nil,
            texture: nil)
    }

    static func read(contentsOf url: URL) throws -> TsdfVolume.Mesh {
        try read(try Data(contentsOf: url))
    }

    // MARK: - Container

    private static func chunks(of data: Data) throws -> (json: Data, binary: Data) {
        guard data.count >= 12 else { throw GlbReadError.notGlb }
        guard u32(data, 0) == magic else { throw GlbReadError.notGlb }

        let version = u32(data, 4)
        guard version == 2 else { throw GlbReadError.unsupportedVersion(version) }

        // The declared total is trusted only as far as the data actually goes:
        // a truncated download declares the length it was supposed to be.
        let declared = Int(u32(data, 8))
        let limit = min(declared, data.count)

        var json = Data()
        var binary = Data()
        var offset = 12

        while offset + 8 <= limit {
            let length = Int(u32(data, offset))
            let kind = u32(data, offset + 4)
            let start = offset + 8
            guard start + length <= limit else {
                throw GlbReadError.truncated(kind == jsonChunk ? "the JSON chunk" : "the binary chunk")
            }
            let payload = data.subdata(in: start..<(start + length))
            // A JSON chunk is padded to four bytes with spaces, and some
            // writers pad with nulls. `JSONSerialization` refuses trailing
            // nulls, so the padding comes off before it sees the bytes.
            if kind == jsonChunk { json = trimmed(payload) }
            if kind == binaryChunk { binary = payload }
            offset = start + length
        }

        guard !json.isEmpty else { throw GlbReadError.truncated("the JSON chunk") }
        return (json, binary)
    }

    /// Strip the chunk padding: trailing spaces, nulls, tabs and newlines.
    private static func trimmed(_ data: Data) -> Data {
        var end = data.endIndex
        while end > data.startIndex {
            let byte = data[end - 1]
            if byte == 0x20 || byte == 0x00 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                end -= 1
            } else {
                break
            }
        }
        return data.subdata(in: data.startIndex..<end)
    }

    // MARK: - Accessors

    private static func slice(
        accessor index: Int,
        accessors: [[String: Any]],
        views: [[String: Any]],
        binary: Data
    ) throws -> (bytes: Data, count: Int, componentType: Int, type: String) {
        guard index >= 0, index < accessors.count else {
            throw GlbReadError.missing("accessor \(index)")
        }
        let accessor = accessors[index]

        if accessor["sparse"] != nil { throw GlbReadError.unsupported("a sparse accessor") }

        guard let viewIndex = accessor["bufferView"] as? Int,
              viewIndex >= 0, viewIndex < views.count else {
            throw GlbReadError.missing("a bufferView for accessor \(index)")
        }
        let view = views[viewIndex]

        // An external or data-URI buffer is refused: a bundle is a folder the
        // user brought here, and this reader does not fetch.
        if (view["buffer"] as? Int ?? 0) != 0 {
            throw GlbReadError.unsupported("more than one buffer")
        }

        let componentType = accessor["componentType"] as? Int ?? componentFloat
        let type = accessor["type"] as? String ?? "SCALAR"
        let count = accessor["count"] as? Int ?? 0

        let elementSize = try size(of: type) * (try size(ofComponent: componentType))
        if let stride = view["byteStride"] as? Int, stride != 0, stride != elementSize {
            throw GlbReadError.unsupported("interleaved vertex data (byteStride \(stride))")
        }

        let start = (view["byteOffset"] as? Int ?? 0) + (accessor["byteOffset"] as? Int ?? 0)
        let length = count * elementSize
        guard start >= 0, start + length <= binary.count else {
            throw GlbReadError.truncated("the binary chunk")
        }

        return (binary.subdata(in: start..<(start + length)), count, componentType, type)
    }

    private static func vectors(
        accessor index: Int,
        accessors: [[String: Any]],
        views: [[String: Any]],
        binary: Data,
        named: String
    ) throws -> [SIMD3<Float>] {
        let slice = try slice(accessor: index, accessors: accessors, views: views, binary: binary)
        guard slice.type == "VEC3" else {
            throw GlbReadError.unsupported("\(named) as \(slice.type)")
        }
        guard slice.componentType == componentFloat else {
            throw GlbReadError.unsupported("\(named) in a component type other than float")
        }

        var out: [SIMD3<Float>] = []
        out.reserveCapacity(slice.count)
        for i in 0..<slice.count {
            let base = i * 12
            out.append(SIMD3<Float>(
                f32(slice.bytes, base),
                f32(slice.bytes, base + 4),
                f32(slice.bytes, base + 8)))
        }
        return out
    }

    private static func bytes(
        accessor index: Int,
        accessors: [[String: Any]],
        views: [[String: Any]],
        binary: Data
    ) throws -> [SIMD3<UInt8>] {
        let slice = try slice(accessor: index, accessors: accessors, views: views, binary: binary)
        let components = try size(of: slice.type)
        guard components == 3 || components == 4 else {
            throw GlbReadError.unsupported("COLOR_0 as \(slice.type)")
        }

        var out: [SIMD3<UInt8>] = []
        out.reserveCapacity(slice.count)
        for i in 0..<slice.count {
            switch slice.componentType {
            case componentUnsignedByte:
                let base = i * components
                out.append(SIMD3<UInt8>(
                    slice.bytes[slice.bytes.startIndex + base],
                    slice.bytes[slice.bytes.startIndex + base + 1],
                    slice.bytes[slice.bytes.startIndex + base + 2]))
            case componentFloat:
                let base = i * components * 4
                // Linear float colour, as the spec stores it. Scaled rather
                // than gamma-corrected: this is an overlay, not a render.
                out.append(SIMD3<UInt8>(
                    channel(f32(slice.bytes, base)),
                    channel(f32(slice.bytes, base + 4)),
                    channel(f32(slice.bytes, base + 8))))
            default:
                throw GlbReadError.unsupported("COLOR_0 in component type \(slice.componentType)")
            }
        }
        return out
    }

    private static func scalars(
        accessor index: Int,
        accessors: [[String: Any]],
        views: [[String: Any]],
        binary: Data
    ) throws -> [UInt32] {
        let slice = try slice(accessor: index, accessors: accessors, views: views, binary: binary)
        guard slice.type == "SCALAR" else {
            throw GlbReadError.unsupported("indices as \(slice.type)")
        }

        var out: [UInt32] = []
        out.reserveCapacity(slice.count)
        for i in 0..<slice.count {
            switch slice.componentType {
            case componentUnsignedInt:
                out.append(u32(slice.bytes, i * 4))
            case componentUnsignedShort:
                out.append(UInt32(u16(slice.bytes, i * 2)))
            case componentUnsignedByte:
                out.append(UInt32(slice.bytes[slice.bytes.startIndex + i]))
            default:
                throw GlbReadError.unsupported("indices in component type \(slice.componentType)")
            }
        }
        return out
    }

    private static func size(of type: String) throws -> Int {
        switch type {
        case "SCALAR": return 1
        case "VEC2": return 2
        case "VEC3": return 3
        case "VEC4": return 4
        default: throw GlbReadError.unsupported("accessor type \(type)")
        }
    }

    private static func size(ofComponent type: Int) throws -> Int {
        switch type {
        case componentFloat, componentUnsignedInt: return 4
        case componentUnsignedShort, 5122: return 2
        case componentUnsignedByte, 5120: return 1
        default: throw GlbReadError.unsupported("component type \(type)")
        }
    }

    private static func channel(_ value: Float) -> UInt8 {
        UInt8(max(0, min(255, (value * 255).rounded())))
    }

    // MARK: - Little-endian reads
    //
    // Byte by byte rather than through `withUnsafeBytes` + `load`: a `Data`
    // slice can start at any offset, and `load(fromByteOffset:as:)` traps on an
    // unaligned address on some architectures. This is read once per file.

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        guard i + 3 < data.endIndex else { return 0 }
        return UInt32(data[i])
            | UInt32(data[i + 1]) << 8
            | UInt32(data[i + 2]) << 16
            | UInt32(data[i + 3]) << 24
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        guard i + 1 < data.endIndex else { return 0 }
        return UInt16(data[i]) | UInt16(data[i + 1]) << 8
    }

    private static func f32(_ data: Data, _ offset: Int) -> Float {
        Float(bitPattern: u32(data, offset))
    }
}
