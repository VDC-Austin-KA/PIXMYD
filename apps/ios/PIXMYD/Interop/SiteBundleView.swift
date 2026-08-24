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
    @State private var placing = false
    @State private var showingModel = false

    /// The bundle as the store currently holds it.
    ///
    /// Not the one the navigation link handed over: placing a mark rewrites
    /// the set on disk and reloads the list, and a screen rendering from the
    /// captured value would go on showing the point count it was opened with.
    /// Falling back to that value keeps the screen readable for the moment
    /// between a delete and the dismiss that follows it.
    private var current: StoredNavBundle {
        site.bundles.first { $0.id == bundle.id } ?? bundle
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Metrics.gutter) {
                provenance
                if let set = current.pointSet {
                    if set.isCaptureFrame {
                        placedHere(set)
                    } else {
                        alignment(set)
                    }
                    points(set)
                }
                if let ar = current.arBundle {
                    model(ar)
                }
                FieldButton(title: "Remove from this device", systemImage: "trash", role: .destructive) {
                    confirmingDelete = true
                }
            }
            .padding(Theme.Metrics.gutter)
        }
        .background(Theme.Palette.background)
        .navigationTitle(current.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showingModel) {
            if let ar = current.arBundle {
                ArModelView(bundle: current, ar: ar)
            }
        }
        .fullScreenCover(isPresented: $placing) {
            PlacePointView(nextId: current.pointSet?.nextLocalPointId ?? "P001") { observed in
                // The bundle it returns is re-read from the store on the next
                // render, so the value here is genuinely unused.
                _ = try? site.placeLocalPoint(at: observed)
            }
        }
        .sheet(isPresented: $uploading) {
            if let set = current.pointSet {
                CaptureSendView(pointSet: set)
            }
        }
        .confirmationDialog(
            "Remove \(current.displayName)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                site.delete(current)
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
        let p = current.pointSet?.provenance ?? current.arBundle?.provenance
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

    /// The panel for a set this phone authored.
    ///
    /// No fit, no RMS, no grade — deliberately. These points *are* their own
    /// observations, so a solve against them is the identity with zero error,
    /// and printing "0 mm, excellent" beside a set nobody has registered yet
    /// would be the most reassuring lie the app could tell. The alignment
    /// becomes real once the same ids are picked on the model, which happens in
    /// Navisworks; what belongs here is how many marks there are and whether
    /// there are enough of them.
    private func placedHere(_ set: NavPointSet) -> some View {
        Panel(title: "Placed on this phone") {
            Text("\(set.points.count) point(s) placed in the room.")
                .font(Theme.Typeface.body)
                .foregroundStyle(Theme.Palette.text)

            if set.points.count < 3 {
                Text("Place at least three, spread out and not in a line. Two points leave the "
                   + "scan free to spin about the line between them; three fix it.")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.caution)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Enough to register the scan. Send it back, then in PIXMYD-Nav press "
                   + "Seed phone points and click each id on the model — the fit is computed "
                   + "there, where both frames finally exist at once.")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            FieldButton(title: "Place another point", systemImage: "mappin.and.ellipse") {
                placing = true
            }

            FieldButton(title: "Send a scan back", systemImage: "arrow.up.doc", role: .primary) {
                uploading = true
            }
            .disabled(projects.projects.isEmpty || set.points.isEmpty)
            .opacity(projects.projects.isEmpty || set.points.isEmpty ? 0.5 : 1)
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
                if set.isCaptureFrame {
                    // No detail screen for a mark placed here: it has no grid
                    // reference, no photo and no id to go and locate — that
                    // screen would be a Locate button that means nothing.
                    NavPointRow(point: point, observed: true)
                        .contextMenu {
                            Button("Remove \(point.id)", role: .destructive) {
                                try? site.removeLocalPoint(id: point.id)
                            }
                        }
                } else {
                    NavigationLink {
                        NavPointDetailView(bundle: current, point: point)
                    } label: {
                        NavPointRow(
                            point: point,
                            observed: site.observation(setId: set.setId, pointId: point.id) != nil
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            if set.points.isEmpty {
                Panel {
                    Text(emptyPointsText(set))
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
            if ar.hasGeometry {
                FieldButton(title: "Place it in the room", systemImage: "arkit", role: .primary) {
                    showingModel = true
                }
                Text(anchoringText)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No geometry was exported with this bundle, so the model cannot be drawn over "
                   + "the room. The box and the reference photo still show where it is. "
                   + "Re-export it from PIXMYD-Nav with \"Include model geometry\" ticked.")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let image = current.file(ar.image), let ui = UIImage(contentsOfFile: image.path) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall))
            }
        }
    }

    // Both of these are statements rather than ternaries inlined into a
    // `Text(...)`. A ternary choosing between two `+`-concatenated literals is
    // the exact shape that has now failed to type-check three times in this
    // app — see `hiddenSummary` in ReceiverScanView and the transfer bar's
    // strings. Cheap to hoist, and it stops being a build risk.

    private func emptyPointsText(_ set: NavPointSet) -> String {
        if set.isCaptureFrame {
            return "No marks placed yet. Aim at something you will recognise in the model, "
                 + "and tap."
        }
        return "This set has no points in it yet."
    }

    private var anchoringText: String {
        if current.pointSet == nil {
            return "There is no point set beside this model, so it can only be dropped by hand "
                 + "and nudged into place. That is enough to see where things are; it is not "
                 + "enough to measure against."
        }
        return "Anchor it on the points from this set: pick one, aim at the real thing, tap. "
             + "One anchor pins it, two turn it, three make the turn trustworthy."
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
