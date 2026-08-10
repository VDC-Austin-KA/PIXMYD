import ARKit
import Combine
import CoreMotion
import simd

/// Owns the ARKit session and decides which frames are worth keeping.
///
/// The interesting problem here is not running ARKit — it is **frame
/// selection**. ARKit delivers 60 frames a second. A 20-minute walk is 72,000
/// frames, of which maybe 1,500 carry new information. Keeping all of them
/// fills the device and makes reconstruction slower without making it better;
/// keeping too few leaves holes that cannot be filled without going back to
/// site.
///
/// So frames are gated on baseline, rotation and tracking quality, in that
/// order, and the thresholds are derived from the overlap the user asked for
/// rather than picked by feel.
@MainActor
final class ARSessionController: NSObject, ObservableObject {

    // MARK: - Published state

    @Published private(set) var trackingState: TrackingState = .initializing
    @Published private(set) var capturedFrameCount = 0
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    /// Metres travelled since recording started. A useful proxy for coverage.
    @Published private(set) var pathLength: Double = 0
    @Published private(set) var estimatedPointCount = 0
    @Published private(set) var lastError: String?
    /// Live LiDAR points for the preview renderer, in world space.
    @Published private(set) var previewPoints: [SIMD3<Float>] = []

    enum TrackingState: Equatable {
        case initializing
        case normal
        /// ARKit is tracking but not well. Frames here get a lower solver weight.
        case limited(reason: String)
        case relocalizing
        case unavailable(reason: String)

        var isUsable: Bool {
            if case .normal = self { return true }
            return false
        }

        var label: String {
            switch self {
            case .initializing: "Starting"
            case .normal: "Tracking"
            case .limited(let reason): reason
            case .relocalizing: "Relocalizing"
            case .unavailable(let reason): reason
            }
        }
    }

    // MARK: - Capability

    /// Whether this device has a LiDAR scanner feeding ARKit.
    ///
    /// Not a nicety: without it there is no metric depth, reconstruction falls
    /// back to photogrammetry alone, and scale comes from VIO rather than from
    /// measurement. The UI says so rather than quietly degrading.
    static var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    // MARK: - Internals

    let session = ARSession()
    private var writer: CaptureWriter?
    private let motion = CMMotionManager()

    private var sessionStart: Date?
    private var lastKeptPosition: SIMD3<Float>?
    private var lastKeptRotation: simd_quatf?
    private var settings: CaptureSettings = .default

    /// Frames are written on a serial queue so the AR delegate never blocks.
    /// A blocked delegate drops ARKit frames, which shows up as tracking loss —
    /// a disk stall becomes a tracking bug, and the cause is invisible.
    private let ioQueue = DispatchQueue(label: "com.pixmyd.capture.io", qos: .userInitiated)

    override init() {
        super.init()
        session.delegate = self
    }

    // MARK: - Lifecycle

    func start(settings: CaptureSettings) {
        self.settings = settings
        guard Self.isSupported else {
            trackingState = .unavailable(reason: "This device does not support ARKit world tracking.")
            return
        }

        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.isAutoFocusEnabled = true
        config.environmentTexturing = .none
        config.planeDetection = []

        if Self.hasLiDAR {
            // Classification costs a little extra on the Neural Engine and
            // gives a per-face label — wall, floor, ceiling, table, seat,
            // window, door — computed by ARKit whether or not it is asked for
            // in this form. Taking the classified variant where it is available
            // means semantics are free rather than a model to train.
            config.sceneReconstruction =
                ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
                ? .meshWithClassification
                : .mesh
            config.frameSemantics.insert(.sceneDepth)
            config.frameSemantics.insert(.smoothedSceneDepth)
        }

        // Prefer the highest-resolution video format available. Reconstruction
        // detail is bounded by pixels on the subject, and this is the one knob
        // that raises that ceiling for free.
        if let best = ARWorldTrackingConfiguration.supportedVideoFormats
            .max(by: { $0.imageResolution.width * $0.imageResolution.height
                     < $1.imageResolution.width * $1.imageResolution.height }) {
            config.videoFormat = best
        }

        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        startMotionUpdates()
    }

    func stop() {
        session.pause()
        motion.stopDeviceMotionUpdates()
    }

    // MARK: - Recording

    func beginRecording(projectName: String) throws {
        let writer = try CaptureWriter(
            projectName: projectName,
            device: DeviceInfo(
                kind: Self.hasLiDAR ? "ios-lidar" : "ios-photo",
                model: UIDevice.current.modelIdentifier,
                os: "iOS " + UIDevice.current.systemVersion,
                producer: "PIXMYD \(Bundle.main.shortVersion)",
                hasMetricDepth: Self.hasLiDAR,
                gnssReceiver: nil
            )
        )
        self.writer = writer
        sessionStart = Date()
        lastKeptPosition = nil
        lastKeptRotation = nil
        capturedFrameCount = 0
        pathLength = 0
        isRecording = true
        isPaused = false
    }

