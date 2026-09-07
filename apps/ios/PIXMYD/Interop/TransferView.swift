import SwiftUI

// The screen behind a scanned pairing code.
//
// It names the machine on the other end before anything moves. That is not
// decoration: the user's mental model is "I scanned the code on that
// workstation", and the only way to confirm the phone agrees is to show it the
// hostname and the open document. A transfer that starts silently is a
// transfer nobody can audit.

struct TransferView: View {
    let ticket: TransferTicket

    @EnvironmentObject private var site: SiteStore
    @Environment(\.dismiss) private var dismiss

    @State private var client: NavTransferClient?
    @State private var session: TransferSession?
    @State private var phase: Phase = .connecting
    @State private var progress: NavTransferClient.Progress?

    enum Phase: Equatable {
        case connecting
        case ready
        case working(String)
        case done(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Metrics.gutter) {
                    endpoint
                    switch phase {
                    case .connecting:
                        Panel { ProgressView("Connecting…").tint(Theme.Palette.accent) }
                    case .ready:
                        offer
                    case let .working(label):
                        working(label)
                    case let .done(message):
                        result(message, tone: .good, icon: "checkmark.circle")
                    case let .failed(message):
                        result(message, tone: .bad, icon: "exclamationmark.triangle")
                    }
                }
                .padding(Theme.Metrics.gutter)
            }
            .background(Theme.Palette.background)
            .navigationTitle("Transfer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task { await connect() }
    }

    // MARK: - Sections

