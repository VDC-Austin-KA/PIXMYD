import XCTest
import simd
@testable import PIXMYD

/// The projective texture bake is the difference between a scan that carries a
/// wall's colour and one that carries what is written on the wall, so the tests
/// that matter are the ones that would catch it quietly going flat again.
final class PhotoTextureTests: XCTestCase {

    // MARK: - Fixtures

    /// A camera at the origin looking along +Z, in the computer-vision axes the
    /// capture bundle stores.
    private func camera(width: Int = 100, height: Int = 100) -> CameraModel.Pinhole {
        CameraModel.Pinhole(
            width: width, height: height,
            fx: Double(width), fy: Double(height),
            cx: Double(width) / 2, cy: Double(height) / 2
        )
    }

    private func viewAtOrigin(width: Int = 100, height: Int = 100)
        -> PhotoTextureBaker.SourceView {
        PhotoTextureBaker.SourceView(
            camera: camera(width: width, height: height),
            pose: Pose(
                translation: SIMD3<Float>(0, 0, 0),
                rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            )
        )
    }

    /// A triangle one metre in front of the camera, wound so its normal faces
    /// back at it.
    private let quad: [SIMD3<Float>] = [
        SIMD3(-0.4, -0.4, 1),
        SIMD3(-0.4, 0.4, 1),
        SIMD3(0.4, -0.4, 1),
    ]

