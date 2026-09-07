import Foundation

// Reading the model back out of a `.glb`.
//
// SceneKit and RealityKit both claim glTF support in the way marketing does and
// not in the way an API does: neither will open a `.glb` from disk. Every
// project that draws one on iOS carries a loader for it. This is that loader,
// cut down to the one file it has to read.
//
// That is defensible only because the producer is ours. PIXMYD-Nav's
// `Core/Ar/GlbWriter.cs` states what it emits and the list is short: one mesh,
// one primitive, positions and indices, optional normals, one buffer, no
// textures, no animation, no scene graph. A general glTF importer would be
// several thousand lines of features that the only file this app will ever be
// handed cannot exercise.
//
// So: read exactly that, and refuse anything else by name rather than by
// drawing nothing. "This reader takes one mesh" is a sentence someone can act
// on; an empty AR view is not.
//
// Foundation only, so the parsing is covered by `swift test` on Linux.

struct GlbMesh: Equatable {
    /// Metres, in glTF's Y-up right-handed frame.
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]?
    var indices: [UInt32]

    var triangleCount: Int { indices.count / 3 }

    /// The axis-aligned box, or nil for an empty mesh.
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard var low = positions.first else { return nil }
        var high = low
        for p in positions {
            low = SIMD3<Float>(Swift.min(low.x, p.x), Swift.min(low.y, p.y), Swift.min(low.z, p.z))
            high = SIMD3<Float>(Swift.max(high.x, p.x), Swift.max(high.y, p.y), Swift.max(high.z, p.z))
        }
        return (low, high)
    }

    static func == (a: GlbMesh, b: GlbMesh) -> Bool {
        a.positions == b.positions && a.normals == b.normals && a.indices == b.indices
    }
}

enum GlbReadError: Error, CustomStringConvertible, Equatable {
    case notGlb
    case unsupportedVersion(UInt32)
    case truncated(String)
    case malformedJson(String)
    case unsupported(String)

    var description: String {
        switch self {
        case .notGlb:
            return "This file does not start with the glTF binary header, so it is not a .glb."
        case let .unsupportedVersion(version):
            return "This is glTF binary version \(version); this reader handles version 2."
        case let .truncated(what):
            return "The file ends part-way through its \(what)."
        case let .malformedJson(detail):
            return "The glTF header could not be read: \(detail)."
        case let .unsupported(what):
            return "This reader takes the shape PIXMYD-Nav writes - one mesh, one primitive, "
                 + "float positions and integer indices. \(what)"
        }
    }
}

enum GlbReader {
    private static let magic: UInt32 = 0x4674_6C67       // "glTF", little-endian
    private static let jsonChunk: UInt32 = 0x4E4F_534A
    private static let binaryChunk: UInt32 = 0x004E_4942

