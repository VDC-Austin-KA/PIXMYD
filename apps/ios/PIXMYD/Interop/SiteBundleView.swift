import SwiftUI

// One point set: its points, what has been located, and how well the two
// frames currently agree.
//
// The alignment readout is the reason this screen exists rather than a plain
// list. `capture.md` requires the consumer to show `rmsError`, `maxError`,
// `accuracyGrade` and the outlier count before anything is committed, and the
// operator is far better off seeing that while still standing next to the
// marks than at a desk an hour later.

struct SiteBundleView: View {
    let bundle: StoredNavBundle

    @EnvironmentObject private var site: SiteStore
    @EnvironmentObject private var projects: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @State private var uploading = false
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Metrics.gutter) {
                provenance
                if let set = bundle.pointSet {
                    alignment(set)
                    points(set)
                }
                if let ar = bundle.arBundle {
                    model(ar)
                }
                FieldButton(title: "Remove from this device", systemImage: "trash", role: .destructive) {
                    confirmingDelete = true
                }
            }
            .padding(Theme.Metrics.gutter)
        }
        .background(Theme.Palette.background)
        .navigationTitle(bundle.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $uploading) {
            if let set = bundle.pointSet {
                CaptureSendView(pointSet: set)
            }
        }
        .confirmationDialog(
            "Remove \(bundle.displayName)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                site.delete(bundle)
                dismiss()
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The points and any positions located against them are deleted from this phone. "
               + "The model in Navisworks is untouched.")
        }
    }

    // MARK: - Sections

    private var provenance: some View {
        let p = bundle.pointSet?.provenance ?? bundle.arBundle?.provenance
        return Panel(title: "Source") {
            if let p {
                Text(p.sourceDocument.isEmpty ? "Unnamed model" : p.sourceDocument)
                    .font(Theme.Typeface.body)
                    .foregroundStyle(Theme.Palette.text)
                HStack(spacing: Theme.Metrics.gutter) {
                    Readout(label: "Units", value: p.targetUnits)
                    Readout(label: "Up axis", value: p.upAxis)
                }
                if !p.isMetric {
                    // The contract fixes target units at metres. Anything else
                    // is a producer bug, and a silent 3.28x is the worst
                    // possible way to find out about it.
                    Text("This export is not in metres. Coordinates will not line up with a scan "
                       + "until it is re-exported.")
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Offset back to model coordinates: "
                   + p.appliedOffset.map { String(format: "%.3f", $0) }.joined(separator: ", "))
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }

    private func alignment(_ set: NavPointSet) -> some View {
        Panel(title: "Alignment") {
            let located = site.observedCount(setId: set.setId)
            Text("\(located) of \(set.points.count) points located in the room.")
                .font(Theme.Typeface.body)
                .foregroundStyle(Theme.Palette.text)

            switch site.solve(for: set) {
            case let .success(solved)?:
                HStack(spacing: Theme.Metrics.gutter) {
                    Readout(
                        label: "RMS",
                        value: String(format: "%.0f", solved.solution.rmsError * 1000),
                        unit: "mm",
                        tone: tone(for: solved.grade.band)
                    )
                    Readout(
                        label: "Max",
                        value: String(format: "%.0f", solved.solution.maxError * 1000),
                        unit: "mm",
                        tone: tone(for: solved.grade.band)
                    )
                    Readout(label: "Points", value: "\(solved.solution.pairCount)")
                }
                StatusChip(text: solved.grade.label, tone: tone(for: solved.grade.band), systemImage: "target")
                Text(solved.grade.guidance)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !solved.outlierPointIds.isEmpty {
                    Text("Suspect: \(solved.outlierPointIds.joined(separator: ", ")). "
                       + "Re-locate these before sending anything back.")
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }

            case let .failure(error)?:
                // The solver's own wording. "Needs at least 3 points" is
                // actionable; "alignment failed" is not.
                Text(String(describing: error))
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.caution)
                    .fixedSize(horizontal: false, vertical: true)

            case nil:
                Text("Locate at least three points to tie this model to the room.")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            FieldButton(title: "Send a scan back", systemImage: "arrow.up.doc", role: .primary) {
                uploading = true
            }
            .disabled(projects.projects.isEmpty)
            .opacity(projects.projects.isEmpty ? 0.5 : 1)
        }
    }

    private func points(_ set: NavPointSet) -> some View {
        VStack(spacing: Theme.Metrics.gutterTight) {
            ForEach(set.points) { point in
                NavigationLink {
                    NavPointDetailView(bundle: bundle, point: point)
                } label: {
                    NavPointRow(
                        point: point,
                        observed: site.observation(setId: set.setId, pointId: point.id) != nil
                    )
                }
                .buttonStyle(.plain)
            }
            if set.points.isEmpty {
                Panel {
                    Text("This set has no points in it yet.")
                        .font(Theme.Typeface.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
    }

    private func model(_ ar: NavArBundle) -> some View {
        Panel(title: "Model bundle") {
            Text(ar.name.isEmpty ? ar.bundleId : ar.name)
                .font(Theme.Typeface.body)
                .foregroundStyle(Theme.Palette.text)
            if let bounds = ar.bounds, bounds.max.count == 3, bounds.min.count == 3 {
                let size = (0..<3).map { bounds.max[$0] - bounds.min[$0] }
                Text("Extent " + size.map { String(format: "%.1f", $0) }.joined(separator: " × ") + " m")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            if !ar.hasGeometry {
                Text("No geometry was exported with this bundle, so the model cannot be drawn over "
                   + "the room. The box and the reference photo still show where it is.")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let image = bundle.file(ar.image), let ui = UIImage(contentsOfFile: image.path) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall))
            }
        }
    }

    private func tone(for band: AccuracyBand) -> Readout.Tone {
        switch band {
        case .layout, .penetrations: return .good
        case .dimensionalControl, .coordination: return .caution
        case .context, .unusable: return .bad
        }
    }
}

// MARK: - Row

private struct NavPointRow: View {
    let point: NavPoint
    let observed: Bool

    var body: some View {
        Panel {
            HStack(spacing: Theme.Metrics.gutter) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(point.id)
                        .font(Theme.Typeface.label(15, weight: .semibold))
                        .foregroundStyle(Theme.Palette.text)
                    if !point.label.isEmpty {
                        Text(point.label)
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    if let grid = point.grid.summary {
                        Text(grid)
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                Spacer()
                if observed {
                    StatusChip(text: "Located", tone: .good, systemImage: "checkmark")
                }
                Image(systemName: "chevron.right")
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }
}
