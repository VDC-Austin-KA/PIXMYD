import Foundation
import simd

// Points placed on the phone, during or after a capture.
//
// Until now this app could only *find* points: a set came from PIXMYD-Nav,
// the operator located each printed marker in the room, and the pairs
// registered the scan. That works when somebody has already been round the
// model placing points and printing markers. It is useless the first time a
// crew walks a space, which is most of the time — and it puts the slow half of
// the job on the person at the workstation.
//
// So points can start here instead. The operator aims at a corner and taps;
// the point is recorded in the capture's own frame, numbered, and travels home
// with the scan. At the workstation the same numbers are placed on the model,
// and the two lists register against each other by id.
//
// ## What these coordinates are
//
// The capture frame. ARKit's world origin is wherever the session started and
// its axes are gravity-aligned with +Y up — a real, metric, right-handed frame,
// but not one anybody else knows about. That is exactly what a control point
// needs to be at this stage: the whole point of the exercise is that the model
// does not yet know where the room is.
//
// So `points.json` written from here says so. `navex:originMode` is
// `CaptureOrigin`, `navex:upAxis` is Y, and `pixmyd:frame` is `capture`. A
// consumer that reads these as model coordinates would place a scan at the
// origin and be confidently wrong, and the fields are there so it cannot.
//
// ## Why the contract shape
//
// This writes the same `points.json` PIXMYD-Nav writes, field for field. Not
// because the plugin needs it to — it could have read anything — but because
// a set of points is a set of points whichever end placed them, and a second
// schema for the same thing is a second parser, a second version gate and a
// second set of bugs. The plugin's existing reader takes this file unchanged.
//
// In `portableSources`: all arithmetic and string building, and `swift test`
// covers it.

/// One point the operator placed in the real world.
struct FieldPoint: Equatable, Identifiable, Codable {
    /// `P001`, `P002`, … — the id the workstation will place against.
    var id: String
    var label: String
    /// Capture frame, metres. ARKit world coordinates at the moment of the tap.
    var position: SIMD3<Double>
    var placedAt: Date
    /// How the position was measured.
    var source: Source
    /// How far the phone was from the point when it was taken, in metres.
    ///
    /// Recorded because it is the single best predictor of how good the point
    /// is: a corner grabbed from 400 mm away off the LiDAR mesh is a
    /// measurement, and the same corner taken from six metres across a room is
    /// an estimate with a decimetre in it. The workstation sees this next to
    /// the residual and can tell one from the other.
    var range: Double?

    enum Source: String, Codable, Equatable {
        /// A depth measurement off the reconstructed scene mesh. What a LiDAR
        /// device gives, and the only one worth calling a measurement.
        case mesh
        /// A raycast against a plane ARKit inferred rather than measured.
        case plane
        /// Typed in, or moved by hand afterwards.
        case manual

        var label: String {
            switch self {
            case .mesh:   return "measured"
            case .plane:  return "estimated"
            case .manual: return "by hand"
            }
        }

        /// Whether this is a depth measurement rather than an inference. Drives
        /// the warning the capture screen shows on a device with no LiDAR.
        var isMeasured: Bool { self == .mesh }
    }

    init(
        id: String,
        label: String = "",
        position: SIMD3<Double>,
        placedAt: Date = Date(),
        source: Source = .mesh,
        range: Double? = nil
    ) {
        self.id = id
        self.label = label.isEmpty ? id : label
        self.position = position
        self.placedAt = placedAt
        self.source = source
        self.range = range
    }

    // SIMD3<Double> is Codable on Apple platforms and not in the Linux shim, so
    // the position is stored as three numbers. That also makes the persisted
    // file readable, which matters for a directory this app treats as the
    // source of truth.
    enum CodingKeys: String, CodingKey {
        case id, label, position, placedAt, source, range
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        let xyz = try c.decodeIfPresent([Double].self, forKey: .position) ?? [0, 0, 0]
        position = SIMD3<Double>(
            xyz.count > 0 ? xyz[0] : 0,
            xyz.count > 1 ? xyz[1] : 0,
            xyz.count > 2 ? xyz[2] : 0)
        placedAt = try c.decodeIfPresent(Date.self, forKey: .placedAt) ?? Date(timeIntervalSince1970: 0)
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .mesh
        range = try c.decodeIfPresent(Double.self, forKey: .range)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode([position.x, position.y, position.z], forKey: .position)
        try c.encode(placedAt, forKey: .placedAt)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(range, forKey: .range)
    }
}

/// The points placed against one capture.
struct FieldPointSet: Equatable, Codable {
    var setId: String
    var setName: String
    var createdUtc: Date
    var points: [FieldPoint]

    init(
        setId: String = UUID().uuidString,
        setName: String = "",
        createdUtc: Date = Date(),
        points: [FieldPoint] = []
    ) {
        self.setId = setId
        self.setName = setName
        self.createdUtc = createdUtc
        self.points = points
    }

    /// The 8-character prefix a QR payload carries, matching `NavPointSet`.
    var shortId: String { String(setId.prefix(8)) }

    var isEmpty: Bool { points.isEmpty }

    /// Enough to register a scan with the vertical held from gravity.
    var canRegister: Bool { points.count >= GravityFrame.minimumPairs }

    func point(id: String) -> FieldPoint? {
        points.first { $0.id == id }
    }

