import Foundation
import simd

// Texturing a fused mesh from the photographs that made it, rather than from
// the colour fusion left on its vertices.
//
// ## Why the old colour could never read a label
//
// Fusion averages colour into the voxel grid, so the finest colour detail a
// scan could carry was one sample per voxel — 25 mm on a room, 6 mm on an
// object. `ColorAtlasBaker` then collapsed that further to one texel per
// triangle, and decimation had already made triangles larger than voxels. A
// 3 mm letter stroke was averaged away twice before anything was written.
//
// Meanwhile the capture bundle holds the original 12-megapixel frames, their
// intrinsics and their poses. At half a metre one of those pixels covers about
// 0.15 mm of wall. The detail to read a valve tag was on disk the whole time;
// nothing downstream was looking at it.
//
// So this projects the photographs back onto the mesh. Each triangle is given
// its own tile in an atlas, sized from how big the triangle actually is in the
// world, and each texel in that tile is filled by projecting its world position
// into the one frame that saw that triangle best.
//
// ## The three decisions that matter
//
// **Tile size follows world size, not triangle count.** A uniform tile spends
// as many texels on a 2 m wall panel as on a 30 mm bracket, which is exactly
// backwards — the wall is where the signage is. Tiles are powers of two chosen
// from each triangle's longest edge against a target texel size, so texel
// density is roughly constant across the model in millimetres, which is the
// unit the person reading the label cares about.
//
// **One frame per triangle, not a blend.** Averaging several views is what
// fusion already did, and averaging is what destroys text: two frames a
// centimetre apart in pose blur strokes into grey. Picking the single most
// head-on, closest, unoccluded view keeps the lens's own sharpness. The cost is
// visible seams where neighbouring triangles chose different frames under
// different exposure — see the ceiling note at the end.
//
// **Occlusion is checked against the frame's own depth map.** Without it a
// column's pixels get painted onto the wall behind it, which looks like a
// texture bug but is really a visibility bug, and is the classic way projective
// texturing goes wrong.
//
// Pure arithmetic — no image decoding, no file access — so it lives in
// `portableSources` and is tested on Linux. The caller decodes frames and hands
// over pixels.

/// Where each triangle's texels live in the atlas.
struct PhotoTextureLayout: Equatable {
    /// The atlas is square; this is its side in texels.
    var side: Int
    /// Top-left texel of each triangle's tile.
    var origins: [SIMD2<Int32>]
    /// Each tile's side in texels, a power of two, gutter included.
    var sizes: [Int32]
    /// Three per triangle, in image space with V pointing down — the same
    /// convention `ColorAtlas` uses, so the writers need no new flip.
    var cornerUvs: [SIMD2<Float>]
    /// Metres per texel this layout achieved. Reported to the user, because
    /// "will the tag be readable" is answered by this number and nothing else.
    var texelMetres: Float

    var triangleCount: Int { sizes.count }
}

/// Projects captured frames onto a mesh, one triangle tile at a time.
final class PhotoTextureBaker {

    /// One captured frame's colour camera and where it was.
    struct SourceView {
        /// Intrinsics of the full-resolution colour image.
        var camera: CameraModel.Pinhole
        /// Camera-to-world, computer-vision axes — the same `Pose` fusion used.
        var pose: Pose
    }

    /// A frame's depth map, used only to decide what it could actually see.
    struct DepthRaster {
        /// Metres, row-major, top row first. Zero means no measurement.
        var metres: [Float]
        var width: Int
        var height: Int
        /// The depth raster's own intrinsics, which are not the colour ones.
        var camera: CameraModel.Pinhole
    }

