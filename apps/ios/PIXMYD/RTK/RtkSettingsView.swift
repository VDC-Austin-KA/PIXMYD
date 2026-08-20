import SwiftUI

/// The RTK section: everything about the receiver and its corrections, in one
/// place, with scanning as the first thing on it.
///
/// Scanning used to be a row among the app's general settings, which made
/// "connect a receiver" look like a preference rather than the thing a user
/// opens this app holding a pole to do. It is now the primary action on its
/// own screen, reachable from the Account tab and from the capture screen.
struct RtkSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var gnss: GnssManager
    @EnvironmentObject private var scanner: ReceiverScanner

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ReceiverScanView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Scan for nearby RTK devices")
                                .font(Theme.Typeface.label(16, weight: .semibold))
                                .foregroundStyle(Theme.Palette.text)
                            Text("Bluetooth and Wi-Fi")
                                .font(Theme.Typeface.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    } icon: {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(Theme.Palette.accent)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Receiver")
            } footer: {
                Text("Connecting a receiver here fills in the profile below — its name, "
                     + "link and address are things the scan already knows, so there is "
                     + "nothing to type.")
                    .font(Theme.Typeface.caption)
            }
            .listRowBackground(Theme.Palette.surface)

            if let receiver = gnss.connectedReceiver {
                Section {
                    LabeledContent("Connected", value: receiver.displayName)
                    LabeledContent("Link", value: "\(receiver.link.label) — \(gnss.linkState.label)")
                    LabeledContent("Stream", value: gnss.streamKind.rawValue.uppercased())
                    LabeledContent("Fix", value: gnss.currentFix?.quality.label ?? "None")
                    Button(role: .destructive) {
                        gnss.disconnectReceiver()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                } header: {
                    Text("Live")
                } footer: {
                    if let advice = gnss.streamKind.advice {
                        Text(advice).font(Theme.Typeface.caption)
                    }
                }
                .listRowBackground(Theme.Palette.surface)
            }

            Section {
                ForEach(settings.rtkProfiles) { profile in
                    NavigationLink {
                        RtkProfileEditor(profile: profile) { updated in
                            settings.update(updated)
                            // An antenna offset edited on the active profile
                            // has to reach the manager now, not at the next
                            // time somebody happens to re-select the profile.
                            if updated.id == settings.activeProfileID { gnss.apply(updated) }
                        }
                    } label: {
                        ProfileRow(
                            profile: profile,
                            isActive: settings.activeProfileID == profile.id,
                            isConnected: gnss.connectedReceiver.map { live in
                                profile.receiver?.isSameDevice(as: SavedReceiver(live)) == true
                            } ?? false
                        )
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            settings.rtkProfiles.removeAll { $0.id == profile.id }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            use(profile)
                        } label: {
                            Label("Use", systemImage: "checkmark")
                        }
                        .tint(Theme.Palette.accent)
                    }
                }

                Button {
                    let profile = RtkProfile()
                    settings.rtkProfiles.append(profile)
                    settings.activeProfileID = profile.id
                } label: {
                    Label("New profile", systemImage: "plus")
                }
            } header: {
                Text("Profiles")
            } footer: {
                Text(settings.rtkProfiles.isEmpty
                     ? "A profile pairs a receiver with the correction stream it should use. "
                        + "Scanning for a receiver creates one."
                     : "Swipe a profile to make it the active one — that connects its receiver "
                        + "and starts its corrections.")
                    .font(Theme.Typeface.caption)
            }
            .listRowBackground(Theme.Palette.surface)

            Section {
                LabeledContent("NTRIP", value: gnss.ntripState.label)
                if let active = settings.activeProfile, active.isComplete {
                    Button {
                        gnss.startNtrip(profile: active)
                    } label: {
                        Label("Start corrections", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    Button(role: .destructive) {
                        gnss.stopNtrip()
                    } label: {
                        Label("Stop corrections", systemImage: "stop.circle")
                    }
                }
            } header: {
                Text("Corrections")
            } footer: {
                Text(settings.activeProfile?.isComplete == true
                     ? "Corrections reach the receiver over the same link the positions come "
                        + "back on. The phone never applies them itself."
                     : "The active profile has no caster yet. Open it and enter the host, then "
                        + "pick a mount point from the caster's own list.")
                    .font(Theme.Typeface.caption)
            }
            .listRowBackground(Theme.Palette.surface)

            if let message = gnss.lastMessage {
                Section {
                    Label(message, systemImage: "info.circle")
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.caution)
                }
                .listRowBackground(Theme.Palette.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.background)
        .navigationTitle("RTK")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Make a profile the active one: connect its receiver, then start its
    /// corrections. Doing only one of the two is what leaves someone with a
    /// connected receiver and no RTK, or a correction stream going nowhere.
    private func use(_ profile: RtkProfile) {
        settings.activeProfileID = profile.id
        gnss.apply(profile)

        if let saved = profile.receiver, gnss.connectedReceiver?.identifier != saved.identifier {
            if let transport = scanner.transport(forSaved: saved) {
                gnss.connect(transport)
            }
        }
        if profile.isComplete {
            gnss.startNtrip(profile: profile)
        }
    }
}

private struct ProfileRow: View {
    let profile: RtkProfile
    let isActive: Bool
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name)
                    .font(Theme.Typeface.label(15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.text)
                Text(receiverLine)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(casterLine)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer()
            if isConnected {
                StatusChip(text: "Live", tone: .good, systemImage: "dot.radiowaves.left.and.right")
            } else if isActive {
                StatusChip(text: "Active", tone: .neutral, systemImage: "checkmark")
            }
        }
        .padding(.vertical, 2)
    }

    private var receiverLine: String {
        guard let receiver = profile.receiver else {
            return "No receiver yet — scan to add one"
        }
        var parts = [receiver.name, receiver.link.label]
        if let address = receiver.addressLabel { parts.append(address) }
        return parts.joined(separator: " · ")
    }

    private var casterLine: String {
        profile.isComplete
            ? "\(profile.host):\(profile.port)/\(profile.mountPoint)"
            : "No caster — corrections not configured"
    }
}