    private var endpoint: some View {
        Panel(title: "Host") {
            Text(session?.hostSummary ?? "\(ticket.host):\(ticket.port)")
                .font(Theme.Typeface.body)
                .foregroundStyle(Theme.Palette.text)
            Text("\(ticket.host):\(ticket.port) on this network")
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    @ViewBuilder
    private var offer: some View {
        if let session {
            if let download = session.download, !download.files.isEmpty {
                Panel(title: "Available to download") {
                    Text(download.name.isEmpty ? download.kind.label : download.name)
                        .font(Theme.Typeface.title)
                        .foregroundStyle(Theme.Palette.text)
                    Text("\(download.kind.label) · \(download.files.count) file(s) · "
                       + byteLabel(download.totalBytes))
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    FieldButton(title: "Download to this phone", systemImage: "arrow.down.circle", role: .primary) {
                        Task { await runDownload(download) }
                    }
                }
            }

            if session.canUpload {
                Panel(title: "Send back") {
                    Text("This session accepts a scan. Pick the point set it was aligned to, "
                       + "then choose the scan.")
                        .font(Theme.Typeface.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    NavigationLink {
                        CaptureSendPicker(client: client, policy: session.upload)
                    } label: {
                        // Matches FieldButton's shape without being a Button
                        // inside a NavigationLink, which swallows the tap.
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.circle")
                            Text("Choose a scan to send")
                        }
                        .font(Theme.Typeface.label(16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Metrics.minimumTapTarget + 6)
                        .foregroundStyle(Theme.Palette.text)
                        .background(
                            Theme.Palette.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius)
                        )
                    }
                }
            }
        }
    }

    private func working(_ label: String) -> some View {
        Panel(title: "Transferring") {
            if let progress {
                ProgressView(value: progress.fraction)
                    .tint(Theme.Palette.accent)
                Text(progress.label)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else {
                ProgressView(label).tint(Theme.Palette.accent)
            }
        }
    }

    private func result(_ message: String, tone: Readout.Tone, icon: String) -> some View {
        Panel {
            HStack(alignment: .top, spacing: Theme.Metrics.gutterTight) {
                Image(systemName: icon).foregroundStyle(tone.color)
                Text(message)
                    .font(Theme.Typeface.body)
                    .foregroundStyle(Theme.Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FieldButton(title: "Done", systemImage: "checkmark") { dismiss() }
        }
    }

    // MARK: - Work

    private func connect() async {
        let client = NavTransferClient(ticket: ticket)
        self.client = client
        do {
            session = try await client.openSession()
            phase = .ready
        } catch {
            phase = .failed("\(error)")
        }
    }

    private func runDownload(_ offer: TransferOffer) async {
        guard let client else { return }
        phase = .working("Downloading")
        do {
            let bundle = try await client.download(offer, into: site.documentsURL) { progress in
                self.progress = progress
            }
            site.reload()
            phase = .done("\(bundle.displayName) is on this phone — \(bundle.pointCount) point(s).")
        } catch {
            phase = .failed("\(error)")
        }
        progress = nil
    }

    /// Statements rather than one ternary mixing interpolation, `max` and
    /// integer division — the shape that timed out the type checker in
    /// `ReceiverScanView`, which the Linux CI cannot see because it only parses
    /// this half of the app.
    private func byteLabel(_ bytes: Int) -> String {
        if bytes < 1_048_576 {
            let kilobytes: Int = Swift.max(1, bytes / 1024)
            return String(kilobytes) + " KB"
        }
        let megabytes: Double = Double(bytes) / 1_048_576
        return String(format: "%.1f MB", megabytes)
    }
}

// MARK: - Sending a capture over a live session

/// Pick the point set and the scan, then send.
private struct CaptureSendPicker: View {
    let client: NavTransferClient?
    let policy: TransferUploadPolicy

    @EnvironmentObject private var site: SiteStore
    @EnvironmentObject private var projects: ProjectStore
    @Environment(\.dismiss) private var dismiss

    /// Empty means "the points placed on this phone" — which is now the normal
    /// case, not a fallback. A crew walking a space for the first time has no
    /// set from the workstation to align against, and used to be stopped here.
    @State private var selectedSetId: String = ""
    @State private var phase: CaptureSendPickerPhase = .idle
    @State private var progress: NavTransferClient.Progress?

    private var sets: [NavPointSet] {
        site.bundles.compactMap { $0.pointSet }
    }

    private var selectedSet: NavPointSet? {
        sets.first { $0.setId == selectedSetId }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Metrics.gutter) {
                setPicker
                CaptureSendBody(
                    pointSet: selectedSet,
                    phase: $phase,
                    progress: $progress
                ) { files in
                    guard let client else {
                        throw TransferError.rejected("The session has closed.")
                    }
                    return try await client.upload(files: files, policy: policy) { p in
                        progress = p
                    }
                }
            }
            .padding(Theme.Metrics.gutter)
        }
        .background(Theme.Palette.background)
        .navigationTitle("Send a scan")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var setPicker: some View {
        Panel(title: "Aligned to") {
            Picker("Point set", selection: $selectedSetId) {
                Text("Points placed on this phone").tag("")
                ForEach(sets, id: \.setId) { set in
                    Text(set.setName.isEmpty ? set.setId : set.setName).tag(set.setId)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.Palette.accent)

            Text(selectedSet == nil
                 ? "The ids you placed travel with the scan. Place the same ids on the model "
                 + "in PIXMYD-Nav and it registers the two sets there."
                 : "The scan is registered here against a set from PIXMYD-Nav, and arrives "
                 + "already in model coordinates.")
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The part shared by "send over this session" and "export to Files": pick a
/// processed scan, show the fit, package it.
struct CaptureSendBody: View {
    /// The set from PIXMYD-Nav this scan was aligned to, when there is one.
    /// Nil means the scan carries points placed on this phone instead, and the
    /// registration happens at the workstation.
    let pointSet: NavPointSet?
    @Binding var phase: CaptureSendPickerPhase
    @Binding var progress: NavTransferClient.Progress?
    /// What to do with the packaged bytes. Returning a commit result means the
    /// host accepted it; throwing surfaces the message.
    let send: ([String: Data]) async throws -> TransferCommitResult

    @EnvironmentObject private var site: SiteStore
    @EnvironmentObject private var projects: ProjectStore
    @State private var selectedProjectId: String?

    private var processed: [CaptureProject] {
        projects.projects.filter { $0.state == .processed }
    }

    private var selectedProject: CaptureProject? {
        guard let selectedProjectId else { return processed.first }
        return processed.first { $0.id == selectedProjectId }
    }

    /// The points placed on the phone during the selected capture, if any.
    ///
    /// Read off disk rather than held in a store: they live in the project
    /// directory beside the frames they were placed during, and the directory
    /// is the source of truth for everything else this app records.
    private var fieldPoints: FieldPointSet? {
        guard let selectedProject else { return nil }
        guard let set = FieldPointSet.load(in: selectedProject.url), !set.isEmpty else { return nil }
        return set
    }

    var body: some View {
        VStack(spacing: Theme.Metrics.gutter) {
            fit
            scanPicker
            action
        }
    }

    @ViewBuilder
    private var fit: some View {
        if let pointSet {
            navSetFit(pointSet)
        } else {
            fieldPointFit
        }
    }

    /// What travels when the points came from this phone.
    ///
    /// There is no fit to show, and saying so is the honest thing: the model
    /// frame does not exist here, which is the entire reason the ids are being
    /// sent. What can be said is whether the set is capable of registering
    /// anything once it gets there, and that is worth saying while the operator
    /// is still standing in the space.
    private var fieldPointFit: some View {
        Panel(title: "Points on this scan") {
            if let fieldPoints {
                HStack(spacing: Theme.Metrics.gutter) {
                    Readout(label: "Placed", value: "\(fieldPoints.points.count)")
                    Readout(
                        label: "Spread",
                        value: String(format: "%.1f", fieldPoints.baselineMetres),
                        unit: "m"
                    )
                    Readout(
                        label: "Measured",
                        value: "\(fieldPoints.points.filter { $0.source.isMeasured }.count)"
                    )
                }
                Text(CaptureExport.registrationReadiness(fieldPoints))
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(fieldPoints.canRegister ? Theme.Palette.textSecondary : Theme.Palette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Place P001 upward on the model in PIXMYD-Nav and it will register the two "
                   + "sets and put the scan where it belongs.")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No points were placed during this scan, and no set from PIXMYD-Nav is "
                   + "selected. The scan will arrive with nothing to align it, and somebody "
                   + "will have to place it by eye.")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func navSetFit(_ pointSet: NavPointSet) -> some View {
        Panel(title: "Fit") {
            switch site.solve(for: pointSet) {
            case let .success(solved)?:
                HStack(spacing: Theme.Metrics.gutter) {
                    Readout(
                        label: "RMS",
                        value: String(format: "%.0f", solved.solution.rmsError * 1000),
                        unit: "mm"
                    )
                    Readout(
                        label: "Max",
                        value: String(format: "%.0f", solved.solution.maxError * 1000),
                        unit: "mm"
                    )
                    Readout(label: "Points", value: "\(solved.solution.pairCount)")
                }
                Text(solved.grade.guidance)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

            case let .failure(error)?:
                Text(String(describing: error))
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The scan can still be sent. Navisworks will offer to solve it there — "
                   + "the raw positions travel with it.")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

            case nil:
                Text(unsolvedText)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(unsolvedTone)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // Statements, not a ternary inlined into `Text(...)`: that shape has failed
    // to type-check three times in this app already.

    private var unsolvedText: String {
        if pointSet?.isCaptureFrame == true {
            return "These points were placed on this phone, so there is nothing to solve "
                 + "against yet. The scan travels with its ids and their positions; press "
                 + "Seed phone points in PIXMYD-Nav, click each id on the model, and the fit "
                 + "is computed there."
        }
        return "No points located against this set. The scan will be sent with its raw "
             + "observations only, and placed by hand in Navisworks."
    }

    /// Not a warning for a phone-authored set: nothing is wrong, the solve
    /// simply happens at the other end.
    private var unsolvedTone: Color {
        pointSet?.isCaptureFrame == true ? Theme.Palette.textSecondary : Theme.Palette.caution
    }

    private var scanPicker: some View {
        Panel(title: "Scan") {
            if processed.isEmpty {
                Text("No processed scans on this phone. Process a capture in Projects first — "
                   + "a scan has to be fused before there is a mesh to place.")
                    .font(Theme.Typeface.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Scan", selection: Binding(
                    get: { selectedProject?.id ?? "" },
                    set: { selectedProjectId = $0 }
                )) {
                    ForEach(processed) { project in
                        Text(project.name).tag(project.id)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.Palette.accent)
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        switch phase {
        case .idle:
            FieldButton(title: "Send", systemImage: "arrow.up.circle", role: .primary) {
                Task { await run() }
            }
            .disabled(selectedProject == nil)
            .opacity(selectedProject == nil ? 0.5 : 1)

        case .working:
            Panel {
                if let progress {
                    ProgressView(value: progress.fraction).tint(Theme.Palette.accent)
                    Text(progress.currentFile).font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    ProgressView("Packaging…").tint(Theme.Palette.accent)
                }
            }

        case let .done(message):
            Panel {
                Text(message)
                    .font(Theme.Typeface.body)
                    .foregroundStyle(Theme.Palette.good)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The scan stays on this phone. Nothing was deleted.")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }

        case let .failed(message):
            Panel {
                Text(message)
                    .font(Theme.Typeface.body)
                    .foregroundStyle(Theme.Palette.bad)
                    .fixedSize(horizontal: false, vertical: true)
                FieldButton(title: "Try again", systemImage: "arrow.clockwise") {
                    phase = .idle
                }
            }
        }
    }

    private func run() async {
        guard let project = selectedProject else { return }
        phase = .working
        do {
            let placed = fieldPoints
            let solved = pointSet.flatMap { try? site.solve(for: $0)?.get() }
            // Whichever end placed the points, the observations travel: from a
            // Nav set they are the markers the operator located, and from this
            // phone they are the points themselves. The consumer can re-solve
            // either way rather than trust a number it cannot check.
            let correspondences = pointSet.map { site.correspondences(for: $0) }
                ?? placed?.correspondences
                ?? []

            let files = try CaptureUpload.package(
                project: project,
                pointSet: pointSet,
                fieldPoints: placed,
                correspondences: correspondences,
                solved: solved
            )
            let result = try await send(files)
            phase = .done(result.message.isEmpty
                ? "Sent. Review the fit in Navisworks before placing it."
                : result.message)
        } catch {
            phase = .failed("\(error)")
        }
        progress = nil
    }
}

/// Named separately so both the picker and the body can bind to it without one
/// importing the other's private type.
enum CaptureSendPickerPhase: Equatable {
    case idle
    case working
    case done(String)
    case failed(String)
}

/// Standalone "send a scan" entry point from a bundle, without a live session.
///
/// It packages exactly the same bytes and hands them to the share sheet. The
/// no-network path is not a fallback bolted on afterwards — it is the one that
/// works when the workstation is on a different VLAN, which on a real site is
/// most of the time.
struct CaptureSendView: View {
    let pointSet: NavPointSet?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var site: SiteStore
    @EnvironmentObject private var projects: ProjectStore

    @State private var phase: CaptureSendPickerPhase = .idle
    @State private var progress: NavTransferClient.Progress?
    @State private var exported: ExportedFolder?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Metrics.gutter) {
                    Panel(title: "Where it goes") {
                        Text("This writes capture.json, capture.fbx and — when you placed "
                           + "points on this scan — points.json, then hands them to the share "
                           + "sheet. Save them somewhere PIXMYD-Nav can open, or scan a "
                           + "transfer code to send them straight to the workstation.")
                            .font(Theme.Typeface.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    CaptureSendBody(
                        pointSet: pointSet,
                        phase: $phase,
                        progress: $progress
                    ) { files in
                        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                            .appendingPathComponent("capture-\(UUID().uuidString)", isDirectory: true)
                        try CaptureUpload.write(files, into: directory)
                        exported = ExportedFolder(url: directory)
                        return TransferCommitResult(
                            accepted: true,
                            captureId: nil,
                            message: "Written. Share it to the workstation."
                        )
                    }
                }
                .padding(Theme.Metrics.gutter)
            }
            .background(Theme.Palette.background)
            .navigationTitle("Send a scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(item: $exported) { folder in
                ShareSheet(items: [folder.url])
            }
        }
    }
}

/// A wrapper rather than a retroactive `URL: Identifiable` conformance.
///
/// Conforming a standard-library type to a standard-library protocol from an
/// app target is a landmine: the day Foundation adds the same conformance the
/// build breaks, and nothing in the diff explains why.
struct ExportedFolder: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
