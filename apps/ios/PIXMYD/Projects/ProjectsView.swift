import MapKit
import SwiftUI

/// The project list: search, filter, and a map of where captures were taken.
struct ProjectsView: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var router: AppRouter
    @State private var showMap = false
    @State private var selected: CaptureProject?
    @State private var renaming: CaptureProject?
    @State private var newName = ""

    var body: some View {
        NavigationStack(path: $router.path) {
            VStack(spacing: 0) {
                filterBar

                if store.visible.isEmpty {
                    empty
                } else {
                    List {
                        ForEach(store.visible) { project in
                            NavigationLink(value: project) {
                                ProjectRow(project: project)
                            }
                            .listRowBackground(Theme.Palette.surface)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.delete(project)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    renaming = project
                                    newName = project.name
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(Theme.Palette.accent)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.Palette.background)
            .navigationTitle("Projects")
            .navigationDestination(for: CaptureProject.self) { ProjectDetailView(id: $0.id) }
            .searchable(text: $store.searchText, prompt: "Search projects")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(store.visible.count)")
                        .font(Theme.Typeface.numeric(15))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .alert("Rename project", isPresented: .constant(renaming != nil)) {
                TextField("Name", text: $newName)
                Button("Rename") {
                    if let renaming { store.rename(renaming, to: newName) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Metrics.gutterTight) {
                ForEach(ProjectStore.Filter.allCases) { filter in
                    Button {
                        store.filter = filter
                    } label: {
                        Text(filter.label)
                            .font(Theme.Typeface.label(14, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .foregroundStyle(store.filter == filter ? .black : Theme.Palette.text)
                            .background(
                                store.filter == filter ? Theme.Palette.accent : Theme.Palette.surfaceRaised,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Metrics.gutter)
            .padding(.vertical, Theme.Metrics.gutterTight)
        }
    }

    private var empty: some View {
        VStack(spacing: Theme.Metrics.gutter) {
            Spacer()
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(store.searchText.isEmpty ? "No captures yet" : "No matches")
                .font(Theme.Typeface.title)
                .foregroundStyle(Theme.Palette.text)
            Text(store.searchText.isEmpty
                 ? "Captures you record appear here, and stay on this device until you export them."
                 : "Nothing matches “\(store.searchText)”.")
                .font(Theme.Typeface.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Metrics.gutter * 2)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct ProjectRow: View {
    let project: CaptureProject

    var body: some View {
        HStack(spacing: Theme.Metrics.gutter) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(Theme.Typeface.label(16, weight: .medium))
                    .foregroundStyle(Theme.Palette.text)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Text(project.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text("\(project.frameCount) frames")
                    if project.hasDepth {
                        Text("·")
                        Text("LiDAR")
                    }
                }
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                StatusChip(text: project.state.label, tone: project.state.tone)
                if let rms = project.registrationRms {
                    // A registered project always shows what the registration
                    // was worth, in the list, not two taps away.
                    Text(String(format: "±%.0f mm", rms * 1000))
                        .font(Theme.Typeface.numeric(11))
                        .foregroundStyle(AccuracyBand.of(rms).tone.color)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Detail

struct ProjectDetailView: View {
    let id: String
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var router: AppRouter
    @StateObject private var processor = ProcessingPipeline()
    @State private var showExport = false

    private var project: CaptureProject? {
        store.projects.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let project {
                detail(project)
            } else {
                ContentUnavailableView(
                    "Project not found",
                    systemImage: "questionmark.folder",
                    description: Text("It may have been deleted.")
                )
                .background(Theme.Palette.background)
            }
        }
        .navigationTitle(project?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ project: CaptureProject) -> some View {
        ScrollView {
            VStack(spacing: Theme.Metrics.gutter) {
                Panel(title: "Capture") {
                    HStack(spacing: Theme.Metrics.gutter * 1.4) {
                        Readout(label: "Frames", value: "\(project.frameCount)")
                        Readout(
                            label: "Depth",
                            value: project.hasDepth ? "LiDAR" : "None",
                            tone: project.hasDepth ? .good : .caution
                        )
                        Readout(label: "Size", value: project.formattedSize)
                    }
                }

                Panel(title: "Georeference") {
                    if let rms = project.registrationRms {
                        let band = AccuracyBand.of(rms)
                        VStack(alignment: .leading, spacing: Theme.Metrics.gutterTight) {
                            HStack {
                                Readout(
                                    label: "RMS residual",
                                    value: String(format: "%.1f", rms * 1000),
                                    unit: "mm",
                                    tone: band.tone
                                )
                                Spacer()
                                StatusChip(text: band.label, tone: band.tone)
                            }
                            Text(band.guidance)
                                .font(Theme.Typeface.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("Not registered to control. Coordinates are local to the capture, "
                             + "with an arbitrary origin and heading.")
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                actions(project)
            }
            .padding(Theme.Metrics.gutter)
        }
        .background(Theme.Palette.background)
        .sheet(isPresented: $showExport) {
            ExportSheet(project: project)
        }
        .onChange(of: processor.state) { _, newState in
            report(newState, for: project)
        }
        .onAppear {
            if router.reviewRequest?.project.id == id {
                router.clearReviewRequest(projectID: id)
                viewProject(project)
            }
        }
        .fullScreenCover(isPresented: reviewBinding) {
            if let mesh = processor.reviewMesh {
                ModelViewer(mesh: mesh) { edited in
                    processor.saveReviewed(mesh: edited, project: project)
                }
            }
        }
    }

    private func actions(_ project: CaptureProject) -> some View {
        VStack(spacing: Theme.Metrics.gutterTight) {
            HStack(spacing: Theme.Metrics.gutterTight) {
                FieldButton(
                    title: "View",
                    systemImage: "eye.fill",
                    role: project.state == .processing ? .secondary : .primary
                ) {
                    if project.state != .processing { viewProject(project) }
                }
                FieldButton(
                    title: "Duplicate",
                    systemImage: "plus.square.on.square",
                    role: .secondary
                ) {
                    store.duplicate(project)
                }
            }

            // A failed result is re-runnable, and a processed one can be
            // rebuilt from the raw frames when the saved result is wrong.
            if project.state == .failed || project.state == .processed {
                FieldButton(title: "Reprocess", systemImage: "arrow.clockwise", role: .secondary) {
                    processor.run(
                        project: project,
                        format: .glb,
                        quality: matchingQuality(for: project),
                        cleanup: .standard,
                        reviewFirst: true,
                        reprocess: true
                    )
                }
            }

            FieldButton(title: "Export", systemImage: "square.and.arrow.up", role: .primary) {
                showExport = true
            }
        }
    }

    /// Open the result for inspection. If a result was already processed it
    /// is reused; otherwise the capture is processed first.
    private func viewProject(_ project: CaptureProject) {
        processor.run(
            project: project,
            format: .glb,
            quality: matchingQuality(for: project),
            cleanup: .standard,
            reviewFirst: true
        )
    }

    private func matchingQuality(for project: CaptureProject) -> ProcessingPipeline.Quality {
        if let mode = project.scanMode {
            return ProcessingPipeline.Quality.matching(voxelSize: mode.voxelSize)
        }
        return .balanced
    }

    /// Keep the list's state chips honest. The pipeline is not visible from
    /// the list, so it reports its progress back to the store instead.
    private func report(_ newState: ProcessingPipeline.State, for project: CaptureProject) {
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

    /// Presented from the pipeline's own state so the viewer cannot outlive
    /// the processing run that produced it.
    private var reviewBinding: Binding<Bool> {
        Binding(
            get: {
                if case .reviewing = processor.state { return true }
                return false
            },
            set: { presented in
                if !presented, case .reviewing = processor.state {
                    processor.cancel()
                    if let project { store.setState(.processed, for: project) }
                }
            }
        )
    }
}

/// Construction tolerance bands, mirroring `classifyAccuracy` in
/// `packages/geo/src/registration.ts`. The wording is deliberately the same on
/// both sides so a number means the same thing on the phone and in the studio.
/// The cases themselves live with the registration code in `Geo/Registration.swift`.
extension AccuracyBand {
    static func of(_ rms: Double) -> AccuracyBand {
        guard rms.isFinite, rms >= 0 else { return .unusable }
        if rms <= 0.003 { return .layout }
        if rms <= 0.006 { return .penetrations }
        if rms <= 0.010 { return .dimensionalControl }
        if rms <= 0.050 { return .coordination }
        if rms <= 0.250 { return .context }
        return .unusable
    }

    var label: String {
        switch self {
        case .layout: "Layout"
        case .penetrations: "Sleeves"
        case .dimensionalControl: "Dimensional control"
        case .coordination: "Coordination"
        case .context: "Context only"
        case .unusable: "Unusable"
        }
    }

    var tone: Readout.Tone {
        switch self {
        case .layout, .penetrations, .dimensionalControl: .good
        case .coordination: .caution
        case .context, .unusable: .bad
        }
    }

    var guidance: String {
        switch self {
        case .layout:
            "Within point layout tolerance. Verify against an instrument before "
                + "laying out from it — this is a fit statistic, not an independent check."
        case .penetrations:
            "Good enough to place sleeves and penetrations. Not for point layout."
        case .dimensionalControl:
            "Good enough to confirm installed work against the model. "
                + "Not a substitute for layout instruments."
        case .coordination:
            "Usable for clash checking and coordination. Do not measure installed "
                + "positions from it."
        case .context:
            "Shows roughly what is where. Wayfinding and zone identification only."
        case .unusable:
            "Past any construction use. Check for a wrong zone, a wrong unit, or a "
                + "mis-keyed control point."
        }
    }
}
