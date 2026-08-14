import SwiftUI

// One point: where the model says it is, what it looks like, and where it has
// been found in the room.
//
// `points.md` puts a photo and grid text on every point precisely so a human
// can place it when no marker is available — a marker knocked off a column is
// the normal case on a live site, not an edge case. So this screen has to work
// as a manual placement aid on its own, with the scan path as the shortcut
// rather than the requirement.

struct NavPointDetailView: View {
    let bundle: StoredNavBundle
    let point: NavPoint

    @EnvironmentObject private var site: SiteStore
    @State private var aligning = false

    private var setId: String { bundle.pointSet?.setId ?? bundle.id }
    private var observed: SIMD3<Double>? {
        site.observation(setId: setId, pointId: point.id)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Metrics.gutter) {
                photo
                position
                located
                actions
            }
            .padding(Theme.Metrics.gutter)
        }
        .background(Theme.Palette.background)
        .navigationTitle(point.id)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $aligning) {
            MarkerAlignView(point: point, bundle: bundle) { position in
                site.record(setId: setId, pointId: point.id, observed: position)
            }
        }
    }

    private var photo: some View {
        Group {
            if let image = bundle.file(point.viewpoint?.image),
               let ui = UIImage(contentsOfFile: image.path) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius)
                            .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
                    )
            } else if point.viewpoint != nil {
                // The JSON names a photo that is not in the folder. Say so
                // once and carry on — this must not stop the point being used.
                Panel {
                    Text("The reference photo for this point did not come across with the export.")
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var position: some View {
        Panel(title: "In the model") {
            if !point.label.isEmpty {
                Text(point.label)
                    .font(Theme.Typeface.title)
                    .foregroundStyle(Theme.Palette.text)
            }
            if let grid = point.grid.summary {
                Text(grid)
                    .font(Theme.Typeface.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                if point.grid.distance > 0 {
                    Text(String(format: "%.0f mm from the grid intersection", point.grid.distance * 1000))
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            } else {
                Text("No grid system was loaded when this was exported, so there is no grid "
                   + "reference. Use the photo and the coordinates.")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Theme.Metrics.gutter) {
                Readout(label: "E", value: String(format: "%.3f", coordinate(0)), unit: "m")
                Readout(label: "N", value: String(format: "%.3f", coordinate(1)), unit: "m")
                Readout(label: "Z", value: String(format: "%.3f", coordinate(2)), unit: "m")
            }

            if let provenance = bundle.pointSet?.provenance {
                let world = provenance.toSourceWorld(point.position)
                Text("Model world: " + world.map { String(format: "%.3f", $0) }.joined(separator: ", "))
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }

    private var located: some View {
        Panel(title: "In the room") {
            if let observed {
                Text("Located.")
                    .font(Theme.Typeface.body)
                    .foregroundStyle(Theme.Palette.good)
                Text(String(format: "%.3f, %.3f, %.3f", observed.x, observed.y, observed.z))
                    .font(Theme.Typeface.numeric(13))
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text("Recorded in the capture frame. It is the pairing with the model coordinate "
                   + "above that gets the scan back into Navisworks.")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Not located yet. Aim at the mark on the real column and record it.")
                    .font(Theme.Typeface.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: Theme.Metrics.gutterTight) {
            FieldButton(
                title: observed == nil ? "Locate this point" : "Locate again",
                systemImage: "scope",
                role: .primary
            ) {
                aligning = true
            }
            if observed != nil {
                FieldButton(title: "Clear this position", systemImage: "xmark", role: .destructive) {
                    site.clearObservation(setId: setId, pointId: point.id)
                }
            }
        }
    }

    private func coordinate(_ index: Int) -> Double {
        point.position.count > index ? point.position[index] : 0
    }
}
