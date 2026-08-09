import SwiftUI

/// A named set of surveyed points.
struct PointCollection: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var crsCode: String
    var unit: String
    var points: [ControlPoint]
    var createdAt: Date = Date()

    var gcpCount: Int { points.filter { $0.role == .gcp }.count }
    var checkpointCount: Int { points.filter { $0.role == .checkpoint }.count }
}

@MainActor
final class SurveyStore: ObservableObject {
    @Published private(set) var collections: [PointCollection] = []

    private let url = CaptureWriter.projectsDirectory
        .appendingPathComponent("collections.json")

    init() { load() }

    func add(_ collection: PointCollection) {
        collections.removeAll { $0.id == collection.id }
        collections.append(collection)
        save()
    }

    func delete(_ collection: PointCollection) {
        collections.removeAll { $0.id == collection.id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(collections) else { return }
        try? data.write(to: url)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([PointCollection].self, from: data)
        else { return }
        collections = decoded
    }
}

/// The Survey tab: point collections, and importing control from a file.
struct SurveyView: View {
    @EnvironmentObject private var store: SurveyStore
    @State private var showImporter = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.collections.isEmpty {
                    empty
                } else {
                    List {
                        ForEach(store.collections) { collection in
                            NavigationLink(value: collection) {
                                CollectionRow(collection: collection)
                            }
                            .listRowBackground(Theme.Palette.surface)
                            .swipeActions {
                                Button(role: .destructive) {
                                    store.delete(collection)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.Palette.background)
            .navigationTitle("Survey")
            .navigationDestination(for: PointCollection.self) { CollectionDetailView(collection: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImporter = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Import control")
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.commaSeparatedText, .plainText, .text]
            ) { result in
                switch result {
                case .success(let url): importControl(from: url)
                case .failure(let error): importError = error.localizedDescription
                }
            }
            .alert("Import failed", isPresented: .constant(importError != nil)) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private var empty: some View {
        VStack(spacing: Theme.Metrics.gutter) {
            Spacer()
            Image(systemName: "mappin.slash")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text("No control loaded")
                .font(Theme.Typeface.title)
                .foregroundStyle(Theme.Palette.text)
            Text("Import a PNEZD point file to place captures in project coordinates "
                 + "and to grade how well they landed.")
                .font(Theme.Typeface.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Metrics.gutter * 2)
            FieldButton(title: "Import point file", systemImage: "square.and.arrow.down", role: .primary) {
                showImporter = true
            }
            .padding(.horizontal, Theme.Metrics.gutter * 2)
            Spacer()
        }
    }

    private func importControl(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let points = try PnezdParser.parse(text)
            guard !points.isEmpty else {
                importError = "No usable points were found in that file."
                return
            }
            store.add(PointCollection(
                name: url.deletingPathExtension().lastPathComponent,
                crsCode: "unknown",
                unit: "usSurveyFoot",
                points: points
            ))
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct CollectionRow: View {
    let collection: PointCollection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(collection.name)
                .font(Theme.Typeface.label(16, weight: .medium))
                .foregroundStyle(Theme.Palette.text)
            HStack(spacing: 10) {
                Text("\(collection.gcpCount) control")
                if collection.checkpointCount > 0 {
                    Text("·")
                    Text("\(collection.checkpointCount) check")
                }
                Text("·")
                Text(collection.crsCode)
            }
            .font(Theme.Typeface.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(.vertical, 6)
    }
}

struct CollectionDetailView: View {
    let collection: PointCollection

    var body: some View {
        List {
            Section {
                ForEach(collection.points) { point in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(point.id)
                                .font(Theme.Typeface.numeric(15, weight: .semibold))
                                .foregroundStyle(Theme.Palette.text)
                            if let description = point.description, !description.isEmpty {
                                Text(description)
                                    .font(Theme.Typeface.caption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.3f", point.project[1]))
                            Text(String(format: "%.3f", point.project[0]))
                        }
                        .font(Theme.Typeface.numeric(12))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        if point.role == .checkpoint {
                            StatusChip(text: "Check", tone: .caution)
                        }
                    }
                    .listRowBackground(Theme.Palette.surface)
                }
            } header: {
                Text("Northing / Easting (\(collection.unit))")
                    .font(Theme.Typeface.overline)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.background)
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// PNEZD point file parser.
///
/// PNEZD is the interchange format every surveyor already has: point number,
/// northing, easting, elevation, description. It is comma-delimited, it has no
/// header, and the column order is **N before E** — the opposite of the X, Y
/// order every graphics API uses. Swapping them silently transposes the site
/// about the 45-degree line, which is the kind of error that looks like a
/// rotation and gets blamed on the scan.
enum PnezdParser {
    static func parse(_ text: String) throws -> [ControlPoint] {
        var points: [ControlPoint] = []
        for (index, rawLine) in text.split(separator: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }

            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 4 else { continue }

            // Skip a header row if one is present, rather than failing on it.
            guard let northing = Double(fields[1]),
                  let easting = Double(fields[2]),
                  let elevation = Double(fields[3])
            else {
                if index == 0 { continue }
                continue
            }

            let description = fields.count > 4 ? fields[4] : ""
            // A description of CP/CHK/CHECK marks a checkpoint: withheld from
            // the solve so it can grade it independently.
            let isCheck = ["CHK", "CHECK", "CP"].contains(description.uppercased())

            points.append(ControlPoint(
                id: fields[0],
                // Stored X, Y, Z — easting first — because that is what every
                // consumer downstream expects. The swap happens here, once.
                project: [easting, northing, elevation],
                observed: nil,
                role: isCheck ? .checkpoint : .gcp,
                description: description.isEmpty ? nil : description,
                sigma: nil
            ))
        }
        return points
    }
}
