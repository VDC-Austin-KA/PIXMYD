import ARKit
import SceneKit
import SwiftUI
import UIKit

// Locating a known point in the real world, so the capture frame and the model
// frame can be tied together.
//
// This is the step that makes everything else true. `points.json` says where a
// column mark is in the model; this says where it is in the room. Three of
// those pairs and the D1 solver has a transform.
//
// ## Why a raycast and not a fiducial
//
// The printed marker carries a QR code, and a QR code read by
// `AVCaptureMetadataOutput` gives an identity, not a pose — the corner
// geometry is not exposed and the symbol is not a calibration target. ArUco or
// AprilTag would give a pose, and neither is on the platform.
//
// So the operator aims at the mark and taps, and ARKit's scene mesh answers
// where that is. On a LiDAR device that is a direct depth measurement of the
// surface the mark is printed on, which is exactly the quantity wanted. It
// costs a deliberate act of aiming per point, and the alternative was a
// dependency plus a printing change plus a pose estimate whose error nobody
// would be able to see. The accuracy grade at the end tells the operator
// whether their aim was good enough, which is the check that actually matters.

struct MarkerAlignView: View {
    let point: NavPoint
    let bundle: StoredNavBundle
    /// Called with the observed position in the AR session's world frame,
    /// metres.
    let onRecord: (SIMD3<Double>) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var aligner = MarkerAligner()

    var body: some View {
        ZStack {
            if ARWorldTrackingConfiguration.isSupported {
                MarkerAlignContainer(aligner: aligner)
                    .ignoresSafeArea()
            } else {
                Theme.Palette.background.ignoresSafeArea()
            }

            crosshair
            overlay
        }
        .background(Theme.Palette.background)
        .onAppear { aligner.start() }
        .onDisappear { aligner.stop() }
    }

    private var crosshair: some View {
        ZStack {
            Circle()
                .strokeBorder(aligner.hasTarget ? Theme.Palette.good : Theme.Palette.textTertiary, lineWidth: 2)
                .frame(width: 44, height: 44)
            Circle()
                .fill(aligner.hasTarget ? Theme.Palette.good : Theme.Palette.textTertiary)
                .frame(width: 5, height: 5)
        }
        .allowsHitTesting(false)
    }

    private var overlay: some View {
        VStack {
            Panel(title: "Locate \(point.id)") {
                Text(point.label.isEmpty ? point.id : point.label)
                    .font(Theme.Typeface.title)
                    .foregroundStyle(Theme.Palette.text)
                if let grid = point.grid.summary {
                    Text(grid)
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Text(aligner.guidance)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Metrics.gutter)

            Spacer()

            VStack(spacing: Theme.Metrics.gutterTight) {
                if let image = bundle.file(point.viewpoint?.image),
                   let ui = UIImage(contentsOfFile: image.path) {
                    // The reference shot from Navisworks. It is the fastest way
                    // for someone to confirm they are aiming at the right
                    // column out of six identical ones.
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 140)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall)
                                .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
                        )
                }

                FieldButton(
                    title: aligner.hasTarget ? "Record this position" : "Aim at the mark",
                    systemImage: "scope",
                    role: .primary
                ) {
                    guard let observed = aligner.currentTarget else { return }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onRecord(SIMD3<Double>(Double(observed.x), Double(observed.y), Double(observed.z)))
                    dismiss()
                }
                .disabled(!aligner.hasTarget)
                .opacity(aligner.hasTarget ? 1 : 0.5)

                FieldButton(title: "Cancel", systemImage: "xmark") { dismiss() }
            }
            .padding(Theme.Metrics.gutter)
            .background(.ultraThinMaterial)
        }
    }
}

/// Aim and tap to put a mark where nothing was imported.
///
/// The same crosshair and the same raycast as `MarkerAlignView`, without the
/// point: there is no id to find and no reference photo to check against,
/// because the model has not been consulted yet. The operator picks a feature
/// they will recognise on screen later — a column corner, a door jamb, an
/// anchor bolt — and taps. What that feature is called, and where the model
/// thinks it is, is decided at the workstation.
struct PlacePointView: View {
    /// The id the next tap will get, shown so it matches what the list says.
    let nextId: String
    /// Called with the tapped position in the AR session's world frame, metres.
    let onPlace: (SIMD3<Double>) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var aligner = MarkerAligner()
    @State private var count = 0

    var body: some View {
        ZStack {
            if ARWorldTrackingConfiguration.isSupported {
                MarkerAlignContainer(aligner: aligner)
                    .ignoresSafeArea()
            } else {
                Theme.Palette.background.ignoresSafeArea()
            }

            crosshair
            overlay
        }
        .background(Theme.Palette.background)
        .onAppear { aligner.start() }
        .onDisappear { aligner.stop() }
    }

    private var crosshair: some View {
        ZStack {
            Circle()
                .strokeBorder(aligner.hasTarget ? Theme.Palette.good : Theme.Palette.textTertiary, lineWidth: 2)
                .frame(width: 44, height: 44)
            Circle()
                .fill(aligner.hasTarget ? Theme.Palette.good : Theme.Palette.textTertiary)
                .frame(width: 5, height: 5)
        }
        .allowsHitTesting(false)
    }

