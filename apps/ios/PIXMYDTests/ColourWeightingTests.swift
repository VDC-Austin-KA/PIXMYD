import Foundation
import XCTest
import simd
@testable import PIXMYD

/// Colour fusion, and specifically whether a square-on look at a surface beats
/// a glancing one.
///
/// The setup is a fronto-parallel wall photographed twice with contradictory
/// colours: once head-on, once at a steep angle. Only the weighting decides
/// which colour wins, so the result is a direct read on whether view-angle
/// weighting is doing anything.
final class ColourWeightingTests: XCTestCase {

    private let width = 64
    private let height = 64
    private let fx: Double = 60
    private let fy: Double = 60

    private var camera: CameraModel.Pinhole {
        CameraModel.Pinhole(
            width: width, height: height,
            fx: fx, fy: fy,
            cx: Double(width) / 2, cy: Double(height) / 2
        )
    }

    private var identity: simd_quatf { simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }

    /// Depth of a plane `z = distance` tilted about the vertical axis by
    /// `tilt` radians, as seen from a camera at the origin looking down +Z.
    ///
    /// A tilt of 0 is fronto-parallel — every pixel the same depth. Increasing
    /// it rakes the plane away so the incidence angle grows across the frame.
    private func tiltedPlaneDepth(distance: Float, tilt: Float) -> [Float] {
        var depth = [Float](repeating: 0, count: width * height)
        let n = SIMD3<Float>(sin(tilt), 0, cos(tilt))   // plane normal
        let offset = distance * cos(tilt)               // n · p = offset

        for py in 0..<height {
            for px in 0..<width {
                let dir = simd_normalize(SIMD3<Float>(
                    (Float(px) + 0.5 - Float(width) / 2) / Float(fx),
                    (Float(py) + 0.5 - Float(height) / 2) / Float(fy),
                    1
                ))
                let denominator = simd_dot(n, dir)
                guard denominator > 1e-4 else { continue }
                let t = offset / denominator
                guard t > 0.2, t < 6 else { continue }
                depth[py * width + px] = t * dir.z      // axial, as ARKit reports
            }
        }
        return depth
    }

