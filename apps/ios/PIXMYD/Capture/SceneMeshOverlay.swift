import ARKit
import Foundation
import SceneKit
import simd

/// The live scene mesh, drawn over the viewfinder while scanning.
///
/// This is the feedback every good scanning app has and this one did not:
/// surfaces filling in as you sweep the room, so coverage is something you can
/// see rather than something you find out about at export. Where there is no
/// mesh, nothing has been measured — which is the whole question a person is
/// asking while they walk around.
///
/// It costs almost nothing to draw, because ARKit has already computed it.
/// `sceneReconstruction` builds these anchors whether or not anything renders
/// them; all this does is hand the existing Metal buffers to SceneKit. The
/// vertex and index buffers are wrapped, not copied.
/// Not main-actor isolated, deliberately. `ARSCNViewDelegate` callbacks arrive
/// on SceneKit's rendering thread, not the main thread, so annotating this
/// `@MainActor` was both a Swift 6 concurrency error and a plain misstatement
/// of where the code runs. Settings are written from `updateUIView` on the main
/// thread and read on the render thread, which is a real race, so the shared
/// state is behind a lock rather than merely un-annotated.
final class SceneMeshOverlay: NSObject, ARSCNViewDelegate {

    /// How faces are coloured.
    enum Style: String, CaseIterable, Identifiable {
        /// One translucent colour. Cheapest, and the clearest read on coverage.
        case coverage
        /// Per-face ARKit classification: floor, wall, ceiling and so on.
        case classification

        var id: String { rawValue }

        var label: String {
            switch self {
            case .coverage: "Coverage"
            case .classification: "Surfaces"
            }
        }
    }

    /// Guards everything below it. Held only around dictionary access and the
    /// two settings — never across `SCNGeometry` construction, which is the
    /// expensive part and touches nothing shared.
    private let lock = NSLock()
    private var storedIsEnabled = false
    private var storedStyle: Style = .coverage
    private var nodes: [UUID: SCNNode] = [:]
    private var anchors: [UUID: ARMeshAnchor] = [:]

