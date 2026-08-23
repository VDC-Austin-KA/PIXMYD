import ARKit
import SceneKit
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
// ## What anchors it
//
// The same registration that puts a scan into the model, run backwards. The
// operator locates two or more of the printed markers with `MarkerAlignView`;
// that solve maps the capture's ARKit frame onto the model's, and its inverse
// is where to draw. The arithmetic is in `ArModelPlacement`, in the portable
// half, because a model drawn nearly right is worse than one drawn obviously
// wrong and that is not a thing to check by looking at it.
//
// ## What it refuses to do
//
// Draw without an anchor. There is no "just show it in front of me" mode: an
// overlay floating at arm's length looks exactly like an aligned one through a
// phone screen, and somebody would measure from it. Below two located points
// the screen says which one is missing and nothing is drawn.
//
// The fit travels with the picture, permanently on screen rather than behind a
// tap, for the same reason the capture screen keeps the accuracy state visible:
// an overlay is only ever as good as the number that placed it.

struct ArModelView: View {
    let bundle: StoredNavBundle

    @EnvironmentObject private var site: SiteStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model = ArModelLoader()
    @State private var opacity: Double = 0.55

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

    var body: some View {
        ZStack {
            if ARWorldTrackingConfiguration.isSupported, readiness.canDraw {
                ArModelContainer(loader: model, opacity: opacity)
                    .ignoresSafeArea()
            } else {
                Theme.Palette.background.ignoresSafeArea()
            }
            overlay
        }
        .background(Theme.Palette.background)
        .onAppear { start() }
        .onDisappear { model.stop() }
    }

    private var overlay: some View {
        VStack {
            Panel(title: bundle.displayName) {
                Text(readiness.summary)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(readiness.canDraw ? Theme.Palette.textSecondary : Theme.Palette.caution)
                    .fixedSize(horizontal: false, vertical: true)

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

            VStack(spacing: Theme.Metrics.gutterTight) {
                if model.node != nil {
                    HStack(spacing: Theme.Metrics.gutterTight) {
                        Image(systemName: "circle.lefthalf.filled")
                            .foregroundStyle(Theme.Palette.textSecondary)
                        // A solid overlay hides the thing it is being compared
                        // against, which is the entire point of holding a phone
                        // up in a room.
                        Slider(value: $opacity, in: 0.15...1)
                            .tint(Theme.Palette.accent)
                    }
                    .padding(.horizontal, Theme.Metrics.gutter)
                }

                if !readiness.canDraw, case .notEnoughPoints = readiness {
                    Text("Locate markers from the Site tab, then come back.")
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }

                FieldButton(title: "Done", systemImage: "checkmark") { dismiss() }
            }
            .padding(Theme.Metrics.gutter)
            .background(.ultraThinMaterial)
        }
    }

    private func start() {
        guard case .ready = readiness,
              let ar = bundle.arBundle,
              let geometry = bundle.file(ar.geometry?.file),
              let pointSet = bundle.pointSet,
              case let .success(solved)? = site.solve(for: pointSet) else {
            return
        }

        model.load(
            glb: geometry,
            placement: ArModelPlacement.worldFromModel(
                solution: solved.solution,
                pointsAppliedOffset: pointSet.provenance.appliedOffset,
                modelAppliedOffset: ar.provenance.appliedOffset))
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

    let session = ARSession()
    private var isRunning = false

    func load(glb: URL, placement: [Double]) {
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
                let built = ArModelLoader.node(for: mesh, placement: placement)
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
    }

    /// Build the SceneKit node, off the main actor.
    ///
    /// `nonisolated` and static because it touches nothing but its arguments:
    /// SceneKit geometry construction is thread-safe as long as the node is not
    /// yet in a scene, and the node only reaches one on the main actor.
    nonisolated private static func node(for mesh: TsdfVolume.Mesh, placement: [Double]) -> SCNNode {
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
        // A wireframe-ish flat fill rather than a lit render: this is a
        // comparison against a real wall, not a picture of a model, and shading
        // it would make a coordinator judge the fit by how convincing it looks.
        material.diffuse.contents = mesh.colors == nil
            ? UIColor(red: 0.36, green: 0.62, blue: 0.94, alpha: 1)
            : nil
        material.writesToDepthBuffer = true
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.simdTransform = float4x4(placement)
        return node
    }
}

/// The `ARSCNView` the model is drawn into.
private struct ArModelContainer: UIViewRepresentable {
    @ObservedObject var loader: ArModelLoader
    let opacity: Double

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = loader.session
        view.automaticallyUpdatesLighting = true
        view.scene = SCNScene()
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        guard let node = loader.node else { return }
        if node.parent == nil { view.scene.rootNode.addChildNode(node) }
        node.opacity = CGFloat(opacity)
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
