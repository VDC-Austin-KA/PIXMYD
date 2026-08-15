import Foundation

// The on-disk JSON that PIXMYD-Nav and this app use to talk to each other.
//
// The schema is not owned by either side: it is written down in the suite's
// `docs/contracts/` directory and both ends read it. That is the whole reason
// this file exists as a separate, dependency-free layer rather than as ad-hoc
// parsing inside a view — a contract you can only see by reading a decoder is
// not a contract.
//
// Three rules from `contracts/README.md` are load-bearing here and are
// implemented rather than assumed:
//
//   1. `contractVersion` is the first field and consumers check the MAJOR
//      version only. A 1.4 file is read by a 1.0 consumer; a 2.0 file is
//      refused with one clear line.
//   2. A missing or malformed file is not an error. It greys a feature out.
//      Nothing in this file throws for absence — that is the caller's job to
//      report, not to crash on.
//   3. Never remove or repurpose a field; only add optional ones. Everything
//      the producer may legitimately omit is `Optional` here, and everything
//      the contract says is "empty string, never null" is decoded through
//      `decodeIfPresent ?? ""` so a null from a future writer still lands as
//      the documented empty string rather than a decode failure.
//
// This file is in `Package.swift`'s `portableSources`, so `swift test` on
// Linux compiles and exercises it. Keep it Foundation-only.

// MARK: - Version gate

/// The contract major version this build speaks.
///
/// Bumping this is a suite-wide decision, not a local one — the producing
/// plugin and every other consumer have to move together.
enum ContractVersion {
    static let supportedMajor = 1

    /// Parses `"1.0"` / `"1"` / `"1.4.2"` and returns the major component.
    ///
    /// Returns nil for anything that is not a leading integer, which is
    /// treated the same as a version mismatch: refuse, do not guess.
    static func major(of raw: String) -> Int? {
        let head = raw.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first
        guard let head, let value = Int(head) else { return nil }
        return value
    }

    static func isSupported(_ raw: String) -> Bool {
        major(of: raw) == supportedMajor
    }
}

/// Why a contract file could not be used.
///
/// Every case carries enough text to be shown to a user verbatim. The contract
/// requires one clear line, and a case that cannot produce one is not useful.
enum ContractError: Error, CustomStringConvertible, Equatable {
    case unsupportedVersion(found: String, supported: Int)
    case malformed(file: String, detail: String)
    case unknownPointSet(setId: String)
    case unknownPoint(pointId: String, setId: String)

    var description: String {
        switch self {
        case let .unsupportedVersion(found, supported):
            return "This file is contract version \(found); this app reads version \(supported).x. "
                 + "Update PIXMYD or re-export from a matching PIXMYD-Nav."
        case let .malformed(file, detail):
            return "\(file) could not be read: \(detail)"
        case let .unknownPointSet(setId):
            return "No point set on this device starts with \(setId). Transfer that set first."
        case let .unknownPoint(pointId, setId):
            return "Point set \(setId) does not contain a point called \(pointId)."
        }
    }
}

// MARK: - Provenance

/// The units / origin block every contract file carries.
///
/// The field names are namespaced `navex:` because NavEx's glTF writer defined
/// this block first and the suite deliberately has one convention rather than
/// two. The namespace is part of the key, not decoration — do not "clean" it.
///
/// `appliedOffset` is the one field with real arithmetic consequence: the
/// producer subtracts it, so adding it back returns a coordinate to the source
/// model's world space. Everything this app draws stays in the exported frame;
/// the offset only matters when handing coordinates back.
struct NavProvenance: Codable, Equatable {
    var sourceDocument: String
    var sourceUnits: String
    var targetUnits: String
    var upAxis: String
    var originMode: String
    var appliedOffset: [Double]
    var offsetNote: String?
    var exportedUtc: String?

