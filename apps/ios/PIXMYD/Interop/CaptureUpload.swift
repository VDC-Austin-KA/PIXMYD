import Foundation
import UIKit

// Assembling the return leg: a processed project plus a solved alignment,
// packaged as the two files `docs/contracts/capture.md` describes.
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
    static let geometryFileName = "capture.glb"

    /// Build `capture.json` + `capture.glb` for a processed project.
    ///
    /// `solved` is optional: the contract calls a capture with raw
    /// correspondences and no solution "the useful degraded mode, not an
    /// error", and a crew that could only reach two marks should still be able
    /// to send the scan home for someone to solve at a desk.
    static func package(
        project: CaptureProject,
        pointSet: NavPointSet,
        correspondences: [CaptureCorrespondence],
        solved: CaptureSolution?
    ) throws -> [String: Data] {
        guard let loaded = try ProcessedArtifact.load(in: project.url) else {
            throw CaptureUploadError.notProcessed
        }
        let mesh = loaded.mesh
        guard !mesh.positions.isEmpty, !mesh.indices.isEmpty else {
            throw CaptureUploadError.noGeometry
        }

        // Written through the existing GLB writer rather than a second one.
        // `Exporters.writeGlb` is the format code the rest of the app ships and
        // its output is what every other consumer in the suite already reads.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("capture-\(UUID().uuidString).glb")
        defer { try? FileManager.default.removeItem(at: scratch) }

        try Exporters.writeGlb(
            positions: mesh.positions,
            normals: mesh.normals,
            colors: mesh.colors,
            indices: mesh.indices,
            to: scratch
        )
        let geometry = try Data(contentsOf: scratch)

        let request = CaptureExportRequest(
            captureId: project.id,
            capturedUtc: project.capturedAt,
            device: currentDevice(),
            pointSet: pointSet,
            correspondences: correspondences,
            geometryFile: geometryFileName,
            geometryBytes: geometry.count
        )

        return [
            CaptureExport.fileName: Data(CaptureExport.render(request, solved: solved).utf8),
            geometryFileName: geometry,
        ]
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
