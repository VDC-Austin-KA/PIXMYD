import Foundation
import XCTest
import simd
@testable import PIXMYD

/// A synthetic depth camera, so the fusion can be tested against geometry whose
/// answer is known exactly rather than against a recorded scan whose ground
/// truth is itself an estimate.
///
/// Depth here is *axial* — the z component of the camera-space point, which is
/// what ARKit's `sceneDepth` reports and what `TsdfVolume.integrate` expects.
/// Feeding it ray length instead produces a surface that bulges toward the
/// edges of frame, and the error is small enough to look like noise.
private struct SyntheticCamera {
    var width = 128
    var height = 128
    var fx: Float = 140
    var fy: Float = 140

    var cx: Float { Float(width) / 2 }
    var cy: Float { Float(height) / 2 }

    var model: CameraModel.Pinhole {
        CameraModel.Pinhole(
            width: width, height: height,
            fx: Double(fx), fy: Double(fy),
            cx: Double(cx), cy: Double(cy)
        )
    }

    /// Camera-space ray through the centre of a pixel, normalised.
    func ray(_ px: Int, _ py: Int) -> SIMD3<Float> {
        simd_normalize(SIMD3<Float>(
            (Float(px) + 0.5 - cx) / fx,
            (Float(py) + 0.5 - cy) / fy,
            1
        ))
    }
}

/// Camera-to-world rotation that points the optical axis (+Z) at the origin.
///
/// Built as an explicit orthonormal basis and converted with Shepperd's method,
/// which is numerically stable for every branch — the naive `w = sqrt(1+trace)/2`
/// form divides by something near zero for exactly the 180-degree cases that
/// two of the six views below need.
private func lookAtOrigin(from position: SIMD3<Float>) -> simd_quatf {
    let forward = simd_normalize(-position)
    // Any vector not parallel to forward will do for the seed; the axis choice
    // only rotates the image about its own centre, which fusion is blind to.
    let seed = abs(forward.y) > 0.9 ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(0, 1, 0)
    let right = simd_normalize(simd_cross(seed, forward))
    let down = simd_cross(forward, right)

    // Rows of the camera-to-world matrix. Its columns are the camera axes
    // expressed in world coordinates: m[row][column].
    let m00 = right.x, m01 = down.x, m02 = forward.x
    let m10 = right.y, m11 = down.y, m12 = forward.y
    let m20 = right.z, m21 = down.z, m22 = forward.z

    let trace: Float = m00 + m11 + m22
    if trace > 0 {
        let s: Float = (trace + 1).squareRoot() * 2
        return simd_quatf(ix: (m21 - m12) / s, iy: (m02 - m20) / s,
                          iz: (m10 - m01) / s, r: 0.25 * s)
    }
    if m00 > m11, m00 > m22 {
        let s: Float = (1 + m00 - m11 - m22).squareRoot() * 2
        return simd_quatf(ix: 0.25 * s, iy: (m01 + m10) / s,
                          iz: (m02 + m20) / s, r: (m21 - m12) / s)
    }
    if m11 > m22 {
        let s: Float = (1 + m11 - m00 - m22).squareRoot() * 2
        return simd_quatf(ix: (m01 + m10) / s, iy: 0.25 * s,
                          iz: (m12 + m21) / s, r: (m02 - m20) / s)
    }
    let s: Float = (1 + m22 - m00 - m11).squareRoot() * 2
    return simd_quatf(ix: (m02 + m20) / s, iy: (m12 + m21) / s,
                      iz: 0.25 * s, r: (m10 - m01) / s)
}

/// Axial depth of a sphere of radius `radius` centred on the world origin, or 0
/// where the ray misses (0 is below `minDepth` and is skipped by fusion).
private func sphereDepth(
    camera: SyntheticCamera,
    position: SIMD3<Float>,
    rotation: simd_quatf,
    radius: Float
) -> [Float] {
    var depth = [Float](repeating: 0, count: camera.width * camera.height)
    let b = simd_dot(position, position) - radius * radius

    for py in 0..<camera.height {
        for px in 0..<camera.width {
            let local = camera.ray(px, py)
            let world = rotation.act(local)
            // |position + t*world|^2 = radius^2, with world normalised.
            let half = simd_dot(position, world)
            let discriminant = half * half - b
            guard discriminant > 0 else { continue }
            let t = -half - discriminant.squareRoot()
            guard t > 0 else { continue }
            depth[py * camera.width + px] = t * local.z
        }
    }
    return depth
}

/// Six views down the coordinate axes.
private let axisViewpoints: [SIMD3<Float>] = [
    SIMD3(1.5, 0, 0), SIMD3(-1.5, 0, 0),
    SIMD3(0, 1.5, 0), SIMD3(0, -1.5, 0),
    SIMD3(0, 0, 1.5), SIMD3(0, 0, -1.5),
]

