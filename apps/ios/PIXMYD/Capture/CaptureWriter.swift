import ARKit
import CoreImage
import Foundation
import simd

/// Writes a capture bundle to disk while the scan is running.
///
/// Everything here is off the main thread and append-only. Two consequences
/// that shaped the design:
///
/// **Append-only means an interrupted capture is still a capture.** The manifest
/// is written last, but frames.jsonl, imu.jsonl and the imagery are complete up
/// to the moment of interruption. `CaptureWriter.recover` rebuilds a manifest
/// from what survived, so a force-quit costs the last frame rather than the
/// session.
///
/// **Back-pressure is real.** A 12-megapixel JPEG is ~3 MB and ARKit will happily
/// hand over frames faster than flash can absorb them. The queue is bounded; when
/// it fills, frames are dropped and counted rather than buffered into an
/// out-of-memory crash. A dropped frame is visible in the coverage readout. A
/// crash 18 minutes into a scan is not recoverable.
actor CaptureWriter {

    struct FramePayload: @unchecked Sendable {
        let timestamp: TimeInterval
        let image: CVPixelBuffer
        let intrinsics: simd_float3x3
        let imageResolution: CGSize
        let pose: Pose
        let poseWeight: Double
        let depth: ARDepthData?
        let exposure: TimeInterval
        let gnss: GnssFix?
    }

    private let root: URL
    private let imagesDirectory: URL
    private let depthDirectory: URL
    private let confidenceDirectory: URL

    private var manifest: CaptureManifest
    private var frameIndex = 0
    private var droppedFrames = 0
    private var camerasSeen: [CameraModel] = []

    private var framesHandle: FileHandle
    private var imuHandle: FileHandle
    private var gnssHandle: FileHandle

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    /// Bounded so a slow disk cannot become an out-of-memory crash.
    private let maxPendingFrames = 12
    private var pendingFrames = 0

    // MARK: - Init

    init(projectName: String, device: DeviceInfo) throws {
        let id = UUID().uuidString
        root = CaptureWriter.projectsDirectory
            .appendingPathComponent("\(id).\(BundleFormat.directoryExtension)", isDirectory: true)
        imagesDirectory = root.appendingPathComponent("images", isDirectory: true)
        depthDirectory = root.appendingPathComponent("depth", isDirectory: true)
        confidenceDirectory = root.appendingPathComponent("conf", isDirectory: true)

        let fm = FileManager.default
        for directory in [root, imagesDirectory, depthDirectory, confidenceDirectory] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        manifest = CaptureManifest(
            formatVersion: BundleFormat.version,
            id: id,
            name: projectName,
            startedAt: ISO8601DateFormatter().string(from: Date()),
            device: device,
            cameras: [],
            crs: nil,
            toProject: nil,
            frameCount: 0,
            bounds: nil,
            notes: nil
        )

        func openAppend(_ name: String) throws -> FileHandle {
            let url = root.appendingPathComponent(name)
            fm.createFile(atPath: url.path, contents: nil)
            return try FileHandle(forWritingTo: url)
        }
        framesHandle = try openAppend("frames.jsonl")
        imuHandle = try openAppend("imu.jsonl")
        gnssHandle = try openAppend("gnss.jsonl")

        // Exclude from iCloud backup. A 4 GB scan silently consuming somebody's
        // iCloud quota is a bad surprise, and the deliverable is the export.
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(resource)
    }

    static var projectsDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Appending

    /// Non-isolated entry point so the AR delegate can fire and forget.
    nonisolated func append(frame: FramePayload) {
        Task { await self.write(frame: frame) }
    }

    nonisolated func append(imu: ImuSample) {
        Task { await self.write(imu: imu) }
    }

    nonisolated func append(gnss: GnssFix) {
        Task { await self.write(gnss: gnss) }
    }

    private func write(frame payload: FramePayload) async {
        guard pendingFrames < maxPendingFrames else {
            droppedFrames += 1
            return
        }
        pendingFrames += 1
        defer { pendingFrames -= 1 }

        let id = String(format: "%06d", frameIndex)
        frameIndex += 1

        // --- camera model, de-duplicated ---
        let camera = CameraModel.pinhole(.init(
            width: Int(payload.imageResolution.width),
            height: Int(payload.imageResolution.height),
            fx: Double(payload.intrinsics[0][0]),
            fy: Double(payload.intrinsics[1][1]),
            cx: Double(payload.intrinsics[2][0]),
            cy: Double(payload.intrinsics[2][1])
            // ARKit hands back intrinsics for an already-rectified image, so
            // the distortion coefficients are genuinely zero rather than unknown.
        ))
        let cameraIndex: Int
        if let existing = camerasSeen.firstIndex(of: camera) {
            cameraIndex = existing
        } else {
            camerasSeen.append(camera)
            cameraIndex = camerasSeen.count - 1
        }

        // --- image ---
        let imageName = "images/\(id).jpg"
        writeJpeg(payload.image, to: root.appendingPathComponent(imageName))

        // --- depth ---
        var depthRef: DepthMapRef?
        if let depth = payload.depth {
            depthRef = writeDepth(depth, id: id, colorResolution: payload.imageResolution,
                                  intrinsics: payload.intrinsics)
        }

        let frame = Frame(
            id: id,
            t: payload.timestamp,
            imageUri: imageName,
            camera: cameraIndex,
            pose: payload.pose,
            poseSource: .vio,
            poseWeight: payload.poseWeight,
            depth: depthRef,
            exposure: payload.exposure,
            iso: nil,
            blur: nil,
            gnss: payload.gnss
        )
        appendLine(frame, to: framesHandle)
    }

    private func write(imu: ImuSample) { appendLine(imu, to: imuHandle) }
    private func write(gnss: GnssFix) { appendLine(gnss, to: gnssHandle) }

    private func appendLine<T: Encodable>(_ value: T, to handle: FileHandle) {
        guard var data = try? encoder.encode(value) else { return }
        data.append(0x0a)
        try? handle.write(contentsOf: data)
    }

    // MARK: - Pixel buffers

    private func writeJpeg(_ buffer: CVPixelBuffer, to url: URL) {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { return }
        // 0.92 rather than 1.0: visually lossless for photogrammetry and roughly
        // half the bytes. Feature detection is unaffected at this quality; below
        // about 0.8 it is not.
        let options: [CIImageRepresentationOption: Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92
        ]
        try? ciContext.writeJPEGRepresentation(
            of: image, to: url, colorSpace: colorSpace, options: options
        )
    }

    /// Depth as uint16 millimetres, confidence as uint8.
    ///
    /// ARKit gives float32 metres at 256x192. Stored raw that is 196 KB per
    /// frame; at 1,500 frames that is 295 MB of depth alone. Millimetre
    /// integers halve it and still resolve ten times finer than the sensor's
    /// actual precision, so nothing measurable is lost.
    private func writeDepth(
        _ depth: ARDepthData,
        id: String,
        colorResolution: CGSize,
        intrinsics: simd_float3x3
    ) -> DepthMapRef? {
        let map = depth.depthMap
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)

        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)

        var millimetres = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                let metres = row[x]
                // 65.535 m is the ceiling of the encoding; anything beyond it is
                // past the sensor's useful range anyway and is stored as zero,
                // which the reader treats as "no measurement".
                millimetres[y * width + x] =
                    (metres.isFinite && metres > 0 && metres < 65.5)
                    ? UInt16(metres * 1000) : 0
            }
        }
        let depthName = "depth/\(id).bin"
        millimetres.withUnsafeBufferPointer { pointer in
            let data = Data(buffer: pointer)
            try? data.write(to: root.appendingPathComponent(depthName))
        }

        var confidenceName: String?
        if let confidence = depth.confidenceMap {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
            if let confidenceBase = CVPixelBufferGetBaseAddress(confidence) {
                let confidenceRowBytes = CVPixelBufferGetBytesPerRow(confidence)
                var bytes = [UInt8](repeating: 0, count: width * height)
                for y in 0..<height {
                    let row = confidenceBase.advanced(by: y * confidenceRowBytes)
                        .assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width { bytes[y * width + x] = row[x] }
                }
                let name = "conf/\(id).bin"
                bytes.withUnsafeBufferPointer { pointer in
                    try? Data(buffer: pointer).write(to: root.appendingPathComponent(name))
                }
                confidenceName = name
            }
        }

        // The depth raster is smaller than the colour frame, so its intrinsics
        // are the colour intrinsics scaled. Storing them explicitly means the
        // consumer never has to infer the ratio.
        let sx = Double(width) / Double(colorResolution.width)
        let sy = Double(height) / Double(colorResolution.height)
        let depthCamera = CameraModel.pinhole(.init(
            width: width,
            height: height,
            fx: Double(intrinsics[0][0]) * sx,
            fy: Double(intrinsics[1][1]) * sy,
            cx: (Double(intrinsics[2][0]) + 0.5) * sx - 0.5,
            cy: (Double(intrinsics[2][1]) + 0.5) * sy - 0.5
        ))

        return DepthMapRef(
            uri: depthName,
            width: width,
            height: height,
            encoding: "uint16-mm",
            confidenceUri: confidenceName,
            camera: depthCamera,
            minRange: 0.15,
            maxRange: 5.0
        )
    }

    // MARK: - Finishing

    func setCrs(_ crs: CrsBlock?) { manifest.crs = crs }

    func finish() async throws -> CaptureProject {
        guard frameIndex > 0 else {
            await discard()
            throw CaptureError.noFrames
        }

        manifest.cameras = camerasSeen
        manifest.frameCount = frameIndex
        if droppedFrames > 0 {
            manifest.notes = "\(droppedFrames) frames dropped to disk back-pressure."
        }

        try? framesHandle.close()
        try? imuHandle.close()
        try? gnssHandle.close()

        let data = try encoder.encode(manifest)
        try data.write(to: root.appendingPathComponent("manifest.json"))

        return CaptureProject(
            id: manifest.id,
            name: manifest.name,
            url: root,
            capturedAt: ISO8601DateFormatter().date(from: manifest.startedAt) ?? Date(),
            frameCount: frameIndex,
            hasDepth: manifest.device.hasMetricDepth ?? false,
            state: .captured
        )
    }

    func discard() async {
        try? framesHandle.close()
        try? imuHandle.close()
        try? gnssHandle.close()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Recovery

    /// Rebuild a manifest for a bundle whose capture was interrupted.
    ///
    /// The manifest is the last thing written, so its absence is exactly the
    /// signature of a crash or a force-quit mid-scan. Everything else on disk is
    /// intact and usable — throwing the capture away because of a missing
    /// summary file would be losing a site visit to a bookkeeping detail.
    static func recover(at url: URL) throws -> CaptureProject? {
        let fm = FileManager.default
        let manifestURL = url.appendingPathComponent("manifest.json")
        guard !fm.fileExists(atPath: manifestURL.path) else { return nil }

        let framesURL = url.appendingPathComponent("frames.jsonl")
        guard let text = try? String(contentsOf: framesURL, encoding: .utf8) else { return nil }

        let decoder = JSONDecoder()
        var frames: [Frame] = []
        var cameras: [CameraModel] = []
        for line in text.split(separator: "\n") {
            // The final line of an interrupted capture is frequently truncated
            // mid-object. Skipping it is the whole point of the line format.
            guard let data = line.data(using: .utf8),
                  let frame = try? decoder.decode(Frame.self, from: data) else { continue }
            frames.append(frame)
        }
        guard !frames.isEmpty else { return nil }

        // Reconstruct the camera table from the frames that survived.
        let maxCameraIndex = frames.map(\.camera).max() ?? 0
        cameras = (0...maxCameraIndex).map { _ in
            CameraModel.pinhole(.init(width: 0, height: 0, fx: 0, fy: 0, cx: 0, cy: 0))
        }

        var manifest = CaptureManifest(
            formatVersion: BundleFormat.version,
            id: url.deletingPathExtension().lastPathComponent,
            name: "Recovered capture",
            startedAt: ISO8601DateFormatter().string(
                from: (try? fm.attributesOfItem(atPath: url.path)[.creationDate] as? Date) ?? Date()
            ),
            device: DeviceInfo(kind: "ios-lidar", model: nil, os: nil,
                               producer: "PIXMYD (recovered)", hasMetricDepth: nil,
                               gnssReceiver: nil),
            cameras: cameras,
            crs: nil,
            toProject: nil,
            frameCount: frames.count,
            bounds: nil,
            notes: "Recovered after an interrupted capture. "
                + "Camera intrinsics could not be recovered and must be re-derived."
        )
        manifest.frameCount = frames.count

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: manifestURL)

        return CaptureProject(
            id: manifest.id,
            name: manifest.name,
            url: url,
            capturedAt: Date(),
            frameCount: frames.count,
            hasDepth: true,
            state: .captured
        )
    }
}