// MARK: - Editor

struct RtkProfileEditor: View {
    @State var profile: RtkProfile
    let onSave: (RtkProfile) -> Void

    @EnvironmentObject private var gnss: GnssManager
    @Environment(\.dismiss) private var dismiss

    @State private var mountPoints: [NtripMountPoint] = []
    @State private var isFetching = false
    @State private var fetchProblem: String?

    var body: some View {
        Form {
            Section("Name") {
                TextField("Profile name", text: $profile.name)
            }
            .listRowBackground(Theme.Palette.surface)

            Section {
                if let receiver = profile.receiver {
                    LabeledContent("Device", value: receiver.name)
                    LabeledContent("Link", value: receiver.link.label)
                    if let address = receiver.addressLabel {
                        LabeledContent("Address", value: address)
                    }
                    if let last = receiver.lastConnected {
                        LabeledContent("Last connected",
                                       value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button(role: .destructive) {
                        profile.receiver = nil
                    } label: {
                        Label("Forget this receiver", systemImage: "minus.circle")
                    }
                } else {
                    Text("None yet. Connect one in scan mode and it is written here.")
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            } header: {
                Text("Receiver")
            } footer: {
                Text("Filled in by the scan, not typed. These are the things the phone found "
                     + "out for itself.")
                    .font(Theme.Typeface.caption)
            }
            .listRowBackground(Theme.Palette.surface)

            Section {
                TextField("Caster host", text: $profile.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", value: $profile.port, format: .number)
                    .keyboardType(.numberPad)
                TextField("Username", text: $profile.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $profile.password)
            } header: {
                Text("NTRIP caster")
            } footer: {
                Text("This half cannot be discovered. Corrections come from a subscription — "
                     + "an account on a network — and no amount of scanning reveals it.")
                    .font(Theme.Typeface.caption)
            }
            .listRowBackground(Theme.Palette.surface)

            Section {
                TextField("Mount point", text: $profile.mountPoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    fetchMountPoints()
                } label: {
                    HStack {
                        Label("Get the caster's list", systemImage: "arrow.down.doc")
                        if isFetching {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(profile.host.isEmpty || isFetching)

                if let fetchProblem {
                    Text(fetchProblem)
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.bad)
                }

                ForEach(orderedMountPoints) { point in
                    Button {
                        select(point)
                    } label: {
                        MountPointRow(
                            point: point,
                            isSelected: point.mountPoint == profile.mountPoint,
                            distance: distance(to: point)
                        )
                    }
                }

                Toggle("Report position to caster", isOn: $profile.sendPositionToCaster)
            } header: {
                Text("Mount point")
            } footer: {
                Text("Picking from the caster's list also sets whether to report position — the "
                     + "table states it per mount point. A VRS stream that needs it and does not "
                     + "get it connects, delivers for a minute, then goes quiet."
                     + (gnss.currentFix == nil
                        ? ""
                        : " Nearest to your current position first."))
                    .font(Theme.Typeface.caption)
            }
            .listRowBackground(Theme.Palette.surface)

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
                     + "Measured, never discovered: no receiver knows where it is bolted. "
                     + "Getting it wrong shifts every point in the capture by exactly the same "
                     + "amount, so the residuals stay small and the whole scan is in the wrong "
                     + "place.")
                    .font(Theme.Typeface.caption)
            }
            .listRowBackground(Theme.Palette.surface)
        }
        .listStyle(.insetGrouped)
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
        }
        // Also on the way out: this screen is reached by a push, and a
        // back-swipe that silently discarded a caster password someone had just
        // typed would be the app losing work it was trusted with.
        .onDisappear { onSave(profile) }
    }

    private var roverPosition: (latitude: Double, longitude: Double)? {
        guard let fix = gnss.currentFix else { return nil }
        return (fix.lat, fix.lon)
    }

    private var orderedMountPoints: [NtripMountPoint] {
        NtripSourceTable.ordered(mountPoints, near: roverPosition)
    }

    private func distance(to point: NtripMountPoint) -> Double? {
        guard let roverPosition else { return nil }
        return point.distance(fromLatitude: roverPosition.latitude, longitude: roverPosition.longitude)
    }

    private func select(_ point: NtripMountPoint) {
        profile.mountPoint = point.mountPoint
        // The table is the authority on this, so picking from it turns a guess
        // into a fact.
        profile.sendPositionToCaster = point.requiresPosition
    }

    private func fetchMountPoints() {
        fetchProblem = nil
        guard let probe = NtripSourceTableProbe(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            password: profile.password
        ) else {
            fetchProblem = "That host and port are not something this app can reach."
            return
        }
        isFetching = true
        probe.start { result in
            isFetching = false
            switch result {
            case .success(let points):
                mountPoints = points
            case .failure(let error):
                fetchProblem = error.label
            }
        }
    }
}

private struct MountPointRow: View {
    let point: NtripMountPoint
    let isSelected: Bool
    let distance: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Theme.Palette.accent : Theme.Palette.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(point.mountPoint)
                    .font(Theme.Typeface.label(15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.text)
                Text(detail)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let distance {
                Text(distance < 10_000
                     ? String(format: "%.0f m", distance)
                     : String(format: "%.0f km", distance / 1000))
                    .font(Theme.Typeface.numeric(12))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if !point.identifier.isEmpty { parts.append(point.identifier) }
        if !point.format.isEmpty { parts.append(point.format) }
        if !point.navSystem.isEmpty { parts.append(point.navSystem) }
        if point.requiresPosition { parts.append("needs position") }
        return parts.joined(separator: " · ")
    }
}
