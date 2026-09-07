import Foundation

// Turning the per-vertex colours a scan already has into a texture that
// importers actually honour.
//
// ## The problem this solves
//
// Fusion produces one colour per vertex. OBJ has no standard way to carry that
// — the `v x y z r g b` form is an extension, and Navisworks, most CAD tools
// and plenty of viewers ignore the trailing three numbers without complaint.
// The mesh arrives grey and the export looks broken when the data was fine all
// along.
//
// A texture is the form every importer reads. So this bakes the colours the
// mesh has into one, rather than inventing detail it does not have.
//
// ## One texel per triangle
//
// Each triangle gets a single texel, and all three of its corners point at that
// texel's exact centre. Sampling anywhere inside the triangle therefore reads
// one texel with bilinear weights of (1, 0, 0, 0) — the exact colour, with no
// bleed from the neighbours packed beside it.
//
// The alternative, a texel per *vertex*, cannot work: a fragment halfway across
// a triangle interpolates to a UV between two texels and samples whatever the
// atlas happens to have packed there, which is some other triangle's colour
// from the far side of the mesh.
//
// The cost is that colour becomes flat per triangle instead of smoothly
// interpolated. On a fused scan — hundreds of thousands of triangles a few
// millimetres across — that is not a visible difference. It is the honest
// trade: exact colour that survives export, against smooth colour that does
// not survive at all.
//
// ## No vertex splitting
//
// Both target formats can index texture coordinates separately from positions:
// OBJ's `f v/vt` pairs, and FBX's `LayerElementUV` with `IndexToDirect`. So the
// atlas hands back one UV per *triangle* and the writers map polygon corners
// onto it. Splitting every shared vertex would have tripled the vertex count
// for nothing.
//
// Pure arithmetic, in `portableSources`.

struct ColorAtlas {
    /// The encoded image, ready to be written beside the mesh or embedded.
    var texture: TsdfVolume.TextureImage
    /// One texture coordinate per triangle, at that triangle's texel centre.
    ///
    /// When `cornerUvs` is present this is that tile's first corner rather
    /// than a centre, and anything wanting the real coordinates should read
    /// `cornerUvs` instead.
    var triangleUvs: [SIMD2<Float>]
    /// Three per triangle, when the atlas gives each triangle a whole tile
    /// rather than a single texel. Nil for the flat per-triangle bake, whose
    /// three corners genuinely do share one coordinate.
    var cornerUvs: [SIMD2<Float>]? = nil
    /// The atlas is square; this is its side in texels.
    var side: Int

    var triangleCount: Int { triangleUvs.count }
}

enum ColorAtlasBaker {
    /// The largest atlas that will be produced.
    ///
    /// A side of 4096 is 16.7 million triangles, far past what a phone fuses,
    /// and keeps the image inside the texture size every renderer supports.
    /// Past that the bake is refused rather than silently truncated: half a
    /// coloured mesh is harder to diagnose than none.
    static let maximumSide = 4096

    /// Expand per-triangle coordinates to one entry per polygon corner — the
    /// shape the FBX writer's `ByPolygonVertex` layer expects.
    ///
    /// The atlas hands one UV per triangle and all three corners of a triangle
    /// sample the same texel, so each corner repeats its triangle's UV.
    /// A photo-textured atlas already has one per corner, and they differ —
    /// that is the whole point of it — so those are handed straight back.
    static func polygonUvs(of atlas: ColorAtlas, for indices: [UInt32]) -> [SIMD2<Float>] {
        if let corners = atlas.cornerUvs, corners.count >= indices.count {
            return Array(corners.prefix(indices.count))
        }
        var out = [SIMD2<Float>]()
        out.reserveCapacity(indices.count)
        for triangle in 0..<(indices.count / 3) {
            let uv = atlas.triangleUvs[triangle]
            out.append(uv)
            out.append(uv)
            out.append(uv)
        }
        return out
    }

    enum BakeError: Error, CustomStringConvertible {
        case noColors
        case noTriangles
        case tooManyTriangles(count: Int, limit: Int)

        var description: String {
            switch self {
            case .noColors:
                return "This mesh has no colour to bake, so there is nothing to put in a texture."
            case .noTriangles:
                return "This mesh has no triangles."
            case let .tooManyTriangles(count, limit):
                return "This mesh has \(count) triangles and the colour atlas holds \(limit). "
                     + "Export at a coarser detail level."
            }
        }
    }

    /// Bake per-vertex colours into a texture plus per-triangle UVs.
    ///
    /// Returns nil when the mesh has no colours at all — that is a normal mesh,
    /// not an error, and the caller writes an untextured file.
    static func bake(
        colors: [SIMD3<UInt8>]?,
        indices: [UInt32],
        vertexCount: Int
    ) throws -> ColorAtlas? {
        guard let colors, !colors.isEmpty else { return nil }
        let triangleCount = indices.count / 3
        guard triangleCount > 0 else { throw BakeError.noTriangles }

        let side = atlasSide(for: triangleCount)
        guard side <= maximumSide else {
            throw BakeError.tooManyTriangles(count: triangleCount, limit: maximumSide * maximumSide)
        }

        // The atlas is initialised to mid-grey rather than black: every texel
        // past the last triangle is unused, and grey padding is invisible if a
        // renderer ever does sample one, where black reads as a hole.
        var rgb = [UInt8](repeating: 0x80, count: side * side * 3)
        var uvs = [SIMD2<Float>]()
        uvs.reserveCapacity(triangleCount)

        let texel = 1.0 / Float(side)
        let half = texel / 2

        for triangle in 0..<triangleCount {
            let base = triangle * 3
            // Guarded rather than trusted: these indices have been through
            // simplification and editing, and one stale index would otherwise
            // be an out-of-bounds crash in an export.
            let a = Int(indices[base])
            let b = Int(indices[base + 1])
            let c = Int(indices[base + 2])

            var r = 0, g = 0, bl = 0, samples = 0
            for vertex in [a, b, c] where vertex >= 0 && vertex < min(vertexCount, colors.count) {
                let colour = colors[vertex]
                r += Int(colour.x)
                g += Int(colour.y)
                bl += Int(colour.z)
                samples += 1
            }

            let column = triangle % side
            let row = triangle / side
            let offset = (row * side + column) * 3
            if samples > 0 {
                rgb[offset] = UInt8(r / samples)
                rgb[offset + 1] = UInt8(g / samples)
                rgb[offset + 2] = UInt8(bl / samples)
            }

            // The exact centre of this triangle's texel, in image space with V
            // pointing down. Writers that need FBX's V-up convention flip it.
            uvs.append(SIMD2<Float>(
                Float(column) * texel + half,
                Float(row) * texel + half
            ))
        }

        let png = try PngWriter.encodeRgb(width: side, height: side, rgb: rgb)
        return ColorAtlas(
            texture: TsdfVolume.TextureImage(
                width: side,
                height: side,
                mimeType: "image/png",
                data: png
            ),
            triangleUvs: uvs,
            side: side
        )
    }

    /// The smallest square that holds one texel per triangle.
    static func atlasSide(for triangleCount: Int) -> Int {
        guard triangleCount > 0 else { return 1 }
        var side = Int(Double(triangleCount).squareRoot().rounded(.up))
        // `rounded(.up)` on a square root can land one short for perfect
        // squares near the floating-point boundary, so this corrects rather
        // than trusts it.
        while side * side < triangleCount { side += 1 }
        return max(side, 1)
    }
}