    struct Options {
        /// The texel size to aim for, metres. One millimetre is about what it
        /// takes to read printed plant tagging; the plan falls back to coarser
        /// texels when the model is too big to hold them.
        var targetTexelMetres: Float = 0.001
        /// Atlas ceiling. 4096 is 50 MB of RGB in memory and is accepted by
        /// every renderer and by Navisworks; 8192 would be four times that on a
        /// device that is also holding the mesh and a decoded frame.
        var maximumSide: Int = 4096
        /// Smallest tile. Below 4 there is no room for both a gutter and two
        /// usable texels, and the result is worse than the flat bake.
        var minimumTile: Int32 = 4
        /// Largest tile. A single triangle taking a 256-texel tile would starve
        /// the rest of the model for the sake of one wall panel.
        var maximumTile: Int32 = 64

        init() {}
    }

    /// Texels of margin on every side of a tile.
    ///
    /// The triangle's corners are pinned one and a half texels inside the tile,
    /// and the margin is painted with the same projection extrapolated outward.
    /// So a bilinear sample at the very edge of the triangle blends with the
    /// natural continuation of the surface rather than with whatever triangle
    /// was packed next door — which, in an atlas, is some unrelated part of the
    /// building.
    static let gutter: Int32 = 1

    let layout: PhotoTextureLayout
    private let positions: [SIMD3<Float>]
    private let indices: [UInt32]
    private let normals: [SIMD3<Float>]

    /// Best view index per triangle, or -1 where no frame saw it.
    private(set) var assignments: [Int32]
    private var scores: [Float]
    private var buckets: [Int32: [Int]]?

    private var rgb: [UInt8]

    // MARK: - Planning

    /// Choose a tile for every triangle and pack them into a square.
    ///
    /// Returns nil when there is nothing to lay out. When the ideal texel size
    /// will not fit, the target is doubled and the whole plan retried rather
    /// than the model being cropped — a coarser texture everywhere is a result;
    /// a sharp texture on the first two thirds of a floorplate is a bug.
    static func plan(
        positions: [SIMD3<Float>],
        indices: [UInt32],
        options: Options = Options()
    ) -> PhotoTextureLayout? {
        let triangleCount = indices.count / 3
        guard triangleCount > 0, !positions.isEmpty else { return nil }

        var edges = [Float](repeating: 0, count: triangleCount)
        for triangle in 0..<triangleCount {
            guard let (a, b, c) = corners(positions: positions, indices: indices, triangle: triangle)
            else { continue }
            edges[triangle] = max(
                simd_distance(a, b), max(simd_distance(b, c), simd_distance(c, a))
            )
        }

        var target = max(options.targetTexelMetres, 1e-5)
        // Twenty doublings takes a millimetre past a kilometre, so this
        // terminates long before it runs out; the bound is only here so a
        // degenerate mesh cannot spin forever.
        for _ in 0..<20 {
            var sizes = [Int32](repeating: options.minimumTile, count: triangleCount)
            for triangle in 0..<triangleCount {
                // Three texels of overhead: one gutter each side, and the half
                // texel at each end that pins a corner on a texel centre.
                // Clamped before the integer conversion: a degenerate mesh
                // with a kilometre-long edge against a millimetre target
                // overflows Int32, and a trap in an export is a worse answer
                // than a tile that is merely too big and then clamped.
                let wanted = (edges[triangle] / target).rounded(.up)
                let across = Int32(min(max(wanted, 1), 1_048_576)) + 3
                sizes[triangle] = min(
                    options.maximumTile, max(options.minimumTile, nextPowerOfTwo(across))
                )
            }

            // Start from the smallest square that could hold the tiles at all,
            // rather than from 64. Packing sorts every triangle, and trying
            // seven hopeless sizes first would sort a 200,000-triangle mesh
            // seven times to learn what arithmetic already knew.
            let area = sizes.reduce(0) { $0 + Int($1) * Int($1) }
            var side = 64
            while side * side < area && side < options.maximumSide { side *= 2 }
            while side <= options.maximumSide {
                if let origins = pack(sizes: sizes, side: side) {
                    return PhotoTextureLayout(
                        side: side,
                        origins: origins,
                        sizes: sizes,
                        cornerUvs: cornerUvs(origins: origins, sizes: sizes, side: side),
                        texelMetres: target
                    )
                }
                side *= 2
            }
            target *= 2
        }
        return nil
    }

