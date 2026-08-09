import SwiftUI

/// Visual language for a field instrument.
///
/// The viewing condition this is designed for is the worst one, not the best:
/// bright Texas daylight, a gloved hand, a hard hat, and dust on the screen.
/// That drives every decision here — high contrast, large targets, a type scale
/// that holds up at arm's length, and colour reserved for meaning.
///
/// The one rule worth stating explicitly: **status colour is never decoration.**
/// Green, amber and red mean accuracy bands and nothing else, and every place
/// they appear also carries a text label. Red/green is the most common colour
/// deficiency and this palette leans on it for pass/fail, so hue alone can
/// never be the carrier of meaning.
enum Theme {

    // MARK: - Colour

    enum Palette {
        /// Camera-first screens sit on black so the viewfinder is the page.
        static let background = Color(red: 0.04, green: 0.045, blue: 0.05)
        static let surface = Color(red: 0.09, green: 0.10, blue: 0.11)
        static let surfaceRaised = Color(red: 0.14, green: 0.15, blue: 0.16)
        static let hairline = Color(red: 0.22, green: 0.23, blue: 0.25)

        static let text = Color(red: 0.95, green: 0.96, blue: 0.97)
        static let textSecondary = Color(red: 0.66, green: 0.68, blue: 0.71)
        /// Only for text that is genuinely inert. Anything actionable uses `text`.
        static let textTertiary = Color(red: 0.44, green: 0.46, blue: 0.49)

        /// The single accent. Used for the active state and nothing else, so
        /// that "this is the live control" is never ambiguous.
        static let accent = Color(red: 0.25, green: 0.62, blue: 0.95)

        // Tolerance semantics. Never used decoratively.
        static let good = Color(red: 0.30, green: 0.78, blue: 0.45)
        static let caution = Color(red: 0.95, green: 0.70, blue: 0.20)
        static let bad = Color(red: 0.92, green: 0.35, blue: 0.32)

        static let recording = Color(red: 0.90, green: 0.25, blue: 0.25)
    }

    // MARK: - Type

    enum Typeface {
        /// Numbers are monospaced everywhere. A northing that reflows as its
        /// digits change is unreadable while walking.
        static func numeric(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }

        static func label(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
            .system(size: size, weight: weight, design: .default)
        }

        static let titleLarge = label(28, weight: .semibold)
        static let title = label(20, weight: .semibold)
        static let body = label(16)
        static let caption = label(13)
        /// Section headers and unit suffixes.
        static let overline = label(11, weight: .semibold)
    }

    // MARK: - Metrics

    enum Metrics {
        /// Gloved hands. This is a floor, not a target.
        static let minimumTapTarget: CGFloat = 44
        static let cornerRadius: CGFloat = 12
        static let cornerRadiusSmall: CGFloat = 8
        static let gutter: CGFloat = 16
        static let gutterTight: CGFloat = 8
        static let shutterDiameter: CGFloat = 76
    }
}

// MARK: - Shared components

/// A labelled readout. The label is always present — a bare number on a field
/// screen invites the reader to guess what it is.
struct Readout: View {
    let label: String
    let value: String
    var unit: String?
    var tone: Tone = .neutral

    enum Tone {
        case neutral, good, caution, bad

        var color: Color {
            switch self {
            case .neutral: Theme.Palette.text
            case .good: Theme.Palette.good
            case .caution: Theme.Palette.caution
            case .bad: Theme.Palette.bad
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(Theme.Typeface.overline)
                .foregroundStyle(Theme.Palette.textSecondary)
                .tracking(0.6)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Theme.Typeface.numeric(17, weight: .semibold))
                    .foregroundStyle(tone.color)
                if let unit {
                    Text(unit)
                        .font(Theme.Typeface.numeric(12))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value) \(unit ?? "")")
    }
}

/// A status chip. Carries both a hue and a word, always — see the note on
/// colour deficiency at the top of this file.
struct StatusChip: View {
    let text: String
    let tone: Readout.Tone
    var systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .bold))
            }
            Text(text)
                .font(Theme.Typeface.label(12, weight: .semibold))
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tone.color.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(tone.color.opacity(0.35), lineWidth: 1))
    }
}

/// Primary action button, sized for a gloved hand.
struct FieldButton: View {
    let title: String
    var systemImage: String?
    var role: Role = .secondary
    let action: () -> Void

    enum Role {
        case primary, secondary, destructive
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 15, weight: .semibold))
                }
                Text(title).font(Theme.Typeface.label(16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Metrics.minimumTapTarget + 6)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius)
                    .strokeBorder(border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var foreground: Color {
        switch role {
        case .primary: .black
        case .secondary: Theme.Palette.text
        case .destructive: Theme.Palette.bad
        }
    }

    private var background: Color {
        switch role {
        case .primary: Theme.Palette.accent
        case .secondary: Theme.Palette.surfaceRaised
        case .destructive: Theme.Palette.bad.opacity(0.12)
        }
    }

    private var border: Color {
        switch role {
        case .primary: .clear
        case .secondary: Theme.Palette.hairline
        case .destructive: Theme.Palette.bad.opacity(0.4)
        }
    }
}

/// A panel that groups readouts. Deliberately flat — no gradients, no shadows.
struct Panel<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.gutterTight) {
            if let title {
                Text(title.uppercased())
                    .font(Theme.Typeface.overline)
                    .tracking(0.7)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            content
        }
        .padding(Theme.Metrics.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius)
                .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
        )
    }
}

/// Shown when a capability the user asked for is genuinely unavailable.
///
/// A missing capability must never look like a bug in the app, and it must say
/// what to do next — "this device has no LiDAR" is information; a spinner that
/// never resolves is not.
struct UnavailableNotice: View {
    let title: String
    let detail: String
    var systemImage: String = "exclamationmark.triangle"

    var body: some View {
        VStack(spacing: Theme.Metrics.gutterTight) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.Palette.caution)
            Text(title)
                .font(Theme.Typeface.title)
                .foregroundStyle(Theme.Palette.text)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(Theme.Typeface.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Metrics.gutter * 1.5)
        .frame(maxWidth: .infinity)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
    }
}