    private var overlay: some View {
        VStack {
            Panel(title: "Place \(currentId)") {
                Text("Aim at something you will recognise in the model — a column corner, "
                   + "a door jamb, a bolt — and tap. Place at least three, spread out and "
                   + "not in a line.")
                    .font(Theme.Typeface.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(aligner.guidance)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Metrics.gutter)

            Spacer()

            VStack(spacing: Theme.Metrics.gutterTight) {
                Text(count == 0
                     ? "Nothing placed in this session yet."
                     : "\(count) placed in this session.")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)

                FieldButton(
                    title: aligner.hasTarget ? "Place \(currentId) here" : "Aim at a surface",
                    systemImage: "mappin.and.ellipse",
                    role: .primary
                ) {
                    guard let observed = aligner.currentTarget else { return }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onPlace(SIMD3<Double>(Double(observed.x), Double(observed.y), Double(observed.z)))
                    count += 1
                }
                .disabled(!aligner.hasTarget)
                .opacity(aligner.hasTarget ? 1 : 0.5)

                FieldButton(title: "Done", systemImage: "checkmark") { dismiss() }
            }
            .padding(Theme.Metrics.gutter)
            .background(.ultraThinMaterial)
        }
    }

    /// The id for the tap about to happen: the store's next id, advanced by
    /// however many have been placed without leaving this screen.
    private var currentId: String {
        guard nextId.count > 1, nextId.hasPrefix("P"),
              let number = Int(nextId.dropFirst()) else { return nextId }
        return String(format: "P%03d", number + count)
    }
}

/// Owns the ARKit session for the alignment screen.

///
/// A session of its own rather than the capture session's: alignment happens
/// before or after a scan, never during one, and sharing would mean the
/// capture writer and this screen both driving one configuration.
@MainActor
final class MarkerAligner: ObservableObject {
    @Published private(set) var currentTarget: SIMD3<Float>?
    @Published private(set) var guidance = "Move the phone slowly so ARKit can see the surface."

    let session = ARSession()
    private var isRunning = false

    var hasTarget: Bool { currentTarget != nil }

    func start() {
        guard ARWorldTrackingConfiguration.isSupported, !isRunning else {
            if !ARWorldTrackingConfiguration.isSupported {
                guidance = "This device cannot run ARKit, so points cannot be located here."
            }
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.environmentTexturing = .none
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        session.pause()
        isRunning = false
        currentTarget = nil
    }

    /// Called from the view's display link with the raycast result under the
    /// crosshair.
    func update(target: SIMD3<Float>?, tracking: ARCamera.TrackingState) {
        currentTarget = target
        switch tracking {
        case .notAvailable:
            guidance = "ARKit is still starting."
        case let .limited(reason):
            switch reason {
            case .excessiveMotion:   guidance = "Slow down — the phone is moving too fast to track."
            case .insufficientFeatures: guidance = "Not enough texture here. Try a surface with more detail."
            case .initializing:      guidance = "Move the phone slowly so ARKit can see the surface."
            case .relocalizing:      guidance = "Re-finding the room."
            @unknown default:        guidance = "Tracking is limited."
            }
        case .normal:
            guidance = target == nil
                ? "Aim the crosshair at the mark. ARKit needs a surface it has already seen."
                : "Hold steady on the mark and record."
        }
    }
}

/// The `ARSCNView` behind the crosshair, raycasting once per frame.
private struct MarkerAlignContainer: UIViewRepresentable {
    let aligner: MarkerAligner

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = aligner.session
        view.automaticallyUpdatesLighting = true
        view.delegate = context.coordinator
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(aligner: aligner) }

    final class Coordinator: NSObject, ARSCNViewDelegate {
        let aligner: MarkerAligner
        weak var view: ARSCNView?

        init(aligner: MarkerAligner) {
            self.aligner = aligner
        }

        /// SceneKit calls this on its own render thread, and everything the
        /// sample needs -- `view.bounds`, `raycastQuery(from:)` -- is UIKit and
        /// main-thread-only. So this hop is not defensive tidying; reading a
        /// view's bounds from the render thread is the kind of race that works
        /// on a desk and tears on a phone under load.
        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            DispatchQueue.main.async { [weak self] in self?.sample() }
        }

        private func sample() {
            guard let view, let frame = view.session.currentFrame else { return }
            let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)

            // Prefer the reconstructed mesh: on a LiDAR device that is a real
            // depth measurement of the surface the mark is printed on. An
            // estimated plane is the fallback and is worth having, because a
            // column face is a plane and the estimate is usually close.
            // `ARSCNView.raycastQuery` returns an Optional -- unlike
            // `ARFrame.raycastQuery`, which does not. The two read identically
            // at the call site and differ in exactly that, which is how one
            // sweep to "fix Xcode 26's non-optional raycastQuery" unwrapped
            // both and broke this one.
            var target: SIMD3<Float>?
            for alignment in [ARRaycastQuery.TargetAlignment.any] {
                if let onGeometry = view.raycastQuery(
                    from: centre, allowing: .existingPlaneGeometry, alignment: alignment),
                   let hit = view.session.raycast(onGeometry).first {
                    target = SIMD3<Float>(hit.worldTransform.columns.3.x,
                                          hit.worldTransform.columns.3.y,
                                          hit.worldTransform.columns.3.z)
                    break
                }
                if let onEstimate = view.raycastQuery(
                    from: centre, allowing: .estimatedPlane, alignment: alignment),
                   let hit = view.session.raycast(onEstimate).first {
                    target = SIMD3<Float>(hit.worldTransform.columns.3.x,
                                          hit.worldTransform.columns.3.y,
                                          hit.worldTransform.columns.3.z)
                    break
                }
            }

            MainActor.assumeIsolated {
                aligner.update(target: target, tracking: frame.camera.trackingState)
            }
        }
    }
}
