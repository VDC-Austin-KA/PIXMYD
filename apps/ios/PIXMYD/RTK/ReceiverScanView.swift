import SwiftUI

/// Scan mode: put the phone in a state where it is looking for a receiver, show
/// what it finds, and connect to the one the user picks.
///
/// The screen is built around the two questions a field user actually asks, in
/// order: *is it finding anything*, and *is the thing it found any good*. So
/// every negative answer carries its reason — Bluetooth switched off, local
/// network refused, a device that connected but is streaming the wrong format —
/// rather than showing an empty list and a spinner.
struct ReceiverScanView: View {
    @EnvironmentObject private var gnss: GnssManager
    @EnvironmentObject private var settings: AppSettings
    /// The scanner belongs to the app, not to this screen — see the note in
    /// `PIXMYDApp`. Scanning stops when the screen goes away; the radio and any
    /// link it opened do not.
    @EnvironmentObject private var scanner: ReceiverScanner

    @State private var manualAddress = ""
    @State private var manualProblem: String?
    @State private var connectProblem: String?
    /// The profile the last connection was written into, so the screen can say
    /// where it went rather than saving something invisibly.
    @State private var savedProfileName: String?

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Metrics.gutter) {
                if gnss.connectedReceiver != nil { connected }
                scanControl
                links
                found
                manual
                notes
            }
            .padding(Theme.Metrics.gutter)
        }
        .background(Theme.Palette.background)
        .navigationTitle("Scan for RTK devices")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
        .onChange(of: gnss.linkState) { _, state in
            // A Bluetooth scan running alongside a live link slows the link and
            // costs battery for a list nobody is reading any more. The Scan
            // button starts it again if the first choice was the wrong one.
            if state.isConnected { scanner.stop() }
        }
    }

    // MARK: - Connected

    @ViewBuilder
    private var connected: some View {
        if let receiver = gnss.connectedReceiver {
            Panel(title: "Connected") {
                VStack(alignment: .leading, spacing: Theme.Metrics.gutterTight) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(receiver.displayName)
                                .font(Theme.Typeface.label(16, weight: .semibold))
                                .foregroundStyle(Theme.Palette.text)
                            Text(receiver.link.label
                                 + (receiver.vendor.map { " — \($0.label)" } ?? ""))
                                .font(Theme.Typeface.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Spacer()
                        StatusChip(text: gnss.linkState.label, tone: linkTone,
                                   systemImage: receiver.link.systemImage)
                    }

                    HStack(spacing: Theme.Metrics.gutter * 1.5) {
                        Readout(
                            label: "Received",
                            value: ByteCountFormatter.string(
                                fromByteCount: Int64(gnss.receiverBytes),
                                countStyle: .binary
                            )
                        )
                        Readout(
                            label: "Stream",
                            value: gnss.streamKind.rawValue.uppercased(),
                            tone: gnss.streamKind == .nmea ? .good : .caution
                        )
                        Readout(
                            label: "Fix",
                            value: gnss.currentFix?.quality.label ?? "None",
                            tone: gnss.currentFix?.quality.isSurveyGrade == true ? .good : .caution
                        )
                    }

                    if let advice = gnss.streamKind.advice {
                        Label(advice, systemImage: "info.circle")
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(Theme.Palette.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !gnss.canForwardCorrections {
                        Label("This link cannot carry corrections back to the receiver, so "
                              + "NTRIP will not reach it.", systemImage: "arrow.up.left.circle")
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(Theme.Palette.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let savedProfileName {
                        Label("Saved to the RTK profile \u{201C}\(savedProfileName)\u{201D}. Its "
                              + "caster details, if any, are untouched.",
                              systemImage: "square.and.arrow.down")
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    FieldButton(title: "Disconnect", systemImage: "xmark", role: .destructive) {
                        gnss.disconnectReceiver()
                    }
                }
            }
        }
    }

    private var linkTone: Readout.Tone {
        switch gnss.linkState {
        case .connected: .good
        case .connecting, .idle: .caution
        case .failed: .bad
        case .closed: .neutral
        }
    }

    // MARK: - Scan control

    private var scanControl: some View {
        Panel {
            VStack(alignment: .leading, spacing: Theme.Metrics.gutterTight) {
                HStack(spacing: 10) {
                    if scanner.isScanning {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.Palette.accent)
                    }
                    Text(scanner.isScanning
                         ? "Listening for receivers over Bluetooth and Wi-Fi"
                         : "Scanning stopped")
                        .font(Theme.Typeface.label(15, weight: .medium))
                        .foregroundStyle(Theme.Palette.text)
                    Spacer()
                }

                Text("Put the receiver in pairing or broadcast mode first. A receiver that is "
                     + "already paired to another phone will not appear.")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if scanner.isScanning {
                    FieldButton(title: "Stop scanning", systemImage: "stop.fill") {
                        scanner.stop()
                    }
                } else {
                    FieldButton(title: "Scan", systemImage: "dot.radiowaves.left.and.right",
                                role: .primary) {
                        scanner.start()
                    }
                }
            }
        }
    }

    // MARK: - Link status

    private var links: some View {
        Panel(title: "Radios") {
            VStack(alignment: .leading, spacing: 10) {
                LinkStatusRow(
                    name: "Bluetooth",
                    systemImage: ReceiverLink.bluetooth.systemImage,
                    availability: scanner.bluetooth,
                    readyNote: "Scanning for nearby receivers."
                )
                LinkStatusRow(
                    name: "Wi-Fi",
                    systemImage: ReceiverLink.wifi.systemImage,
                    availability: scanner.network,
                    readyNote: "Browsing this network. Receivers in access-point mode are "
                        + "found only once the phone has joined their network."
                )
                if let message = scanner.message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Results

    private var found: some View {
        Panel(title: "Found") {
            VStack(alignment: .leading, spacing: Theme.Metrics.gutterTight) {
                if scanner.receivers.isEmpty {
                    Text(scanner.isScanning
                         ? "Nothing yet. A receiver usually appears within a few seconds of "
                            + "being switched on."
                         : "Start a scan to look for receivers.")
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(scanner.receivers) { receiver in
                    ReceiverRow(
                        receiver: receiver,
                        isConnected: gnss.connectedReceiver?.id == receiver.id,
                        connect: { connect(receiver) }
                    )
                }

                if let connectProblem {
                    Label(connectProblem, systemImage: "exclamationmark.triangle")
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().overlay(Theme.Palette.hairline)

                Toggle(isOn: $scanner.includeUnknownDevices) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show every Bluetooth device")
                            .font(Theme.Typeface.label(14, weight: .medium))
                            .foregroundStyle(Theme.Palette.text)
                        Text(scanner.hiddenCount == 0
                             ? "Nothing is being hidden."
                             : "\(scanner.hiddenCount) nearby device"
                                + (scanner.hiddenCount == 1 ? "" : "s")
                                + " did not look like a receiver and "
                                + (scanner.hiddenCount == 1 ? "is" : "are") + " hidden.")
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: - Manual endpoint

    private var manual: some View {
        Panel(title: "By address") {
            VStack(alignment: .leading, spacing: Theme.Metrics.gutterTight) {
                Text("A receiver with a TCP output port does not announce itself. Join its "
                     + "Wi-Fi and type where it is — \(ReceiverEndpoint.defaultPort) is the "
                     + "usual port.")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("192.168.42.1:\(ReceiverEndpoint.defaultPort)", text: $manualAddress)
                    .textFieldStyle(.plain)
                    .font(Theme.Typeface.numeric(15))
                    .foregroundStyle(Theme.Palette.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(12)
                    .background(Theme.Palette.surfaceRaised,
                                in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadiusSmall))

                if let manualProblem {
                    Text(manualProblem)
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.bad)
                }

                FieldButton(title: "Connect", systemImage: "link") {
                    connectManually()
                }
            }
        }
    }

    private var notes: some View {
        Panel(title: "If nothing appears") {
            VStack(alignment: .leading, spacing: 6) {
                ScanHint(text: "MFi receivers — Bad Elf, some Trimble — pair in iOS Settings "
                         + "rather than here, and appear in this list once attached.")
                ScanHint(text: "A receiver already connected to another phone or to its own "
                         + "app will not advertise. Disconnect it there first.")
                ScanHint(text: "Bluetooth range is optimistic on paper. If the receiver is on "
                         + "a pole several metres up, hold the phone higher.")
            }
        }
    }

    // MARK: - Actions

    private func connect(_ receiver: DiscoveredReceiver) {
        connectProblem = nil
        guard receiver.isConnectableAsRover else {
            // A caster hands out corrections; it has no position to give. The
            // link would open, deliver RTCM, and never produce a fix.
            connectProblem = "\(receiver.displayName) is an NTRIP caster, not a receiver. "
                + "Put it in an RTK profile as the correction source instead."
            return
        }
        guard let transport = scanner.transport(for: receiver) else {
            connectProblem = "\(receiver.displayName) is no longer reachable. Scan again."
            return
        }
        gnss.connect(transport)
        // Written down immediately, not on some later "save" the user has to
        // find: what the scan learned — the device, its link, its address — is
        // exactly what the profile screen would otherwise ask them to type.
        // Their caster, credentials and antenna offsets are never touched.
        savedProfileName = settings.remember(SavedReceiver(receiver)).name
    }

    private func connectManually() {
        manualProblem = nil
        guard let receiver = scanner.manualEndpoint(manualAddress) else {
            manualProblem = "That is not an address and port this app can reach. "
                + "Use host or host:port, for example 192.168.42.1:\(ReceiverEndpoint.defaultPort)."
            return
        }
        connect(receiver)
    }
}

// MARK: - Rows

private struct LinkStatusRow: View {
    let name: String
    let systemImage: String
    let availability: ReceiverScanner.LinkAvailability
    let readyNote: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .frame(width: 22)
                .foregroundStyle(availability.isReady ? Theme.Palette.good : Theme.Palette.caution)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Theme.Typeface.label(14, weight: .medium))
                    .foregroundStyle(Theme.Palette.text)
                Text(availability.explanation ?? readyNote)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ReceiverRow: View {
    let receiver: DiscoveredReceiver
    let isConnected: Bool
    let connect: () -> Void

    var body: some View {
        Button(action: connect) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: receiver.link.systemImage)
                    .font(.system(size: 16))
                    .frame(width: 24)
                    .foregroundStyle(receiver.isLikelyReceiver
                                     ? Theme.Palette.accent : Theme.Palette.textTertiary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(receiver.displayName)
                        .font(Theme.Typeface.label(15, weight: .semibold))
                        .foregroundStyle(Theme.Palette.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: Theme.Metrics.gutterTight)

                if isConnected {
                    StatusChip(text: "In use", tone: .good, systemImage: "checkmark")
                } else if receiver.role == .caster {
                    StatusChip(text: "Corrections", tone: .neutral,
                               systemImage: "antenna.radiowaves.left.and.right")
                } else if let bars = receiver.signalBars {
                    SignalBars(bars: bars, rssi: receiver.rssi)
                }
            }
            .frame(minHeight: Theme.Metrics.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isConnected)
        .accessibilityLabel("\(receiver.displayName), \(subtitle)")
        .accessibilityHint(isConnected ? "Already connected" : "Connect to this receiver")
    }

    private var subtitle: String {
        if receiver.role == .caster {
            return "Correction source — add it to an RTK profile as the caster"
        }
        var parts: [String] = [receiver.link.label]
        if let vendor = receiver.vendor { parts.append(vendor.label) }
        if let detail = receiver.detail { parts.append(detail) }
        return parts.joined(separator: " · ")
    }
}

/// Signal strength as bars *and* the number.
///
/// Bars alone are the reason nobody can tell a marginal Bluetooth link from a
/// good one; −92 dBm is a link that will drop when the operator turns around,
/// and it draws the same as −45 dBm on most designs.
private struct SignalBars: View {
    let bars: Int
    let rssi: Int?

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(index < bars ? tone : Theme.Palette.hairline)
                        .frame(width: 3, height: 5 + CGFloat(index) * 3)
                }
            }
            if let rssi {
                Text("\(rssi) dBm")
                    .font(Theme.Typeface.numeric(10))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rssi.map { "Signal \($0) dBm" } ?? "Signal unknown")
    }

    private var tone: Color {
        switch bars {
        case 0, 1: Theme.Palette.bad
        case 2: Theme.Palette.caution
        default: Theme.Palette.good
        }
    }
}

private struct ScanHint: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(.top, 6)
            Text(text)
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