    static func read(_ data: Data) throws -> GlbMesh {
        guard data.count >= 12 else { throw GlbReadError.truncated("header") }
        guard u32(data, 0) == magic else { throw GlbReadError.notGlb }
        let version = u32(data, 4)
        guard version == 2 else { throw GlbReadError.unsupportedVersion(version) }

        // The declared lengths are trusted only as far as the bytes actually
        // present: a truncated download should say so rather than read past the
        // end of the buffer.
        var json: Data?
        var binary = Data()
        var cursor = 12
        while cursor + 8 <= data.count {
            let length = Int(u32(data, cursor))
            let kind = u32(data, cursor + 4)
            let start = cursor + 8
            guard start + length <= data.count else {
                throw GlbReadError.truncated("chunks")
            }
            let chunk = data.subdata(in: start ..< start + length)
            if kind == jsonChunk, json == nil { json = chunk }
            if kind == binaryChunk, binary.isEmpty { binary = chunk }
            cursor = start + length
        }
        guard let json else { throw GlbReadError.truncated("JSON chunk") }

        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
                throw GlbReadError.malformedJson("the header is not a JSON object")
            }
            root = object
        } catch let error as GlbReadError {
            throw error
        } catch {
            throw GlbReadError.malformedJson("\(error)")
        }

        return try mesh(root: root, binary: binary)
    }

    // MARK: - The one mesh

    private static func mesh(root: [String: Any], binary: Data) throws -> GlbMesh {
        guard let meshes = root["meshes"] as? [[String: Any]], let first = meshes.first else {
            throw GlbReadError.unsupported("This file declares no meshes.")
        }
        guard let primitives = first["primitives"] as? [[String: Any]],
              let primitive = primitives.first else {
            throw GlbReadError.unsupported("Its mesh has no primitives.")
        }
        // glTF's default mode is 4, triangles, so an absent mode is fine.
        if let mode = primitive["mode"] as? Int, mode != 4 {
            throw GlbReadError.unsupported("Its primitive is mode \(mode), not triangles.")
        }
        guard let attributes = primitive["attributes"] as? [String: Any],
              let positionIndex = attributes["POSITION"] as? Int else {
            throw GlbReadError.unsupported("Its primitive has no POSITION attribute.")
        }

        let accessors = root["accessors"] as? [[String: Any]] ?? []
        let views = root["bufferViews"] as? [[String: Any]] ?? []

        let positions = try vec3(accessors, views, binary, positionIndex, name: "POSITION")

        var normals: [SIMD3<Float>]?
        if let normalIndex = attributes["NORMAL"] as? Int {
            let read = try vec3(accessors, views, binary, normalIndex, name: "NORMAL")
            // A normal array of the wrong length is worse than none at all:
            // SceneKit would read past the end of it.
            normals = read.count == positions.count ? read : nil
        }

        var indices: [UInt32]
        if let indexAccessor = primitive["indices"] as? Int {
            indices = try scalarIndices(accessors, views, binary, indexAccessor)
        } else {
            // Non-indexed geometry is legal glTF. Ours is always indexed, but
            // synthesising the sequence is one line and saves a refusal.
            indices = (0 ..< UInt32(positions.count)).map { $0 }
        }
        guard indices.allSatisfy({ Int($0) < positions.count }) else {
            throw GlbReadError.unsupported("An index points past the end of the vertex list.")
        }

        return GlbMesh(positions: positions, normals: normals, indices: indices)
    }

    // MARK: - Accessors

    private static func vec3(
        _ accessors: [[String: Any]],
        _ views: [[String: Any]],
        _ binary: Data,
        _ index: Int,
        name: String
    ) throws -> [SIMD3<Float>] {
        let (bytes, count, stride) = try slice(accessors, views, binary, index, name: name)
        guard count > 0 else { return [] }
        guard (accessors[index]["type"] as? String) == "VEC3" else {
            throw GlbReadError.unsupported("\(name) is not a VEC3.")
        }
        guard (accessors[index]["componentType"] as? Int) == 5126 else {
            throw GlbReadError.unsupported("\(name) is not float.")
        }
        let step = stride == 0 ? 12 : stride
        guard bytes.count >= (count - 1) * step + 12 else {
            throw GlbReadError.truncated("\(name) data")
        }
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(count)
        for i in 0 ..< count {
            let at = i * step
            out.append(SIMD3<Float>(f32(bytes, at), f32(bytes, at + 4), f32(bytes, at + 8)))
        }
        return out
    }

    private static func scalarIndices(
        _ accessors: [[String: Any]],
        _ views: [[String: Any]],
        _ binary: Data,
        _ index: Int
    ) throws -> [UInt32] {
        let (bytes, count, stride) = try slice(accessors, views, binary, index, name: "indices")
        guard count > 0 else { return [] }
        guard (accessors[index]["type"] as? String) == "SCALAR" else {
            throw GlbReadError.unsupported("The index accessor is not SCALAR.")
        }
        // 5121 unsigned byte, 5123 unsigned short, 5125 unsigned int. All three
        // are common enough that refusing the small ones would be a refusal
        // over nothing.
        let component = accessors[index]["componentType"] as? Int ?? 5125
        let width: Int
        switch component {
        case 5121: width = 1
        case 5123: width = 2
        case 5125: width = 4
        default: throw GlbReadError.unsupported("The index component type is \(component).")
        }
        let step = stride == 0 ? width : stride
        guard bytes.count >= (count - 1) * step + width else {
            throw GlbReadError.truncated("index data")
        }
        var out: [UInt32] = []
        out.reserveCapacity(count)
        for i in 0 ..< count {
            let at = i * step
            switch width {
            case 1: out.append(UInt32(bytes[bytes.startIndex + at]))
            case 2: out.append(UInt32(u16(bytes, at)))
            default: out.append(u32(bytes, at))
            }
        }
        return out
    }

    /// The bytes an accessor addresses, its element count, and the view's
    /// stride. Zero stride means tightly packed, which is glTF's own default.
    private static func slice(
        _ accessors: [[String: Any]],
        _ views: [[String: Any]],
        _ binary: Data,
        _ index: Int,
        name: String
    ) throws -> (Data, Int, Int) {
        guard index >= 0, index < accessors.count else {
            throw GlbReadError.unsupported("\(name) names accessor \(index), which does not exist.")
        }
        let accessor = accessors[index]
        if accessor["sparse"] != nil {
            throw GlbReadError.unsupported("\(name) is a sparse accessor.")
        }
        let count = accessor["count"] as? Int ?? 0
        guard count > 0 else { return (Data(), 0, 0) }
        guard let viewIndex = accessor["bufferView"] as? Int,
              viewIndex >= 0, viewIndex < views.count else {
            throw GlbReadError.unsupported("\(name) has no bufferView.")
        }
        let view = views[viewIndex]
        let viewOffset = view["byteOffset"] as? Int ?? 0
        let viewLength = view["byteLength"] as? Int ?? 0
        let stride = view["byteStride"] as? Int ?? 0
        let offset = viewOffset + (accessor["byteOffset"] as? Int ?? 0)
        let end = viewOffset + viewLength
        guard viewOffset >= 0, viewLength >= 0, offset >= viewOffset,
              end <= binary.count, offset <= end else {
            throw GlbReadError.truncated("\(name) buffer view")
        }
        return (binary.subdata(in: offset ..< end), count, stride)
    }

    // MARK: - Little-endian reads

    private static func u32(_ data: Data, _ at: Int) -> UInt32 {
        let i = data.startIndex + at
        guard i >= data.startIndex, i + 4 <= data.endIndex else { return 0 }
        return UInt32(data[i]) | UInt32(data[i + 1]) << 8
             | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }

    private static func u16(_ data: Data, _ at: Int) -> UInt16 {
        let i = data.startIndex + at
        guard i >= data.startIndex, i + 2 <= data.endIndex else { return 0 }
        return UInt16(data[i]) | UInt16(data[i + 1]) << 8
    }

    private static func f32(_ data: Data, _ at: Int) -> Float {
        Float(bitPattern: u32(data, at))
    }
}
