import Foundation
import UIKit
import simd

// Assembling the return leg: a processed project, the points it was aligned
// to, and the mesh — packaged as the files `docs/contracts/capture.md`
// describes.
//
// The packaging is here rather than in `CaptureExport.swift` because it needs
// the mesh off disk and the device's model name, neither of which exists on
// Linux. The contract logic — the solve, the JSON, the field order — stays in
// the portable half where the tests are.
//
// Nothing in this file uploads. It produces bytes; the caller decides whether
// they go to a transfer session or to the share sheet. That split is what lets
// the same package be exported with no network at all, which the product
// promise requires and which is also simply the path that works in a basement.
//
// ## FBX, not GLB
//
// The mesh used to be a `.glb`. Navisworks does not read GLB, and appending a
// file is the only way a plugin can put geometry into an open document — so a
// scan arrived at the workstation as a file it could see and not open, and the
// plugin wrote out a matrix and told the user to transform the mesh themselves
// in some other tool. FBX is a format Navisworks reads with nothing extra
// installed, and this app already has a writer for it whose output the monorepo
// tests feed through three.js's own FBXLoader.
//
// ## Which frame the mesh is in
//
// Two cases, and the file says which:
//
// * **Aligned to a set from PIXMYD-Nav.** The model frame is known here, so the
//   solution is baked into the vertices before writing and `geometry.frame` is
//   `model`. The workstation appends it and it is already in place — no
//   transform to apply, and nothing to get wrong.
// * **Points placed on this phone.** There is no model frame yet: that is the
//   whole point. The mesh is written in the capture's own frame,
//   `geometry.frame` is `capture`, and the workstation places the matching ids
//   on the model and transforms the appended scan itself.
//
// Writing that field is not decoration. Applying the transform to a mesh that
// already carries it puts the scan exactly as far past the model as it was
// short of it, which looks like a solver bug and is not.

enum CaptureUploadError: Error, CustomStringConvertible {
    case notProcessed
    case noGeometry

    var description: String {
        switch self {
        case .notProcessed:
            return "This scan has not been processed yet. Open it in Projects and process it first."
        case .noGeometry:
            return "This scan produced no mesh, so there is nothing to place in the model."
        }
    }
}

enum CaptureUpload {
    static let geometryFileName = CaptureUploadNames.geometry

    /// Build the files for one processed project.
    ///
    /// `solved` is optional on purpose: the contract calls a capture with raw
    /// correspondences and no solution "the useful degraded mode, not an
    /// error", and a crew that could only reach two marks should still be able
    /// to send the scan home. With field points it is the normal case, not a
    /// degraded one — the workstation is where the model frame lives.
    static func package(
        project: CaptureProject,
        pointSet: NavPointSet?,
        fieldPoints: FieldPointSet?,
        correspondences: [CaptureCorrespondence],
        solved: CaptureSolution?,
        onProgress: (String) -> Void = { _ in }
    ) throws -> [String: Data] {
        guard let loaded = try ProcessedArtifact.load(in: project.url) else {
            throw CaptureUploadError.notProcessed
        }
        let mesh = loaded.mesh
        guard !mesh.positions.isEmpty, !mesh.indices.isEmpty else {
            throw CaptureUploadError.noGeometry
        }

        // Bake only when the model frame is actually known here.
        let bakeable = pointSet != nil ? solved : nil
        let frame: CaptureGeometryFrame = bakeable == nil ? .capture : .model

        onProgress(frame == .model ? "Placing the mesh…" : "Preparing the mesh…")

        var positions = mesh.positions
        var normals = mesh.normals
        if let bakeable {
            // Model world coordinates: the solution, then the point set's
            // appliedOffset — the two steps capture.md specifies, in that
            // order, done once here instead of on the far side.
            let offset = pointSet?.provenance.appliedOffset ?? [0, 0, 0]
            positions = positions.map { bake(point: $0, with: bakeable.solution, offset: offset) }
            normals = normals.map { $0.map { bake(direction: $0, with: bakeable.solution) } }
        }

        // The photographs are projected onto the *captured* geometry, because
        // that is the frame the camera poses are in. The UVs that come back are
        // per polygon corner and say nothing about position, so they are still
        // correct once the mesh has been moved into the model's frame above —
        // which is why this runs after the bake rather than before it.
        let atlas = try? ProcessingPipeline.texturedAtlas(
            mesh: mesh,
            project: project,
            quality: ProcessingQuality.matching(voxelSize: loaded.meta.voxelSize)
        ) { stage, _ in onProgress(stage + "…") }

        onProgress("Writing \(geometryFileName)…")

        // No up-axis turn, unlike the FBX this replaced. FBX declares Y as
        // its up axis, so a reader turns the geometry on the way in and the
        // writer had to pre-compensate. OBJ declares nothing: the coordinates
        // are the ones written, the plugin converts them to NWC unturned, and
        // the transform it applies is the solution as solved. One less frame
        // to get wrong, and the plugin asserts the same thing from its side.

        let scratchDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratchDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        // The stem fixes what the sidecars are called, and the plugin looks for
        // those exact names.
        let objURL = scratchDirectory.appendingPathComponent(CaptureUploadNames.geometry)
        let writtenURLs = try Exporters.writeObj(
            positions: positions,
            normals: normals,
            colors: mesh.colors,
            indices: mesh.indices,
            atlas: atlas,
            materialName: objURL.deletingPathExtension().lastPathComponent,
            to: objURL
        )
        let geometry = try Data(contentsOf: objURL)

        let request = CaptureExportRequest(
            captureId: project.id,
            capturedUtc: project.capturedAt,
            device: currentDevice(),
            pointSet: pointSet,
            fieldPoints: fieldPoints,
            correspondences: correspondences,
            geometryFile: geometryFileName,
            geometryBytes: geometry.count,
            geometryFrame: frame
        )

        var files: [String: Data] = [
            CaptureUploadNames.capture: Data(CaptureExport.render(request, solved: solved).utf8),
            geometryFileName: geometry,
        ]

        // The material and the atlas, when there is one. OBJ has no single-file
        // form that carries a texture, so all three travel or the scan arrives
        // untextured — which is the whole point of the photographic bake.
        for url in writtenURLs where url != objURL {
            if let bytes = try? Data(contentsOf: url) {
                files[url.lastPathComponent] = bytes
            }
        }

        // The points placed on this phone travel as their own contract file, in
        // the same shape PIXMYD-Nav writes and reads. A second schema for the
        // same thing would be a second parser and a second version gate.
        if let fieldPoints, !fieldPoints.isEmpty {
            files[CaptureUploadNames.fieldPoints] =
                Data(fieldPoints.renderPointsJson(sourceDocument: project.name).utf8)
        }

        onProgress("Ready to send.")
        return files
    }

