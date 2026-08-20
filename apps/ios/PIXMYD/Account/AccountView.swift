import SwiftUI

/// App-wide settings, persisted to UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    @Published var capture: CaptureSettings = .default { didSet { persist() } }
    @Published var tagDetectionEnabled = false { didSet { persist() } }
    @Published var arPointsEnabled = false { didSet { persist() } }
    @Published var arLabelsEnabled = true { didSet { persist() } }
    @Published var arLinesEnabled = false { didSet { persist() } }
    @Published var rtkProfiles: [RtkProfile] = [] { didSet { persist() } }
    @Published var activeProfileID: UUID? { didSet { persist() } }
    /// Working units for display. Storage is always metres.
    @Published var displayUnit: String = "metre" { didSet { persist() } }

    private let key = "com.pixmyd.settings"

    init() { restore() }

    var activeProfile: RtkProfile? {
        rtkProfiles.first { $0.id == activeProfileID }
    }

    /// Replace a profile in place, keeping its position in the list.
    func update(_ profile: RtkProfile) {
        guard let index = rtkProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
        rtkProfiles[index] = profile
    }

    /// Write a receiver the scan just connected into the profiles.
    ///
    /// The rules live in `RtkProfileBinding`, which is pure and tested; this is
    /// the part that has to touch published state.
    @discardableResult
    func remember(_ receiver: SavedReceiver) -> RtkProfile {
        var profiles = rtkProfiles
        var active = activeProfileID
        let profile = RtkProfileBinding.remember(receiver, in: &profiles, active: &active)
        rtkProfiles = profiles
        activeProfileID = active
        return profile
    }

    private struct Stored: Codable {
        var capture: CaptureSettings
        var tagDetection: Bool
        var arPoints: Bool
        var arLabels: Bool
        var arLines: Bool
        var profiles: [RtkProfile]
        var activeProfileID: UUID?
        var displayUnit: String
    }

    private func persist() {
        let stored = Stored(
            capture: capture,
            tagDetection: tagDetectionEnabled,
            arPoints: arPointsEnabled,
            arLabels: arLabelsEnabled,
            arLines: arLinesEnabled,
            profiles: rtkProfiles,
            activeProfileID: activeProfileID,
            displayUnit: displayUnit
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        capture = stored.capture
        tagDetectionEnabled = stored.tagDetection
        arPointsEnabled = stored.arPoints
        arLabelsEnabled = stored.arLabels
        arLinesEnabled = stored.arLines
        rtkProfiles = stored.profiles
        activeProfileID = stored.activeProfileID
        displayUnit = stored.displayUnit
    }
}

struct AccountView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var gnss: GnssManager

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { CaptureSettingsView() } label: {
                        Label("Capture", systemImage: "camera")
                    }
                    NavigationLink { RtkSettingsView() } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("RTK")
                                Text(rtkSummary)
                                    .font(Theme.Typeface.caption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                        } icon: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                    }
                    NavigationLink { ArSettingsView() } label: {
                        Label("AR display", systemImage: "arkit")
                    }
                } header: {
                    Text("Settings")
                }
                .listRowBackground(Theme.Palette.surface)

                Section {
                    LabeledContent("Position source", value: gnss.source.rawValue)
                    if let receiver = gnss.connectedReceiver {
                        LabeledContent("Receiver", value: receiver.displayName)
                        LabeledContent("Link", value: "\(receiver.link.label) — \(gnss.linkState.label)")
                        // The format matters as much as the connection: a link
                        // that is up and carrying something other than NMEA
                        // yields no position at all.
                        LabeledContent("Stream", value: gnss.streamKind.rawValue.uppercased())
                    }
                    LabeledContent("NTRIP", value: gnss.ntripState.label)
                    LabeledContent("LiDAR", value: ARSessionController.hasLiDAR ? "Available" : "Not on this device")
                } header: {
                    Text("Hardware")
                }
                .listRowBackground(Theme.Palette.surface)

                Section {
                    LabeledContent("Version", value: Bundle.main.shortVersion)
                    Link(destination: URL(string: "https://github.com/VDC-Austin-KA/PIXMYD")!) {
                        Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("PIXMYD is free and open source. Captures stay on this device "
                         + "until you export them — there is no account and nothing is "
                         + "uploaded anywhere.")
                        .font(Theme.Typeface.caption)
                }
                .listRowBackground(Theme.Palette.surface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
            .navigationTitle("Account")
        }
    }
}