    enum CodingKeys: String, CodingKey {
        case sourceDocument = "navex:sourceDocument"
        case sourceUnits    = "navex:sourceUnits"
        case targetUnits    = "navex:targetUnits"
        case upAxis         = "navex:upAxis"
        case originMode     = "navex:originMode"
        case appliedOffset  = "navex:appliedOffset"
        case offsetNote     = "navex:offsetNote"
        case exportedUtc    = "navex:exportedUtc"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceDocument = try c.decodeIfPresent(String.self, forKey: .sourceDocument) ?? ""
        sourceUnits    = try c.decodeIfPresent(String.self, forKey: .sourceUnits) ?? ""
        targetUnits    = try c.decodeIfPresent(String.self, forKey: .targetUnits) ?? "Meters"
        upAxis         = try c.decodeIfPresent(String.self, forKey: .upAxis) ?? "Z"
        originMode     = try c.decodeIfPresent(String.self, forKey: .originMode) ?? ""
        appliedOffset  = try c.decodeIfPresent([Double].self, forKey: .appliedOffset) ?? [0, 0, 0]
        offsetNote     = try c.decodeIfPresent(String.self, forKey: .offsetNote)
        exportedUtc    = try c.decodeIfPresent(String.self, forKey: .exportedUtc)
    }

    init(
        sourceDocument: String,
        sourceUnits: String,
        targetUnits: String = "Meters",
        upAxis: String = "Z",
        originMode: String = "",
        appliedOffset: [Double] = [0, 0, 0],
        offsetNote: String? = nil,
        exportedUtc: String? = nil
    ) {
        self.sourceDocument = sourceDocument
        self.sourceUnits = sourceUnits
        self.targetUnits = targetUnits
        self.upAxis = upAxis
        self.originMode = originMode
        self.appliedOffset = appliedOffset
        self.offsetNote = offsetNote
        self.exportedUtc = exportedUtc
    }

    /// True when the producer's target units are metres, which is the only
    /// case the solver and ARKit agree on without a scale factor.
    ///
    /// The contract fixes `targetUnits` at metres, so a file that says
    /// otherwise is a producer bug — but reading it and saying so beats
    /// silently drawing a model 3.28x too big.
    var isMetric: Bool {
        let u = targetUnits.lowercased()
        return u.hasPrefix("met") || u == "m"
    }

    /// Model world coordinate for a point in the exported frame.
    func toSourceWorld(_ p: [Double]) -> [Double] {
        guard p.count == 3, appliedOffset.count == 3 else { return p }
        return [p[0] + appliedOffset[0], p[1] + appliedOffset[1], p[2] + appliedOffset[2]]
    }
}

// MARK: - points.json

/// Where a point sits relative to the nearest grid intersection.
///
/// `intersection` and `level` are empty strings — never nil — when the model
/// has no grid system loaded. `points.md` is explicit that this is the normal
/// case and not a failure, and the current plugin always writes empty strings
/// because the managed grid classes turned out to expose no public members.
/// So: render the point without grid text, do not treat it as degraded data.
struct NavGridRef: Codable, Equatable {
    var intersection: String
    var level: String
    var offset: [Double]
    var distance: Double

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intersection = try c.decodeIfPresent(String.self, forKey: .intersection) ?? ""
        level        = try c.decodeIfPresent(String.self, forKey: .level) ?? ""
        offset       = try c.decodeIfPresent([Double].self, forKey: .offset) ?? [0, 0, 0]
        distance     = try c.decodeIfPresent(Double.self, forKey: .distance) ?? 0
    }

    init(intersection: String = "", level: String = "", offset: [Double] = [0, 0, 0], distance: Double = 0) {
        self.intersection = intersection
        self.level = level
        self.offset = offset
        self.distance = distance
    }

    /// True when there is nothing worth showing. Drives the empty state rather
    /// than printing "Grid:  ,  " on a marker.
    var isEmpty: Bool { intersection.isEmpty && level.isEmpty }

    /// One line of human text, or nil when there is no grid to describe.
    var summary: String? {
        switch (intersection.isEmpty, level.isEmpty) {
        case (true, true):   return nil
        case (false, true):  return intersection
        case (true, false):  return level
        case (false, false): return "\(level) · \(intersection)"
        }
    }
}