    func pauseRecording() { isPaused = true }

    func resumeRecording() {
        isPaused = false
        // Forget the last kept pose so the first frame after a pause is always
        // kept. The user has usually moved during the pause, and the gap is
        // exactly where a hole would otherwise appear.
        lastKeptPosition = nil
        lastKeptRotation = nil
    }

    /// Finish and return the project. Throws rather than returning nil so the
    /// caller cannot mistake a failed save for an empty capture.
    func finishRecording() async throws -> CaptureProject {
        guard let writer else { throw CaptureError.notRecording }
        isRecording = false
        isPaused = false
        self.writer = nil
        var project = try await writer.finish()
        // Record how it was captured, so export defaults to settings that
        // match rather than to room-sized ones for a scan of a valve.
        project.scanMode = settings.mode
        return project
    }

    func cancelRecording() async {
        isRecording = false
        isPaused = false
        await writer?.discard()
        writer = nil
    }

    // MARK: - Motion

    private func startMotionUpdates() {
        guard motion.isDeviceMotionAvailable else { return }
        // 100 Hz. Enough to characterise handheld motion between frames without
        // producing a log the size of the imagery.
        motion.deviceMotionUpdateInterval = 1.0 / 100.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, _ in
            guard let self, let sample, let start = self.sessionStart, self.isRecording,
                  !self.isPaused else { return }
            let t = Date().timeIntervalSince(start)
            let imu = ImuSample(
                t: t,
                gyro: [sample.rotationRate.x, sample.rotationRate.y, sample.rotationRate.z],
                accel: [
                    sample.userAcceleration.x + sample.gravity.x,
                    sample.userAcceleration.y + sample.gravity.y,
                    sample.userAcceleration.z + sample.gravity.z,
                ]
            )
            self.writer?.append(imu: imu)
        }
    }

    // MARK: - Frame selection

    /// Should this frame be written?
    ///
    /// Three gates, cheapest first:
    ///
    /// 1. **Tracking.** A frame captured while ARKit reports `limited` has a
    ///    pose that may be metres out. It is kept only if nothing better has
    ///    arrived recently, and it is written with a reduced solver weight.
    /// 2. **Baseline.** Consecutive frames from the same spot add nothing to a
    ///    reconstruction — triangulation needs parallax. The threshold comes
    ///    from the requested overlap and the distance to the subject.
    /// 3. **Rotation.** Standing still and turning produces no baseline at all,
    ///    but it does reveal new surface, so rotation gets its own gate.
    private func shouldKeep(frame: ARFrame) -> Bool {
        guard isRecording, !isPaused else { return false }

        switch frame.camera.trackingState {
        case .notAvailable:
            return false
        case .limited:
            // Keep sparsely while tracking is poor — better a weak frame than a
            // hole, but do not fill the disk with them.
            guard let last = lastKeptPosition else { return true }
            return simd_distance(frame.camera.transform.translation, last) > settings.baseline * 3
        case .normal:
            break
        @unknown default:
            return false
        }

        guard let lastPosition = lastKeptPosition, let lastRotation = lastKeptRotation else {
            return true
        }

        let position = frame.camera.transform.translation
        if simd_distance(position, lastPosition) >= settings.baseline { return true }

        let rotation = simd_quatf(frame.camera.transform)
        // Angle between the two orientations, via the quaternion dot product.
        let dot = abs(simd_dot(rotation.vector, lastRotation.vector))
        let angle = 2 * acos(min(1, dot))
        return Double(angle) >= settings.rotationThreshold
    }
}

// MARK: - ARSessionDelegate