// MARK: - Capture settings

struct CaptureSettings: Equatable, Codable {
    /// Requested image overlap, 0-1. Drives the baseline gate.
    var overlap: Double = 0.9
    /// Assumed distance to the subject, metres. With overlap this determines
    /// how far the camera must move before a frame carries new information.
    var subjectDistance: Double = 2.0
    /// Radians of rotation that force a keyframe regardless of baseline.
    var rotationThreshold: Double = 0.13 // ~7.5 degrees
    var trigger: Trigger = .automatic
    var saveVideo = false

    enum Trigger: String, Codable, CaseIterable, Identifiable {
        case automatic, manual, timed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: "Automatic"
            case .manual: "Manual"
            case .timed: "Timed"
            }
        }
        var detail: String {
            switch self {
            case .automatic: "Captures when you have moved far enough to add detail."
            case .manual: "Captures only when you tap. For deliberate, sparse coverage."
            case .timed: "Captures at a fixed interval regardless of movement."
            }
        }
    }

    /// Metres the camera must travel before the next frame is kept.
    ///
    /// A camera at distance `d` with horizontal field of view `f` sees a strip
    /// roughly `2 d tan(f/2)` wide. Requiring `overlap` between consecutive
    /// frames means moving at most `(1 - overlap)` of that width. The 60-degree
    /// figure is a reasonable stand-in for a phone's main camera; the exact
    /// value matters less than the fact that the threshold scales with distance
    /// rather than being a constant that is wrong at both ends.
    var baseline: Float {
        let halfFov = 30.0 * .pi / 180.0
        let footprint = 2 * subjectDistance * tan(halfFov)
        return Float(max(0.02, footprint * (1 - overlap)))
    }

    static let `default` = CaptureSettings()
}