    var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storedIsEnabled }
        set {
            lock.lock()
            let changed = storedIsEnabled != newValue
            storedIsEnabled = newValue
            let affected = changed ? Array(nodes.values) : []
            lock.unlock()

            for node in affected { node.isHidden = !newValue }
            if changed, newValue { rebuildAll() }
        }
    }

    var style: Style {
        get { lock.lock(); defer { lock.unlock() }; return storedStyle }
        set {
            lock.lock()
            let changed = storedStyle != newValue
            storedStyle = newValue
            lock.unlock()

            if changed { rebuildAll() }
        }
    }

    // MARK: - ARSCNViewDelegate

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let mesh = anchor as? ARMeshAnchor else { return }

        lock.lock()
        anchors[anchor.identifier] = mesh
        nodes[anchor.identifier] = node
        let enabled = storedIsEnabled
        let style = storedStyle
        lock.unlock()

        node.isHidden = !enabled
        if enabled { node.geometry = Self.geometry(from: mesh.geometry, style: style) }
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let mesh = anchor as? ARMeshAnchor else { return }

        lock.lock()
        anchors[anchor.identifier] = mesh
        let enabled = storedIsEnabled
        let style = storedStyle
        lock.unlock()

        // ARKit revises a block's geometry as it accumulates evidence, so the
        // node has to be rebuilt rather than merely re-posed. Skipping this is
        // how live meshes end up frozen at their first, roughest estimate.
        guard enabled else { return }
        node.geometry = Self.geometry(from: mesh.geometry, style: style)
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        lock.lock()
        anchors[anchor.identifier] = nil
        nodes[anchor.identifier] = nil
        lock.unlock()
    }

    func reset() {
        lock.lock()
        let existing = Array(nodes.values)
        nodes.removeAll()
        anchors.removeAll()
        lock.unlock()

        for node in existing { node.geometry = nil }
    }

    private func rebuildAll() {
        lock.lock()
        let work = anchors.compactMap { id, anchor in nodes[id].map { ($0, anchor) } }
        let enabled = storedIsEnabled
        let style = storedStyle
        lock.unlock()

        guard enabled else { return }
        for (node, anchor) in work {
            node.geometry = Self.geometry(from: anchor.geometry, style: style)
        }
    }

    // MARK: - ARMeshGeometry to SCNGeometry

    /// Wrap ARKit's mesh buffers as SceneKit geometry.
    ///
    /// `ARGeometrySource` and `ARGeometryElement` are already Metal buffers in
    /// the layout SceneKit wants, so both sources here are views onto ARKit's
    /// memory rather than copies. Only the classification split copies, and only
    /// the indices.
    static func geometry(from mesh: ARMeshGeometry, style: Style) -> SCNGeometry {
        let vertices = SCNGeometrySource(
            buffer: mesh.vertices.buffer,
            vertexFormat: mesh.vertices.format,
            semantic: .vertex,
            vertexCount: mesh.vertices.count,
            dataOffset: mesh.vertices.offset,
            dataStride: mesh.vertices.stride
        )
        let normals = SCNGeometrySource(
            buffer: mesh.normals.buffer,
            vertexFormat: mesh.normals.format,
            semantic: .normal,
            vertexCount: mesh.normals.count,
            dataOffset: mesh.normals.offset,
            dataStride: mesh.normals.stride
        )

        if style == .classification, let classification = mesh.classification {
            let geometry = classified(mesh: mesh, classification: classification,
                                      sources: [vertices, normals])
            if let geometry { return geometry }
            // Fall through to the plain mesh if the split produced nothing,
            // which happens on a device without classification support.
        }

        let element = SCNGeometryElement(
            buffer: mesh.faces.buffer,
            primitiveType: .triangles,
            primitiveCount: mesh.faces.count,
            bytesPerIndex: mesh.faces.bytesPerIndex
        )
        let geometry = SCNGeometry(sources: [vertices, normals], elements: [element])
        geometry.materials = [coverageMaterial()]
        return geometry
    }

    /// Split faces by ARKit's per-face label into one element per class, so
    /// each can carry its own colour.
    private static func classified(
        mesh: ARMeshGeometry,
        classification: ARGeometrySource,
        sources: [SCNGeometrySource]
    ) -> SCNGeometry? {
        let faceCount = mesh.faces.count
        guard faceCount > 0, mesh.faces.bytesPerIndex == MemoryLayout<UInt32>.size else {
            return nil
        }

        let labels = classification.buffer.contents()
        let faces = mesh.faces.buffer.contents().assumingMemoryBound(to: UInt32.self)

        var buckets: [UInt8: [UInt32]] = [:]
        for face in 0..<faceCount {
            let raw = labels
                .advanced(by: classification.offset + classification.stride * face)
                .assumingMemoryBound(to: UInt8.self)
                .pointee
            buckets[raw, default: []]
                .append(contentsOf: [faces[face * 3], faces[face * 3 + 1], faces[face * 3 + 2]])
        }
        guard !buckets.isEmpty else { return nil }

        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []
        // Sorted so element order — and therefore material order — is stable
        // between updates. Unsorted, a block would flicker through colours as
        // dictionary order changed.
        for (raw, indices) in buckets.sorted(by: { $0.key < $1.key }) {
            let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
            elements.append(
                SCNGeometryElement(
                    data: data,
                    primitiveType: .triangles,
                    primitiveCount: indices.count / 3,
                    bytesPerIndex: MemoryLayout<UInt32>.size
                )
            )
            materials.append(
                material(color: color(for: ARMeshClassification(rawValue: Int(raw)) ?? .none))
            )
        }

        let geometry = SCNGeometry(sources: sources, elements: elements)
        geometry.materials = materials
        return geometry
    }

    // MARK: - Appearance

    /// Colours for ARKit's classes.
    ///
    /// ARKit classifies into exactly these eight and no more: there is no
    /// column, no beam, and no distinction between a desk and any other table.
    /// Anything structural it cannot place lands in `.none`, which is why that
    /// case is drawn in a neutral grey rather than hidden — an unlabelled
    /// surface is still a measured one.
    static func color(for classification: ARMeshClassification) -> UIColor {
        switch classification {
        case .floor: UIColor(red: 0.24, green: 0.60, blue: 0.98, alpha: 1)
        case .ceiling: UIColor(red: 0.62, green: 0.44, blue: 0.96, alpha: 1)
        case .wall: UIColor(red: 0.36, green: 0.80, blue: 0.68, alpha: 1)
        case .table: UIColor(red: 0.98, green: 0.72, blue: 0.28, alpha: 1)
        case .seat: UIColor(red: 0.98, green: 0.48, blue: 0.42, alpha: 1)
        case .window: UIColor(red: 0.42, green: 0.88, blue: 0.98, alpha: 1)
        case .door: UIColor(red: 0.86, green: 0.62, blue: 0.98, alpha: 1)
        case .none: UIColor(white: 0.72, alpha: 1)
        @unknown default: UIColor(white: 0.72, alpha: 1)
        }
    }

    static func label(for classification: ARMeshClassification) -> String {
        switch classification {
        case .floor: "Floor"
        case .ceiling: "Ceiling"
        case .wall: "Wall"
        case .table: "Table"
        case .seat: "Seat"
        case .window: "Window"
        case .door: "Door"
        case .none: "Unclassified"
        @unknown default: "Unclassified"
        }
    }

    private static func material(color: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color.withAlphaComponent(0.45)
        material.isDoubleSided = true
        // Unlit: the overlay is a diagram, not part of the scene. Shading it
        // would make it read as an object in the room and compete with the
        // camera feed it is drawn over.
        material.lightingModel = .constant
        material.transparency = 0.45
        // Do not write depth. Overlapping mesh blocks otherwise punch holes in
        // each other where they interpenetrate, which they constantly do.
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
        return material
    }

    private static func coverageMaterial() -> SCNMaterial {
        let material = Self.material(color: UIColor(red: 0.30, green: 0.78, blue: 0.94, alpha: 1))
        // Wireframe for the plain style: a filled overlay hides the very thing
        // the viewfinder is for. The grid reads as coverage without obscuring
        // what is being scanned.
        material.fillMode = .lines
        material.transparency = 0.6
        return material
    }
}
