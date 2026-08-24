import Foundation
import UIKit
import SwiftUI

// The observable wrapper around `NavBundleStore`, plus the observations the
// operator records against a point set.
//
// The store itself is pure and tested; this is the part that holds it in
// memory for SwiftUI and owns the one piece of mutable state the interop
// feature has — which points have been located in the real world, and where.
//
// Observations are kept per point set rather than per capture. A crew locates
// the column marks once and then scans three rooms; making them re-locate the
// same marks for each scan would be the fastest way to ensure nobody uses the
// feature twice.

@MainActor
final class SiteStore: ObservableObject {
    @Published private(set) var bundles: [StoredNavBundle] = []
    /// Directories that failed to parse, reported once rather than silently
    /// showing the user fewer bundles than they copied over.
    @Published private(set) var problems: [String] = []
    /// Observed positions, keyed by set id then point id, in the capture
    /// frame, metres.
    @Published private(set) var observations: [String: [String: SIMD3<Double>]] = [:]

    private let documents: URL

    init(documents: URL? = nil) {
        self.documents = documents
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        reload()
        loadObservations()
    }

    var documentsURL: URL { documents }

    // MARK: - Bundles

    func reload() {
        let result = NavBundleStore.list(in: documents)
        bundles = result.bundles
        problems = result.problems
    }

    func bundle(setId: String) -> StoredNavBundle? {
        bundles.first { $0.pointSet?.setId == setId }
    }

    @discardableResult
    func importFolder(at url: URL) throws -> StoredNavBundle {
        // A folder picked through `fileImporter` is outside the app container
        // and has to be opened explicitly, or every read fails with a
        // permission error that reads like a corrupt file.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let bundle = try NavBundleStore.importFolder(at: url, into: documents)
        reload()
        return bundle
    }

    func install(files: [String: Data]) throws -> StoredNavBundle {
        let bundle = try NavBundleStore.install(files: files, into: documents)
        reload()
        return bundle
    }

    func delete(_ bundle: StoredNavBundle) {
        try? NavBundleStore.delete(bundle)
        if let setId = bundle.pointSet?.setId {
            observations[setId] = nil
            saveObservations()
        }
        reload()
    }

    // MARK: - Resolving a scan

    /// What a scanned code turned out to be.
    enum ScanOutcome {
        case point(ResolvedNavPoint)
        case bundle(StoredNavBundle)
        case transfer(TransferTicket)
        /// A `pixmy://` code this device cannot resolve. The raw payload is
        /// carried so the UI can show it — the contract requires a scanner
        /// without the set to show the payload and name the set it needs,
        /// rather than attempt a fetch.
        case unresolved(payload: String, reason: String)
        /// A QR code that is not ours at all.
        case foreign(String)
    }

    func resolve(_ raw: String) -> ScanOutcome {
        guard let payload = PixmyPayload.parse(raw) else {
            return .foreign(raw)
        }
        switch payload {
        case .point:
            do {
                return .point(try NavBundleStore.resolve(point: payload, in: bundles))
            } catch {
                return .unresolved(payload: raw, reason: "\(error)")
            }
        case .bundle:
            do {
                return .bundle(try NavBundleStore.resolve(bundle: payload, in: bundles))
            } catch {
                return .unresolved(payload: raw, reason: "\(error)")
            }
        case let .transfer(ticket):
            return .transfer(ticket)
        }
    }

    // MARK: - Observations

    func observation(setId: String, pointId: String) -> SIMD3<Double>? {
        observations[setId]?[pointId]
    }

    func record(setId: String, pointId: String, observed: SIMD3<Double>) {
        observations[setId, default: [:]][pointId] = observed
        saveObservations()
    }

    func clearObservation(setId: String, pointId: String) {
        observations[setId]?[pointId] = nil
        saveObservations()
    }

    func clearObservations(setId: String) {
        observations[setId] = nil
        saveObservations()
    }

    func observedCount(setId: String) -> Int {
        observations[setId]?.count ?? 0
    }

    /// The correspondences for a set, in point order so a solve is
    /// reproducible from the same data.
    func correspondences(for set: NavPointSet) -> [CaptureCorrespondence] {
        let recorded = observations[set.setId] ?? [:]
        return set.points.compactMap { point in
            guard let observed = recorded[point.id] else { return nil }
            return CaptureCorrespondence(pointId: point.id, observed: observed)
        }
    }

