import Foundation
import XCTest
import simd
@testable import PIXMYD

/// An axis-aligned box as 12 triangles, at a given place and size.
private func box(size: Float, at centre: SIMD3<Float> = .zero) -> TsdfVolume.Mesh {
    let h = size / 2
    let positions: [SIMD3<Float>] = [
        SIMD3(-h, -h, -h), SIMD3(h, -h, -h), SIMD3(h, h, -h), SIMD3(-h, h, -h),
        SIMD3(-h, -h, h), SIMD3(h, -h, h), SIMD3(h, h, h), SIMD3(-h, h, h),
    ].map { $0 + centre }
    let indices: [UInt32] = [
        0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7,
        0, 1, 5, 0, 5, 4, 2, 3, 7, 2, 7, 6,
        0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5,
    ]
    return TsdfVolume.Mesh(positions: positions, normals: nil, indices: indices, colors: nil)
}

private func combine(_ meshes: [TsdfVolume.Mesh]) -> TsdfVolume.Mesh {
    var positions: [SIMD3<Float>] = []
    var indices: [UInt32] = []
    var colors: [SIMD3<UInt8>] = []
    var anyColors = false
    for mesh in meshes {
        let base = UInt32(positions.count)
        positions += mesh.positions
        indices += mesh.indices.map { $0 + base }
        if let c = mesh.colors {
            colors += c
            anyColors = true
        } else {
            colors += Array(repeating: SIMD3<UInt8>(0, 0, 0), count: mesh.positions.count)
        }
    }
    return TsdfVolume.Mesh(
        positions: positions, normals: nil, indices: indices,
        colors: anyColors ? colors : nil
    )
}

/// A flat grid in the XY plane, so cropping has something with interior
/// triangles to cut through rather than only corners.
private func sheet(side: Int, extent: Float) -> TsdfVolume.Mesh {
    var positions: [SIMD3<Float>] = []
    for y in 0...side {
        for x in 0...side {
            positions.append(SIMD3(
                Float(x) / Float(side) * extent - extent / 2,
                Float(y) / Float(side) * extent - extent / 2,
                0
            ))
        }
    }
    var indices: [UInt32] = []
    for y in 0..<side {
        for x in 0..<side {
            let a = UInt32(y * (side + 1) + x)
            let b = a + 1
            let c = a + UInt32(side + 1)
            let d = c + 1
            indices += [a, c, b, b, c, d]
        }
    }
    return TsdfVolume.Mesh(positions: positions, normals: nil, indices: indices, colors: nil)
}

final class MeshEditingTests: XCTestCase {

    // MARK: - Bounds

    func testBoundsCoverTheGeometry() throws {
        let bounds = try XCTUnwrap(MeshEditing.bounds(of: box(size: 2, at: SIMD3(1, 2, 3))))
        XCTAssertEqual(bounds.minimum.x, 0, accuracy: 1e-6)
        XCTAssertEqual(bounds.maximum.x, 2, accuracy: 1e-6)
        XCTAssertEqual(bounds.centre.y, 2, accuracy: 1e-6)
        XCTAssertEqual(bounds.size.z, 2, accuracy: 1e-6)
    }

    func testBoundsOfAnEmptyMeshAreNil() {
        let empty = TsdfVolume.Mesh(positions: [], normals: nil, indices: [], colors: nil)
        XCTAssertNil(MeshEditing.bounds(of: empty))
    }

    // MARK: - Crop

    func testCropKeepsOnlyWhatIsInside() {
        // Two boxes 6 m apart; a crop around the first must leave the first.
        let scene = combine([box(size: 1), box(size: 1, at: SIMD3(6, 0, 0))])
        let cropped = MeshEditing.crop(
            scene,
            to: .init(minimum: SIMD3(-1, -1, -1), maximum: SIMD3(1, 1, 1))
        )

        XCTAssertEqual(cropped.indices.count / 3, 12)
        for p in cropped.positions {
            XCTAssertLessThan(p.x, 1.001)
        }
    }

    func testCropCutsWhereThePlaneWasPut() {
        // Half of a symmetric sheet, cut down the middle. Judging a triangle by
        // its centroid keeps the count at half; requiring all three vertices
        // inside would shave an extra row off the cut edge, which reads as the
        // crop being placed tighter than it was.
        let mesh = sheet(side: 20, extent: 2)
        let before = mesh.indices.count / 3

        let cropped = MeshEditing.crop(
            mesh,
            to: .init(minimum: SIMD3(0, -2, -1), maximum: SIMD3(2, 2, 1))
        )

        XCTAssertEqual(cropped.indices.count / 3, before / 2, accuracy: 0)
        for p in cropped.positions {
            XCTAssertGreaterThan(p.x, -0.06, "geometry survived well outside the crop")
        }
    }

    func testCroppingEverythingAwayGivesAnEmptyMesh() {
        let cropped = MeshEditing.crop(
            box(size: 1),
            to: .init(minimum: SIMD3(50, 50, 50), maximum: SIMD3(51, 51, 51))
        )
        XCTAssertTrue(cropped.indices.isEmpty)
        XCTAssertTrue(cropped.positions.isEmpty)
    }

    func testCropRenumbersWithoutDanglingIndices() {
        let scene = combine([box(size: 1), box(size: 1, at: SIMD3(6, 0, 0))])
        let cropped = MeshEditing.crop(
            scene,
            to: .init(minimum: SIMD3(-1, -1, -1), maximum: SIMD3(1, 1, 1))
        )
        for index in cropped.indices {
            XCTAssertLessThan(Int(index), cropped.positions.count)
        }
    }

