import SceneKit
import SwiftUI
import simd

/// Look at the result, and fix it, before it becomes a deliverable.
///
/// Without this the only way to find out what a scan produced was to export it,
/// move the file to a computer, and open it there — and if it was wrong, walk
/// back to site. A scan always contains things nobody asked for: the doorway
/// you entered through, the corridor beyond it, half a colleague, whatever the
/// sensor caught over a parapet. All of it was genuinely measured, so no
/// automatic rule removes it; it needs a person who knows what the job was.
///
/// Orbiting is `SCNView.allowsCameraControl`, which is a complete gesture set —
/// orbit, pan, pinch, double-tap to frame — for one line. Writing a camera
/// controller to get worse behaviour would be an odd way to spend a week.
struct ModelViewer: View {
    let original: TsdfVolume.Mesh
    /// Called with the edited mesh when the user accepts.
    let onExport: (TsdfVolume.Mesh) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var edited: TsdfVolume.Mesh
    @State private var history: [TsdfVolume.Mesh] = []
    @State private var crop: MeshEditing.Bounds
    @State private var fullExtent: MeshEditing.Bounds
    @State private var showCropControls = false
    @State private var tapToDelete = false

    init(mesh: TsdfVolume.Mesh, onExport: @escaping (TsdfVolume.Mesh) -> Void) {
        original = mesh
        self.onExport = onExport
        let extent = MeshEditing.bounds(of: mesh)
            ?? .init(minimum: .zero, maximum: SIMD3(repeating: 1))
        _edited = State(initialValue: mesh)
        _crop = State(initialValue: extent)
        _fullExtent = State(initialValue: extent)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                SceneMeshView(
                    mesh: edited,
                    cropBox: showCropControls ? crop : nil,
                    onTap: tapToDelete ? deleteComponent(at:) : nil
                )
                .ignoresSafeArea(edges: .bottom)

                controls
            }
            .background(Theme.Palette.background)
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Export") {
                        onExport(edited)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: Theme.Metrics.gutterTight) {
            statistics

            if showCropControls { cropSliders }

            HStack(spacing: Theme.Metrics.gutterTight) {
                toolButton(
                    "Crop", systemImage: "crop", active: showCropControls
                ) {
                    showCropControls.toggle()
                }
                toolButton(
                    "Tap to delete", systemImage: "hand.tap", active: tapToDelete
                ) {
                    tapToDelete.toggle()
                }
                toolButton("Largest only", systemImage: "square.stack.3d.up") {
                    apply { MeshEditing.keepLargestComponent($0) }
                }
                toolButton("Undo", systemImage: "arrow.uturn.backward") {
                    undo()
                }
                .disabled(history.isEmpty)
            }
        }
        .padding(Theme.Metrics.gutter)
        .background(.ultraThinMaterial)
    }

    private var statistics: some View {
        let triangles = edited.indices.count / 3
        let pieces = MeshEditing.componentCount(edited)
        return HStack(spacing: Theme.Metrics.gutter) {
            Readout(label: "Triangles", value: "\(triangles)")
            Readout(label: "Pieces", value: "\(pieces)")
            // Estimated at 12 bytes of position, 12 of normal and 3 of colour
            // per vertex plus indices — near enough to tell a 3 MB file from a
            // 300 MB one, which is the decision being made here.
            Readout(label: "About", value: sizeEstimate)
            Spacer()
        }
    }

    private var sizeEstimate: String {
        let bytes = edited.positions.count * 27 + edited.indices.count * 4
        let megabytes = Double(bytes) / 1_000_000
        return megabytes < 1
            ? String(format: "%.0f KB", Double(bytes) / 1000)
            : String(format: "%.1f MB", megabytes)
    }

    /// Six sliders rather than a draggable 3D box.
    ///
    /// A gizmo looks better in a demo and is worse to use: on a phone, dragging
    /// a handle in perspective is imprecise, and a crop is usually being set to
    /// a known line — the face of a wall, a gridline, the edge of a slab.
    /// Sliders can be nudged to a number and do not fight the orbit gesture for
    /// the same touch.
    private var cropSliders: some View {
        VStack(spacing: 4) {
            axisSlider("X", min: fullExtent.minimum.x, max: fullExtent.maximum.x,
                       low: $crop.minimum.x, high: $crop.maximum.x)
            axisSlider("Y", min: fullExtent.minimum.y, max: fullExtent.maximum.y,
                       low: $crop.minimum.y, high: $crop.maximum.y)
            axisSlider("Z", min: fullExtent.minimum.z, max: fullExtent.maximum.z,
                       low: $crop.minimum.z, high: $crop.maximum.z)

            HStack {
                Button("Reset") { crop = fullExtent }
                    .font(Theme.Typeface.caption)
                Spacer()
                Button("Apply crop") {
                    apply { MeshEditing.crop($0, to: crop) }
                    showCropControls = false
                }
                .font(Theme.Typeface.label(14, weight: .semibold))
                Button("Delete inside") {
                    apply { MeshEditing.erase($0, within: crop) }
                    showCropControls = false
                }
                .font(Theme.Typeface.label(14, weight: .semibold))
                .foregroundStyle(Theme.Palette.bad)
            }
            .padding(.top, 2)
        }
    }

    private func axisSlider(
        _ label: String,
        min lower: Float,
        max upper: Float,
        low: Binding<Float>,
        high: Binding<Float>
    ) -> some View {
        // A degenerate range makes Slider misbehave, and a scan can be flat in
        // one axis — a floor slab is exactly that.
        let span = Swift.max(upper - lower, 0.001)
        return HStack(spacing: 8) {
            Text(label)
                .font(Theme.Typeface.numeric(12))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 12)
            Slider(value: low, in: lower...(lower + span))
                .onChange(of: low.wrappedValue) { _, value in
                    if value > high.wrappedValue { high.wrappedValue = value }
                }
            Slider(value: high, in: lower...(lower + span))
                .onChange(of: high.wrappedValue) { _, value in
                    if value < low.wrappedValue { low.wrappedValue = value }
                }
            Text(String(format: "%.2f m", high.wrappedValue - low.wrappedValue))
                .font(Theme.Typeface.numeric(12))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 56, alignment: .trailing)
        }
    }

    private func toolButton(
        _ title: String,
        systemImage: String,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                Text(title)
                    .font(Theme.Typeface.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .foregroundStyle(active ? Theme.Palette.background : Theme.Palette.text)
            .background(
                active ? Theme.Palette.accent : Theme.Palette.surface,
                in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius)
            )
        }
    }

    // MARK: - Edits

    /// Every edit goes through here so undo is not something to remember to
    /// wire up per action. Deleting the wrong piece is a certainty, and without
    /// undo the recovery is to re-run fusion — minutes on a real capture.
    private func apply(_ transform: (TsdfVolume.Mesh) -> TsdfVolume.Mesh) {
        let next = transform(edited)
        guard next.indices.count != edited.indices.count else { return }
        history.append(edited)
        edited = next
    }

    private func undo() {
        guard let previous = history.popLast() else { return }
        edited = previous
    }

    private func deleteComponent(at point: SIMD3<Float>) {
        guard let vertex = MeshEditing.nearestVertex(in: edited, to: point) else { return }
        apply { MeshEditing.removeComponent(of: $0, containing: vertex) }
    }
}