extension AccountView {
    /// One line under the RTK row saying where the receiver stands, so the
    /// answer to "am I connected" does not need a tap.
    var rtkSummary: String {
        if let receiver = gnss.connectedReceiver {
            return "\(receiver.displayName) over \(receiver.link.label)"
        }
        return "Scan for a receiver, profiles, corrections"
    }
}

struct CaptureSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    /// Selecting a mode writes its values into the individual settings, which
    /// stay editable afterwards. A preset, not a lock.
    private var modeBinding: Binding<ScanMode> {
        Binding(
            get: { settings.capture.mode },
            set: { settings.capture.apply($0) }
        )
    }

    var body: some View {
        List {
            Section {
                Picker("Mode", selection: modeBinding) {
                    ForEach(ScanMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(settings.capture.mode.detail)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                if !settings.capture.matchesMode {
                    // Say so rather than showing a mode that no longer
                    // describes what will happen.
                    Text("Adjusted from the \(settings.capture.mode.label) preset.")
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.caution)
                }
            } header: {
                Text("What are you scanning")
            }
            .listRowBackground(Theme.Palette.surface)

            Section {
                Picker("Trigger", selection: $settings.capture.trigger) {
                    ForEach(CaptureSettings.Trigger.allCases) { trigger in
                        Text(trigger.label).tag(trigger)
                    }
                }
                Text(settings.capture.trigger.detail)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            } header: {
                Text("Image trigger")
            }
            .listRowBackground(Theme.Palette.surface)

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Overlap")
                        Spacer()
                        Text("\(Int(settings.capture.overlap * 100))%")
                            .font(Theme.Typeface.numeric(15))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Slider(value: $settings.capture.overlap, in: 0.5...0.95, step: 0.05)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Subject distance")
                        Spacer()
                        Text(String(format: "%.1f m", settings.capture.subjectDistance))
                            .font(Theme.Typeface.numeric(15))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Slider(value: $settings.capture.subjectDistance, in: 0.5...10, step: 0.5)
                }
            } header: {
                Text("Coverage")
            } footer: {
                // The derived number is shown because it is the thing that
                // actually governs capture, and a user who understands it can
                // reason about the two sliders instead of guessing.
                Text(String(
                    format: "Captures a frame every %.2f m of travel, or every %.0f° of turn. "
                        + "Higher overlap and closer subjects mean more frames and more detail, "
                        + "at the cost of storage and processing time.",
                    Double(settings.capture.baseline),
                    settings.capture.rotationThreshold * 180 / .pi
                ))
                .font(Theme.Typeface.caption)
            }
            .listRowBackground(Theme.Palette.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.background)
        .navigationTitle("Capture")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ArSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        List {
            Section {
                Toggle("AR points", isOn: $settings.arPointsEnabled)
                Toggle("Labels", isOn: $settings.arLabelsEnabled)
                    .disabled(!settings.arPointsEnabled)
                Toggle("Lines between points", isOn: $settings.arLinesEnabled)
                    .disabled(!settings.arPointsEnabled)
            } footer: {
                Text("Drawn points are positioned from your current fix. At a metre-level "
                     + "fix they will be metres out — the drawing is as accurate as the "
                     + "position behind it, and no more.")
                    .font(Theme.Typeface.caption)
            }
            .listRowBackground(Theme.Palette.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.background)
        .navigationTitle("AR display")
        .navigationBarTitleDisplayMode(.inline)
    }
}