struct NavCamera: Codable, Equatable {
    var position: [Double]
    var lookAt: [Double]
    var upVector: [Double]
    var fovDegrees: Double

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position   = try c.decodeIfPresent([Double].self, forKey: .position) ?? [0, 0, 0]
        lookAt     = try c.decodeIfPresent([Double].self, forKey: .lookAt) ?? [0, 0, 0]
        upVector   = try c.decodeIfPresent([Double].self, forKey: .upVector) ?? [0, 0, 1]
        fovDegrees = try c.decodeIfPresent(Double.self, forKey: .fovDegrees) ?? 45
    }

    init(position: [Double], lookAt: [Double], upVector: [Double] = [0, 0, 1], fovDegrees: Double = 45) {
        self.position = position
        self.lookAt = lookAt
        self.upVector = upVector
        self.fovDegrees = fovDegrees
    }
}

/// The reference shot for a point.
///
/// Optional in full: `points.md` says the producer omits `viewpoint` rather
/// than emitting it empty before a photo has been captured, and the plugin
/// does exactly that. A point with no viewpoint is still a usable point — the
/// coordinates are the deliverable, the photo is the aid.
struct NavViewpoint: Codable, Equatable {
    /// Bundle-relative, forward slashes.
    var image: String
    /// Small black-and-white image used on the printed marker. Optional; a
    /// printer derives it from `image` when absent.
    var thumbMono: String?
    var camera: NavCamera?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        image     = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
        thumbMono = try c.decodeIfPresent(String.self, forKey: .thumbMono)
        camera    = try c.decodeIfPresent(NavCamera.self, forKey: .camera)
    }

    init(image: String, thumbMono: String? = nil, camera: NavCamera? = nil) {
        self.image = image
        self.thumbMono = thumbMono
        self.camera = camera
    }
}

/// A surveyed location a human can find in the real world, because it is
/// described relative to a grid intersection and shown in a photo.
struct NavPoint: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    /// Three numbers in `provenance.targetUnits`, in the exported frame.
    var position: [Double]
    var grid: NavGridRef
    var viewpoint: NavViewpoint?
    /// The exact string encoded into the printed QR. Present so the app never
    /// has to reconstruct it and risk drifting from the producer.
    var qrPayload: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        label     = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        position  = try c.decodeIfPresent([Double].self, forKey: .position) ?? [0, 0, 0]
        grid      = try c.decodeIfPresent(NavGridRef.self, forKey: .grid) ?? NavGridRef()
        viewpoint = try c.decodeIfPresent(NavViewpoint.self, forKey: .viewpoint)
        qrPayload = try c.decodeIfPresent(String.self, forKey: .qrPayload)
    }

    init(
        id: String,
        label: String,
        position: [Double],
        grid: NavGridRef = NavGridRef(),
        viewpoint: NavViewpoint? = nil,
        qrPayload: String? = nil
    ) {
        self.id = id
        self.label = label
        self.position = position
        self.grid = grid
        self.viewpoint = viewpoint
        self.qrPayload = qrPayload
    }

    var positionVector: SIMD3<Double> {
        guard position.count >= 3 else { return SIMD3<Double>(0, 0, 0) }
        return SIMD3<Double>(position[0], position[1], position[2])
    }
}

/// A `points.json` file: a named set of points sharing one coordinate frame.
struct NavPointSet: Codable, Equatable {
    var contractVersion: String
    var setId: String
    var setName: String
    var createdUtc: String?
    var provenance: NavProvenance
    var points: [NavPoint]