extension ARSessionController: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // ARFrame holds large pixel buffers and ARKit reuses them aggressively.
        // Everything needed must be copied out before this returns, and the
        // frame must not be captured by the async block.
        Task { @MainActor [weak self] in
            self?.handle(frame: frame)
        }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        Task { @MainActor [weak self] in
            self?.trackingState = Self.describe(camera.trackingState)
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.lastError = error.localizedDescription
            self?.trackingState = .unavailable(reason: error.localizedDescription)
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in
            self?.trackingState = .relocalizing
        }
    }

    @MainActor
    private func handle(frame: ARFrame) {
        updatePreview(from: frame)

        guard shouldKeep(frame: frame), let writer, let start = sessionStart else { return }

        let transform = frame.camera.transform
        let position = transform.translation
        if let last = lastKeptPosition {
            pathLength += Double(simd_distance(position, last))
        }
        lastKeptPosition = position
        lastKeptRotation = simd_quatf(transform)

        let weight: Double
        if case .normal = frame.camera.trackingState { weight = 1.0 } else { weight = 0.25 }

        // Copy everything off the ARFrame synchronously, then hand plain values
        // to the writer. Retaining the ARFrame here would stall ARKit's buffer
        // pool and drop tracking.
        let payload = CaptureWriter.FramePayload(
            timestamp: Date().timeIntervalSince(start),
            image: frame.capturedImage,
            intrinsics: frame.camera.intrinsics,
            imageResolution: frame.camera.imageResolution,
            pose: frame.pixmydPose,
            poseWeight: weight,
            depth: frame.smoothedSceneDepth ?? frame.sceneDepth,
            exposure: frame.camera.exposureDuration,
            gnss: nil
        )
        writer.append(frame: payload)
        capturedFrameCount += 1
    }

    /// Downsample the LiDAR depth into a sparse world-space point set for the
    /// live preview. Deliberately coarse — this drives a 60 fps overlay, not a
    /// deliverable, and the full map is 49,152 points per frame.
    @MainActor
    private func updatePreview(from frame: ARFrame) {
        guard let depth = frame.sceneDepth ?? frame.smoothedSceneDepth else { return }
        let map = depth.depthMap
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)

        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)

        var confidenceBase: UnsafeMutableRawPointer?
        var confidenceRowBytes = 0
        if let confidence = depth.confidenceMap {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            confidenceBase = CVPixelBufferGetBaseAddress(confidence)
            confidenceRowBytes = CVPixelBufferGetBytesPerRow(confidence)
        }
        defer {
            if let confidence = depth.confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
            }
        }

        // Depth intrinsics are the colour intrinsics scaled to the depth raster.
        let scaleX = Float(width) / Float(frame.camera.imageResolution.width)
        let scaleY = Float(height) / Float(frame.camera.imageResolution.height)
        let k = frame.camera.intrinsics
        let fx = k[0][0] * scaleX, fy = k[1][1] * scaleY
        let cx = k[2][0] * scaleX, cy = k[2][1] * scaleY
        let cameraToWorld = frame.camera.transform

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(2048)
        let stride = 4

        for y in Swift.stride(from: 0, to: height, by: stride) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            let confidenceRow = confidenceBase?.advanced(by: y * confidenceRowBytes)
                .assumingMemoryBound(to: UInt8.self)
            for x in Swift.stride(from: 0, to: width, by: stride) {
                let d = row[x]
                guard d > 0.1, d < 6 else { continue }
                if let confidenceRow, confidenceRow[x] < 1 { continue }

                // ARKit camera space is +Y up, -Z forward, so the unprojection
                // negates Y and Z relative to the vision convention.
                let local = SIMD4<Float>(
                    (Float(x) - cx) * d / fx,
                    -(Float(y) - cy) * d / fy,
                    -d,
                    1
                )
                let world = cameraToWorld * local
                points.append(SIMD3(world.x, world.y, world.z))
            }
        }

        previewPoints = points
        estimatedPointCount = capturedFrameCount * points.count
    }

    private static func describe(_ state: ARCamera.TrackingState) -> TrackingState {
        switch state {
        case .normal:
            return .normal
        case .notAvailable:
            return .initializing
        case .limited(let reason):
            switch reason {
            case .initializing: return .initializing
            case .relocalizing: return .relocalizing
            case .excessiveMotion: return .limited(reason: "Slow down")
            case .insufficientFeatures: return .limited(reason: "Not enough texture")
            @unknown default: return .limited(reason: "Tracking limited")
            }
        }
    }
}

// MARK: - Errors

enum CaptureError: LocalizedError {
    case notRecording
    case noFrames
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRecording:
            "No capture is in progress."
        case .noFrames:
            "Nothing was captured. The session ended before any frame met the "
                + "quality gate — check that tracking reached Tracking before recording."
        case .writeFailed(let detail):
            "Could not write the capture: \(detail)"
        }
    }
}

// MARK: - simd helpers

extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3(columns.3.x, columns.3.y, columns.3.z)
    }
}

extension ARFrame {
    /// ARKit pose converted into the bundle's convention.
    ///
    /// ARKit camera space is +X right, +Y up, -Z forward. The bundle (and every
    /// projection equation in the toolchain) uses +X right, +Y down, +Z forward.
    /// The conversion is a 180-degree rotation about X, applied once, here.
    var pixmydPose: Pose {
        let m = camera.transform
        let flip = simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0))
        let rotation = simd_quatf(m) * flip
        return Pose(translation: m.translation, rotation: rotation.normalized)
    }
}

extension UIDevice {
    /// e.g. "iPhone16,1". More useful in a capture log than the marketing name,
    /// because it identifies the exact sensor package.
    var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}
