import Combine
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif
import simd

/// Turns a captured bundle into a deliverable, entirely on the device.
///
/// The pipeline is: read frames → fuse depth into a TSDF → extract a surface or
/// a point cloud → write the file. It mirrors `packages/recon`, and the
/// thresholds are the same, so a capture processed on the phone and the same
/// capture processed in the studio agree.
///
/// Nothing here contacts a network. That is the point of the project: the
/// deliverable is produced by the device that captured it, and it never depends
/// on somebody else's cloud being up, in business, or willing to give it back.
@MainActor
final class ProcessingPipeline: ObservableObject {

    enum State: Equatable {
        case idle
        case running(stage: String, fraction: Double)
        /// Fusion is done and the mesh is in memory, waiting to be looked at.
        /// The file is not written until the user accepts, so an edit costs
        /// nothing and a bad scan never becomes a deliverable by accident.
        case reviewing(mesh: TsdfVolume.Mesh, summary: String)
        case finished(url: URL, summary: String)
        case failed(String)
    }

    // The presets live in Model/ProcessingPresets.swift so they can be
    // compiled and tested on Linux; this class cannot, because Combine is
    // Apple-only. Re-exported here so every call site reads unchanged.
    typealias Quality = ProcessingQuality
    typealias Cleanup = ProcessingCleanup
    @Published private(set) var state: State = .idle

    private var task: Task<Void, Never>?

