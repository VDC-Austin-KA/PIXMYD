import ARKit
@preconcurrency import SceneKit
import SwiftUI
import UIKit

// Drawing the exported model over the real world.
//
// This is what the AR model export was always for, and what it could not do
// until PIXMYD-Nav learned to tessellate a document: the bundle used to carry a
// bounding box, a camera and a photograph, and this app's own decoder said so —
// "a bundle with no geometry is still worth showing. It just cannot be drawn
// over the world."
//
// ## Two ways to anchor it, and they are not equal
//
// **The survey fit.** The operator locates three or more of the printed markers
// with `MarkerAlignView`; that solve maps the capture's ARKit frame onto the
// model's, and its inverse is where to draw. The arithmetic is in
// `ArModelPlacement`, in the portable half, because a model drawn nearly right
// is worse than one drawn obviously wrong and that is not a thing to check by
// looking at it. This path is measurable, and the screen reports its RMS.
//
// **By hand.** Anchor on whatever points the bundle carries, from one, and
// correct it by eye afterwards: drag to slide, twist to turn, arrows for
// height. Any anchor can be replaced or cleared and the placement re-solves as
// it happens. The arithmetic is in `ArHandPlacement`.
//
// This screen used to have only the first, and refused to draw anything at all
// below the threshold, on the grounds that an overlay floating at arm's length
// looks exactly like an aligned one through a phone screen and somebody would
// measure from it. The reasoning is sound; the conclusion was too strong. Most
// of the time nobody has walked the site with a marker pack, and the real
// question is "do those ducts clash with that beam" — which a model placed by
// eye answers and a model that refuses to appear does not.
//
// So both exist, and the screen never lets them be confused. A hand-placed
// overlay is labelled NOT MEASURABLE in the panel that is permanently on
// screen, in the same place the survey fit shows its RMS. There is no
// reassuring number to be had from the hand path, because it does not have one.

struct ArModelView: View {
    let bundle: StoredNavBundle

    @EnvironmentObject private var site: SiteStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model = ArModelLoader()
    @State private var opacity: Double = 0.55

    /// The operator has chosen to place it by hand. Sticky, and never entered
    /// automatically: a hand placement must not be able to drift into looking
    /// like a measured one because a solve happened to become available.
    @State private var byHand = false
    @State private var anchors: [ArHandAnchor] = []
    @State private var selected: String?
    @State private var nudgeYaw: Double = 0
    @State private var nudgeOffset = SIMD3<Double>(repeating: 0)

    private var located: Int {
        guard let setId = bundle.pointSet?.setId else { return 0 }
        return site.observedCount(setId: setId)
    }

    private var readiness: ArModelPlacement.Readiness {
        ArModelPlacement.readiness(
            hasGeometry: bundle.arBundle?.hasGeometry == true,
            pointSet: bundle.pointSet,
            located: located,
            solved: bundle.pointSet.flatMap { site.solve(for: $0) })
    }

    /// The points this bundle offers as anchors, in the AR model's own frame.
    ///
    /// Empty when the bundle carries no `points.json`, which is a supported
    /// state: with no ids to anchor to, one tap still drops the model's origin
    /// where the operator is aiming.
    private var candidates: [(point: NavPoint, model: SIMD3<Double>)] {
        guard let ar = bundle.arBundle, let set = bundle.pointSet else { return [] }
        return set.points.map { ($0, ar.modelFrame(of: $0, in: set)) }
    }

    private var handPlacement: ArHandPlacement? {
        ArHandPlacement.solve(anchors: anchors)?.nudged(yaw: nudgeYaw, by: nudgeOffset)
    }

    /// The transform actually in force, or nil when there is nothing to draw.
    private var placement: [Double]? {
        if byHand { return handPlacement?.matrix }
        guard case .ready = readiness,
              let ar = bundle.arBundle,
              let set = bundle.pointSet,
              case let .success(solved)? = site.solve(for: set) else { return nil }
        return ArModelPlacement.worldFromModel(
            solution: solved.solution,
            pointsAppliedOffset: set.provenance.appliedOffset,
            modelAppliedOffset: ar.provenance.appliedOffset)
    }

    private var hasGeometry: Bool { bundle.arBundle?.hasGeometry == true }