    /// Shelf packing, largest tile first.
    ///
    /// Sorting descending is what makes something this simple close to optimal:
    /// every row's height is set by its first tile, and every tile placed after
    /// it in that row is the same size or smaller and a power of two, so the
    /// only waste is the ragged end of a row.
    static func pack(sizes: [Int32], side: Int) -> [SIMD2<Int32>]? {
        let limit = Int32(side)
        let order = sizes.indices.sorted { sizes[$0] > sizes[$1] }
        var origins = [SIMD2<Int32>](repeating: .zero, count: sizes.count)
        var x: Int32 = 0, y: Int32 = 0, rowHeight: Int32 = 0

        for triangle in order {
            let size = sizes[triangle]
            if x + size > limit {
                x = 0
                y += rowHeight
                rowHeight = 0
            }
            guard y + size <= limit else { return nil }
            origins[triangle] = SIMD2(x, y)
            x += size
            rowHeight = max(rowHeight, size)
        }
        return origins
    }

    /// Where a tile's three triangle corners sit, in atlas UV.
    ///
    /// Corners land on texel *centres*, not texel corners: a UV on a boundary
    /// samples two texels half and half, which would soften every triangle edge
    /// in the model for no reason.
    static func cornerUvs(
        origins: [SIMD2<Int32>], sizes: [Int32], side: Int
    ) -> [SIMD2<Float>] {
        var uvs = [SIMD2<Float>]()
        uvs.reserveCapacity(sizes.count * 3)
        let scale = 1 / Float(side)
        for triangle in sizes.indices {
            let origin = origins[triangle]
            let anchor = Float(gutter) + 0.5
            let span = Float(sizes[triangle] - 2 * gutter - 1)
            let x0 = Float(origin.x) + anchor
            let y0 = Float(origin.y) + anchor
            uvs.append(SIMD2(x0 * scale, y0 * scale))
            uvs.append(SIMD2((x0 + span) * scale, y0 * scale))
            uvs.append(SIMD2(x0 * scale, (y0 + span) * scale))
        }
        return uvs
    }

    // MARK: - Init

    init(positions: [SIMD3<Float>], indices: [UInt32], layout: PhotoTextureLayout) {
        self.positions = positions
        self.indices = indices
        self.layout = layout

        let triangleCount = indices.count / 3
        var faceNormals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: triangleCount)
        for triangle in 0..<triangleCount {
            guard let (a, b, c) = Self.corners(
                positions: positions, indices: indices, triangle: triangle
            ) else { continue }
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            if length > 1e-12 { faceNormals[triangle] = cross / length }
        }
        normals = faceNormals