/// The axis views plus the eight cube-corner directions.
///
/// The corners are not padding. With the six axis views alone the sphere comes
/// out with roughly 700 open edges, every one of them within a few degrees of a
/// (±1, ±1, ±1) direction — the places a six-view rig sees only at 54.7 degrees
/// of incidence, where the truncation bands from the three contributing views
/// barely overlap and some cubes end up with an unobserved corner. That is the
/// rig being thin there, not the mesher failing, and it is the same reason a
/// real scan needs oblique passes and not just elevations. Adding the corner
/// stations is what closes it, on site and here.
private let fullCoverageViewpoints: [SIMD3<Float>] = axisViewpoints + {
    let d = 1.5 / Float(3).squareRoot()
    return [
        SIMD3<Float>(d, d, d), SIMD3<Float>(-d, d, d),
        SIMD3<Float>(d, -d, d), SIMD3<Float>(d, d, -d),
        SIMD3<Float>(-d, -d, d), SIMD3<Float>(-d, d, -d),
        SIMD3<Float>(d, -d, -d), SIMD3<Float>(-d, -d, -d),
    ]
}()

/// Edges used by anything other than exactly two triangles. Zero means closed
/// and manifold; anything else is a rim, a crack, or a fold.
private func openEdgeCount(_ mesh: TsdfVolume.Mesh) -> Int {
    var use: [Int64: Int] = [:]
    for i in stride(from: 0, to: mesh.indices.count, by: 3) {
        let v = [mesh.indices[i], mesh.indices[i + 1], mesh.indices[i + 2]]
        for k in 0..<3 {
            let a = min(v[k], v[(k + 1) % 3]), b = max(v[k], v[(k + 1) % 3])
            use[Int64(a) << 32 | Int64(b), default: 0] += 1
        }
    }
    return use.values.filter { $0 != 2 }.count
}

/// Signed volume via the divergence theorem. Positive means the triangles wind
/// counter-clockwise seen from outside — an inverted mesh renders black or
/// invisible in half the software that opens it, and looks fine in the other
/// half, so it is not something a screenshot catches.
private func signedVolume(_ mesh: TsdfVolume.Mesh) -> Double {
    var total = 0.0
    for i in stride(from: 0, to: mesh.indices.count, by: 3) {
        let a = SIMD3<Double>(mesh.positions[Int(mesh.indices[i])])
        let b = SIMD3<Double>(mesh.positions[Int(mesh.indices[i + 1])])
        let c = SIMD3<Double>(mesh.positions[Int(mesh.indices[i + 2])])
        let cross = SIMD3<Double>(
            b.y * c.z - b.z * c.y,
            b.z * c.x - b.x * c.z,
            b.x * c.y - b.y * c.x
        )
        total += (a.x * cross.x + a.y * cross.y + a.z * cross.z) / 6
    }
    return total
}

final class TsdfVolumeTests: XCTestCase {

    private func pose(_ position: SIMD3<Float>, _ rotation: simd_quatf) -> Pose {
        Pose(translation: position, rotation: rotation)
    }

    private func fusedSphere(
        radius: Float,
        voxelSize: Double,
        viewpoints: [SIMD3<Float>] = fullCoverageViewpoints
    ) -> TsdfVolume {
        let volume = TsdfVolume(voxelSize: voxelSize)
        let camera = SyntheticCamera()
        for position in viewpoints {
            let rotation = lookAtOrigin(from: position)
            volume.integrate(
                depth: sphereDepth(camera: camera, position: position, rotation: rotation, radius: radius),
                confidence: nil,
                width: camera.width,
                height: camera.height,
                camera: camera.model,
                pose: pose(position, rotation)
            )
        }
        return volume
    }

    // MARK: - Points

    func testFusedSpherePointsLieOnTheSphere() {
        let radius: Float = 0.5
        let cloud = fusedSphere(radius: radius, voxelSize: 0.02).extractPoints()

        XCTAssertGreaterThan(cloud.positions.count, 2000)

        var worst: Float = 0
        for p in cloud.positions {
            worst = max(worst, abs(simd_length(p) - radius))
        }
        // One voxel. The zero crossing is found by linear interpolation along a
        // grid edge, so it cannot be better than that, and if it is much worse
        // the depth convention or the pose is wrong rather than the resolution.
        XCTAssertLessThan(worst, 0.02, "surface points drift off the sphere")
    }

    func testEmptyVolumeProducesNothing() {
        let volume = TsdfVolume(voxelSize: 0.02)
        XCTAssertTrue(volume.extractPoints().positions.isEmpty)
        XCTAssertTrue(volume.extractSurface().indices.isEmpty)
        XCTAssertNil(volume.extractSurface().normals)
    }

    // MARK: - Surface

