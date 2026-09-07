import Foundation

// On-device storage for the folders PIXMYD-Nav exports.
//
// PIXMYD-Nav writes a folder: `points.json` plus per-point PNGs, or
// `ar-model.json` plus a reference image, or both together. This store copies
// such a folder onto the device intact and indexes it, so a scanned marker can
// be resolved locally.
//
// "Locally" is the point. `points.md` is explicit: a QR payload is an
// identifier, not a data carrier, and a scanner that does not have the set
// must show the raw payload and name the set it needs rather than attempt a
// network fetch. That rule is what makes the app usable in a basement with no
// signal, and it is enforced here by the store simply having no fetch path.
//
// ## Layout
//
//     Documents/NavBundles/<bundleKey>/points.json
//                                     /ar-model.json
//                                     /P001_photo.png
//                                     /model.glb
//
// `bundleKey` is the set id when the folder carries points, otherwise the
// model id. Using the producer's own id rather than a local counter means
// importing the same export twice replaces it instead of accumulating
// near-duplicates that differ only in which one the user tapped.
//
// Foundation only, so `swift test` covers it on Linux — this is where the
// resolution rules live and they are worth testing without a phone.

/// One imported folder, as the app sees it.
struct StoredNavBundle: Identifiable, Equatable {
    /// The producer's id: set id when there are points, else model id.
    var id: String
    var directory: URL
    var pointSet: NavPointSet?
    var arBundle: NavArBundle?
    var importedAt: Date

    var displayName: String {
        if let name = pointSet?.setName, !name.isEmpty { return name }
        if let name = arBundle?.name, !name.isEmpty { return name }
        return id
    }

    var pointCount: Int { pointSet?.points.count ?? 0 }

    /// Absolute URL for a bundle-relative path from the contract, or nil when
    /// the file the JSON names is not actually there.
    ///
    /// A referenced image that is missing is explicitly not fatal: render the
    /// marker without the photo and note it once. So this returns nil rather
    /// than a URL that will fail to load later, further from the decision.
    func file(_ relative: String?) -> URL? {
        guard let relative, !relative.isEmpty else { return nil }
        // Contract paths are forward-slashed and bundle-relative. Reject any
        // attempt to climb out of the bundle directory: this data arrived over
        // a network or from a folder the user picked, and neither is trusted
        // to stay inside its own tree.
        let parts = relative.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        let url = parts.reduce(directory) { $0.appendingPathComponent($1) }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// What a resolved field-marker scan yields.
struct ResolvedNavPoint: Equatable {
    var bundle: StoredNavBundle
    var point: NavPoint
}

enum NavBundleStore {
    static let directoryName = "NavBundles"
    /// The contract file a bundle's points live in.
    ///
    /// Named here because this is what reads it. `SiteStore` writes a set the
    /// phone authored itself back through `install`, and a locally authored
    /// set that lands under any other name is a bundle this store then reports
    /// as holding no points at all.
    static let pointsFileName = "points.json"

    /// The store's root, created on demand.
    static func root(in documents: URL) -> URL {
        documents.appendingPathComponent(directoryName, isDirectory: true)
    }

    // MARK: - Reading

    /// Every bundle currently on the device, newest import first.
    ///
    /// A directory that fails to parse is skipped, not thrown: one corrupt
    /// import must not make the list unopenable. The skipped ids come back in
    /// `problems` so the UI can say so once instead of silently showing less
    /// than the user copied over.
    static func list(in documents: URL) -> (bundles: [StoredNavBundle], problems: [String]) {
        let fm = FileManager.default
        let base = root(in: documents)
        guard let entries = try? fm.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], [])
        }

