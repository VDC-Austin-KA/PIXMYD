import SwiftUI

/// The tools menu: tag detection, AR points, annotations.
///
/// Each entry states what it needs. A tool that silently does nothing because a
/// precondition is unmet is worse than one that is visibly unavailable with the
/// reason attached.
struct ToolsSheet: View {
    @ObservedObject var controller: ARSessionController
    @EnvironmentObject private var survey: SurveyStore
    @EnvironmentObject private var gnss: GnssManager
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Metrics.gutterTight) {
                    ToolRow(
                        title: "Automatic tag detection",
                        detail: "Finds coded targets in the frame and records their centres "
                            + "as control observations without stopping the scan.",
                        systemImage: "viewfinder.circle",
                        isOn: $settings.tagDetectionEnabled,
                        requirement: nil
                    )

                    ToolRow(
                        title: "AR points",
                        detail: "Draws control points from a collection in the camera view so "
                            + "you can see where they are before you walk to them.",
                        systemImage: "mappin.and.ellipse",
                        isOn: $settings.arPointsEnabled,
                        requirement: survey.collections.isEmpty
                            ? "Needs a point collection. Create one in the Survey tab."
                            : (gnss.currentFix == nil
                               ? "Needs a position fix to know which points are nearby."
                               : nil)
                    )

                    ToolRow(
                        title: "AR labels",
                        detail: "Shows the point number and residual next to each drawn point.",
                        systemImage: "text.bubble",
                        isOn: $settings.arLabelsEnabled,
                        requirement: settings.arPointsEnabled ? nil : "Turn on AR points first."
                    )

                    ToolRow(
                        title: "AR lines",
                        detail: "Connects drawn points in collection order, so a traverse reads "
                            + "as a path rather than a scatter.",
                        systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                        isOn: $settings.arLinesEnabled,
                        requirement: settings.arPointsEnabled ? nil : "Turn on AR points first."
                    )

                    Panel(title: "This device") {
                        VStack(alignment: .leading, spacing: 10) {
                            CapabilityRow(
                                name: "LiDAR depth",
                                available: ARSessionController.hasLiDAR,
                                note: ARSessionController.hasLiDAR
                                    ? "Measured depth. Scale comes from the sensor."
                                    : "No LiDAR on this device. Geometry is inferred from "
                                        + "imagery and scale comes from motion tracking, which "
                                        + "is an estimate."
                            )
                            CapabilityRow(
                                name: "World tracking",
                                available: ARSessionController.isSupported,
                                note: "Provides the per-frame pose."
                            )
                            CapabilityRow(
                                name: "RTK receiver",
                                available: gnss.connectedReceiver != nil,
                                note: receiverNote
                            )
                        }
                    }

                    NavigationLink {
                        ReceiverScanView()
                    } label: {
                        Panel {
                            HStack(alignment: .top, spacing: Theme.Metrics.gutterTight) {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.system(size: 19))
                                    .frame(width: 28)
                                    .foregroundStyle(Theme.Palette.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Scan for nearby RTK devices")
                                        .font(Theme.Typeface.label(16, weight: .semibold))
                                        .foregroundStyle(Theme.Palette.text)
                                    Text("Looks for an RTK receiver over Bluetooth or Wi-Fi and "
                                         + "connects to it, without leaving the capture screen.")
                                        .font(Theme.Typeface.caption)
                                        .foregroundStyle(Theme.Palette.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.Palette.textTertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(Theme.Metrics.gutter)
            }
            .background(Theme.Palette.background)
            .navigationTitle("Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// What the receiver row says. A connected link that is not producing
    /// positions is its own state, and the note says which of the three it is.
    private var receiverNote: String {
        guard let receiver = gnss.connectedReceiver else {
            return "Not connected. Positions come from the internal GNSS, which is "
                + "metre-level. Scan below to connect one."
        }
        if let fix = gnss.currentFix {
            return "\(receiver.displayName) over \(receiver.link.label). \(fix.quality.label)."
        }
        return "\(receiver.displayName) over \(receiver.link.label). "
            + (gnss.streamKind.advice ?? "No fix yet.")
    }
}

private struct ToolRow: View {
    let title: String
    let detail: String
    let systemImage: String
    @Binding var isOn: Bool
    /// When non-nil the tool is unavailable, and this says why.
    let requirement: String?

    var body: some View {
        Panel {
            HStack(alignment: .top, spacing: Theme.Metrics.gutterTight) {
                Image(systemName: systemImage)
                    .font(.system(size: 19))
                    .frame(width: 28)
                    .foregroundStyle(requirement == nil ? Theme.Palette.accent : Theme.Palette.textTertiary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(Theme.Typeface.label(16, weight: .semibold))
                        .foregroundStyle(Theme.Palette.text)
                    Text(detail)
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let requirement {
                        Label(requirement, systemImage: "info.circle")
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(Theme.Palette.caution)
                            .padding(.top, 2)
                    }
                }

                Spacer()

                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .disabled(requirement != nil)
            }
        }
    }
}

private struct CapabilityRow: View {
    let name: String
    let available: Bool
    let note: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? Theme.Palette.good : Theme.Palette.textTertiary)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Theme.Typeface.label(14, weight: .medium))
                    .foregroundStyle(Theme.Palette.text)
                Text(note)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Save

/// Shown when recording stops. Reports what was captured before asking for a
/// name, so the decision to keep or discard is made against evidence.
struct SaveCaptureSheet: View {
    let project: CaptureProject?
    let onKeep: (String) -> Void
    let onDiscard: () -> Void
    let onKeepAndReview: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Metrics.gutter) {
                    if let project {
                        Panel(title: "Captured") {
                            HStack(spacing: Theme.Metrics.gutter * 1.5) {
                                Readout(label: "Frames", value: "\(project.frameCount)")
                                Readout(
                                    label: "Depth",
                                    value: project.hasDepth ? "LiDAR" : "None",
                                    tone: project.hasDepth ? .good : .caution
                                )
                                Readout(label: "Size", value: project.formattedSize)
                            }
                        }

                        if !project.hasDepth {
                            Panel {
                                Label {
                                    Text("No depth was recorded, so this capture has no measured "
                                         + "scale. It can still be reconstructed, but distances "
                                         + "will be estimates until it is fitted to control.")
                                    .font(Theme.Typeface.caption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(Theme.Palette.caution)
                                }
                            }
                        }
                    }

                    Panel(title: "Name") {
                        TextField("Project name", text: $name)
                            .textFieldStyle(.plain)
                            .font(Theme.Typeface.body)
                            .foregroundStyle(Theme.Palette.text)
                            .padding(12)
                            .background(Theme.Palette.surfaceRaised,
                                        in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall))
                    }

                    FieldButton(title: "Keep capture", systemImage: "checkmark", role: .primary) {
                        onKeep(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                               ? (project?.name ?? "Capture") : name)
                        dismiss()
                    }

                    FieldButton(title: "Keep & review", systemImage: "eye.fill", role: .secondary) {
                        onKeepAndReview(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? (project?.name ?? "Capture") : name)
                        dismiss()
                    }

                    FieldButton(title: "Discard", systemImage: "trash", role: .destructive) {
                        onDiscard()
                        dismiss()
                    }
                }
                .padding(Theme.Metrics.gutter)
            }
            .background(Theme.Palette.background)
            .navigationTitle("Capture finished")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
        }
        .onAppear { name = project?.name ?? "" }
    }
}
