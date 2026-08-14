import Foundation

/// What a processed project is made of, and the settings it was made with.
///
/// The settings matter as much as the geometry: the saved result is only a
/// shortcut while the requested settings still match. Change the detail level
/// or cleanup and the cache is deliberately ignored — a result made with the
/// wrong voxel size is not "good enough", it is the wrong deliverable.
struct ProcessedMeta: Codable, Equatable {
    var voxelSize: Double
    var keepFraction: Double?
    var noiseExtentInVoxels: Float
    var integratedFrames: Int
    var scanMode: String?
    var meshVertices: Int
    var meshTriangles: Int
    var pointsCount: Int
    var processingSeconds: Double
    var createdAt: Date

    /// True when this result was made with the exact settings being asked for.
    func matches(quality: ProcessingQuality, cleanup: ProcessingCleanup) -> Bool {
        abs(voxelSize - quality.voxelSize) < 1e-9
            && keepFraction == cleanup.keepFraction
            && noiseExtentInVoxels == cleanup.noiseExtentInVoxels
    }
}

/// The processed result of a project, persisted next to the capture so it
/// survives app restarts and is never rebuilt unless the settings change.
///
/// Stored as `<project>/processed/artifact.pixmymesh` plus `meta.json`, inside
/// the project directory so every existing rule about the directory — delete,
/// duplicate, iCloud exclusion — applies to the result without a second
/// mechanism to keep in step.
enum ProcessedArtifact {
    static let directoryName = "processed"
    static let meshFileName = "artifact.pixmymesh"
    static let metaFileName = "meta.json"

    static func directory(in project: URL) -> URL {
        project.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func meshURL(in project: URL) -> URL {
        directory(in: project).appendingPathComponent(meshFileName)
    }

    static func metaURL(in project: URL) -> URL {
        directory(in: project).appendingPathComponent(metaFileName)
    }

    /// Persist a fused result. Points are optional — a mesh-only run stores
    /// the mesh, a points-only run stores the cloud.
    static func save(
        mesh: TsdfVolume.Mesh,
        points: TsdfVolume.PointCloud?,
        meta: ProcessedMeta,
        in project: URL
    ) throws {
        let directory = directory(in: project)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try MeshArchive.encode(mesh: mesh, points: points).write(to: meshURL(in: project))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: metaURL(in: project))
    }

    /// Load the saved result, or nil when nothing has been processed yet.
    static func load(
        in project: URL
    ) throws -> (mesh: TsdfVolume.Mesh, points: TsdfVolume.PointCloud?, meta: ProcessedMeta)? {
        guard let meta = meta(in: project) else { return nil }
        let data = try Data(contentsOf: meshURL(in: project))
        let (mesh, points) = try MeshArchive.decode(data)
        return (mesh, points, meta)
    }

    static func meta(in project: URL) -> ProcessedMeta? {
        guard let data = try? Data(contentsOf: metaURL(in: project)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ProcessedMeta.self, from: data)
    }

    /// Replace the saved mesh, keeping any saved points. Used when the user
    /// saves their edits in the review viewer.
    static func replaceMesh(_ mesh: TsdfVolume.Mesh, in project: URL) throws {
        let existing = try load(in: project)
        let meta = ProcessedMeta(
            voxelSize: existing?.meta.voxelSize ?? 0,
            keepFraction: existing?.meta.keepFraction,
            noiseExtentInVoxels: existing?.meta.noiseExtentInVoxels ?? 0,
            integratedFrames: existing?.meta.integratedFrames ?? 0,
            scanMode: existing?.meta.scanMode,
            meshVertices: mesh.positions.count,
            meshTriangles: mesh.indices.count / 3,
            pointsCount: existing?.meta.pointsCount ?? 0,
            processingSeconds: existing?.meta.processingSeconds ?? 0,
            createdAt: existing?.meta.createdAt ?? Date()
        )
        try save(mesh: mesh, points: existing?.points, meta: meta, in: project)
    }
}
