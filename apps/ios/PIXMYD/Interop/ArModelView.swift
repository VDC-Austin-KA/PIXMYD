import ARKit
@preconcurrency import SceneKit
import SwiftUI
import UIKit

// Standing inside the model.
//
// `ar-model.json` has always said where the model is and what it looks like
// from one viewpoint. This is the screen that draws it over the room, which is
// the thing the whole AR half of the contract was for.
//
// ## The procedure
//
// Anchoring, not scanning. The operator picks a point that PIXMYD-Nav already
// placed on the model -- a column corner, a door jamb, a bolt -- aims at the
// real one, and taps. The model appears immediately, on one anchor. A second
// anchor gives it a heading. A third and a fourth make the heading better. At
// no stage does the screen refuse to draw something, because a model that is
// roughly right and visibly there is the common case and it is worth a great
// deal; a model that will not appear until three taps are perfect is worth
// nothing at all.
//
// Every anchor can be replaced or cleared afterwards, and the fit re-solves as
// it happens. That is the whole interaction: aim, tap, look, fix the one that
// is wrong. Nobody gets three taps right the first time in a room where the
// column you meant is one of six identical ones.
//
// On top of the fit there is a manual nudge -- drag to slide, twist to turn,
// a stepper for height -- and it is deliberately kept out of the numbers. The
// residuals below the model always describe the *fit*, never the nudge, so
// dragging the model until it looks right cannot make the accuracy readout
// agree with you.

struct ArModelView: View {
    let bundle: StoredNavBundle
    let ar: NavArBundle

    @Environment(\.dismiss) private var dismiss
    @StateObject private var aligner = MarkerAligner()

    @State private var anchors: [ArAnchor] = []
    @State private var selected: String?
    /// The operator's own adjustment, kept apart from the solve.
    @State private var nudgeYaw: Double = 0
    @State private var nudgeOffset = SIMD3<Double>(repeating: 0)
    @State private var model: GlbMesh?
    @State private var loadError: String?
    @State private var showDetail = true

    /// Points from the set in this bundle, in the AR model's own frame.
    ///
    /// Empty when the bundle carries no `points.json` — which the plugin's AR
    /// export does not write. That is a supported state: with no ids to anchor
    /// to, a single tap still drops the model's origin where the operator is
    /// standing, which is the "just show me roughly where it is" case.
    private var candidates: [(point: NavPoint, model: SIMD3<Double>)] {
        guard let set = bundle.pointSet, !set.isCaptureFrame else { return [] }
        return set.points.map { ($0, ar.modelFrame(of: $0, in: set)) }
    }

    private var placement: ArPlacement? {
        ArPlacement.solve(anchors: anchors, headingHint: 0)?
            .nudged(yaw: nudgeYaw, by: nudgeOffset)
    }

    var body: some View {
        ZStack {
            if ARWorldTrackingConfiguration.isSupported {
                ArModelContainer(
                    aligner: aligner,
                    mesh: model,
                    placement: placement,
                    anchors: anchors,
                    onNudgeYaw: { nudgeYaw += $0 },
                    onNudgeMove: { nudgeOffset += $0 }
                )
                .ignoresSafeArea()
            } else {
                Theme.Palette.background.ignoresSafeArea()
            }

            crosshair
            overlay
        }
        .background(Theme.Palette.background)
        .onAppear {
            aligner.start()
            loadModel()
            if selected == nil { selected = candidates.first?.point.id }
        }
        .onDisappear { aligner.stop() }
    }

    // MARK: - Loading