        var bundles: [StoredNavBundle] = []
        var problems: [String] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            do {
                if let bundle = try load(directory: entry) {
                    bundles.append(bundle)
                }
            } catch {
                problems.append("\(entry.lastPathComponent): \(error)")
            }
        }
        return (bundles.sorted { $0.importedAt > $1.importedAt }, problems)
    }

    /// Parse one bundle directory. Returns nil when it holds neither contract
    /// file, which is how an unrelated folder is ignored rather than reported.
    static func load(directory: URL) throws -> StoredNavBundle? {
        let fm = FileManager.default

        var pointSet: NavPointSet?
        let pointsURL = directory.appendingPathComponent(pointsFileName)
        if fm.fileExists(atPath: pointsURL.path) {
            pointSet = try NavPointSet.decode(try Data(contentsOf: pointsURL))
        }

        var arBundle: NavArBundle?
        for name in ["ar-bundle.json", "ar-model.json"] {
            let url = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                arBundle = try NavArBundle.decode(try Data(contentsOf: url), file: name)
                break
            }
        }

        guard pointSet != nil || arBundle != nil else { return nil }

        let modified = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date(timeIntervalSince1970: 0)

        return StoredNavBundle(
            id: key(pointSet: pointSet, arBundle: arBundle) ?? directory.lastPathComponent,
            directory: directory,
            pointSet: pointSet,
            arBundle: arBundle,
            importedAt: modified
        )
    }

    /// The directory name a bundle is stored under.
    static func key(pointSet: NavPointSet?, arBundle: NavArBundle?) -> String? {
        if let id = pointSet?.setId, !id.isEmpty { return id }
        if let id = arBundle?.bundleId, !id.isEmpty { return id }
        return nil
    }

    // MARK: - Resolving a scan

    /// Turn a scanned marker into a point, using only what is on the device.
    ///
    /// The set is matched on the 8-character prefix the QR carries, which is
    /// all the printed marker has room for. A collision would need two sets
    /// whose UUIDs share 32 leading bits; if it ever happens the first match
    /// wins and the point id disambiguates in practice.
    static func resolve(
        point payload: PixmyPayload,
        in bundles: [StoredNavBundle]
    ) throws -> ResolvedNavPoint {
        guard case let .point(setId8, pointId) = payload else {
            throw ContractError.malformed(file: "qr", detail: "not a field marker payload")
        }
        guard let bundle = bundles.first(where: { $0.pointSet?.shortId.lowercased() == setId8 }) else {
            throw ContractError.unknownPointSet(setId: setId8)
        }
        guard let point = bundle.pointSet?.point(id: pointId) else {
            throw ContractError.unknownPoint(pointId: pointId, setId: setId8)
        }
        return ResolvedNavPoint(bundle: bundle, point: point)
    }

    static func resolve(
        bundle payload: PixmyPayload,
        in bundles: [StoredNavBundle]
    ) throws -> StoredNavBundle {
        guard case let .bundle(bundleId8) = payload else {
            throw ContractError.malformed(file: "qr", detail: "not a model bundle payload")
        }
        guard let match = bundles.first(where: { $0.arBundle?.shortId.lowercased() == bundleId8 })
                       ?? bundles.first(where: { $0.id.lowercased().hasPrefix(bundleId8) }) else {
            throw ContractError.unknownPointSet(setId: bundleId8)
        }
        return match
    }

    // MARK: - Writing

    /// Copy a folder the user picked into the store.
    ///
    /// Parsed before anything is copied, so a folder that is not an export
    /// leaves no trace and the user gets one message rather than an empty
    /// bundle appearing in the list.
    @discardableResult
    static func importFolder(at source: URL, into documents: URL) throws -> StoredNavBundle {
        guard let staged = try load(directory: source) else {
            throw ContractError.malformed(
                file: source.lastPathComponent,
                detail: "no points.json or ar-model.json in this folder"
            )
        }
        let destination = try install(
            key: staged.id,
            into: documents,
            copyingContentsOf: source
        )
        guard let bundle = try load(directory: destination) else {
            throw ContractError.malformed(file: staged.id, detail: "import did not produce a readable bundle")
        }
        return bundle
    }

    /// Write a set of received files as a bundle.
    ///
    /// This is the landing point for the LAN transfer: the files arrive as
    /// bytes with contract-relative names, and get the same validation an
    /// imported folder does. Bytes off a network are not more trusted than a
    /// folder off a thumb drive.
    @discardableResult
    static func install(
        files: [String: Data],
        into documents: URL
    ) throws -> StoredNavBundle {
        let staging = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("navbundle-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        for (name, data) in files {
            let parts = name.split(separator: "/").map(String.init)
            guard !parts.isEmpty, !parts.contains(".."), !parts.contains("") else {
                throw ContractError.malformed(file: name, detail: "unsafe path in transfer")
            }
            let url = parts.reduce(staging) { $0.appendingPathComponent($1) }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        return try importFolder(at: staging, into: documents)
    }

    /// Replace `NavBundles/<key>` with the contents of `source`.
    ///
    /// Replace rather than merge: re-exporting a set after moving a point must
    /// not leave the old photo behind to be shown next to the new coordinate.
    private static func install(
        key: String,
        into documents: URL,
        copyingContentsOf source: URL
    ) throws -> URL {
        let fm = FileManager.default
        let base = root(in: documents)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        let destination = base.appendingPathComponent(sanitised(key), isDirectory: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
        return destination
    }

    static func delete(_ bundle: StoredNavBundle) throws {
        try FileManager.default.removeItem(at: bundle.directory)
    }

    /// A producer id is a UUID in practice, but it arrives from another
    /// process and becomes a path component here, so it is filtered rather
    /// than trusted.
    static func sanitised(_ key: String) -> String {
        let allowed = key.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return allowed.isEmpty ? UUID().uuidString : String(allowed.prefix(64))
    }
}