    // MARK: - Erase

    func testEraseRemovesTheInsideAndKeepsTheRest() {
        // A person standing in front of a wall: remove them without touching it.
        let scene = combine([
            sheet(side: 10, extent: 4),
            box(size: 0.5, at: SIMD3(0, 0, 1)),
        ])
        let wallTriangles = sheet(side: 10, extent: 4).indices.count / 3

        let erased = MeshEditing.erase(
            scene,
            within: .init(minimum: SIMD3(-0.5, -0.5, 0.5), maximum: SIMD3(0.5, 0.5, 1.5))
        )

        XCTAssertEqual(erased.indices.count / 3, wallTriangles, "the wall was damaged")
        for p in erased.positions {
            XCTAssertLessThan(p.z, 0.5)
        }
    }

    func testCropAndEraseArePreciseComplements() {
        let mesh = sheet(side: 12, extent: 3)
        let bounds = MeshEditing.Bounds(
            minimum: SIMD3(-0.4, -0.4, -1), maximum: SIMD3(0.4, 0.4, 1)
        )
        let inside = MeshEditing.crop(mesh, to: bounds).indices.count / 3
        let outside = MeshEditing.erase(mesh, within: bounds).indices.count / 3
        XCTAssertEqual(inside + outside, mesh.indices.count / 3)
    }

    // MARK: - Components

    func testDeletingAComponentLeavesTheOthers() throws {
        let scene = combine([
            box(size: 2),
            box(size: 0.3, at: SIMD3(5, 0, 0)),
            box(size: 0.3, at: SIMD3(0, 5, 0)),
        ])
        XCTAssertEqual(MeshEditing.componentCount(scene), 3)

        // Tap near the speck at (5, 0, 0).
        let picked = try XCTUnwrap(
            MeshEditing.nearestVertex(in: scene, to: SIMD3(5, 0.1, 0.1))
        )
        let edited = MeshEditing.removeComponent(of: scene, containing: picked)

        XCTAssertEqual(MeshEditing.componentCount(edited), 2)
        XCTAssertEqual(edited.indices.count / 3, 24)
        for p in edited.positions {
            XCTAssertLessThan(p.x, 4, "the wrong piece survived")
        }
    }

    func testNearestVertexFindsThePiecePointedAt() throws {
        let scene = combine([box(size: 2), box(size: 0.3, at: SIMD3(5, 0, 0))])

        let nearBig = try XCTUnwrap(MeshEditing.nearestVertex(in: scene, to: SIMD3(1, 1, 1)))
        XCTAssertLessThan(simd_length(scene.positions[nearBig]), 2)

        let nearSmall = try XCTUnwrap(MeshEditing.nearestVertex(in: scene, to: SIMD3(5, 0, 0)))
        XCTAssertGreaterThan(scene.positions[nearSmall].x, 4)
    }

    func testKeepLargestDropsEverythingElse() {
        let scene = combine([
            box(size: 3),
            box(size: 0.2, at: SIMD3(7, 0, 0)),
            box(size: 0.2, at: SIMD3(0, 7, 0)),
            box(size: 0.2, at: SIMD3(0, 0, 7)),
        ])
        let kept = MeshEditing.keepLargestComponent(scene)

        XCTAssertEqual(MeshEditing.componentCount(kept), 1)
        XCTAssertEqual(kept.indices.count / 3, 12)
        XCTAssertEqual(kept.positions.count, 8)
    }

    func testKeepLargestOnASinglePieceChangesNothing() {
        let single = box(size: 1)
        let kept = MeshEditing.keepLargestComponent(single)
        XCTAssertEqual(kept.indices.count, single.indices.count)
        XCTAssertEqual(kept.positions.count, single.positions.count)
    }

    func testEditsCarryColoursThrough() {
        var scene = combine([box(size: 2), box(size: 0.3, at: SIMD3(5, 0, 0))])
        scene.colors = scene.positions.map { p in
            p.x > 4 ? SIMD3<UInt8>(255, 0, 0) : SIMD3<UInt8>(0, 0, 255)
        }

        let cropped = MeshEditing.crop(
            scene, to: .init(minimum: SIMD3(-2, -2, -2), maximum: SIMD3(2, 2, 2))
        )
        XCTAssertEqual(cropped.colors?.count, cropped.positions.count)
        // Only the blue box is left; a red vertex surviving would mean colours
        // and positions were renumbered out of step.
        for colour in cropped.colors ?? [] {
            XCTAssertEqual(colour.z, 255)
            XCTAssertEqual(colour.x, 0)
        }
    }

    func testOperationsOnAnEmptyMeshDoNotThrow() {
        let empty = TsdfVolume.Mesh(positions: [], normals: nil, indices: [], colors: nil)
        let bounds = MeshEditing.Bounds(minimum: .zero, maximum: SIMD3(1, 1, 1))

        XCTAssertTrue(MeshEditing.crop(empty, to: bounds).indices.isEmpty)
        XCTAssertTrue(MeshEditing.erase(empty, within: bounds).indices.isEmpty)
        XCTAssertTrue(MeshEditing.keepLargestComponent(empty).indices.isEmpty)
        XCTAssertEqual(MeshEditing.componentCount(empty), 0)
        XCTAssertNil(MeshEditing.nearestVertex(in: empty, to: .zero))
        XCTAssertTrue(MeshEditing.removeComponent(of: empty, containing: 0).indices.isEmpty)
    }
}
