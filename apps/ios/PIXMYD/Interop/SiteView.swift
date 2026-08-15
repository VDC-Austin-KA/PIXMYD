import SwiftUI
import UniformTypeIdentifiers

// The Site tab: the point sets and model bundles this device holds, where they
// came from, and what has been located in the field against them.
//
// This is the consumer end of `points.md`. Everything it shows arrived either
// by a transfer the user started or by a folder the user picked; there is no
// path here that reaches the network on its own, and no path that resolves a
// scanned marker against anything but local data.

struct SiteView: View {
    @EnvironmentObject private var site: SiteStore

    @State private var scanning = false
    @State private var importing = false
    @State private var message: Message?
    @State private var pendingTicket: TransferTicket?
    @State private var resolvedPoint: ResolvedNavPoint?

    struct Message: Identifiable {
        let id = UUID()
        var title: String
        var detail: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Metrics.gutter) {
                    actions
                    if site.bundles.isEmpty {
                        empty
                    } else {
                        ForEach(site.bundles) { bundle in
                            NavigationLink(value: bundle.id) {
                                SiteBundleCard(bundle: bundle, observed: observedCount(bundle))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !site.problems.isEmpty {
                        problemsPanel
                    }
                }
                .padding(Theme.Metrics.gutter)
            }
            .background(Theme.Palette.background)
            .navigationTitle("Site")
            .navigationDestination(for: String.self) { id in
                if let bundle = site.bundles.first(where: { $0.id == id }) {
                    SiteBundleView(bundle: bundle)
                }
            }
        }
        .sheet(isPresented: $scanning) {
            ScanSheet { raw in
                scanning = false
                handle(scan: raw)
            }
        }
        .sheet(item: $pendingTicket) { ticket in
            TransferView(ticket: ticket)
        }
        .sheet(item: $resolvedPoint) { resolved in
            NavigationStack {
                NavPointDetailView(bundle: resolved.bundle, point: resolved.point)
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert(item: $message) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.detail),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Pieces

    private var actions: some View {
        VStack(spacing: Theme.Metrics.gutterTight) {
            FieldButton(title: "Scan a code", systemImage: "qrcode.viewfinder", role: .primary) {
                scanning = true
            }
            FieldButton(title: "Import a folder", systemImage: "folder.badge.plus") {
                importing = true
            }
        }
    }

    private var empty: some View {
        Panel(title: "Nothing here yet") {
            Text("Scan the transfer code shown by PIXMYD-Nav to pull a point set over the "
               + "local network, or import a folder that was copied to this device.")
                .font(Theme.Typeface.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Both paths end up in the same place. The transfer is faster; the folder works "
               + "with no network at all.")
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var problemsPanel: some View {
        Panel(title: "Could not read") {
            ForEach(site.problems, id: \.self) { problem in
                Text(problem)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    private func observedCount(_ bundle: StoredNavBundle) -> Int {
        guard let setId = bundle.pointSet?.setId else { return 0 }
        return site.observedCount(setId: setId)
    }

    private func handle(scan raw: String) {
        switch site.resolve(raw) {
        case let .point(resolved):
            resolvedPoint = resolved

        case let .bundle(bundle):
            message = Message(
                title: bundle.displayName,
                detail: bundle.arBundle?.hasGeometry == true
                    ? "This model bundle is on the device."
                    : "This bundle is on the device. It carries no model geometry, so it can show "
                    + "where the model is but not draw it over the room."
            )

        case let .transfer(ticket):
            pendingTicket = ticket

        case let .unresolved(payload, reason):
            // The contract's rule: name the set that is needed, show the raw
            // payload, and do not fetch.
            message = Message(
                title: "Not on this device",
                detail: "\(reason)\n\n\(payload)"
            )

        case let .foreign(raw):
            message = Message(
                title: "Not a PIXMYD code",
                detail: raw.count > 200 ? String(raw.prefix(200)) + "…" : raw
            )
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            do {
                let bundle = try site.importFolder(at: url)
                message = Message(
                    title: "Imported",
                    detail: "\(bundle.displayName) — \(bundle.pointCount) point(s)."
                )
            } catch {
                message = Message(title: "Could not import", detail: "\(error)")
            }
        case let .failure(error):
            message = Message(title: "Could not import", detail: "\(error)")
        }
    }
}

// `sheet(item:)` needs identity; a ticket is identified by the session it opens.
extension TransferTicket: Identifiable {
    var id: String { "\(host):\(port)/\(token)" }
}

extension ResolvedNavPoint: Identifiable {
    var id: String { "\(bundle.id)/\(point.id)" }
}

// MARK: - Bundle card

private struct SiteBundleCard: View {
    let bundle: StoredNavBundle
    let observed: Int

    var body: some View {
        Panel {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(bundle.displayName)
                        .font(Theme.Typeface.title)
                        .foregroundStyle(Theme.Palette.text)
                    Text(subtitle)
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            HStack(spacing: Theme.Metrics.gutterTight) {
                if bundle.pointCount > 0 {
                    StatusChip(
                        text: "\(observed)/\(bundle.pointCount) located",
                        tone: observed >= 3 ? .good : .neutral,
                        systemImage: "mappin"
                    )
                }
                if bundle.arBundle != nil {
                    StatusChip(
                        text: bundle.arBundle?.hasGeometry == true ? "Model" : "Model (no geometry)",
                        tone: bundle.arBundle?.hasGeometry == true ? .good : .caution,
                        systemImage: "cube"
                    )
                }
            }
        }
    }

    private var subtitle: String {
        let document = bundle.pointSet?.provenance.sourceDocument
            ?? bundle.arBundle?.provenance.sourceDocument
            ?? ""
        return document.isEmpty ? bundle.id : document
    }
}

// MARK: - Scan sheet

struct ScanSheet: View {
    let onScan: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let failure {
                    UnavailableNotice(title: "Cannot scan", detail: failure, systemImage: "camera.fill")
                        .padding(Theme.Metrics.gutter)
                } else {
                    QrScannerView(
                        onScan: onScan,
                        onFailure: { failure = $0 }
                    )
                    .ignoresSafeArea()

                    VStack {
                        Spacer()
                        Text("Point the camera at a field marker or a transfer code.")
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(.white)
                            .padding(Theme.Metrics.gutter)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, Theme.Metrics.gutter * 2)
                    }
                }
            }
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
