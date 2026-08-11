import XCTest
@testable import PIXMYD

/// The artifact is the "process once" contract with the user: after the first
/// export the result lives on disk under the project, and the app must find it
/// again after a restart. These tests pin the on-disk layout and the
/// replace-mesh path that saves review edits.
final class ProcessedArtifactTests: XCTestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessedArtifactTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let projectURL {
            try? FileManager.default.removeItem(at: projectURL)
        }
    }

    private func someMesh() -> TsdfVolume.Mesh {
        TsdfVolume.Mesh(
            positions: [[0, 0, 0], [1, 0, 0], [0, 1, 0]],
            normals: [[0, 0, 1], [0, 0, 1], [0, 0, 1]],
            indices: [0, 1, 2],
            colors: nil
        )
    }

    private func someMeta() -> ProcessedMeta {
        ProcessedMeta(
            voxelSize: 0.025,
            keepFraction: 0.25,
            noiseExtentInVoxels: 3,
            integratedFrames: 64,
            scanMode: "object",
            meshVertices: 3,
            meshTriangles: 1,
            pointsCount: 0,
            processingSeconds: 42,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testSaveAndLoadRoundTrip() throws {
        let mesh = someMesh()
        let points = TsdfVolume.PointCloud(
            positions: [[0.1, 0.2, 0.3]],
            colors: [SIMD3<UInt8>(9, 8, 7)]
        )
        let meta = someMeta()

        try ProcessedArtifact.save(mesh: mesh, points: points, meta: meta, in: projectURL)

        let loaded = try ProcessedArtifact.load(in: projectURL)
        XCTAssertNotNil(loaded, "a saved result must be loadable")
        XCTAssertEqual(loaded?.mesh.positions, mesh.positions)
        XCTAssertEqual(loaded?.mesh.indices, mesh.indices)
        XCTAssertEqual(loaded?.points?.positions, points.positions)
        XCTAssertEqual(loaded?.points?.colors, points.colors)
        XCTAssertEqual(loaded?.meta, meta)
        XCTAssertTrue(loaded!.meta.matches(quality: .balanced, cleanup: .standard))
    }

    func testSaveWithoutPoints() throws {
        try ProcessedArtifact.save(mesh: someMesh(), points: nil, meta: someMeta(), in: projectURL)
        let loaded = try ProcessedArtifact.load(in: projectURL)
        XCTAssertNil(loaded?.points, "a points-less result must load without fabricating a cloud")
    }

    func testNoArtifactLoadsAsNil() throws {
        let loaded = try ProcessedArtifact.load(in: projectURL)
        XCTAssertNil(loaded, "an unprocessed project has no artifact, not a crash")
        XCTAssertNil(ProcessedArtifact.meta(in: projectURL))
    }

    func testReplaceMeshKeepsMetaAndPoints() throws {
        let points = TsdfVolume.PointCloud(positions: [[0.1, 0.2, 0.3]], colors: nil)
        try ProcessedArtifact.save(mesh: someMesh(), points: points, meta: someMeta(), in: projectURL)

        let edited = TsdfVolume.Mesh(
            positions: [[0, 0, 0], [1, 0, 0], [0, 1, 0], [1, 1, 0]],
            normals: [[0, 0, 1], [0, 0, 1], [0, 0, 1], [0, 0, 1]],
            indices: [0, 1, 2, 1, 3, 2],
            colors: nil
        )
        try ProcessedArtifact.replaceMesh(edited, in: projectURL)

        let loaded = try ProcessedArtifact.load(in: projectURL)
        XCTAssertEqual(loaded?.mesh.positions, edited.positions)
        XCTAssertEqual(loaded?.points?.positions, points.positions, "points must survive a mesh edit")
        XCTAssertEqual(loaded?.meta.voxelSize, 0.025)
        XCTAssertEqual(loaded?.meta.meshVertices, 4)
        XCTAssertEqual(loaded?.meta.meshTriangles, 2)
    }

    func testMetaMismatchInvalidatesCache() {
        var meta = someMeta()
        meta.voxelSize = 0.05
        XCTAssertFalse(meta.matches(quality: .balanced, cleanup: .standard))

        meta = someMeta()
        meta.keepFraction = 0.5
        XCTAssertFalse(meta.matches(quality: .balanced, cleanup: .standard))

        meta = someMeta()
        meta.noiseExtentInVoxels = 5
        XCTAssertFalse(meta.matches(quality: .balanced, cleanup: .standard))
    }
}