    var body: some View {
        ZStack {
            if ARWorldTrackingConfiguration.isSupported, hasGeometry {
                ArModelContainer(
                    loader: model,
                    opacity: opacity,
                    placement: placement,
                    anchors: byHand ? anchors : [],
                    aiming: byHand,
                    onNudgeYaw: { nudgeYaw += $0 },
                    onNudgeMove: { nudgeOffset += $0 })
                    .ignoresSafeArea()
            } else {
                Theme.Palette.background.ignoresSafeArea()
            }
            if byHand { crosshair }
            overlay
        }
        .background(Theme.Palette.background)
        .onAppear { start() }
        .onDisappear { model.stop() }
    }

    private var crosshair: some View {
        ZStack {
            Circle()
                .strokeBorder(model.hasTarget ? Theme.Palette.good : Theme.Palette.textTertiary,
                              lineWidth: 2)
                .frame(width: 44, height: 44)
            Circle()
                .fill(model.hasTarget ? Theme.Palette.good : Theme.Palette.textTertiary)
                .frame(width: 5, height: 5)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Panel

    private var overlay: some View {
        VStack {
            Panel(title: bundle.displayName) {
                if byHand {
                    handStatus
                } else {
                    Text(readiness.summary)
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(readiness.canDraw
                                         ? Theme.Palette.textSecondary
                                         : Theme.Palette.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let failure = model.failure {
                    Text(failure)
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.isLoading {
                    ProgressView("Reading the model…").tint(Theme.Palette.accent)
                }
                if let triangles = model.triangleCount {
                    Text("\(triangles) triangles")
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .padding(Theme.Metrics.gutter)

            Spacer()

            controls
        }
    }

    /// The hand-placement readout.
    ///
    /// NOT MEASURABLE sits exactly where the survey fit puts its RMS,
    /// deliberately: the one number a reader looks for is missing, and what
    /// replaces it says why. The anchor spread is shown because it is the
    /// honest proxy — how far the marks are from where the placement puts them
    /// — but it is labelled "spread" rather than "error", because it describes
    /// self-consistency and not accuracy against the building.
    private var handStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatusChip(text: "NOT MEASURABLE",
                       tone: .caution,
                       systemImage: "exclamationmark.triangle")

            Text(handGuidance)
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if anchors.count >= 2, let fit = ArHandPlacement.solve(anchors: anchors) {
                HStack(spacing: Theme.Metrics.gutter) {
                    Readout(label: "Anchors", value: "\(anchors.count)")
                    Readout(label: "Spread",
                            value: String(format: "%.0f", fit.rmsError * 1000),
                            unit: "mm",
                            tone: fit.rmsError < 0.05 ? .neutral : .caution)
                }
            }
        }
    }

    private var handGuidance: String {
        if anchors.isEmpty {
            if candidates.isEmpty {
                return "No point set came with this model, so there are no ids to anchor to. "
                     + "Tap once to drop the model's origin where you are aiming, then drag "
                     + "and twist it into place."
            }
            return "Pick a point below, aim at the real one, and tap. The model appears on "
                 + "the first anchor."
        }
        if anchors.count == 1 {
            return "Pinned. Its heading is a guess — anchor a second point well away from the "
                 + "first to turn it the right way, or twist it into place by hand."
        }
        return "Drag to slide, twist to turn, arrows for height. Long-press an id below to "
             + "place it again or clear it."
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: Theme.Metrics.gutterTight) {
            if model.node != nil {
                HStack(spacing: Theme.Metrics.gutterTight) {
                    Image(systemName: "circle.lefthalf.filled")
                        .foregroundStyle(Theme.Palette.textSecondary)
                    // A solid overlay hides the thing it is being compared
                    // against, which is the entire point of holding a phone up
                    // in a room.
                    Slider(value: $opacity, in: 0.15...1)
                        .tint(Theme.Palette.accent)
                }
                .padding(.horizontal, Theme.Metrics.gutter)
            }

            if byHand {
                handControls
            } else {
                surveyControls
            }

            FieldButton(title: "Done", systemImage: "checkmark") { dismiss() }
        }
        .padding(Theme.Metrics.gutter)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var surveyControls: some View {
        if !readiness.canDraw, case .notEnoughPoints = readiness {
            Text("Locate markers from the Site tab for a fit you can measure against.")
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Offered whether or not the survey fit is available. A crew that has
        // located three markers may still want to shove the overlay half a
        // metre to see what is behind it, and refusing that would send them
        // back to the van for a tape measure instead.
        if hasGeometry {
            FieldButton(title: "Place it by hand instead", systemImage: "hand.draw") {
                byHand = true
                if selected == nil { selected = candidates.first?.point.id }
            }
        }
    }

    @ViewBuilder
    private var handControls: some View {
        if !candidates.isEmpty { pointStrip }

        HStack(spacing: Theme.Metrics.gutterTight) {
            FieldButton(title: placeTitle, systemImage: "mappin.and.ellipse", role: .primary) {
                place()
            }
            .disabled(!model.hasTarget)
            .opacity(model.hasTarget ? 1 : 0.5)

            FieldButton(title: "Undo", systemImage: "arrow.uturn.backward") {
                // Newest first: undo means "not that one", and the one they
                // mean is always the one they just did.
                if !anchors.isEmpty { anchors.removeLast() }
            }
            .disabled(anchors.isEmpty)
            .opacity(anchors.isEmpty ? 0.5 : 1)
        }

        HStack(spacing: Theme.Metrics.gutterTight) {
            FieldButton(title: "Down", systemImage: "arrow.down") { nudgeOffset.y -= 0.05 }
            FieldButton(title: "Up", systemImage: "arrow.up") { nudgeOffset.y += 0.05 }
            FieldButton(title: "Reset", systemImage: "arrow.counterclockwise", role: .destructive) {
                anchors.removeAll()
                nudgeYaw = 0
                nudgeOffset = SIMD3<Double>(repeating: 0)
            }
        }

        if readiness.canDraw {
            FieldButton(title: "Back to the survey fit", systemImage: "target") {
                byHand = false
            }
        }
    }

    private var placeTitle: String {
        guard let id = selected else { return "Drop the model here" }
        let already = anchors.contains(where: { $0.pointId == id })
        return already ? "Replace \(id)" : "Place \(id)"
    }

    /// The ids, with the placed ones marked. Tapping selects; long-press clears.
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
                        .foregroundStyle(selected == id
                                         ? Theme.Palette.background
                                         : Theme.Palette.text)
                        .background(chipBackground(selected: selected == id, placed: placed),
                                    in: RoundedRectangle(
                                        cornerRadius: Theme.Metrics.cornerRadiusSmall))
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

    private func chipBackground(selected: Bool, placed: Bool) -> Color {
        if selected { return Theme.Palette.accent }
        if placed { return Theme.Palette.good.opacity(0.25) }
        return Theme.Palette.surfaceRaised
    }

    // MARK: - Placing

    private func place() {
        guard let target = model.currentTarget else { return }
        let world = SIMD3<Double>(Double(target.x), Double(target.y), Double(target.z))
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        guard let id = selected,
              let candidate = candidates.first(where: { $0.point.id == id }) else {
            // No point set: one anchor at the model's own origin, which the
            // operator then drags. Replacing rather than appending, because a
            // second tap here means "no, there" and not "another anchor".
            anchors = [ArHandAnchor(pointId: "origin",
                                    model: SIMD3<Double>(repeating: 0),
                                    world: world)]
            return
        }

        let anchor = ArHandAnchor(pointId: id, model: candidate.model, world: world)
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
        if let next = unplaced { selected = next.point.id }
    }

    private func start() {
        guard let ar = bundle.arBundle, let geometry = bundle.file(ar.geometry?.file) else { return }
        // Loaded whenever there is geometry, not only when the survey fit is
        // ready: the hand path needs the mesh too, and it is the path somebody
        // reaches for precisely because the fit is not ready.
        model.load(glb: geometry)
    }
}

/// Owns the ARKit session and the loaded model.
///
/// A session of its own rather than the capture session's: an overlay is looked
/// at before or after a scan, never during one, and sharing would mean the
/// capture writer and this screen both driving one configuration.
@MainActor
final class ArModelLoader: ObservableObject {
    @Published private(set) var node: SCNNode?
    @Published private(set) var isLoading = false
    @Published private(set) var failure: String?
    @Published private(set) var triangleCount: Int?
    /// Where the crosshair is pointing, in the world frame. Nil when the scene
    /// has nothing under it yet.
    @Published private(set) var currentTarget: SIMD3<Float>?

    var hasTarget: Bool { currentTarget != nil }

    let session = ARSession()
    private var isRunning = false

    /// Load the mesh, without a placement.
    ///
    /// The transform used to be baked into the node at build time, which was
    /// fine while it could only ever come from one solve. It is written on
    /// every render instead now, because the hand path changes it while the
    /// operator watches — and re-uploading a multi-megabyte mesh to the GPU for
    /// every frame of a drag is not a thing to do when a transform will do.
    func load(glb: URL) {
        guard node == nil, !isLoading else { return }
        isLoading = true
        failure = nil
        run()

        // Off the main actor: an exported model is tens of megabytes and
        // parsing it on the main thread drops the AR session's frames, which
        // shows up as tracking loss rather than as a slow read.
        Task.detached(priority: .userInitiated) {
            do {
                let mesh = try GlbReader.read(contentsOf: glb)
                let built = ArModelLoader.node(for: mesh)
                await MainActor.run {
                    self.node = built
                    self.triangleCount = mesh.indices.count / 3
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.failure = "\(error)"
                    self.isLoading = false
                }
            }
        }
    }

    func update(target: SIMD3<Float>?) {
        currentTarget = target
    }

    private func run() {
        guard ARWorldTrackingConfiguration.isSupported, !isRunning else { return }
        let config = ARWorldTrackingConfiguration()
        // Gravity-aligned, matching how a capture is recorded: the registration
        // that anchors this model was solved against a session run the same way.
        config.worldAlignment = .gravity
        config.environmentTexturing = .none
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
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

    /// Build the SceneKit node, off the main actor.
    ///
    /// `nonisolated` and static because it touches nothing but its arguments:
    /// SceneKit geometry construction is thread-safe as long as the node is not
    /// yet in a scene, and the node only reaches one on the main actor.
    nonisolated private static func node(for mesh: TsdfVolume.Mesh) -> SCNNode {
        var sources: [SCNGeometrySource] = [
            SCNGeometrySource(vertices: mesh.positions.map { SCNVector3($0.x, $0.y, $0.z) })
        ]
        if let normals = mesh.normals, normals.count == mesh.positions.count {
            sources.append(SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) }))
        }
        if let colors = mesh.colors, colors.count == mesh.positions.count {
            let values = colors.map {
                SIMD3<Float>(Float($0.x) / 255, Float($0.y) / 255, Float($0.z) / 255)
            }
            sources.append(SCNGeometrySource(
                data: Data(bytes: values, count: values.count * MemoryLayout<SIMD3<Float>>.stride),
                semantic: .color,
                vectorCount: values.count,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SIMD3<Float>>.stride))
        }

        let element = SCNGeometryElement(
            data: Data(bytes: mesh.indices, count: mesh.indices.count * MemoryLayout<UInt32>.size),
            primitiveType: .triangles,
            primitiveCount: mesh.indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size)

        let geometry = SCNGeometry(sources: sources, elements: [element])

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        // A flat fill rather than a lit render: this is a comparison against a
        // real wall, not a picture of a model, and shading it would make a
        // coordinator judge the fit by how convincing it looks.
        material.diffuse.contents = mesh.colors == nil
            ? UIColor(red: 0.36, green: 0.62, blue: 0.94, alpha: 1)
            : nil
        material.writesToDepthBuffer = true
        geometry.materials = [material]

        return SCNNode(geometry: geometry)
    }
}

/// The `ARSCNView` the model is drawn into.
private struct ArModelContainer: UIViewRepresentable {
    @ObservedObject var loader: ArModelLoader
    let opacity: Double
    /// Column-major 4x4, or nil to draw nothing.
    let placement: [Double]?
    let anchors: [ArHandAnchor]
    /// True while the operator is placing by hand: the crosshair samples the
    /// scene and the drag gestures are live. False leaves the survey fit
    /// untouchable, which is the point of it.
    let aiming: Bool
    let onNudgeYaw: (Double) -> Void
    let onNudgeMove: (SIMD3<Double>) -> Void

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = loader.session
        view.automaticallyUpdatesLighting = true
        view.scene = SCNScene()
        view.delegate = context.coordinator
        view.scene.rootNode.addChildNode(context.coordinator.anchorNode)
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
        context.coordinator.aiming = aiming
        context.coordinator.onNudgeYaw = onNudgeYaw
        context.coordinator.onNudgeMove = onNudgeMove
        context.coordinator.show(anchors: anchors)

        guard let node = loader.node else { return }
        if node.parent == nil { view.scene.rootNode.addChildNode(node) }
        node.opacity = CGFloat(opacity)
        if let placement {
            node.isHidden = false
            node.simdTransform = float4x4(placement)
        } else {
            node.isHidden = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(loader: loader) }

    final class Coordinator: NSObject, ARSCNViewDelegate {
        let loader: ArModelLoader
        weak var view: ARSCNView?
        let anchorNode = SCNNode()

        var aiming = false
        var onNudgeYaw: (Double) -> Void = { _ in }
        var onNudgeMove: (SIMD3<Double>) -> Void = { _ in }

        private var panAnchor = CGPoint.zero
        private var shownAnchors = ""

        init(loader: ArModelLoader) {
            self.loader = loader
            super.init()
        }

        /// Dots where the operator tapped, so they can see which one is wrong
        /// without leaving the screen.
        @MainActor
        func show(anchors: [ArHandAnchor]) {
            let key = anchors.map { "\($0.pointId):\($0.world)" }.joined()
            guard key != shownAnchors else { return }
            shownAnchors = key
            anchorNode.childNodes.forEach { $0.removeFromParentNode() }
            for anchor in anchors {
                let dot = SCNNode(geometry: SCNSphere(radius: 0.03))
                dot.geometry?.firstMaterial?.diffuse.contents = UIColor.systemGreen
                dot.geometry?.firstMaterial?.lightingModel = .constant
                dot.position = SCNVector3(Float(anchor.world.x),
                                          Float(anchor.world.y),
                                          Float(anchor.world.z))
                anchorNode.addChildNode(dot)
            }
        }

        // MARK: Gestures

        @objc func onRotate(_ gesture: UIRotationGestureRecognizer) {
            guard aiming, gesture.state == .changed else {
                gesture.rotation = 0
                return
            }
            // Twisting clockwise on screen should turn the model clockwise seen
            // from above, which is a negative turn about +Y.
            onNudgeYaw(-Double(gesture.rotation))
            gesture.rotation = 0
        }

        @objc func onPan(_ gesture: UIPanGestureRecognizer) {
            guard aiming, let view, let frame = view.session.currentFrame else { return }
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
                // that is what Up and Down are for, and mixing the two makes
                // both feel broken.
                let camera = frame.camera.transform
                let right = horizontal(camera.columns.0)
                let forward = horizontal(-camera.columns.2)

                // 400 points of drag to a metre: fine enough to trim a doorway,
                // coarse enough to cross a room without a marathon.
                let metresPerPoint = 1.0 / 400.0
                onNudgeMove(right * (dx * metresPerPoint) + forward * (-dy * metresPerPoint))
            default:
                break
            }
        }

        private func horizontal(_ column: SIMD4<Float>) -> SIMD3<Double> {
            var v = SIMD3<Double>(Double(column.x), 0, Double(column.z))
            let length = (v.x * v.x + v.z * v.z).squareRoot()
            // Straight up or straight down: no horizontal direction to take, so
            // the drag does nothing rather than something arbitrary.
            guard length > 1e-6 else { return SIMD3<Double>(repeating: 0) }
            v /= length
            return v
        }

        // MARK: Crosshair

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            DispatchQueue.main.async { [weak self] in self?.sample() }
        }

        private func sample() {
            guard aiming, let view, view.session.currentFrame != nil else { return }
            let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            // `raycastQuery` is non-optional as of Xcode 26.
            let query = view.raycastQuery(from: centre, allowing: .estimatedPlane, alignment: .any)
            let hit = view.session.raycast(query).first
            let target = hit.map {
                SIMD3<Float>($0.worldTransform.columns.3.x,
                             $0.worldTransform.columns.3.y,
                             $0.worldTransform.columns.3.z)
            }
            MainActor.assumeIsolated { loader.update(target: target) }
        }
    }
}

private extension float4x4 {
    /// From the suite's column-major 4x4, which is `m[c * 4 + r]` — the same
    /// layout `simd_float4x4`'s column initialiser takes.
    init(_ m: [Double]) {
        guard m.count == 16 else { self = matrix_identity_float4x4; return }
        self.init(
            SIMD4<Float>(Float(m[0]), Float(m[1]), Float(m[2]), Float(m[3])),
            SIMD4<Float>(Float(m[4]), Float(m[5]), Float(m[6]), Float(m[7])),
            SIMD4<Float>(Float(m[8]), Float(m[9]), Float(m[10]), Float(m[11])),
            SIMD4<Float>(Float(m[12]), Float(m[13]), Float(m[14]), Float(m[15])))
    }
}