    /// Solve a set's recorded observations, or nil when there is nothing to
    /// solve. Errors are returned rather than thrown so the caller can show
    /// the solver's own wording next to a disabled button.
    func solve(for set: NavPointSet) -> Result<CaptureSolution, Error>? {
        // A set the phone authored has its observed positions *as* its
        // coordinates, so a solve against it is the identity with zero error —
        // a perfect-looking fit that means nothing. There is nothing to solve
        // until the same ids are picked on the model, which happens in
        // Navisworks, so say nothing here rather than something reassuring.
        guard !set.isCaptureFrame else { return nil }
        let pairs = correspondences(for: set)
        guard !pairs.isEmpty else { return nil }
        do {
            return .success(try CaptureExport.solve(pointSet: set, correspondences: pairs))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Points placed on this phone

    /// The set this phone authored, if there is one.
    ///
    /// One per device rather than one per job: a second local set would need a
    /// name, and naming a thing before it has any points in it is the step
    /// everyone skips. Marks accumulate into the same set and the workstation
    /// sorts out which job they belong to, which it has to do anyway.
    var localBundle: StoredNavBundle? {
        bundles.first { $0.pointSet?.isCaptureFrame == true }
    }

    /// Add a mark at `observed` — metres, in the AR session's world frame —
    /// to the phone's own set, creating that set the first time.
    ///
    /// The position is written twice on purpose: once as the point's
    /// coordinate, because in the capture frame that is what it is, and once as
    /// an observation, because that is the column `correspondences(for:)`
    /// reads. Placing a mark and locating it are the same act here.
    @discardableResult
    func placeLocalPoint(at observed: SIMD3<Double>, label: String = "") throws -> StoredNavBundle {
        let existing = localBundle?.pointSet
        let base = existing ?? NavPointSet.local(
            name: "Placed on site",
            device: UIDevice.current.model,
            createdUtc: Self.timestamp()
        )
        let updated = base.addingLocalPoint(at: observed, label: label)
        let bundle = try installLocal(updated)
        if let placed = updated.points.last {
            record(setId: updated.setId, pointId: placed.id, observed: observed)
        }
        return bundle
    }

    /// Remove one mark from the phone's own set, and the observation with it.
    func removeLocalPoint(id: String) throws {
        guard let set = localBundle?.pointSet else { return }
        _ = try installLocal(set.removingPoint(id: id))
        clearObservation(setId: set.setId, pointId: id)
    }

    /// Write a locally authored set back to disk as a bundle.
    ///
    /// Through `NavBundleStore.install` rather than a private path: the store
    /// keys a bundle on its set id and replaces the folder, so re-writing the
    /// set after every mark updates one bundle instead of accumulating a
    /// folder per point. Everything downstream — the list, the observations,
    /// sending a scan back — then works on it without knowing it was authored
    /// here rather than imported.
    private func installLocal(_ set: NavPointSet) throws -> StoredNavBundle {
        try install(files: [CaptureUpload.pointsFileName: try set.renderJson()])
    }

    nonisolated private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    // MARK: - Persistence

    /// Observations live in one small file rather than inside each bundle, so
    /// re-importing a point set — which deliberately replaces the folder —
    /// does not throw away work done in the field against it.
    private var observationsURL: URL {
        documents.appendingPathComponent("nav-observations.json")
    }

    private struct StoredObservation: Codable {
        var setId: String
        var pointId: String
        var observed: [Double]
    }

    private func loadObservations() {
        guard let data = try? Data(contentsOf: observationsURL),
              let rows = try? JSONDecoder().decode([StoredObservation].self, from: data) else { return }
        var map: [String: [String: SIMD3<Double>]] = [:]
        for row in rows where row.observed.count == 3 {
            map[row.setId, default: [:]][row.pointId] =
                SIMD3<Double>(row.observed[0], row.observed[1], row.observed[2])
        }
        observations = map
    }

    private func saveObservations() {
        let rows = observations.flatMap { setId, points in
            points.map { StoredObservation(setId: setId, pointId: $0.key, observed: [$0.value.x, $0.value.y, $0.value.z]) }
        }
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? data.write(to: observationsURL, options: .atomic)
    }
}