    /// The 8-character prefix printed into every QR payload in this set.
    ///
    /// Short by design: QR density drives printed marker legibility, and a
    /// longer symbol photographs badly on a dusty column under site lighting.
    var shortId: String { String(setId.prefix(8)) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try c.decodeIfPresent(String.self, forKey: .contractVersion) ?? "0"
        setId           = try c.decodeIfPresent(String.self, forKey: .setId) ?? ""
        setName         = try c.decodeIfPresent(String.self, forKey: .setName) ?? ""
        createdUtc      = try c.decodeIfPresent(String.self, forKey: .createdUtc)
        provenance      = try c.decodeIfPresent(NavProvenance.self, forKey: .provenance)
                            ?? NavProvenance(sourceDocument: "", sourceUnits: "")
        // An empty `points` array is explicitly valid: render an empty state.
        points          = try c.decodeIfPresent([NavPoint].self, forKey: .points) ?? []
    }

    init(
        contractVersion: String = "1.0",
        setId: String,
        setName: String,
        createdUtc: String? = nil,
        provenance: NavProvenance,
        points: [NavPoint]
    ) {
        self.contractVersion = contractVersion
        self.setId = setId
        self.setName = setName
        self.createdUtc = createdUtc
        self.provenance = provenance
        self.points = points
    }

    func point(id: String) -> NavPoint? {
        points.first { $0.id == id }
    }

    /// Decode a `points.json`, checking the contract version first.
    ///
    /// Version is checked before anything else so a version-2 file produces
    /// the version message rather than a confusing field-level decode error
    /// from a schema this build was never meant to read.
    static func decode(_ data: Data) throws -> NavPointSet {
        let version = try probeContractVersion(data, file: "points.json")
        guard ContractVersion.isSupported(version) else {
            throw ContractError.unsupportedVersion(found: version, supported: ContractVersion.supportedMajor)
        }
        do {
            return try JSONDecoder().decode(NavPointSet.self, from: data)
        } catch {
            throw ContractError.malformed(file: "points.json", detail: "\(error)")
        }
    }
}

// MARK: - ar-model.json

/// The axis-aligned box the exported model slice occupies.
struct NavBounds: Codable, Equatable {
    var min: [Double]
    var max: [Double]
    var center: [Double]?
    var size: [Double]?
    /// Present in `ar-bundle.json`-shaped files; absent from the current
    /// plugin's `ar-model.json`.
    var paddingApplied: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        min            = try c.decodeIfPresent([Double].self, forKey: .min) ?? [0, 0, 0]
        max            = try c.decodeIfPresent([Double].self, forKey: .max) ?? [0, 0, 0]
        center         = try c.decodeIfPresent([Double].self, forKey: .center)
        size           = try c.decodeIfPresent([Double].self, forKey: .size)
        paddingApplied = try c.decodeIfPresent(Double.self, forKey: .paddingApplied)
    }

    init(min: [Double], max: [Double], center: [Double]? = nil, size: [Double]? = nil, paddingApplied: Double? = nil) {
        self.min = min
        self.max = max
        self.center = center
        self.size = size
        self.paddingApplied = paddingApplied
    }
}

/// The geometry payload beside an AR bundle.
///
/// Optional throughout, because the shipping plugin does not write one yet —
/// its AR Model Export emits the box, the camera and a reference photo, and
/// the `.glb` slice is deferred work. A bundle with no geometry is still worth
/// showing: it tells the user where the model is and what it looks like from
/// the export viewpoint. It just cannot be drawn over the world.
struct NavGeometryRef: Codable, Equatable {
    var file: String
    var bytes: Int?
    var triangleCount: Int?
}