    func testFusedSphereMeshIsClosedAndWoundOutward() {
        let radius: Float = 0.5
        let mesh = fusedSphere(radius: radius, voxelSize: 0.02).extractSurface()

        XCTAssertGreaterThan(mesh.indices.count / 3, 1000)
        XCTAssertEqual(mesh.indices.count % 3, 0)
        XCTAssertEqual(mesh.normals?.count, mesh.positions.count)

        // Every edge shared by exactly two triangles: the definition of a closed
        // manifold, and what marching *tetrahedra* buys over marching cubes,
        // whose ambiguous cases leave cracks.
        let open = openEdgeCount(mesh)
        XCTAssertEqual(open, 0, "mesh has \(open) non-manifold or open edges")

        let expected = 4.0 / 3.0 * Double.pi * pow(Double(radius), 3)
        let volume = signedVolume(mesh)
        // Positive is the assertion that matters; the magnitude just confirms
        // it is the sphere and not some inside-out shell of the same surface.
        XCTAssertGreaterThan(volume, 0, "triangles wind inward")
        XCTAssertEqual(volume, expected, accuracy: expected * 0.1)

        for p in mesh.positions {
            XCTAssertEqual(Double(simd_length(p)), Double(radius), accuracy: 0.03)
        }

        // Normals point away from the centre, since the centre is inside.
        var inwardCount = 0
        for (index, n) in (mesh.normals ?? []).enumerated() {
            if simd_dot(n, simd_normalize(mesh.positions[index])) < 0 { inwardCount += 1 }
            XCTAssertEqual(simd_length(n), 1, accuracy: 1e-3)
        }
        XCTAssertEqual(inwardCount, 0, "\(inwardCount) vertex normals point inward")
    }

    func testUnobservedSpaceIsLeftOpenRatherThanCapped() {
        // A single view of a plane. Everything behind and beside it was never
        // measured, and a mesher that treats "unobserved" as "empty" will close
        // the volume off with a surface nobody scanned — an as-built with an
        // invented lid, which reads as a real measurement.
        let camera = SyntheticCamera()
        let volume = TsdfVolume(voxelSize: 0.02)
        let planeZ: Float = 1.0

        var depth = [Float](repeating: 0, count: camera.width * camera.height)
        for py in 0..<camera.height {
            for px in 0..<camera.width where px < camera.width / 2 {
                // Fronto-parallel plane: axial depth is constant across it.
                depth[py * camera.width + px] = planeZ
            }
        }

        volume.integrate(
            depth: depth, confidence: nil,
            width: camera.width, height: camera.height,
            camera: camera.model,
            pose: pose(SIMD3(0, 0, 0), simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        )

        let cloud = volume.extractPoints()
        XCTAssertFalse(cloud.positions.isEmpty)

        for p in cloud.positions {
            XCTAssertEqual(Double(p.z), Double(planeZ), accuracy: 0.03)
            // The right half of frame was never given a depth, so nothing may
            // appear there. cx is the centre; x grows to the right.
            XCTAssertLessThan(p.x, 0.02, "surface invented where nothing was measured")
        }

        // The sheet has a rim: it is a surface with a boundary, not a solid.
        // (Its signed volume is not a useful check here — the divergence
        // integral over an open sheet is the volume of the cone back to the
        // origin, which for this patch is a perfectly healthy 0.13.)
        let mesh = volume.extractSurface()
        XCTAssertGreaterThan(openEdgeCount(mesh), 0, "an unobserved region was capped")
    }

    // MARK: - Rejection rules

    func testDepthOutsideTheSensorRangeIsDiscarded() {
        let camera = SyntheticCamera()
        let volume = TsdfVolume(voxelSize: 0.02, minDepth: 0.5, maxDepth: 2.0)

        var depth = [Float](repeating: 0, count: camera.width * camera.height)
        for i in depth.indices { depth[i] = i.isMultiple(of: 2) ? 0.2 : 8.0 }

        volume.integrate(
            depth: depth, confidence: nil,
            width: camera.width, height: camera.height,
            camera: camera.model,
            pose: pose(.zero, simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        )

        // Every reading is either too near or too far. LiDAR returns both — a
        // finger over the sensor and the sky — and fusing either one drags the
        // surface with it.
        XCTAssertTrue(volume.extractPoints().positions.isEmpty)
    }

    func testLowConfidenceSamplesAreDiscarded() {
        let camera = SyntheticCamera()
        let strict = TsdfVolume(voxelSize: 0.02, minConfidence: 2)
        let lenient = TsdfVolume(voxelSize: 0.02, minConfidence: 0)

        let depth = [Float](repeating: 1.0, count: camera.width * camera.height)
        // ARKit's confidence is 0 (low), 1 (medium), 2 (high).
        let confidence = [UInt8](repeating: 1, count: camera.width * camera.height)
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

        for volume in [strict, lenient] {
            volume.integrate(
                depth: depth, confidence: confidence,
                width: camera.width, height: camera.height,
                camera: camera.model,
                pose: pose(.zero, identity)
            )
        }

        XCTAssertTrue(strict.extractPoints().positions.isEmpty)
        XCTAssertFalse(lenient.extractPoints().positions.isEmpty)
    }

    func testFinerVoxelsResolveTheSphereMoreAccurately() {
        // Not a tautology worth skipping: it is the check that the voxel size
        // actually reaches the grid rather than being stored and ignored, which
        // a refactor can quietly break while every other test still passes.
        func worstError(voxelSize: Double) -> Float {
            let cloud = fusedSphere(
                radius: 0.5, voxelSize: voxelSize, viewpoints: axisViewpoints
            ).extractPoints()
            return cloud.positions.reduce(0) { max($0, abs(simd_length($1) - 0.5)) }
        }
        XCTAssertLessThan(worstError(voxelSize: 0.01), worstError(voxelSize: 0.04))
    }
}