    func estimatedSeconds(frameCount: Int, quality: Quality) -> Double {
        max(2, Double(frameCount) / quality.framesPerSecond)
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    func run(
        project: CaptureProject,
        format: ExportFormat,
        quality: Quality,
        cleanup: Cleanup = .standard,
        reviewFirst: Bool = false
    ) {
        task?.cancel()
        state = .running(stage: "Reading capture", fraction: 0)

        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await Self.process(
                    project: project,
                    format: format,
                    quality: quality,
                    cleanup: cleanup,
                    reviewFirst: reviewFirst
                ) { stage, fraction in
                    await MainActor.run {
                        self.state = .running(stage: stage, fraction: fraction)
                    }
                }
                await MainActor.run {
                    switch outcome {
                    case .file(let url, let summary):
                        self.state = .finished(url: url, summary: summary)
                    case .mesh(let mesh, let summary):
                        self.state = .reviewing(mesh: mesh, summary: summary)
                    }
                }
            } catch is CancellationError {
                await MainActor.run { self.state = .idle }
            } catch {
                await MainActor.run {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Write a mesh the user has just finished editing.
    ///
    /// Fusion is not repeated — the geometry on screen is exactly the geometry
    /// written, which is the entire point of reviewing before export.
    func exportReviewed(
        mesh: TsdfVolume.Mesh,
        project: CaptureProject,
        format: ExportFormat,
        quality: Quality,
        integratedFrames: Int
    ) {
        state = .running(stage: "Writing \(format.title)", fraction: 0.9)
        let url = Self.exportURL(for: project, format: format)

        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try Self.writeMesh(
                    mesh, format: format, to: url,
                    project: project, quality: quality, integrated: integratedFrames
                )
                let summary = "\(mesh.positions.count) vertices, "
                    + "\(mesh.indices.count / 3) triangles, as edited."
                await MainActor.run {
                    self.state = .finished(url: url, summary: summary)
                }
            } catch {
                await MainActor.run { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: - Work

    private enum Outcome {
        case file(URL, String)
        case mesh(TsdfVolume.Mesh, String)
    }

    /// Write an already-built mesh. Shared by the straight-to-file path and by
    /// export-after-review, so the two cannot drift into producing different
    /// files from the same geometry.
    static func writeMesh(
        _ mesh: TsdfVolume.Mesh,
        format: ExportFormat,
        to url: URL,
        project: CaptureProject,
        quality: Quality,
        integrated: Int
    ) throws {
        switch format {
        case .glb:
            try Exporters.writeGlb(
                positions: mesh.positions, normals: mesh.normals,
                colors: mesh.colors, indices: mesh.indices, to: url
            )
        case .obj:
            try Exporters.writeObj(
                positions: mesh.positions, normals: mesh.normals,
                colors: mesh.colors, indices: mesh.indices, to: url
            )
        case .html:
            // The page carries a GLB, so one is written to a scratch file and
            // read back rather than duplicating the writer.
            let glbURL = url.deletingPathExtension().appendingPathExtension("embedded.glb")
            try Exporters.writeGlb(
                positions: mesh.positions, normals: mesh.normals,
                colors: mesh.colors, indices: mesh.indices, to: glbURL
            )
            defer { try? FileManager.default.removeItem(at: glbURL) }

            try WebPageExport.write(
                glb: try Data(contentsOf: glbURL),
                name: project.name,
                capturedAt: project.capturedAt,
                facts: [
                    .init(label: "Triangles", value: "\(mesh.indices.count / 3)"),
                    .init(label: "Vertices", value: "\(mesh.positions.count)"),
                    .init(label: "Resolution", value: "\(Int(quality.voxelSize * 1000)) mm"),
                    .init(label: "Frames", value: "\(integrated)"),
                ],
                to: url
            )
        default:
            try Exporters.writeMeshPly(
                positions: mesh.positions, normals: mesh.normals,
                colors: mesh.colors, indices: mesh.indices, to: url
            )
        }
    }

    /// Where exports are put, and the filename for one.
    static func exportURL(for project: CaptureProject, format: ExportFormat) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = project.name.replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent("\(safeName).\(format.rawValue)")
    }

    private static func process(
        project: CaptureProject,
        format: ExportFormat,
        quality: Quality,
        cleanup: Cleanup,
        reviewFirst: Bool,
        progress: @escaping (String, Double) async -> Void
    ) async throws -> Outcome {

        // --- read the bundle ---
        await progress("Reading capture", 0.02)
        let manifestData = try Data(contentsOf: project.url.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(CaptureManifest.self, from: manifestData)

        let framesText = try String(
            contentsOf: project.url.appendingPathComponent("frames.jsonl"),
            encoding: .utf8
        )
        let decoder = JSONDecoder()
        var frames: [Frame] = []
        for line in framesText.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let frame = try? decoder.decode(Frame.self, from: data) else { continue }
            frames.append(frame)
        }
        guard !frames.isEmpty else { throw CaptureError.noFrames }

        // --- fuse ---
        // A scan of a valve and a scan of a warehouse bay want different depth
        // windows. Accepting a 4 m reading while scanning a fitting fuses the
        // wall behind it into the part; refusing anything past 1.5 m in a room
        // discards most of the room.
        let mode = project.scanMode ?? .room
        let volume = TsdfVolume(
            voxelSize: quality.voxelSize,
            minDepth: mode.minDepth,
            maxDepth: mode.maxDepth
        )
        var integrated = 0

        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            guard let depthRef = frame.depth, let pose = frame.pose else { continue }
            guard let depth = loadDepth(bundle: project.url, ref: depthRef) else { continue }
            let confidence = depthRef.confidenceUri.flatMap {
                loadConfidence(bundle: project.url, uri: $0, count: depth.count)
            }
            guard case .pinhole(let camera) = depthRef.camera ?? manifest.cameras.first else { continue }

            var color: [UInt8]?
            var colorCamera: CameraModel.Pinhole?
            if manifest.cameras.indices.contains(frame.camera),
               case .pinhole(let fullRes) = manifest.cameras[frame.camera],
               let pixels = loadColor(bundle: project.url, uri: frame.imageUri) {
                color = pixels
                colorCamera = fullRes
            }

            volume.integrate(
                depth: depth,
                confidence: confidence,
                width: depthRef.width,
                height: depthRef.height,
                camera: camera,
                pose: pose,
                color: color,
                colorWidth: colorCamera?.width ?? 0,
                colorHeight: colorCamera?.height ?? 0,
                colorCamera: colorCamera
            )
            integrated += 1

            if index % 5 == 0 {
                await progress("Fusing depth", 0.05 + 0.65 * Double(index) / Double(frames.count))
            }
        }

        guard integrated > 0 else {
            throw ProcessingError.noDepth(
                "This capture has no depth frames, so there is nothing to fuse. "
                    + "Photogrammetry-only reconstruction is not yet implemented on device — "
                    + "export the bundle and process it in the studio."
            )
        }

        // --- extract ---
        await progress("Extracting surface", 0.75)
        try Task.checkCancellation()

        let url = Self.exportURL(for: project, format: format)
        let summary: String

        switch format.kind {
        case .mesh:
            var mesh = volume.extractSurface()
            guard !mesh.indices.isEmpty else {
                throw ProcessingError.emptyResult(
                    "Fusion produced no surface. The capture may be too sparse, or the "
                        + "detail setting too fine for the voxels that were observed."
                )
            }

            let rawTriangles = mesh.indices.count / 3

            // Noise before decimation. Decimation spends a triangle budget on
            // whatever it is given, so cleaning up afterwards means part of the
            // budget went on representing specks faithfully.
            if cleanup.noiseExtentInVoxels > 0 {
                await progress("Removing noise", 0.8)
                try Task.checkCancellation()
                // The floor comes from the mode, not from a constant. 100 mm is
                // right for a room — buildings have no 4 cm features floating
                // unattached — and would delete the subject of an object scan.
                mesh = MeshSimplify.removeNoiseComponents(
                    mesh,
                    minimumExtent: max(
                        cleanup.noiseExtentInVoxels * Float(quality.voxelSize),
                        mode.noiseExtent()
                    )
                )
            }

            if let keep = cleanup.keepFraction {
                await progress("Simplifying mesh", 0.85)
                try Task.checkCancellation()
                mesh = MeshSimplify.simplify(
                    mesh,
                    targetTriangles: max(64, Int(Double(mesh.indices.count / 3) * keep))
                )
            }

            guard !mesh.indices.isEmpty else {
                throw ProcessingError.emptyResult(
                    "Everything fusion produced was removed as noise. Try a lower "
                        + "cleanup setting."
                )
            }

            let finalTriangles = mesh.indices.count / 3
            // Report the reduction rather than just the result. Someone judging
            // whether the cleanup setting was too harsh needs both numbers.
            let reduction = rawTriangles > finalTriangles
                ? " (down from \(rawTriangles))"
                : ""
            summary = "\(mesh.positions.count) vertices, \(finalTriangles) triangles\(reduction), "
                + "\(quality.voxelSize * 1000) mm voxels"
                + (mesh.colors == nil ? "." : ", coloured from \(integrated) frames.")

            // Hand the mesh back unwritten when the user asked to look first.
            if reviewFirst { return .mesh(mesh, summary) }

            await progress("Writing \(format.title)", 0.9)
            try writeMesh(
                mesh, format: format, to: url,
                project: project, quality: quality, integrated: integrated
            )

        case .points, .either:
            let cloud = volume.extractPoints()
            guard !cloud.positions.isEmpty else {
                throw ProcessingError.emptyResult("Fusion produced no points.")
            }
            await progress("Writing \(format.title)", 0.9)
            let positions = cloud.positions.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
            switch format {
            case .las:
                try Exporters.writeLas(
                    positions: positions, colors: cloud.colors, origin: .zero, to: url
                )
            case .e57:
                // The E57 writer lives in the shared TypeScript package and is
                // not yet ported to Swift, so on device the honest move is to
                // say so rather than quietly hand back a PLY named .e57.
                throw ProcessingError.notImplemented(
                    "E57 export runs in the studio, not on the phone. Export PLY or LAS "
                        + "here, or open the capture in the studio for E57."
                )
            default:
                try Exporters.writePointCloudPly(
                    positions: positions, colors: cloud.colors, to: url
                )
            }
            summary = "\(cloud.positions.count) points, \(quality.voxelSize * 1000) mm voxels, "
                + "fused from \(integrated) depth frames."
        }

        await progress("Done", 1)
        return .file(url, summary)
    }

    // MARK: - Loading

    private static func loadDepth(bundle: URL, ref: DepthMapRef) -> [Float]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent(ref.uri)) else {
            return nil
        }
        let count = ref.width * ref.height
        guard data.count >= count * 2 else { return nil }
        var depth = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let millimetres = raw.bindMemory(to: UInt16.self)
            for i in 0..<count {
                depth[i] = Float(UInt16(littleEndian: millimetres[i])) / 1000
            }
        }
        return depth
    }

    private static func loadConfidence(bundle: URL, uri: String, count: Int) -> [UInt8]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent(uri)),
              data.count >= count else { return nil }
        return [UInt8](data.prefix(count))
    }

    /// Decodes the frame's JPEG to top-row-first RGBA8. Colour is fused at
    /// full sensor resolution; the 256×192 depth map only decides visibility.
    private static func loadColor(bundle: URL, uri: String) -> [UInt8]? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithURL(
            bundle.appendingPathComponent(uri) as CFURL, nil
        ), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
        #else
        return nil
        #endif
    }
}

enum ProcessingError: LocalizedError {
    case noDepth(String)
    case emptyResult(String)
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .noDepth(let message), .emptyResult(let message), .notImplemented(let message):
            message
        }
    }
}