    /// Four channels, not three: `integrate` requires
    /// `colorWidth * colorHeight * 4` bytes and silently ignores colour
    /// otherwise, which is how the first version of this test measured nothing
    /// while appearing to pass.
    private func solidColour(_ rgb: (UInt8, UInt8, UInt8)) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4] = rgb.0
            pixels[i * 4 + 1] = rgb.1
            pixels[i * 4 + 2] = rgb.2
        }
        return pixels
    }

    private func integrate(
        into volume: TsdfVolume,
        depth: [Float],
        colour: (UInt8, UInt8, UInt8),
        pose: Pose
    ) {
        volume.integrate(
            depth: depth, confidence: nil,
            width: width, height: height,
            camera: camera, pose: pose,
            color: solidColour(colour),
            colorWidth: width, colorHeight: height,
            colorCamera: camera
        )
    }

    /// Mean colour of the extracted cloud.
    private func meanColour(_ cloud: TsdfVolume.PointCloud) -> SIMD3<Double> {
        guard let colors = cloud.colors, !colors.isEmpty else { return .zero }
        var total = SIMD3<Double>.zero
        for c in colors { total += SIMD3<Double>(Double(c.x), Double(c.y), Double(c.z)) }
        return total / Double(colors.count)
    }

    func testFaceOnColourOutweighsGlancingColour() {
        // Same wall, same distance, two irreconcilable colours. The head-on
        // view is red; the 75-degree view is blue.
        let headOn = tiltedPlaneDepth(distance: 1.0, tilt: 0)
        let oblique = tiltedPlaneDepth(distance: 1.0, tilt: 75 * .pi / 180)

        let volume = TsdfVolume(voxelSize: 0.02)
        integrate(into: volume, depth: oblique, colour: (0, 0, 255),
                  pose: Pose(translation: .zero, rotation: identity))
        integrate(into: volume, depth: headOn, colour: (255, 0, 0),
                  pose: Pose(translation: .zero, rotation: identity))

        let cloud = volume.extractPoints()
        XCTAssertNotNil(cloud.colors, "no colour was fused at all")
        let mean = meanColour(cloud)
        // Guard against the whole assertion passing on 0 vs 0, which is what
        // happened when the colour buffer was the wrong number of channels.
        XCTAssertGreaterThan(mean.x + mean.z, 1, "no colour reached the cloud")
        XCTAssertGreaterThan(
            mean.x, mean.z,
            "the glancing view won: red \(mean.x) vs blue \(mean.z)"
        )
    }

    func testTwoFaceOnViewsAverageEvenly() {
        // Both views are square-on, so neither should be preferred and the
        // result should land near the midpoint. This is the control: without
        // it, the test above would pass just as well if colour were being
        // decided by integration order.
        let depth = tiltedPlaneDepth(distance: 1.0, tilt: 0)

        let volume = TsdfVolume(voxelSize: 0.02)
        integrate(into: volume, depth: depth, colour: (255, 0, 0),
                  pose: Pose(translation: .zero, rotation: identity))
        integrate(into: volume, depth: depth, colour: (0, 0, 255),
                  pose: Pose(translation: .zero, rotation: identity))

        let cloud = volume.extractPoints()
        XCTAssertNotNil(cloud.colors, "no colour was fused at all")
        let mean = meanColour(cloud)
        XCTAssertGreaterThan(mean.x + mean.z, 1, "no colour reached the cloud")
        // Wide tolerance: the average happens in linear light and comes back
        // through sRGB, so an even blend of pure red and pure blue is not 127.
        XCTAssertEqual(mean.x, mean.z, accuracy: 40,
                       "even views did not blend evenly: \(mean.x) vs \(mean.z)")
    }

    func testAnOnlyEverObliqueSurfaceStillGetsItsColour() {
        // The failure mode a hard angle cutoff would introduce: a surface never
        // seen square-on ends up grey. Weighting must scale a contribution
        // down, never discard it.
        let oblique = tiltedPlaneDepth(distance: 1.0, tilt: 75 * .pi / 180)

        let volume = TsdfVolume(voxelSize: 0.02)
        integrate(into: volume, depth: oblique, colour: (0, 200, 0),
                  pose: Pose(translation: .zero, rotation: identity))

        let cloud = volume.extractPoints()
        XCTAssertFalse(cloud.positions.isEmpty)
        XCTAssertNotNil(cloud.colors, "an obliquely-viewed surface got no colour at all")

        let mean = meanColour(cloud)
        XCTAssertGreaterThan(mean.y, 80, "green was lost: \(mean)")
        XCTAssertGreaterThan(mean.y, mean.x)
        XCTAssertGreaterThan(mean.y, mean.z)
    }

    func testTheEffectGrowsWithTheAngle() {
        // Isolates the incidence weighting from everything else. The same pair
        // of views is fused twice, differing only in how steeply the second one
        // sees the wall. If the angle is what drives the result, the steeper
        // pair must favour the face-on colour more strongly.
        //
        // Without this, the earlier test would look identical if colour were
        // simply decided by whichever frame was integrated last.
        func redShare(obliqueTilt: Float) -> Double {
            let volume = TsdfVolume(voxelSize: 0.02)
            integrate(into: volume,
                      depth: tiltedPlaneDepth(distance: 1.0, tilt: obliqueTilt),
                      colour: (0, 0, 255),
                      pose: Pose(translation: .zero, rotation: identity))
            integrate(into: volume,
                      depth: tiltedPlaneDepth(distance: 1.0, tilt: 0),
                      colour: (255, 0, 0),
                      pose: Pose(translation: .zero, rotation: identity))
            let mean = meanColour(volume.extractPoints())
            return mean.x / max(mean.x + mean.z, 1)
        }

        let mild = redShare(obliqueTilt: 30 * .pi / 180)
        let steep = redShare(obliqueTilt: 78 * .pi / 180)

        XCTAssertGreaterThan(
            steep, mild,
            "a steeper view was not demoted more: \(steep) vs \(mild)"
        )
    }

    func testGeometryIsUnaffectedByColourWeighting() {
        // Colour weight must not leak into the SDF. If it did, an oblique view
        // would also stop contributing to the surface position, which is a far
        // worse bug than any colour artefact.
        let depth = tiltedPlaneDepth(distance: 1.0, tilt: 0)

        let withColour = TsdfVolume(voxelSize: 0.02)
        integrate(into: withColour, depth: depth, colour: (255, 0, 0),
                  pose: Pose(translation: .zero, rotation: identity))

        let withoutColour = TsdfVolume(voxelSize: 0.02)
        withoutColour.integrate(
            depth: depth, confidence: nil,
            width: width, height: height,
            camera: camera, pose: Pose(translation: .zero, rotation: identity)
        )

        XCTAssertEqual(
            withColour.extractPoints().positions.count,
            withoutColour.extractPoints().positions.count,
            "colour changed the geometry"
        )
    }
}
