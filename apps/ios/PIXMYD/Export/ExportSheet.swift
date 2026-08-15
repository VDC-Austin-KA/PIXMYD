import SwiftUI
import UniformTypeIdentifiers

/// Export a captured project.
///
/// The sheet processes on device — fuse the depth frames, extract a surface or
/// a point cloud, write the file — and reports progress honestly, including how
/// long it is likely to take. Nothing is uploaded anywhere.
struct ExportSheet: View {
    let project: CaptureProject

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ProjectStore
    @StateObject private var processor = ProcessingPipeline()
    @State private var format: ExportFormat = .glb
    @State private var quality: ProcessingPipeline.Quality = .balanced
    // Standard by default. The raw output of fusion is not a sensible
    // deliverable — it is hundreds of megabytes of mostly-flat triangles and
    // floating specks — so "no cleanup" is the deliberate choice, not the
    // default anyone lands on by accident.
    @State private var cleanup: ProcessingPipeline.Cleanup = .standard
    @State private var exportedURLs: [URL]?
    @State private var showShare = false
    /// Look at the result before writing it. On by default for meshes: the
    /// whole complaint was not being able to tell what a scan produced without
    /// exporting it and opening it somewhere else.
    @State private var reviewFirst = true
    /// True until the user touches Detail or Cleanup, so the defaults can be
    /// taken from how the scan was captured without overwriting a deliberate
    /// choice on a later re-render.
    @State private var usingCaptureDefaults = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Metrics.gutter) {
                    formatPicker

                    if !format.isAvailable {
                        unavailableBridge
                    } else {
                        qualityPicker
                        // Only meshes are decimated. A point cloud has no
                        // topology to collapse, so offering the control there
                        // would promise a reduction that never arrives.
                        if format.kind == .mesh {
                            cleanupPicker
                            reviewToggle
                        }
                        progress
                    }
                }
                .padding(Theme.Metrics.gutter)
            }
            .background(Theme.Palette.background)
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: adoptCaptureDefaults)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        processor.cancel()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showShare) {
                if let exportedURLs {
                    ShareSheet(items: exportedURLs.map { $0 as Any })
                }
            }
            .fullScreenCover(isPresented: reviewBinding) {
                if let mesh = processor.reviewMesh {
                    ModelViewer(mesh: mesh) { edited in
                        processor.exportReviewed(
                            mesh: edited,
                            project: project,
                            format: format,
                            quality: quality,
                            integratedFrames: project.frameCount
                        )
                    }
                }
            }
            .onChange(of: processor.state) { _, newState in
                // The project list shows whether a capture ever got processed,
                // so the sheet reports its outcome back to the store.
                switch newState {
                case .running:
                    store.setState(.processing, for: project)
                case .finished:
                    store.setState(.processed, for: project)
                case .failed:
                    store.setState(.failed, for: project)
                default:
                    break
                }
            }
        }
    }

    /// Start from the mode the scan was captured in.
    ///
    /// A scan of a valve taken in Object mode defaulting to 25 mm voxels and
    /// room-sized noise removal would come out smoothed away, and the person
    /// exporting it has no reason to suspect the default was wrong for it.
    private func adoptCaptureDefaults() {
        guard usingCaptureDefaults, let mode = project.scanMode else { return }
        quality = ProcessingPipeline.Quality.matching(voxelSize: mode.voxelSize)
        cleanup = ProcessingPipeline.Cleanup.matching(keepFraction: mode.keepFraction)
        usingCaptureDefaults = false
    }

    /// Presented from the pipeline's own state rather than a separate flag, so
    /// the viewer cannot be showing while the pipeline thinks it is idle.
    /// Dismissing it — cancelling the review — returns the pipeline to idle.
    private var reviewBinding: Binding<Bool> {
        Binding(
            get: {
                if case .reviewing = processor.state { return true }
                return false
            },
            set: { presented in
                if !presented, case .reviewing = processor.state { processor.cancel() }
            }
        )
    }

    private var reviewToggle: some View {
        Panel {
            Toggle(isOn: $reviewFirst) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review before exporting")
                        .font(Theme.Typeface.label(15, weight: .medium))
                    Text("Look at the mesh, crop it, and delete stray pieces. "
                         + "Nothing is written until you accept.")
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Theme.Palette.accent)
        }
    }

    private var formatPicker: some View {
        Panel(title: "Format") {
            VStack(spacing: 0) {
                ForEach(ExportFormat.allCases) { candidate in
                    Button {
                        format = candidate
                    } label: {
                        HStack(alignment: .top, spacing: Theme.Metrics.gutterTight) {
                            Image(systemName: format == candidate
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(format == candidate
                                                 ? Theme.Palette.accent : Theme.Palette.textTertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(candidate.title)
                                        .font(Theme.Typeface.label(15, weight: .semibold))
                                        .foregroundStyle(Theme.Palette.text)
                                    if !candidate.isAvailable {
                                        StatusChip(text: candidate.via, tone: .caution)
                                    }
                                }
                                Text(candidate.detail)
                                    .font(Theme.Typeface.caption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    if candidate != ExportFormat.allCases.last {
                        Divider().overlay(Theme.Palette.hairline)
                    }
                }
            }
        }
    }

    private var cleanupPicker: some View {
        Panel(title: "Cleanup") {
            VStack(alignment: .leading, spacing: Theme.Metrics.gutterTight) {
                Picker("Cleanup", selection: $cleanup) {
                    ForEach(ProcessingPipeline.Cleanup.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)

                Text(cleanup.detail)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var qualityPicker: some View {
        Panel(title: "Detail") {
            VStack(alignment: .leading, spacing: Theme.Metrics.gutterTight) {
                Picker("Detail", selection: $quality) {
                    ForEach(ProcessingPipeline.Quality.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)

                Text(quality.detail)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // An honest estimate, derived from the frame count. Users make
                // a different choice when they know it is eight minutes.
                Text(estimate)
                    .font(Theme.Typeface.numeric(12))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }

    private var progress: some View {
        VStack(spacing: Theme.Metrics.gutter) {
            if case .running(let stage, let fraction) = processor.state {
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(stage)
                                .font(Theme.Typeface.label(14, weight: .medium))
                                .foregroundStyle(Theme.Palette.text)
                            Spacer()
                            Text("\(Int(fraction * 100))%")
                                .font(Theme.Typeface.numeric(14))
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        ProgressView(value: fraction)
                            .tint(Theme.Palette.accent)
                    }
                }
                FieldButton(title: "Cancel", role: .destructive) { processor.cancel() }
            } else if case .failed(let message) = processor.state {
                Panel {
                    Label {
                        Text(message)
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    } icon: {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundStyle(Theme.Palette.bad)
                    }
                }
                FieldButton(title: "Try again", systemImage: "arrow.clockwise", role: .primary) {
                    run()
                }
            } else if case .finished(let urls, let summary) = processor.state {
                Panel(title: "Done") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(summary)
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        if urls.count > 1 {
                            // An OBJ export is the mesh plus its .mtl and .png
                            // sidecars; the share sheet carries all of them so
                            // the trio arrives on the other machine together.
                            Text("\(urls.count) files")
                                .font(Theme.Typeface.caption)
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                    }
                }
                FieldButton(title: "Share", systemImage: "square.and.arrow.up", role: .primary) {
                    exportedURLs = urls
                    showShare = true
                }
            } else {
                FieldButton(title: "Process and export", systemImage: "gearshape.2", role: .primary) {
                    run()
                }
            }
        }
    }

    private var rcsBridge: some View {
        VStack(spacing: Theme.Metrics.gutter) {
            Panel(title: "Why not directly") {
                Text(RcsBridge.explanation)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(RcsBridge.routes, id: \.name) { route in
                Panel(title: route.name) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Needs \(route.requires)")
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                        ForEach(Array(route.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1).")
                                    .font(Theme.Typeface.numeric(12))
                                    .foregroundStyle(Theme.Palette.textTertiary)
                                Text(step)
                                    .font(Theme.Typeface.caption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            FieldButton(title: "Export E57 instead", systemImage: "arrow.right", role: .primary) {
                format = .e57
            }
        }
    }

    /// The bridge panel for whichever proprietary format was picked. Both
    /// unavailable formats explain honestly and point at the export that
    /// actually works.
    private var unavailableBridge: some View {
        if format == .rcs {
            rcsBridge
        } else {
            nwcBridge
        }
    }

    private var nwcBridge: some View {
        VStack(spacing: Theme.Metrics.gutter) {
            Panel(title: "Why not directly") {
                Text(NwcBridge.explanation)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(NwcBridge.routes, id: \.name) { route in
                Panel(title: route.name) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Needs \(route.requires)")
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                        ForEach(Array(route.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1).")
                                    .font(Theme.Typeface.numeric(12))
                                    .foregroundStyle(Theme.Palette.textTertiary)
                                Text(step)
                                    .font(Theme.Typeface.caption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            FieldButton(title: "Export FBX instead", systemImage: "arrow.right", role: .primary) {
                format = .fbx
            }
        }
    }

    private var estimate: String {
        let seconds = processor.estimatedSeconds(frameCount: project.frameCount, quality: quality)
        if seconds < 60 { return "Roughly \(Int(seconds)) s on this device." }
        return String(format: "Roughly %.0f min on this device.", seconds / 60)
    }

    private func run() {
        processor.run(
            project: project,
            format: format,
            quality: quality,
            cleanup: cleanup,
            // Only meshes can be reviewed — the viewer renders triangles, and a
            // point cloud has none.
            reviewFirst: reviewFirst && format.kind == .mesh
        )
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