    private func loadModel() {
        guard model == nil else { return }
        guard let file = ar.geometry?.file, let url = bundle.file(file) else {
            loadError = "This bundle carries no model geometry, so there is nothing to draw. "
                      + "Re-export it from PIXMYD-Nav with \"Include model geometry\" ticked."
            return
        }
        // Off the main thread: a whole-floor mesh is tens of megabytes and
        // parsing it under the AR session's frame callback would drop the
        // camera feed to a slideshow. The detached task is handed a URL and
        // gives back plain values, so nothing view-shaped crosses the boundary.
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> (GlbMesh?, String?) in
                do {
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    return (try GlbReader.read(data), nil)
                } catch {
                    return (nil, "\(error)")
                }
            }.value
            model = outcome.0
            loadError = outcome.1
        }
    }

    // MARK: - Chrome

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
        VStack(spacing: 0) {
            if showDetail { status.padding(Theme.Metrics.gutter) }
            Spacer()
            controls
        }
    }

    private var status: some View {
        Panel(title: ar.name.isEmpty ? "Model" : ar.name) {
            if let loadError {
                Text(loadError)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.caution)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model == nil {
                ProgressView("Reading the model…").tint(Theme.Palette.accent)
            }

            if let fit = ArPlacement.solve(anchors: anchors) {
                HStack(spacing: Theme.Metrics.gutter) {
                    Readout(label: "Anchors", value: "\(anchors.count)")
                    Readout(
                        label: "RMS",
                        value: String(format: "%.0f", fit.rmsError * 1000),
                        unit: "mm",
                        tone: anchors.count < 2 ? .neutral : (fit.rmsError < 0.05 ? .good : .caution)
                    )
                    Readout(
                        label: "Worst",
                        value: String(format: "%.0f", fit.maxError * 1000),
                        unit: "mm",
                        tone: anchors.count < 2 ? .neutral : (fit.maxError < 0.1 ? .good : .caution)
                    )
                }
            }

            Text(guidance)
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One line saying what to do next, which is the only thing anyone reads
    /// while holding a phone up at a wall.
    private var guidance: String {
        if candidates.isEmpty && anchors.isEmpty {
            return "No point set came with this model, so there are no ids to anchor to. "
                 + "Tap once to drop the model's origin where you are aiming, then drag and "
                 + "twist it into place."
        }
        switch anchors.count {
        case 0:  return "Pick a point below, aim at the real one, and tap. The model appears "
                      + "on the first anchor."
        case 1:  return "Placed. The model is pinned but its heading is a guess — anchor a "
                      + "second point, well away from the first, to turn it the right way."
        case 2:  return "Turned. A third anchor, away from the line between these two, is what "
                      + "makes the heading trustworthy rather than merely plausible."
        default: return anchorAdvice
        }
    }

    private var anchorAdvice: String {
        guard let fit = ArPlacement.solve(anchors: anchors) else { return "" }
        if fit.maxError > 0.25, let worst = fit.residuals.max(by: { $0.value < $1.value })?.key {
            return "\(worst) is \(Int(fit.maxError * 1000)) mm from where the fit puts it. "
                 + "Either it was tapped on the wrong feature, or the model is wrong there. "
                 + "Long-press it below to place it again."
        }
        return "Good fit. Drag to slide, twist to turn, and use the arrows for height if the "
             + "model still needs coaxing — the numbers above stay honest either way."
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: Theme.Metrics.gutterTight) {
            if !candidates.isEmpty { pointStrip }

            HStack(spacing: Theme.Metrics.gutterTight) {
                FieldButton(
                    title: placeTitle,
                    systemImage: "mappin.and.ellipse",
                    role: .primary
                ) { place() }
                .disabled(!aligner.hasTarget)
                .opacity(aligner.hasTarget ? 1 : 0.5)

                FieldButton(title: "Undo", systemImage: "arrow.uturn.backward") {
                    // Newest first: undo means "not that one", and the one they
                    // mean is always the one they just did.
                    if !anchors.isEmpty { anchors.removeLast() }
                }
                .disabled(anchors.isEmpty)
                .opacity(anchors.isEmpty ? 0.5 : 1)
            }

            HStack(spacing: Theme.Metrics.gutterTight) {
                FieldButton(title: "Down", systemImage: "arrow.down") {
                    nudgeOffset.y -= 0.05
                }
                FieldButton(title: "Up", systemImage: "arrow.up") {
                    nudgeOffset.y += 0.05
                }
                FieldButton(title: "Reset", systemImage: "arrow.counterclockwise", role: .destructive) {
                    anchors.removeAll()
                    nudgeYaw = 0
                    nudgeOffset = SIMD3<Double>(repeating: 0)
                }
                FieldButton(title: showDetail ? "Hide" : "Show", systemImage: "text.bubble") {
                    showDetail.toggle()
                }
            }

            FieldButton(title: "Done", systemImage: "checkmark") { dismiss() }
        }
        .padding(Theme.Metrics.gutter)
        .background(.ultraThinMaterial)
    }

    private var placeTitle: String {
        guard let id = selected else { return "Drop the model here" }
        let already = anchors.contains(where: { $0.pointId == id })
        return already ? "Replace \(id)" : "Place \(id)"
    }

    /// The ids, with the placed ones marked. Long-press clears one; tapping
    /// selects it, and placing again replaces it in place.
    private var pointStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(candidates, id: \.point.id) { candidate in
                    let id = candidate.point.id
                    let placed = anchors.contains(where: { $0.pointId == id })
                    Button {
                        selected = id
                    } label: {
                        VStack(spacing: 2) {
                            Text(id)
                                .font(Theme.Typeface.label(14, weight: .semibold))
                            Text(placed ? "placed" : "—")
                                .font(Theme.Typeface.caption)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundStyle(selected == id ? Theme.Palette.background : Theme.Palette.text)
                        .background(
                            selected == id
                                ? Theme.Palette.accent
                                : (placed ? Theme.Palette.good.opacity(0.25) : Theme.Palette.surfaceRaised),
                            in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if placed {
                            Button("Clear \(id)", role: .destructive) {
                                anchors.removeAll { $0.pointId == id }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Metrics.gutter)
        }
    }

    // MARK: - Placing

    private func place() {
        guard let target = aligner.currentTarget else { return }
        let world = SIMD3<Double>(Double(target.x), Double(target.y), Double(target.z))
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        guard let id = selected,
              let candidate = candidates.first(where: { $0.point.id == id }) else {
            // No point set: one anchor at the model's own origin, which the
            // operator then drags. Replacing rather than appending, because a
            // second tap here means "no, there" and not "another anchor".
            anchors = [ArAnchor(pointId: "origin", model: SIMD3<Double>(repeating: 0), world: world)]
            return
        }

        let anchor = ArAnchor(pointId: id, model: candidate.model, world: world)
        if let existing = anchors.firstIndex(where: { $0.pointId == id }) {
            anchors[existing] = anchor
        } else {
            anchors.append(anchor)
        }
        // Move the selection along so the common case — anchor three points in
        // a row — is three taps and no fiddling with the strip in between.
        let unplaced = candidates.first { candidate in
            !anchors.contains(where: { $0.pointId == candidate.point.id })
        }
        if let next = unplaced {
            selected = next.point.id
        }
    }
}

// MARK: - The AR view

/// The `ARSCNView` with the model in it.
///
/// Rebuilding the SceneKit geometry every time the placement changes would
/// re-upload a multi-megabyte mesh to the GPU on every frame of a drag. So the
/// geometry is built once when the mesh arrives and only the node's transform
/// is written afterwards, which is what a transform is for.
private struct ArModelContainer: UIViewRepresentable {
    let aligner: MarkerAligner
    let mesh: GlbMesh?
    let placement: ArPlacement?
    let anchors: [ArAnchor]
    let onNudgeYaw: (Double) -> Void
    let onNudgeMove: (SIMD3<Double>) -> Void

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = aligner.session
        view.automaticallyUpdatesLighting = true
        view.delegate = context.coordinator
        view.scene.rootNode.addChildNode(context.coordinator.root)
        context.coordinator.view = view

        let pan = UIPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.onPan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(UIRotationGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.onRotate(_:))))
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        context.coordinator.onNudgeYaw = onNudgeYaw
        context.coordinator.onNudgeMove = onNudgeMove
        context.coordinator.apply(mesh: mesh, placement: placement, anchors: anchors)
    }

    func makeCoordinator() -> Coordinator { Coordinator(aligner: aligner) }

    final class Coordinator: NSObject, ARSCNViewDelegate {
        let aligner: MarkerAligner
        weak var view: ARSCNView?

        let root = SCNNode()
        private let modelNode = SCNNode()
        private let anchorNode = SCNNode()
        private var builtTriangles = -1
        private var lastAnchorKey = ""

        var onNudgeYaw: (Double) -> Void = { _ in }
        var onNudgeMove: (SIMD3<Double>) -> Void = { _ in }

        private var panAnchor = CGPoint.zero

        init(aligner: MarkerAligner) {
            self.aligner = aligner
            super.init()
            root.addChildNode(modelNode)
            root.addChildNode(anchorNode)
            modelNode.isHidden = true
        }

        // MARK: Scene

        @MainActor
        func apply(mesh: GlbMesh?, placement: ArPlacement?, anchors: [ArAnchor]) {
            if let mesh, mesh.triangleCount != builtTriangles {
                builtTriangles = mesh.triangleCount
                modelNode.geometry = Coordinator.geometry(from: mesh)
            }

            if let placement {
                modelNode.isHidden = modelNode.geometry == nil
                modelNode.position = SCNVector3(
                    Float(placement.translation.x),
                    Float(placement.translation.y),
                    Float(placement.translation.z))
                modelNode.eulerAngles = SCNVector3(0, Float(placement.yaw), 0)
            } else {
                modelNode.isHidden = true
            }

            // The marks the operator tapped, so they can see which one they got
            // wrong without leaving the screen.
            let key = anchors.map { "\($0.pointId):\($0.world)" }.joined()
            if key != lastAnchorKey {
                lastAnchorKey = key
                anchorNode.childNodes.forEach { $0.removeFromParentNode() }
                for anchor in anchors {
                    let dot = SCNNode(geometry: SCNSphere(radius: 0.03))
                    dot.geometry?.firstMaterial?.diffuse.contents = UIColor.systemGreen
                    dot.geometry?.firstMaterial?.lightingModel = .constant
                    dot.position = SCNVector3(
                        Float(anchor.world.x), Float(anchor.world.y), Float(anchor.world.z))
                    anchorNode.addChildNode(dot)
                }
            }
        }

        /// Translucent and double-sided, on purpose.
        ///
        /// This is an overlay to look *through* — the wall behind it is the
        /// thing being checked against. An opaque model would hide exactly the
        /// evidence the operator came for, and back-face culling would make
        /// every room look empty from inside it.
        private static func geometry(from mesh: GlbMesh) -> SCNGeometry? {
            guard !mesh.positions.isEmpty, mesh.indices.count >= 3 else { return nil }

            let vertices = SCNGeometrySource(
                vertices: mesh.positions.map { SCNVector3($0.x, $0.y, $0.z) })
            var sources = [vertices]
            if let normals = mesh.normals, normals.count == mesh.positions.count {
                sources.append(SCNGeometrySource(
                    normals: normals.map { SCNVector3($0.x, $0.y, $0.z) }))
            }

            let indexData = mesh.indices.withUnsafeBufferPointer { Data(buffer: $0) }
            let element = SCNGeometryElement(
                data: indexData,
                primitiveType: .triangles,
                primitiveCount: mesh.indices.count / 3,
                bytesPerIndex: MemoryLayout<UInt32>.size)

            let geometry = SCNGeometry(sources: sources, elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.systemTeal
            material.transparency = 0.45
            material.isDoubleSided = true
            material.lightingModel = .constant
            material.writesToDepthBuffer = false
            geometry.firstMaterial = material
            return geometry
        }

        // MARK: Gestures

        @objc func onRotate(_ gesture: UIRotationGestureRecognizer) {
            guard gesture.state == .changed else {
                gesture.rotation = 0
                return
            }
            // Twisting clockwise on screen should turn the model clockwise
            // seen from above, which is a negative turn about +Y.
            onNudgeYaw(-Double(gesture.rotation))
            gesture.rotation = 0
        }

        @objc func onPan(_ gesture: UIPanGestureRecognizer) {
            guard let view, let frame = view.session.currentFrame else { return }
            switch gesture.state {
            case .began:
                panAnchor = gesture.translation(in: view)
            case .changed:
                let now = gesture.translation(in: view)
                let dx = Double(now.x - panAnchor.x)
                let dy = Double(now.y - panAnchor.y)
                panAnchor = now

                // Slide in the camera's own horizontal plane rather than in
                // world axes: dragging right has to move the model right from
                // where the operator is standing, whichever way they are
                // facing. The vertical component of the camera's axes is
                // dropped so a drag can never lift the model off the floor —
                // that is what the Up and Down buttons are for, and mixing the
                // two makes both feel broken.
                let camera = frame.camera.transform
                let right = normalisedHorizontal(camera.columns.0)
                let forward = normalisedHorizontal(-camera.columns.2)

                // 400 points of drag to a metre: fine enough to trim a doorway,
                // coarse enough to cross a room without a marathon.
                let metresPerPoint = 1.0 / 400.0
                let move = right * (dx * metresPerPoint) + forward * (-dy * metresPerPoint)
                onNudgeMove(move)
            default:
                break
            }
        }

        private func normalisedHorizontal(_ column: SIMD4<Float>) -> SIMD3<Double> {
            var v = SIMD3<Double>(Double(column.x), 0, Double(column.z))
            let length = (v.x * v.x + v.z * v.z).squareRoot()
            // Straight down or straight up: no horizontal direction to take, so
            // the drag does nothing rather than something arbitrary.
            guard length > 1e-6 else { return SIMD3<Double>(repeating: 0) }
            v /= length
            return v
        }

        // MARK: Raycast

        /// Same sampling as the marker aligner: the crosshair asks the scene
        /// where it is pointing, once a frame, on the main thread.
        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            DispatchQueue.main.async { [weak self] in self?.sample() }
        }

        private func sample() {
            guard let view, let frame = view.session.currentFrame else { return }
            let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            var target: SIMD3<Float>?
            if let query = view.raycastQuery(
                from: centre, allowing: .estimatedPlane, alignment: .any),
               let hit = view.session.raycast(query).first {
                target = SIMD3<Float>(
                    hit.worldTransform.columns.3.x,
                    hit.worldTransform.columns.3.y,
                    hit.worldTransform.columns.3.z)
            }
            MainActor.assumeIsolated {
                aligner.update(target: target, tracking: frame.camera.trackingState)
            }
        }
    }
}
