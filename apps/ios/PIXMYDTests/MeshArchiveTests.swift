import XCTest
@testable import PIXMYD

/// The archive is the storage seam of the whole "process once" workflow: if a
/// mesh does not round-trip byte-identically, the user re-fuses a scan that
/// was already fused, and the saved result stops being the result.
final class MeshArchiveTests: XCTestCase {

    private func cubeMesh() -> TsdfVolume.Mesh {
        let p: [SIMD3<Float>] = [
            [0, 0, 0], [1, 0, 0], [0, 1, 0],
            [1, 1, 0], [0, 0, 1], [1, 0, 1],
            [0, 1, 1], [1, 1, 1],
        ]
        let normals = p.map { v -> SIMD3<Float> in
            let len = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
            return len > 0 ? v / len : v
        }
        return TsdfVolume.Mesh(
            positions: p,
            normals: normals,
            indices: [0, 1, 2, 1, 3, 2, 4, 5, 6, 5, 7, 6],
            colors: p.map { SIMD3<UInt8>(UInt8($0.x * 255), 128, 64) },
            uvs: p.map { SIMD2($0.x, $0.y) },
            texture: TsdfVolume.TextureImage(
                width: 2, height: 2,
                mimeType: "image/png",
                data: [1, 2, 3, 4, 5, 6, 7, 8]
            )
        )
    }

    func testFullRoundTrip() throws {
        let mesh = cubeMesh()
        let points = TsdfVolume.PointCloud(
            positions: [[0, 0, 0], [1, 2, 3]],
            colors: [SIMD3<UInt8>(1, 2, 3), SIMD3<UInt8>(4, 5, 6)]
        )
        let data = MeshArchive.encode(mesh: mesh, points: points)
        let (decoded, decodedPoints) = try MeshArchive.decode(data)

        XCTAssertEqual(decoded.positions, mesh.positions)
        XCTAssertEqual(decoded.normals, mesh.normals)
        XCTAssertEqual(decoded.colors, mesh.colors)
        XCTAssertEqual(decoded.indices, mesh.indices)
        XCTAssertEqual(decoded.uvs, mesh.uvs)
        XCTAssertEqual(decoded.texture, mesh.texture)
        XCTAssertEqual(decodedPoints?.positions, points.positions)
        XCTAssertEqual(decodedPoints?.colors, points.colors)
    }

    func testPointsOnlyRoundTrip() throws {
        let points = TsdfVolume.PointCloud(positions: [[0, 0, 0], [0.5, -1, 2]], colors: nil)
        let data = MeshArchive.encode(
            mesh: TsdfVolume.Mesh(positions: [], normals: nil, indices: [], colors: nil),
            points: points
        )
        let (mesh, decoded) = try MeshArchive.decode(data)
        XCTAssertTrue(mesh.positions.isEmpty)
        XCTAssertEqual(decoded?.positions, points.positions)
        XCTAssertNil(decoded?.colors)
    }

    func testMinimalMeshWithoutOptionals() throws {
        let mesh = TsdfVolume.Mesh(
            positions: [[0, 0, 0], [1, 0, 0], [0, 1, 0]],
            normals: nil, indices: [0, 1, 2], colors: nil, uvs: nil, texture: nil
        )
        let data = MeshArchive.encode(mesh: mesh, points: nil)
        let (decoded, points) = try MeshArchive.decode(data)
        XCTAssertEqual(decoded.positions, mesh.positions)
        XCTAssertEqual(decoded.indices, mesh.indices)
        XCTAssertNil(decoded.normals)
        XCTAssertNil(decoded.colors)
        XCTAssertNil(decoded.uvs)
        XCTAssertNil(decoded.texture)
        XCTAssertNil(points)
    }

    func testEmptyMeshRoundTrips() throws {
        let mesh = TsdfVolume.Mesh(positions: [], normals: nil, indices: [], colors: nil)
        let data = MeshArchive.encode(mesh: mesh, points: nil)
        let (decoded, points) = try MeshArchive.decode(data)
        XCTAssertTrue(decoded.positions.isEmpty)
        XCTAssertTrue(decoded.indices.isEmpty)
        XCTAssertNil(points)
    }

    func testDeterministicOutput() {
        let mesh = cubeMesh()
        XCTAssertEqual(MeshArchive.encode(mesh: mesh, points: nil),
                       MeshArchive.encode(mesh: mesh, points: nil))
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try MeshArchive.decode(Data([1, 2, 3]))) { error in
            guard case MeshArchive.Error.badMagic = error else {
                return XCTFail("expected badMagic, got \(error)")
            }
        }
    }

    func testRejectsTruncatedData() {
        let mesh = cubeMesh()
        let data = MeshArchive.encode(mesh: mesh, points: nil)
        XCTAssertThrowsError(try MeshArchive.decode(data.dropLast(10)))
    }
}

/// Meta must match the settings it was produced under, or a saved result is
/// silently reused for the wrong detail level.
final class ProcessedMetaTests: XCTestCase {

    private func meta(voxelSize: Double = 0.025,
                      keepFraction: Double? = 0.25,
                      noise: Float = 3) -> ProcessedMeta {
        ProcessedMeta(
            voxelSize: voxelSize, keepFraction: keepFraction, noiseExtentInVoxels: noise,
            integratedFrames: 100, scanMode: "room", meshVertices: 10, meshTriangles: 16,
            pointsCount: 0, processingSeconds: 12, createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testMatchesSameSettings() {
        XCTAssertTrue(meta().matches(quality: .balanced, cleanup: .standard))
    }

    func testDoesNotMatchDifferentVoxelSize() {
        XCTAssertFalse(meta(voxelSize: 0.05).matches(quality: .balanced, cleanup: .standard))
        XCTAssertTrue(meta(voxelSize: 0.05).matches(quality: .fast, cleanup: .standard))
    }

    func testDoesNotMatchDifferentCleanup() {
        XCTAssertFalse(meta().matches(quality: .balanced, cleanup: .aggressive))
        XCTAssertFalse(meta().matches(quality: .balanced, cleanup: .none))
        XCTAssertTrue(meta(keepFraction: nil, noise: 0).matches(quality: .balanced, cleanup: .none))
    }
}
