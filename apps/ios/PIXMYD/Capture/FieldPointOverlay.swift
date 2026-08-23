import SwiftUI
import UIKit

// The crosshair and the panel behind "place a point".
//
// Kept out of `CaptureView` because that screen is already the busiest in the
// app and this is a mode that most of the time is off. `CaptureView` toggles
// it and shows it; everything about how a point is aimed and recorded lives
// here and in `ARSessionController`'s field-point block.
//
// ## Why this is on the capture screen at all
//
// A field point is an ARKit world coordinate, and ARKit's world origin is
// wherever the session started. A point placed in a later session is in a
// different frame, and pairing it with the scan would be arithmetic on two
// different rooms. So the only moment these can be placed is while the space
// is being captured — which is also the only moment somebody is standing in
// front of the corner they want.

/// The aiming reticle. Green when there is something to record, and it says
/// what kind of something.
struct FieldPointCrosshair: View {
    let hasTarget: Bool
    let source: FieldPoint.Source
    let range: Double

    private var tint: Color {
        guard hasTarget else { return Theme.Palette.textTertiary }
        return source.isMeasured ? Theme.Palette.good : Theme.Palette.caution
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .strokeBorder(tint, lineWidth: 2)
                    .frame(width: 52, height: 52)
                // Ticks rather than a filled dot: a dot covers the very thing
                // being aimed at, which on a 3 mm scribe mark is the whole
                // target.
                ForEach(0..<4, id: \.self) { i in
                    Rectangle()
                        .fill(tint)
                        .frame(width: 2, height: 10)
                        .offset(y: -32)
                        .rotationEffect(.degrees(Double(i) * 90))
                }
                Circle()
                    .fill(tint)
                    .frame(width: 3, height: 3)
            }

            Text(caption)
                .font(Theme.Typeface.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.6), in: Capsule())
        }
        .allowsHitTesting(false)
    }

    private var caption: String {
        guard hasTarget else { return "Nothing under the crosshair" }
        let distance = String(format: "%.2f m", range)
        return source.isMeasured
            ? "Measured · \(distance)"
            : "Estimated surface · \(distance)"
    }
}

/// The list of points placed so far, and what the set can support.
struct FieldPointPanel: View {
    let set: FieldPointSet
    let onRemove: (String) -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.gutterTight) {
            HStack {
                Text("Points")
                    .font(Theme.Typeface.label(15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button("Done", action: onDone)
                    .font(Theme.Typeface.label(15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
            }

            if set.points.isEmpty {
                Text("Aim at a corner you could find again with a tape — a column edge, a "
                   + "doorway reveal, a scribe mark — and press the shutter.")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(set.points) { point in
                            row(point)
                        }
                    }
                }
                .frame(maxHeight: 132)
            }

            Text(CaptureExport.registrationReadiness(set))
                .font(Theme.Typeface.caption)
                .foregroundStyle(set.canRegister ? Theme.Palette.good : Theme.Palette.caution)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Metrics.gutter)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
    }

    private func row(_ point: FieldPoint) -> some View {
        HStack(spacing: 8) {
            Text(point.id)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 42, alignment: .leading)
            Text(point.source.label)
                .font(Theme.Typeface.caption)
                .foregroundStyle(point.source.isMeasured
                                 ? Theme.Palette.good : Theme.Palette.caution)
            if let range = point.range {
                Text(String(format: "%.2f m", range))
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button {
                onRemove(point.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.bad)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Remove \(point.id)")
        }
    }
}
