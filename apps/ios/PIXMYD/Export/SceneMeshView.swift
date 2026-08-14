import SceneKit
import SwiftUI
import simd

/// Renders a fused mesh, and turns a tap into a point on its surface.
struct SceneMeshView: UIViewRepresentable {
    let mesh: TsdfVolume.Mesh
    /// Drawn as a wireframe when set, showing where a crop would cut.
    var cropBox: MeshEditing.Bounds?
    /// Nil disables picking, so the tap gesture does not fight orbiting.
    var onTap: ((SIMD3<Float>) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene()
        view.backgroundColor = .black
        // A complete gesture set — orbit, pan, pinch, double-tap to frame — for
        // one line, and better behaved than anything hand-rolled.
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling2X

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.parent = self

        // Rebuilding geometry is expensive, so only do it when the mesh has
        // actually changed. SwiftUI calls this for any state change, including
        // toggling a button.
        if context.coordinator.renderedTriangles != mesh.indices.count
            || context.coordinator.renderedVertices != mesh.positions.count {
            context.coordinator.renderedTriangles = mesh.indices.count
            context.coordinator.renderedVertices = mesh.positions.count
            rebuild(view)
        }
        updateCropBox(view)
    }

    // MARK: - Geometry

    private func rebuild(_ view: SCNView) {
        view.scene?.rootNode.childNode(withName: "mesh", recursively: false)?.removeFromParentNode()
        guard !mesh.indices.isEmpty else { return }

        let node = SCNNode(geometry: Self.geometry(from: mesh))
        node.name = "mesh"
        view.scene?.rootNode.addChildNode(node)

        // Frame the model on first build. Without this the camera starts at the
        // origin, which for a scan whose coordinates are metres from wherever
        // the session began is often inside a wall or nowhere near the mesh.
        if view.pointOfView == nil || view.defaultCameraController.pointOfView == nil {
            view.defaultCameraController.frameNodes([node])
        }
    }

    static func geometry(from mesh: TsdfVolume.Mesh) -> SCNGeometry {
        let positionData = mesh.positions.withUnsafeBufferPointer { Data(buffer: $0) }
        var sources = [
            SCNGeometrySource(
                data: positionData,
                semantic: .vertex,
                vectorCount: mesh.positions.count,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SIMD3<Float>>.stride
            )
        ]

        if let normals = mesh.normals, normals.count == mesh.positions.count {
            let data = normals.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(
                SCNGeometrySource(
                    data: data,
                    semantic: .normal,
                    vectorCount: normals.count,
                    usesFloatComponents: true,
                    componentsPerVector: 3,
                    bytesPerComponent: MemoryLayout<Float>.size,
                    dataOffset: 0,
                    dataStride: MemoryLayout<SIMD3<Float>>.stride
                )
            )
        }

        if let colors = mesh.colors, colors.count == mesh.positions.count {
            // SceneKit wants float colour components. Vertex colours are the
            // whole point of looking at the result — a grey mesh tells you the
            // geometry is there but not whether the colour projection worked.
            let floats = colors.flatMap { c in
                [Float(c.x) / 255, Float(c.y) / 255, Float(c.z) / 255]
            }
            let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(
                SCNGeometrySource(
                    data: data,
                    semantic: .color,
                    vectorCount: colors.count,
                    usesFloatComponents: true,
                    componentsPerVector: 3,
                    bytesPerComponent: MemoryLayout<Float>.size,
                    dataOffset: 0,
                    dataStride: MemoryLayout<Float>.size * 3
                )
            )
        }

        let indexData = mesh.indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: mesh.indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.9
        material.metalness.contents = 0.0
        // Fusion can leave a triangle wound the wrong way, and a single-sided
        // material renders those as holes — which reads as a gap in the scan
        // rather than as a winding artefact.
        material.isDoubleSided = true
        if mesh.colors == nil { material.diffuse.contents = UIColor(white: 0.78, alpha: 1) }
        geometry.materials = [material]
        return geometry
    }

    private func updateCropBox(_ view: SCNView) {
        let existing = view.scene?.rootNode.childNode(withName: "crop", recursively: false)
        existing?.removeFromParentNode()

        guard let cropBox else { return }
        let size = cropBox.size
        let box = SCNBox(
            width: CGFloat(max(size.x, 0.001)),
            height: CGFloat(max(size.y, 0.001)),
            length: CGFloat(max(size.z, 0.001)),
            chamferRadius: 0
        )
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 0.30, green: 0.64, blue: 1.0, alpha: 0.22)
        material.isDoubleSided = true
        // Neither reads nor writes depth, so the box is visible through the
        // mesh it is cutting. A crop box you cannot see inside is useless.
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
        box.materials = [material]

        let node = SCNNode(geometry: box)
        node.name = "crop"
        node.position = SCNVector3(cropBox.centre.x, cropBox.centre.y, cropBox.centre.z)
        node.renderingOrder = 10
        view.scene?.rootNode.addChildNode(node)
    }

    // MARK: - Picking

    final class Coordinator: NSObject {
        var parent: SceneMeshView
        weak var view: SCNView?
        var renderedTriangles = -1
        var renderedVertices = -1

        init(_ parent: SceneMeshView) {
            self.parent = parent
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let onTap = parent.onTap, let view else { return }
            let point = recognizer.location(in: view)
            // Only the mesh is pickable; the crop box is a guide, and hitting
            // it instead would delete whatever happened to be behind it.
            let hits = view.hitTest(point, options: [
                .searchMode: SCNHitTestSearchMode.closest.rawValue,
                .ignoreHiddenNodes: true,
            ])
            guard let hit = hits.first(where: { $0.node.name == "mesh" }) else { return }
            let world = hit.worldCoordinates
            onTap(SIMD3(Float(world.x), Float(world.y), Float(world.z)))
        }
    }
}