        assignments = [Int32](repeating: -1, count: triangleCount)
        scores = [Float](repeating: 0, count: triangleCount)
        // Mid-grey rather than black, for the same reason the flat atlas uses
        // it: an unpainted texel should read as "no information", and black
        // reads as a hole in the surface.
        rgb = [UInt8](repeating: 0x80, count: layout.side * layout.side * 3)
    }

    // MARK: - Choosing a view

    /// Score one frame against every triangle, keeping the best so far.
    ///
    /// Called once per frame with that frame's depth map, so the caller never
    /// has to hold more than one raster at a time. Colour pixels are not needed
    /// here — deciding *which* frame wins is geometry, and decoding a
    /// 12-megapixel JPEG for a frame that turns out to win nothing is the
    /// expensive mistake this ordering avoids.
    func consider(view: SourceView, index: Int, depth: DepthRaster?) {
        // Invalidated here rather than in a property observer on `assignments`:
        // an observer fires on every element write, and this loop makes
        // millions of them.
        buckets = nil
        let inverse = Self.inverseRotation(view.pose)
        let eye = Self.translation(view.pose)

        let fx = Float(view.camera.fx), fy = Float(view.camera.fy)
        let cx = Float(view.camera.cx), cy = Float(view.camera.cy)
        let width = Float(view.camera.width), height = Float(view.camera.height)
        guard fx > 0, fy > 0, width > 1, height > 1 else { return }

        for triangle in assignments.indices {
            guard let (a, b, c) = Self.corners(
                positions: positions, indices: indices, triangle: triangle
            ) else { continue }
            let centre = (a + b + c) / 3

            let camera = inverse.act(centre - eye)
            guard camera.z > 0.05 else { continue }

            let u = camera.x * fx / camera.z + cx
            let v = camera.y * fy / camera.z + cy
            guard u >= 0, v >= 0, u <= width - 1, v <= height - 1 else { continue }

            // Facing the camera, and not so edge-on that a texel smears across
            // half the image. Below about 25 degrees the pixels are worthless
            // and a further-away head-on frame is the better answer.
            let toEye = simd_normalize(eye - centre)
            let facing = simd_dot(normals[triangle], toEye)
            guard facing > 0.25 else { continue }

            if let depth, !Self.visible(centre: camera, in: depth) { continue }

            // Texels per metre goes as 1/z and sharpness with the cosine, and
            // both matter twice over when what is being resolved is a stroke
            // width, so each is squared.
            let score = facing * facing / (camera.z * camera.z)
            if score > scores[triangle] {
                scores[triangle] = score
                assignments[triangle] = Int32(index)
            }
        }
    }

    /// Whether a camera-space point agrees with what that frame measured.
    ///
    /// The tolerance is generous on purpose. Depth is 256x192 against a
    /// 12-megapixel image, so a single depth sample covers a patch of scene and
    /// straddles edges; a tight test would reject the correct view along every
    /// silhouette and leave grey fringes around everything in the model.
    static func visible(centre: SIMD3<Float>, in depth: DepthRaster) -> Bool {
        let fx = Float(depth.camera.fx), fy = Float(depth.camera.fy)
        let cx = Float(depth.camera.cx), cy = Float(depth.camera.cy)
        guard fx > 0, fy > 0, depth.width > 0, depth.height > 0, centre.z > 1e-4
        else { return true }

        let u = Int((centre.x * fx / centre.z + cx).rounded())
        let v = Int((centre.y * fy / centre.z + cy).rounded())
        guard u >= 0, v >= 0, u < depth.width, v < depth.height else { return true }

        let observed = depth.metres[v * depth.width + u]
        // No measurement is not evidence of occlusion.
        guard observed > 0 else { return true }
        return centre.z <= observed + 0.08
    }

    // MARK: - Painting

    /// The triangles that chose a given frame. Empty means its pixels are never
    /// needed and the caller can skip decoding it.
    ///
    /// Bucketed on first use rather than scanned per call: painting asks this
    /// once per winning frame, and a linear scan each time would be the
    /// triangle count times the frame count again, for the second time in one
    /// export.
    func triangles(assignedTo index: Int) -> [Int] {
        if buckets == nil {
            var built: [Int32: [Int]] = [:]
            for triangle in assignments.indices where assignments[triangle] >= 0 {
                built[assignments[triangle], default: []].append(triangle)
            }
            buckets = built
        }
        return buckets?[Int32(index)] ?? []
    }

    /// Fill every tile that chose this frame, by projecting its texels into it.
    ///
    /// `pixels` is RGBA8, top row first, at the colour camera's full resolution.
    func paint(
        index: Int,
        view: SourceView,
        pixels: [UInt8],
        width: Int,
        height: Int
    ) {
        guard width > 1, height > 1, pixels.count >= width * height * 4 else { return }
        let inverse = Self.inverseRotation(view.pose)
        let eye = Self.translation(view.pose)
        let fx = Float(view.camera.fx), fy = Float(view.camera.fy)
        let cx = Float(view.camera.cx), cy = Float(view.camera.cy)
        guard fx > 0, fy > 0 else { return }

        // The colour camera's intrinsics describe the frame it was captured at;
        // a caller that hands over a resized decode has to be projected in that
        // decode's pixels, not the original's.
        let sx = Float(width) / Float(max(view.camera.width, 1))
        let sy = Float(height) / Float(max(view.camera.height, 1))

        for triangle in triangles(assignedTo: index) {
            guard let (a, b, c) = Self.corners(
                positions: positions, indices: indices, triangle: triangle
            ) else { continue }

            let origin = layout.origins[triangle]
            let size = layout.sizes[triangle]
            let anchor = Float(Self.gutter) + 0.5
            let span = Float(size - 2 * Self.gutter - 1)
            guard span > 0 else { continue }

            for ty in 0..<Int(size) {
                for tx in 0..<Int(size) {
                    // Barycentric weights of corners b and c. Texels in the
                    // gutter give weights outside [0, 1], which extrapolates
                    // the surface plane outward — exactly the bleed a bilinear
                    // sample at the triangle's edge should find there.
                    let wb = (Float(tx) + 0.5 - anchor) / span
                    let wc = (Float(ty) + 0.5 - anchor) / span
                    let world = a + (b - a) * wb + (c - a) * wc

                    let camera = inverse.act(world - eye)
                    guard camera.z > 0.01 else { continue }
                    let u = (camera.x * fx / camera.z + cx) * sx
                    let v = (camera.y * fy / camera.z + cy) * sy

                    let colour = Self.bilinear(
                        pixels, u: u, v: v, width: width, height: height
                    )
                    let offset = ((Int(origin.y) + ty) * layout.side + Int(origin.x) + tx) * 3
                    rgb[offset] = colour.0
                    rgb[offset + 1] = colour.1
                    rgb[offset + 2] = colour.2
                }
            }
        }
    }

    /// Fill a triangle's whole tile with one colour.
    ///
    /// For triangles no frame saw. Their fused vertex colour is worse than a
    /// photograph and better than grey, and a hole in the texture is read as a
    /// hole in the building.
    func fill(triangle: Int, with colour: SIMD3<UInt8>) {
        guard triangle >= 0, triangle < layout.sizes.count else { return }
        let origin = layout.origins[triangle]
        let size = Int(layout.sizes[triangle])
        for ty in 0..<size {
            var offset = ((Int(origin.y) + ty) * layout.side + Int(origin.x)) * 3
            for _ in 0..<size {
                rgb[offset] = colour.x
                rgb[offset + 1] = colour.y
                rgb[offset + 2] = colour.z
                offset += 3
            }
        }
    }

    /// Fill every unassigned tile from the mesh's own vertex colours.
    func fillUnassigned(colors: [SIMD3<UInt8>]?) {
        guard let colors, !colors.isEmpty else { return }
        for triangle in assignments.indices where assignments[triangle] < 0 {
            let base = triangle * 3
            var r = 0, g = 0, b = 0, samples = 0
            for corner in 0..<3 {
                let vertex = Int(indices[base + corner])
                guard vertex >= 0, vertex < colors.count else { continue }
                r += Int(colors[vertex].x)
                g += Int(colors[vertex].y)
                b += Int(colors[vertex].z)
                samples += 1
            }
            guard samples > 0 else { continue }
            fill(
                triangle: triangle,
                with: SIMD3(UInt8(r / samples), UInt8(g / samples), UInt8(b / samples))
            )
        }
    }

    /// How many triangles ended up with a photograph on them.
    var paintedTriangles: Int { assignments.reduce(0) { $0 + ($1 >= 0 ? 1 : 0) } }

    /// Encode the atlas. Shaped as a `ColorAtlas` so both writers take it
    /// unchanged — the only difference from the flat bake is that `cornerUvs`
    /// is populated and the UVs differ per corner.
    func finish() throws -> ColorAtlas {
        let png = try PngWriter.encodeRgb(width: layout.side, height: layout.side, rgb: rgb)
        // `triangleUvs` keeps its meaning for anything that only wants one UV
        // per face: the tile's first corner.
        var flat = [SIMD2<Float>]()
        flat.reserveCapacity(layout.triangleCount)
        for triangle in 0..<layout.triangleCount { flat.append(layout.cornerUvs[triangle * 3]) }

        return ColorAtlas(
            texture: TsdfVolume.TextureImage(
                width: layout.side,
                height: layout.side,
                mimeType: "image/png",
                data: png
            ),
            triangleUvs: flat,
            cornerUvs: layout.cornerUvs,
            side: layout.side
        )
    }

    // MARK: - Arithmetic

    static func corners(
        positions: [SIMD3<Float>], indices: [UInt32], triangle: Int
    ) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)? {
        let base = triangle * 3
        guard base + 2 < indices.count else { return nil }
        let a = Int(indices[base]), b = Int(indices[base + 1]), c = Int(indices[base + 2])
        guard a >= 0, b >= 0, c >= 0,
              a < positions.count, b < positions.count, c < positions.count else { return nil }
        return (positions[a], positions[b], positions[c])
    }

    static func nextPowerOfTwo(_ value: Int32) -> Int32 {
        var result: Int32 = 1
        while result < value && result < (1 << 20) { result <<= 1 }
        return result
    }

    /// World-to-camera rotation.
    ///
    /// Built by negating the imaginary part rather than by asking for a
    /// conjugate, because the Linux `simd` shim this file is compiled against
    /// on CI does not have one -- and `TsdfVolume` inverts its poses the same
    /// way, so the two agree by construction.
    static func inverseRotation(_ pose: Pose) -> simd_quatf {
        let q = quaternion(pose)
        return simd_quatf(ix: -q.imag.x, iy: -q.imag.y, iz: -q.imag.z, r: q.real)
    }

    static func quaternion(_ pose: Pose) -> simd_quatf {
        guard pose.q.count >= 4 else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        return simd_quatf(
            ix: Float(pose.q[0]), iy: Float(pose.q[1]),
            iz: Float(pose.q[2]), r: Float(pose.q[3])
        )
    }

    static func translation(_ pose: Pose) -> SIMD3<Float> {
        guard pose.t.count >= 3 else { return .zero }
        return SIMD3(Float(pose.t[0]), Float(pose.t[1]), Float(pose.t[2]))
    }

    /// Bilinear RGBA8 sample, top row first.
    ///
    /// Sampled and stored in sRGB rather than round-tripped through linear.
    /// Fusion averages many frames and has to average in linear or the result
    /// darkens; this takes one sample from one frame, and a round trip would
    /// only cost two transfer-function evaluations per texel and a little
    /// contrast on exactly the edges that make text legible.
    static func bilinear(
        _ pixels: [UInt8], u: Float, v: Float, width: Int, height: Int
    ) -> (UInt8, UInt8, UInt8) {
        let x = max(0, min(Float(width) - 1.001, u))
        let y = max(0, min(Float(height) - 1.001, v))
        let x0 = Int(x), y0 = Int(y)
        let fx = x - Float(x0), fy = y - Float(y0)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)

        func channel(_ offset: Int) -> UInt8 {
            let a = Float(pixels[(y0 * width + x0) * 4 + offset])
            let b = Float(pixels[(y0 * width + x1) * 4 + offset])
            let c = Float(pixels[(y1 * width + x0) * 4 + offset])
            let d = Float(pixels[(y1 * width + x1) * 4 + offset])
            let top = a * (1 - fx) + b * fx
            let bottom = c * (1 - fx) + d * fx
            return UInt8(max(0, min(255, (top * (1 - fy) + bottom * fy).rounded())))
        }
        return (channel(0), channel(1), channel(2))
    }
}

// ponytail: no exposure matching between adjacent tiles, so a wall lit by two
// frames at different exposures shows a seam along the triangle edge where the
// chosen frame changes. The fix is a per-view gain solved over the seam graph;
// worth doing when somebody complains about banding rather than about text.
