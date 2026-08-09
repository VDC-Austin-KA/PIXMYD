import MapKit
import SwiftUI

/// The project list: search, filter, and a map of where captures were taken.
struct ProjectsView: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var showMap = false
    @State private var selected: CaptureProject?
    @State private var renaming: CaptureProject?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
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
            .navigationDestination(for: CaptureProject.self) { ProjectDetailView(project: $0) }
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
    let project: CaptureProject
    @EnvironmentObject private var store: ProjectStore
    @State private var showExport = false

    var body: some View {
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

                FieldButton(title: "Export", systemImage: "square.and.arrow.up", role: .primary) {
                    showExport = true
                }
            }
            .padding(Theme.Metrics.gutter)
        }
        .background(Theme.Palette.background)
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showExport) {
            ExportSheet(project: project)
        }
    }
}

/// Construction tolerance bands, mirroring `classifyAccuracy` in
/// `packages/geo/src/registration.ts`. The wording is deliberately the same on
/// both sides so a number means the same thing on the phone and in the studio.
enum AccuracyBand {
    case layout, penetrations, dimensionalControl, coordination, context, unusable

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