    /// A point from the capture frame into model world coordinates.
    private static func bake(
        point: SIMD3<Float>,
        with solution: RigidSolution,
        offset: [Double]
    ) -> SIMD3<Float> {
        let p = SIMD3<Double>(Double(point.x), Double(point.y), Double(point.z))
        let mapped = applyTransform(
            rotation: solution.rotation,
            translation: solution.translation,
            scale: solution.scale,
            p)
        let shift = offset.count == 3
            ? SIMD3<Double>(offset[0], offset[1], offset[2])
            : SIMD3<Double>(0, 0, 0)
        let world = mapped + shift
        return SIMD3<Float>(Float(world.x), Float(world.y), Float(world.z))
    }

    /// A normal carries the rotation and nothing else — no translation, and no
    /// offset. Adding either would point every normal at the model origin.
    private static func bake(direction: SIMD3<Float>, with solution: RigidSolution) -> SIMD3<Float> {
        let n = SIMD3<Double>(Double(direction.x), Double(direction.y), Double(direction.z))
        let turned = solution.rotation.rotate(n)
        return SIMD3<Float>(Float(turned.x), Float(turned.y), Float(turned.z))
    }

    /// Write the package into a folder, for the share-sheet path.
    @discardableResult
    static func write(_ files: [String: Data], into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in files {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        return directory
    }

    /// The device string that goes into `capture.json`.
    ///
    /// `UIDevice.model` is "iPhone" for every iPhone ever made, which tells a
    /// reviewer nothing about whether the scan came off a LiDAR device. The
    /// hardware identifier does, and `hasLidar` is recorded next to it rather
    /// than inferred later from a lookup table that will be out of date.
    static func currentDevice() -> CaptureDevice {
        CaptureDevice(model: hardwareIdentifier(), hasLidar: ARSessionController.hasLiDAR)
    }

    private static func hardwareIdentifier() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return UIDevice.current.model }

        // `withUnsafeBytes` rather than the `withUnsafePointer` +
        // `withMemoryRebound(to:capacity:)` spelling every example uses: that
        // one passes `MemoryLayout.size(ofValue: info.machine)` as the
        // capacity, which reads `info.machine` inside a closure that already
        // holds it exclusively. Swift rejects the overlapping access, and the
        // buffer here carries its own count so nothing needs to ask.
        let identifier = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }
}