    /// An image whose every pixel says where it is: red is twice the column,
    /// green twice the row. Any sample that lands in the wrong place is then a
    /// wrong number rather than a plausible colour.
    private func coordinateImage(width: Int = 100, height: Int = 100) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8(min(255, x * 2))
                pixels[i + 1] = UInt8(min(255, y * 2))
                pixels[i + 2] = 128
                pixels[i + 3] = 255
            }
        }
        return pixels
    }

    /// The texel a UV lands in, decoded with `PngTestReader` -- the same
    /// independent decoder the colour atlas tests use, so a writer bug cannot
    /// cancel against a reader bug here either.
    private func texel(_ atlas: ColorAtlas, at uv: SIMD2<Float>) throws -> (Double, Double, Double) {
        let decoded = try PngTestReader.decode(Data(atlas.texture.data))
        let x = Int((uv.x * Float(decoded.width)).rounded(.down))
        let y = Int((uv.y * Float(decoded.height)).rounded(.down))
        let offset = (y * decoded.width + x) * 3
        return (
            Double(decoded.rgb[offset]),
            Double(decoded.rgb[offset + 1]),
            Double(decoded.rgb[offset + 2])
        )
    }

    // MARK: - Layout

    func testTileSizeFollowsWorldSizeNotTriangleCount() throws {
        // Two triangles, one ten times the other. The point of the whole
        // layout is that the big one gets more texels, not the same number.
        let positions: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0.02, 0, 0), SIMD3(0, 0.02, 0),
            SIMD3(1, 0, 0), SIMD3(1.4, 0, 0), SIMD3(1, 0.4, 0),
        ]
        let layout = try XCTUnwrap(
            PhotoTextureBaker.plan(positions: positions, indices: [0, 1, 2, 3, 4, 5])
        )
        XCTAssertGreaterThan(
            layout.sizes[1], layout.sizes[0],
            "a 400 mm triangle must get a bigger tile than a 20 mm one"
        )
        for size in layout.sizes {
            XCTAssertEqual(size & (size - 1), 0, "every tile is a power of two")
            XCTAssertGreaterThanOrEqual(size, 4)
            XCTAssertLessThanOrEqual(size, 64)
        }
    }

    func testTilesNeverOverlapAndStayInsideTheAtlas() throws {
        let sizes: [Int32] = [64, 4, 32, 16, 4, 8, 64, 16, 4, 32]
        let side = 128
        let origins = try XCTUnwrap(PhotoTextureBaker.pack(sizes: sizes, side: side))

        var claimed = [Bool](repeating: false, count: side * side)
        for (triangle, origin) in origins.enumerated() {
            let size = Int(sizes[triangle])
            XCTAssertLessThanOrEqual(Int(origin.x) + size, side)
            XCTAssertLessThanOrEqual(Int(origin.y) + size, side)
            for y in 0..<size {
                for x in 0..<size {
                    let index = (Int(origin.y) + y) * side + Int(origin.x) + x
                    XCTAssertFalse(claimed[index], "tile \(triangle) overlaps another")
                    claimed[index] = true
                }
            }
        }
    }

    func testCornersLandOnTexelCentresInsideTheirOwnTile() throws {
        let layout = try XCTUnwrap(
            PhotoTextureBaker.plan(positions: quad, indices: [0, 1, 2])
        )
        let size = Float(layout.sizes[0])
        let origin = layout.origins[0]
        let side = Float(layout.side)

        for corner in 0..<3 {
            let uv = layout.cornerUvs[corner]
            let x = uv.x * side - Float(origin.x)
            let y = uv.y * side - Float(origin.y)
            // Inside the gutter on every side, and on a texel centre.
            XCTAssertGreaterThanOrEqual(x, 1)
            XCTAssertGreaterThanOrEqual(y, 1)
            XCTAssertLessThanOrEqual(x, size - 1)
            XCTAssertLessThanOrEqual(y, size - 1)
            XCTAssertEqual(x - x.rounded(.down), 0.5, accuracy: 1e-4)
            XCTAssertEqual(y - y.rounded(.down), 0.5, accuracy: 1e-4)
        }
        XCTAssertNotEqual(layout.cornerUvs[0], layout.cornerUvs[1])
        XCTAssertNotEqual(layout.cornerUvs[0], layout.cornerUvs[2])
    }

    /// A model too big for the atlas gets coarser texels everywhere rather than
    /// sharp texels on the part that happened to fit.
    func testTooMuchGeometryCoarsensRatherThanDroppingTriangles() throws {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for i in 0..<100 {
            let base = UInt32(positions.count)
            let x = Float(i) * 2
            positions += [SIMD3(x, 0, 0), SIMD3(x + 1, 0, 0), SIMD3(x, 1, 0)]
            indices += [base, base + 1, base + 2]
        }
        var options = PhotoTextureBaker.Options()
        options.maximumSide = 256

        let layout = try XCTUnwrap(
            PhotoTextureBaker.plan(positions: positions, indices: indices, options: options)
        )
        XCTAssertEqual(layout.sizes.count, 100, "every triangle still has a tile")
        XCTAssertEqual(layout.cornerUvs.count, 300)
        XCTAssertGreaterThan(
            layout.texelMetres, 0.001,
            "the target has to have been relaxed for this to fit at all"
        )
        XCTAssertLessThanOrEqual(layout.side, 256)
    }

    // MARK: - Projection

    /// The one that would catch the whole thing silently going flat: two texels
    /// inside the same triangle must carry different pixels, and each must carry
    /// the pixel that projects to it.
    func testTexelsCarryTheirOwnPixelNotTheTriangleAverage() throws {
        let layout = try XCTUnwrap(
            PhotoTextureBaker.plan(positions: quad, indices: [0, 1, 2])
        )
        let baker = PhotoTextureBaker(positions: quad, indices: [0, 1, 2], layout: layout)
        let view = viewAtOrigin()
        baker.consider(view: view, index: 0, depth: nil)
        XCTAssertEqual(baker.assignments, [0], "the only view sees the only triangle")

        baker.paint(index: 0, view: view, pixels: coordinateImage(), width: 100, height: 100)
        let atlas = try baker.finish()

        // Corner 0 is at (-0.4, -0.4, 1), which projects to pixel (10, 10):
        // red is twice the column, green twice the row.
        let first = try texel(atlas, at: layout.cornerUvs[0])
        XCTAssertEqual(first.0, 20, accuracy: 3)
        XCTAssertEqual(first.1, 20, accuracy: 3)

        // Corner 2 is at (0.4, -0.4, 1) — pixel (90, 10). Same row, far column.
        let third = try texel(atlas, at: layout.cornerUvs[2])
        XCTAssertEqual(third.0, 180, accuracy: 3)
        XCTAssertEqual(third.1, 20, accuracy: 3)

        // Corner 1 is at (-0.4, 0.4, 1) — pixel (10, 90).
        let second = try texel(atlas, at: layout.cornerUvs[1])
        XCTAssertEqual(second.0, 20, accuracy: 3)
        XCTAssertEqual(second.1, 180, accuracy: 3)
    }

    func testBackFacingTrianglesAreNotAssigned() throws {
        // The same triangle with its winding reversed faces away.
        let indices: [UInt32] = [0, 2, 1]
        let layout = try XCTUnwrap(
            PhotoTextureBaker.plan(positions: quad, indices: indices)
        )
        let baker = PhotoTextureBaker(positions: quad, indices: indices, layout: layout)
        baker.consider(view: viewAtOrigin(), index: 0, depth: nil)
        XCTAssertEqual(baker.assignments, [-1])
        XCTAssertEqual(baker.paintedTriangles, 0)
    }

    func testTrianglesBehindTheCameraAreNotAssigned() throws {
        let behind = quad.map { SIMD3<Float>($0.x, $0.y, -1) }
        let layout = try XCTUnwrap(
            PhotoTextureBaker.plan(positions: behind, indices: [0, 1, 2])
        )
        let baker = PhotoTextureBaker(positions: behind, indices: [0, 1, 2], layout: layout)
        baker.consider(view: viewAtOrigin(), index: 0, depth: nil)
        XCTAssertEqual(baker.assignments, [-1])
    }

    /// Something nearer than the surface means this frame did not see it, and
    /// painting it anyway is how a column ends up printed on the wall behind.
    func testAFrameThatCannotSeeThroughIsRejected() {
        let raster = PhotoTextureBaker.DepthRaster(
            metres: [Float](repeating: 0.3, count: 16),
            width: 4, height: 4,
            camera: CameraModel.Pinhole(width: 4, height: 4, fx: 4, fy: 4, cx: 2, cy: 2)
        )
        XCTAssertFalse(
            PhotoTextureBaker.visible(centre: SIMD3<Float>(0, 0, 1.0), in: raster),
            "a surface a metre away behind a reading at 0.3 m is occluded"
        )
        XCTAssertTrue(
            PhotoTextureBaker.visible(centre: SIMD3<Float>(0, 0, 0.32), in: raster),
            "within tolerance of the reading is the surface itself"
        )
    }

    func testNoMeasurementIsNotEvidenceOfOcclusion() {
        let raster = PhotoTextureBaker.DepthRaster(
            metres: [Float](repeating: 0, count: 16),
            width: 4, height: 4,
            camera: CameraModel.Pinhole(width: 4, height: 4, fx: 4, fy: 4, cx: 2, cy: 2)
        )
        XCTAssertTrue(PhotoTextureBaker.visible(centre: SIMD3<Float>(0, 0, 5), in: raster))
    }

    func testTheCloserMoreHeadOnFrameWins() throws {
        let layout = try XCTUnwrap(
            PhotoTextureBaker.plan(positions: quad, indices: [0, 1, 2])
        )
        let baker = PhotoTextureBaker(positions: quad, indices: [0, 1, 2], layout: layout)

        // Frame 0 is four metres back; frame 1 is at the origin, one metre off.
        let far = PhotoTextureBaker.SourceView(
            camera: camera(),
            pose: Pose(
                translation: SIMD3<Float>(0, 0, -3),
                rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            )
        )
        baker.consider(view: far, index: 0, depth: nil)
        baker.consider(view: viewAtOrigin(), index: 1, depth: nil)
        XCTAssertEqual(baker.assignments, [1])
    }

    // MARK: - Falling back

    func testUnseenTrianglesKeepTheirFusedColour() throws {
        let indices: [UInt32] = [0, 2, 1]  // facing away, so nothing sees it
        let layout = try XCTUnwrap(
            PhotoTextureBaker.plan(positions: quad, indices: indices)
        )
        let baker = PhotoTextureBaker(positions: quad, indices: indices, layout: layout)
        baker.consider(view: viewAtOrigin(), index: 0, depth: nil)
        baker.fillUnassigned(colors: [
            SIMD3<UInt8>(200, 100, 50),
            SIMD3<UInt8>(200, 100, 50),
            SIMD3<UInt8>(200, 100, 50),
        ])

        let atlas = try baker.finish()
        let colour = try texel(atlas, at: layout.cornerUvs[0])
        XCTAssertEqual(colour.0, 200)
        XCTAssertEqual(colour.1, 100)
        XCTAssertEqual(colour.2, 50)
    }

    func testTheAtlasHandsBackPerCornerCoordinates() throws {
        let layout = try XCTUnwrap(
            PhotoTextureBaker.plan(positions: quad, indices: [0, 1, 2])
        )
        let baker = PhotoTextureBaker(positions: quad, indices: [0, 1, 2], layout: layout)
        baker.consider(view: viewAtOrigin(), index: 0, depth: nil)
        baker.paint(index: 0, view: viewAtOrigin(), pixels: coordinateImage(), width: 100, height: 100)
        let atlas = try baker.finish()

        let corners = ColorAtlasBaker.polygonUvs(of: atlas, for: [0, 1, 2])
        XCTAssertEqual(corners.count, 3)
        XCTAssertEqual(corners, layout.cornerUvs)
        XCTAssertNotEqual(
            corners[0], corners[1],
            "the flat bake's one-texel-per-face rule must not have been applied"
        )
    }

    func testTheFlatBakeStillGivesOneCoordinatePerFace() throws {
        let colors = [SIMD3<UInt8>](repeating: SIMD3(10, 20, 30), count: 3)
        let atlas = try XCTUnwrap(
            ColorAtlasBaker.bake(colors: colors, indices: [0, 1, 2], vertexCount: 3)
        )
        XCTAssertNil(atlas.cornerUvs)
        let corners = ColorAtlasBaker.polygonUvs(of: atlas, for: [0, 1, 2])
        XCTAssertEqual(corners[0], corners[1])
        XCTAssertEqual(corners[1], corners[2])
    }

}