    /// The next id in sequence.
    ///
    /// Numbered from the highest `P###` present rather than from the count, so
    /// deleting P002 out of three points gives P004 next and never re-uses a
    /// number that has already been written down on site.
    func nextId() -> String {
        var highest = 0
        for point in points {
            guard point.id.hasPrefix("P"), let value = Int(point.id.dropFirst()) else { continue }
            if value > highest { highest = value }
        }
        return String(format: "P%03d", highest + 1)
    }

    mutating func place(
        at position: SIMD3<Double>,
        source: FieldPoint.Source,
        range: Double?,
        label: String = ""
    ) -> FieldPoint {
        let point = FieldPoint(
            id: nextId(), label: label, position: position, source: source, range: range)
        points.append(point)
        return point
    }

    mutating func remove(id: String) {
        points.removeAll { $0.id == id }
    }

    mutating func move(id: String, to position: SIMD3<Double>) {
        guard let index = points.firstIndex(where: { $0.id == id }) else { return }
        points[index].position = position
        points[index].source = .manual
    }

    /// The correspondences this set contributes to a capture, in point order so
    /// a solve is reproducible from the same data.
    var correspondences: [CaptureCorrespondence] {
        points.map { CaptureCorrespondence(pointId: $0.id, observed: $0.position) }
    }

    /// The spread of the points, which is what actually decides whether a
    /// registration is well conditioned.
    ///
    /// Two points a metre apart at one end of a warehouse will register, and
    /// the far end of the scan will be metres out. The number is shown rather
    /// than used to refuse, because a one-metre baseline is right for a plant
    /// room and wrong for a slab, and the app does not know which it is in.
    var baselineMetres: Double {
        guard points.count >= 2 else { return 0 }
        var longest = 0.0
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                let d = simd_length(points[i].position - points[j].position)
                if d > longest { longest = d }
            }
        }
        return longest
    }

    // MARK: - The contract file

    static let fileName = "points.json"
    static let contractVersion = "1.0"

    /// Render `points.json` exactly as `docs/contracts/points.md` specifies,
    /// with `contractVersion` first.
    ///
    /// Hand-written through `OrderedJson` for the same reason `capture.json` is:
    /// every consumer probes the version before it commits to the rest of the
    /// schema, and `JSONEncoder` does not promise key order.
    func renderPointsJson(sourceDocument: String = "") -> String {
        var fields: [(String, OrderedJson.Value)] = [
            ("contractVersion", .string(Self.contractVersion)),
            ("setId", .string(setId)),
            ("setName", .string(setName.isEmpty ? "Field points" : setName)),
            ("createdUtc", .string(CaptureExport.iso8601(createdUtc))),
            ("provenance", .object([
                ("navex:sourceDocument", .string(sourceDocument)),
                ("navex:sourceUnits", .string("Meters")),
                ("navex:targetUnits", .string("Meters")),
                // ARKit, not a model. Both of the next two say so, because a
                // consumer that reads these as model coordinates would place a
                // scan at the origin and be confidently wrong.
                ("navex:upAxis", .string("Y")),
                ("navex:originMode", .string("CaptureOrigin")),
                ("navex:appliedOffset", OrderedJson.vector([0, 0, 0])),
                ("navex:offsetNote", .string(
                    "These are capture-frame coordinates from the phone, not model world "
                  + "coordinates. Place the matching ids on the model and register the two sets.")),
                ("navex:exportedUtc", .string(CaptureExport.iso8601(createdUtc))),
                ("pixmyd:frame", .string("capture")),
                ("pixmyd:captureUpAxis", .string("Y")),
            ])),
        ]

        fields.append(("points", .array(points.map { point in
            var entry: [(String, OrderedJson.Value)] = [
                ("id", .string(point.id)),
                ("label", .string(point.label)),
                ("position", OrderedJson.vector([point.position.x, point.position.y, point.position.z])),
                // The contract says empty strings, never null, when there is no
                // grid — and a phone has no grid system at all.
                ("grid", .object([
                    ("intersection", .string("")),
                    ("level", .string("")),
                    ("offset", OrderedJson.vector([0, 0, 0])),
                    ("distance", .number(0)),
                ])),
                ("qrPayload", .string("pixmy://p/\(shortId)/\(point.id)")),
            ]
            // Namespaced additions, so a consumer written against 1.0 skips
            // them and one that knows about them gets the measurement quality.
            entry.append(("pixmyd:source", .string(point.source.rawValue)))
            if let range = point.range {
                entry.append(("pixmyd:rangeMetres", .number(range)))
            }
            return .object(entry)
        })))

        return OrderedJson.render(.object(fields)) + "\n"
    }

    @discardableResult
    func writePointsJson(to directory: URL, sourceDocument: String = "") throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.fileName)
        try Data(renderPointsJson(sourceDocument: sourceDocument).utf8)
            .write(to: url, options: .atomic)
        return url
    }

    // MARK: - Persistence

    /// Field points live in the project directory, beside the frames they were
    /// placed during. The directory is the source of truth for everything else
    /// this app records, and a point placed on site is not the thing to make an
    /// exception for.
    static let storeFileName = "field-points.json"

    static func url(in project: URL) -> URL {
        project.appendingPathComponent(storeFileName)
    }

    static func load(in project: URL) -> FieldPointSet? {
        guard let data = try? Data(contentsOf: url(in: project)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FieldPointSet.self, from: data)
    }

    func save(in project: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(in: project), options: .atomic)
    }
}