/// An `ar-model.json` / `ar-bundle.json` file.
///
/// Both spellings are accepted deliberately. `docs/contracts/ar-model.md`
/// specifies `ar-bundle.json` with `bundleId`, `anchorPointIds` and a `.glb`;
/// the plugin as shipped writes `ar-model.json` with `modelId`, a bounding box
/// and no geometry. Reading only the documented shape would mean reading none
/// of the files that actually exist, and reading only the shipped shape would
/// break the day the plugin catches up. So the decoder takes either and the UI
/// reports what is missing.
/// Decode-only: the two spellings mean `CodingKeys` carries cases with no
/// matching stored property, which is fine for reading and cannot synthesise
/// a writer. This app never writes an AR bundle — PIXMYD-Nav produces them.
struct NavArBundle: Decodable, Equatable {
    var contractVersion: String
    /// `bundleId` when present, else `modelId`.
    var bundleId: String
    var name: String
    var createdUtc: String?
    /// Which point set anchors this bundle. Absent in the shipped plugin
    /// output, which is why AR alignment has to ask the user which set to use.
    var pointSetId: String?
    var anchorPointIds: [String]
    var bounds: NavBounds?
    var camera: NavCamera?
    var geometry: NavGeometryRef?
    var image: String?
    var thumbMono: String?
    var provenance: NavProvenance

    enum CodingKeys: String, CodingKey {
        case contractVersion, bundleId, modelId, name, modelName, createdUtc
        case pointSetId, anchorPointIds, bounds, boundingBox, camera, geometry
        case image, thumbMono, provenance
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try c.decodeIfPresent(String.self, forKey: .contractVersion) ?? "0"
        bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId)
            ?? c.decodeIfPresent(String.self, forKey: .modelId)
            ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .modelName)
            ?? ""
        createdUtc     = try c.decodeIfPresent(String.self, forKey: .createdUtc)
        pointSetId     = try c.decodeIfPresent(String.self, forKey: .pointSetId)
        anchorPointIds = try c.decodeIfPresent([String].self, forKey: .anchorPointIds) ?? []
        bounds = try c.decodeIfPresent(NavBounds.self, forKey: .bounds)
            ?? c.decodeIfPresent(NavBounds.self, forKey: .boundingBox)
        camera         = try c.decodeIfPresent(NavCamera.self, forKey: .camera)
        geometry       = try c.decodeIfPresent(NavGeometryRef.self, forKey: .geometry)
        image          = try c.decodeIfPresent(String.self, forKey: .image)
        thumbMono      = try c.decodeIfPresent(String.self, forKey: .thumbMono)
        provenance     = try c.decodeIfPresent(NavProvenance.self, forKey: .provenance)
                           ?? NavProvenance(sourceDocument: "", sourceUnits: "")
    }

    var shortId: String { String(bundleId.prefix(8)) }

    /// True when there is a `.glb` to draw. False is a normal, supported state.
    var hasGeometry: Bool {
        guard let file = geometry?.file else { return false }
        return !file.isEmpty
    }

    static func decode(_ data: Data, file: String = "ar-model.json") throws -> NavArBundle {
        let version = try probeContractVersion(data, file: file)
        guard ContractVersion.isSupported(version) else {
            throw ContractError.unsupportedVersion(found: version, supported: ContractVersion.supportedMajor)
        }
        do {
            return try JSONDecoder().decode(NavArBundle.self, from: data)
        } catch {
            throw ContractError.malformed(file: file, detail: "\(error)")
        }
    }
}

// MARK: - Version probe

/// Reads `contractVersion` out of a file without committing to the rest of the
/// schema.
///
/// Decoding the whole document first would mean a version-2 file fails with
/// whatever field happened to change, and the user is told about a missing
/// `grid` when the real answer is "this file is from a newer plugin".
private struct ContractVersionProbe: Decodable {
    var contractVersion: String?
}

func probeContractVersion(_ data: Data, file: String) throws -> String {
    do {
        let probe = try JSONDecoder().decode(ContractVersionProbe.self, from: data)
        guard let version = probe.contractVersion, !version.isEmpty else {
            throw ContractError.malformed(file: file, detail: "no contractVersion field")
        }
        return version
    } catch let error as ContractError {
        throw error
    } catch {
        throw ContractError.malformed(file: file, detail: "not valid JSON")
    }
}
