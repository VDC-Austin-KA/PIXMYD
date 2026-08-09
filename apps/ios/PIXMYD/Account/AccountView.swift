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
                    NavigationLink { RtkProfilesView() } label: {
                        Label("RTK profiles", systemImage: "antenna.radiowaves.left.and.right")
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
                    if let receiver = gnss.receiverName {
                        LabeledContent("Receiver", value: receiver)
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

struct CaptureSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        List {
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

struct RtkProfilesView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var gnss: GnssManager
    @State private var editing: RtkProfile?

    var body: some View {
        List {
            Section {
                ForEach(settings.rtkProfiles) { profile in
                    Button {
                        editing = profile
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                    .foregroundStyle(Theme.Palette.text)
                                Text(profile.isComplete
                                     ? "\(profile.host):\(profile.port)/\(profile.mountPoint)"
                                     : "Incomplete")
                                    .font(Theme.Typeface.caption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                            Spacer()
                            if settings.activeProfileID == profile.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.Palette.good)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            settings.rtkProfiles.removeAll { $0.id == profile.id }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            settings.activeProfileID = profile.id
                            gnss.startNtrip(profile: profile)
                        } label: {
                            Label("Use", systemImage: "checkmark")
                        }
                        .tint(Theme.Palette.accent)
                    }
                }
            } header: {
                Text("Profiles")
            }
            .listRowBackground(Theme.Palette.surface)

            Section {
                Button {
                    let profile = RtkProfile()
                    settings.rtkProfiles.append(profile)
                    editing = profile
                } label: {
                    Label("New profile", systemImage: "plus")
                }
            }
            .listRowBackground(Theme.Palette.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.background)
        .navigationTitle("RTK profiles")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { profile in
            RtkProfileEditor(profile: profile) { updated in
                if let index = settings.rtkProfiles.firstIndex(where: { $0.id == updated.id }) {
                    settings.rtkProfiles[index] = updated
                }
            }
        }
    }
}

struct RtkProfileEditor: View {
    @State var profile: RtkProfile
    let onSave: (RtkProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Profile name", text: $profile.name)
                }

                Section {
                    TextField("Caster host", text: $profile.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", value: $profile.port, format: .number)
                        .keyboardType(.numberPad)
                    TextField("Mount point", text: $profile.mountPoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username", text: $profile.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $profile.password)
                    Toggle("Report position to caster", isOn: $profile.sendPositionToCaster)
                } header: {
                    Text("NTRIP caster")
                } footer: {
                    Text("Most VRS networks stop sending corrections unless the rover keeps "
                         + "reporting where it is. Leave this on unless your caster says otherwise.")
                        .font(Theme.Typeface.caption)
                }

                Section {
                    LabeledContent("Forward (X)") {
                        TextField("m", value: $profile.leverArmX, format: .number)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Up (Y)") {
                        TextField("m", value: $profile.leverArmY, format: .number)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Right (Z)") {
                        TextField("m", value: $profile.leverArmZ, format: .number)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Antenna height") {
                        TextField("m", value: $profile.antennaHeight, format: .number)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Antenna offset")
                } footer: {
                    Text("Offset from the antenna phase centre to the camera, in device axes. "
                         + "This does not average out: getting it wrong shifts every point in "
                         + "the capture by exactly the same amount, so the residuals stay small "
                         + "and the whole scan is in the wrong place.")
                        .font(Theme.Typeface.caption)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
            .navigationTitle("RTK profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(profile)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
