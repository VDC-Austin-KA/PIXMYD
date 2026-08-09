import Foundation
import SwiftUI

/// A captured project on disk.
struct CaptureProject: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var url: URL
    var capturedAt: Date
    var frameCount: Int
    var hasDepth: Bool
    var state: State
    /// Set once the capture has been fitted to control.
    var registrationRms: Double?

    enum State: String, Codable, CaseIterable, Identifiable {
        case captured, processing, processed, failed
        var id: String { rawValue }

        var label: String {
            switch self {
            case .captured: "Captured"
            case .processing: "Processing"
            case .processed: "Processed"
            case .failed: "Failed"
            }
        }

        var tone: Readout.Tone {
            switch self {
            case .captured: .neutral
            case .processing: .caution
            case .processed: .good
            case .failed: .bad
            }
        }
    }

    func renamed(to newName: String) -> CaptureProject {
        var copy = self
        copy.name = newName
        return copy
    }

    var byteSize: Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}

/// Owns the on-disk project list.
///
/// Projects live as directories under Documents/Projects, and the directory is
/// the source of truth rather than a database. That matters for a field tool:
/// if the app is deleted, reinstalled, or crashes badly enough to lose its
/// index, the captures are still there and still readable — they are plain
/// files in a documented layout, not rows in a schema only this app understands.
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [CaptureProject] = []
    @Published var searchText = ""
    @Published var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all, captured, processing, processed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "All"
            case .captured: "Captured"
            case .processing: "Processing"
            case .processed: "Processed"
            }
        }
    }

    private let indexURL = CaptureWriter.projectsDirectory
        .appendingPathComponent("index.json")

    init() {
        load()
    }

    var visible: [CaptureProject] {
        projects
            .filter { project in
                switch filter {
                case .all: true
                case .captured: project.state == .captured
                case .processing: project.state == .processing
                case .processed: project.state == .processed
                }
            }
            .filter {
                searchText.isEmpty
                    || $0.name.localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    func add(_ project: CaptureProject) {
        projects.removeAll { $0.id == project.id }
        projects.append(project)
        save()
    }

    func update(_ project: CaptureProject) { add(project) }

    func delete(_ project: CaptureProject) {
        try? FileManager.default.removeItem(at: project.url)
        projects.removeAll { $0.id == project.id }
        save()
    }

    func rename(_ project: CaptureProject, to name: String) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].name = name
        save()
    }

    func suggestedName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "Scan \(formatter.string(from: Date()))"
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: indexURL)
    }

    /// Load the index, then reconcile it against what is actually on disk.
    ///
    /// The reconciliation is the important half. The index can disagree with
    /// the filesystem in both directions — a directory deleted through the
    /// Files app leaves a stale entry, and a capture interrupted before its
    /// manifest was written leaves a directory with no entry. Both are recovered
    /// rather than reported as corruption.
    private func load() {
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([CaptureProject].self, from: data) {
            projects = decoded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }

        let known = Set(projects.map(\.url.lastPathComponent))
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: CaptureWriter.projectsDirectory,
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []

        for url in contents where url.pathExtension == BundleFormat.directoryExtension {
            guard !known.contains(url.lastPathComponent) else { continue }
            if let recovered = try? CaptureWriter.recover(at: url) {
                projects.append(recovered)
            } else if let project = Self.readManifest(at: url) {
                projects.append(project)
            }
        }
        save()
    }

    private static func readManifest(at url: URL) -> CaptureProject? {
        let manifestURL = url.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(CaptureManifest.self, from: data)
        else { return nil }
        return CaptureProject(
            id: manifest.id,
            name: manifest.name,
            url: url,
            capturedAt: ISO8601DateFormatter().date(from: manifest.startedAt) ?? Date(),
            frameCount: manifest.frameCount,
            hasDepth: manifest.device.hasMetricDepth ?? false,
            state: .captured
        )
    }
}
