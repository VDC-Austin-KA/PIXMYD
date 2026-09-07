import Foundation

// The return leg: a scan going back into Navisworks already positioned.
//
// `docs/contracts/capture.md` — this app produces `capture.json` plus a mesh
// payload, and PIXMYD-Nav consumes it by applying `solution.matrix` and then
// adding the point set's `appliedOffset` to land the mesh in model world
// coordinates.
//
// Two decisions in the contract are worth restating because they look like
// omissions rather than choices:
//
// **Scale is fixed at 1.0.** A LiDAR capture and a BIM model are both metric.
// Letting scale float would absorb real error into a fitted parameter and make
// a bad alignment look good — the RMS drops, the mesh is still in the wrong
// place. `SolveOptions(estimateScale: false)` is the default and stays.
//
// **The raw correspondences ship alongside the solved transform.** The
// consumer can re-solve rather than trust a number it cannot check. That is
// also the useful degraded mode: a `capture.json` with correspondences but no
// solution is not an error, it is an invitation to solve locally.
//
// The JSON is written by hand rather than through `JSONEncoder` for one
// reason: `contractVersion` must be the first field in the file, every
// consumer probes it before committing to the rest of the schema, and
// `JSONEncoder` does not promise key order. Hand-writing also makes the output
// byte-stable, which is what lets the tests assert on it.
//
// In `portableSources`: the whole of this file is arithmetic and string
// building, and `swift test` covers it.

// MARK: - Ordered JSON

/// A minimal ordered JSON writer.
///
/// Deliberately not a general-purpose encoder. It exists to guarantee field
/// order and stable number formatting for one contract file, and matches the
/// hand-rolled writers on the Navisworks side rather than adding a dependency
/// to save fifty lines.
enum OrderedJson {
    indirect enum Value {
        case string(String)
        case number(Double)
        case int(Int)
        case bool(Bool)
        case object([(String, Value)])
        case array([Value])
        case null
    }

    static func render(_ value: Value, indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let padInner = String(repeating: "  ", count: indent + 1)

        switch value {
        case let .string(s):
            return "\"\(escape(s))\""
        case let .number(d):
            return number(d)
        case let .int(i):
            return String(i)
        case let .bool(b):
            return b ? "true" : "false"
        case .null:
            return "null"
        case let .object(fields):
            guard !fields.isEmpty else { return "{}" }
            let body = fields
                .map { "\(padInner)\"\(escape($0.0))\": \(render($0.1, indent: indent + 1))" }
                .joined(separator: ",\n")
            return "{\n\(body)\n\(pad)}"
        case let .array(items):
            guard !items.isEmpty else { return "[]" }
            // Vectors read far better on one line, and every array in this
            // contract is either a short vector or a list of objects.
            let scalarsOnly = items.allSatisfy {
                if case .object = $0 { return false }
                if case .array = $0 { return false }
                return true
            }
            if scalarsOnly {
                return "[ " + items.map { render($0, indent: indent) }.joined(separator: ", ") + " ]"
            }
            let body = items
                .map { "\(padInner)\(render($0, indent: indent + 1))" }
                .joined(separator: ",\n")
            return "[\n\(body)\n\(pad)]"
        }
    }

    /// Shortest round-trippable form, with non-finite values clamped to 0.
    ///
    /// JSON has no NaN or Infinity. Emitting one produces a file the consumer
    /// cannot parse at all, which turns a single bad residual into a lost
    /// capture — so a non-finite number becomes 0 and the caller is expected
    /// to have refused to write the file long before this point.
    static func number(_ d: Double) -> String {
        guard d.isFinite else { return "0" }
        if d == d.rounded(), abs(d) < 1e15 {
            return String(format: "%.1f", d)
        }
        return "\(d)"
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out
    }

    static func vector(_ v: [Double]) -> Value {
        .array(v.map { .number($0) })
    }
}

// MARK: - Inputs

/// One point the operator located in the real world during a capture.
struct CaptureCorrespondence: Equatable {
    /// The id from `points.json`. This is what ties the two frames together.
    var pointId: String
    /// Where it was observed, in the capture's own coordinate frame, metres,
    /// before any transform.
    var observed: SIMD3<Double>
    /// 1-sigma survey accuracy, when the operator recorded one. Feeds the
    /// solver's weighting.
    var sigma: Double?

    init(pointId: String, observed: SIMD3<Double>, sigma: Double? = nil) {
        self.pointId = pointId
        self.observed = observed
        self.sigma = sigma
    }
}

struct CaptureDevice: Equatable {
    var model: String
    var hasLidar: Bool
}

/// Which frame the mesh beside a capture is written in.
///
/// It matters because a mesh already in model coordinates is appended and left
/// alone, and a raw one has to be transformed. Applying the transform twice
/// puts the scan exactly as far past the model as it was short of it, which
/// looks like a solver bug and is not.
enum CaptureGeometryFrame: String, Equatable {
    /// The capture's own ARKit frame. The consumer applies the solution.
    case capture
    /// Model world coordinates: the phone baked the solution into the geometry
    /// before writing it, so the consumer appends it and leaves it alone.
    case model
}

/// Everything `capture.json` needs that is not derived from the solve.
struct CaptureExportRequest {
    var captureId: String
    var capturedUtc: Date
    var device: CaptureDevice
    /// The set from PIXMYD-Nav the correspondences were taken against, when
    /// there is one. Nil for a capture whose points were placed on the phone —
    /// which is the whole point of `fieldPoints` below.
    var pointSet: NavPointSet?
    /// Points placed on the phone, when there are any. They travel as their own
    /// contract file beside the capture; this records that they exist and what
    /// they are called.
    var fieldPoints: FieldPointSet?
    var correspondences: [CaptureCorrespondence]
    /// Sibling filename of the mesh payload, and its size.
    var geometryFile: String
    var geometryBytes: Int
    var geometryFrame: CaptureGeometryFrame

    init(
        captureId: String = UUID().uuidString,
        capturedUtc: Date = Date(),
        device: CaptureDevice,
        pointSet: NavPointSet? = nil,
        fieldPoints: FieldPointSet? = nil,
        correspondences: [CaptureCorrespondence],
        geometryFile: String = CaptureUploadNames.geometry,
        geometryBytes: Int,
        geometryFrame: CaptureGeometryFrame = .capture
    ) {
        self.captureId = captureId
        self.capturedUtc = capturedUtc
        self.device = device
        self.pointSet = pointSet
        self.fieldPoints = fieldPoints
        self.correspondences = correspondences
        self.geometryFile = geometryFile
        self.geometryBytes = geometryBytes
        self.geometryFrame = geometryFrame
    }

    /// The id the consumer matches against. The Nav set when there is one,
    /// otherwise the phone's own set — a capture always names the points it
    /// was taken against, whichever end placed them.
    var pointSetId: String {
        if let id = pointSet?.setId, !id.isEmpty { return id }
        return fieldPoints?.setId ?? ""
    }

    /// The provenance block to carry.
    ///
    /// A capture aligned to a Nav set carries that set's provenance verbatim —
    /// the consumer needs its `appliedOffset` to get back to model world
    /// coordinates, and it must be the offset of the set the capture was taken
    /// against rather than anything this app guessed. A capture whose points
    /// were placed here has no such set, and says so.
    var provenance: NavProvenance {
        if let pointSet { return pointSet.provenance }
        return NavProvenance(
            sourceDocument: "",
            sourceUnits: "Meters",
            targetUnits: "Meters",
            upAxis: "Y",
            originMode: "CaptureOrigin",
            appliedOffset: [0, 0, 0],
            offsetNote: "These are capture-frame coordinates from the phone, not model world "
                      + "coordinates. Place the matching ids on the model and register the two sets."
        )
    }
}

/// The filenames the return leg uses, in one place so the writer and the
/// packager cannot drift.
enum CaptureUploadNames {
    /// OBJ, not FBX.
    ///
    /// The plugin turns this into an NWC on arrival, and appends that. NWC is
    /// the format Navisworks writes for its own cache, so appending one is a
    /// load rather than a translation — the one reader that is never the weak
    /// link. FBX has to survive a reader nobody here controls, and on the
    /// machine this suite is used on it did not: a four-kilobyte single
    /// triangle came back "the contents are corrupt" exactly like a
    /// sixty-eight megabyte scan.
    ///
    /// OBJ is what carries it there because the plugin can *read* it — it
    /// could never read FBX, which is why geometry used to be handed straight
    /// to Navisworks — and because it carries a texture coordinate per polygon
    /// corner, which is what the photographic atlas needs and what the NWC
    /// geometry stream takes.
    ///
    /// Three files, not one: OBJ has no single-file form that carries a
    /// texture. The material and the atlas travel beside it.
    static let geometry = "capture.obj"
    static let material = "capture.mtl"
    static let texture = "capture.png"
    static let capture = "capture.json"
    static let fieldPoints = FieldPointSet.fileName
}

/// The solve behind a capture, in the terms the consumer has to show a user.
struct CaptureSolution {
    var solution: RigidSolution
    var grade: AccuracyGrade
    var outliers: [Outlier]

    var outlierPointIds: [String] {
        outliers.compactMap { $0.id }
    }
}

enum CaptureExportError: Error, CustomStringConvertible, Equatable {
    case noMatchingPoints
    case unknownPointIds([String])

    var description: String {
        switch self {
        case .noMatchingPoints:
            return "None of the located points are in this point set. "
                 + "Check that the scan was taken against the set you are exporting to."
        case let .unknownPointIds(ids):
            return "These located points are not in the point set: \(ids.joined(separator: ", "))."
        }
    }
}

// MARK: - Writer

enum CaptureExport {
    static let fileName = "capture.json"
    static let contractVersion = "1.0"

    /// Solve the capture against its point set.
    ///
    /// Throws whatever the solver throws — too few pairs, or a degenerate
    /// (collinear / coincident) network. Those messages were written to be
    /// shown to a field user and are surfaced verbatim rather than replaced,
    /// because "needs at least 3 points" is actionable and "registration
    /// failed" is not.
    static func solve(
        pointSet: NavPointSet,
        correspondences: [CaptureCorrespondence],
        forceGravity: Bool = false
    ) throws -> CaptureSolution {
        var pairs: [ControlPair] = []
        var unknown: [String] = []

        for c in correspondences {
            guard let point = pointSet.point(id: c.pointId) else {
                unknown.append(c.pointId)
                continue
            }
            pairs.append(ControlPair(
                project: point.positionVector,
                observed: c.observed,
                id: c.pointId,
                sigma: c.sigma
            ))
        }

        guard !pairs.isEmpty else {
            throw unknown.isEmpty
                ? CaptureExportError.noMatchingPoints
                : CaptureExportError.unknownPointIds(unknown)
        }

        // estimateScale stays false. See the note at the top of this file.
        //
        // Two pairs are now enough: both frames know which way down is, so the
        // vertical is held from gravity and the heading is the only rotation
        // left to solve. `solveBestAvailable` picks that path below three pairs
        // and Horn's above, and says which it used.
        let solution = try solveBestAvailable(
            pairs,
            projectUp: GravityFrame.up(forAxis: pointSet.provenance.upAxis),
            forceGravity: forceGravity,
            options: SolveOptions(estimateScale: false)
        )
        return CaptureSolution(
            solution: solution,
            grade: classifyAccuracy(solution.rmsError),
            // Outlier detection refits without each point in turn, which needs
            // four. Below that there is nothing to leave out.
            outliers: pairs.count >= 4 ? findOutliers(solution) : []
        )
    }

    /// Solve a capture whose points were placed on the phone.
    ///
    /// There is no project frame yet — that is the point. The observations are
    /// the field points and the "project" side is whatever the workstation
    /// places against the same ids, so nothing can be solved here. This exists
    /// to report what the set can support before the operator walks away from
    /// the space, which is the only moment it can still be fixed.
    static func registrationReadiness(_ set: FieldPointSet) -> String {
        if set.points.isEmpty {
            return "No points placed. Two are enough to align this scan to the model; "
                 + "three or more make the error mean something."
        }
        if set.points.count == 1 {
            return "One point fixes where the scan sits and nothing about which way it faces. "
                 + "Place at least one more, well away from this one."
        }
        let baseline = String(format: "%.1f", set.baselineMetres)
        let estimated = set.points.filter { !$0.source.isMeasured }.count
        var line = "\(set.points.count) points, \(baseline) m apart at the widest. "
                 + GravityFrame.redundancyGuidance(pairCount: set.points.count)
        if estimated > 0 {
            line += " \(estimated) of them were taken off an estimated surface rather than "
                  + "measured depth, which is worth a decimetre on a bad day."
        }
        return line
    }

    /// Render `capture.json`.
    ///
    /// `solved` is optional on purpose: the contract calls a file with
    /// correspondences and no solution "the useful degraded mode, not an
    /// error". A capture taken with two visible points still carries its
    /// observations home for someone to solve at a desk.
    static func render(_ request: CaptureExportRequest, solved: CaptureSolution?) -> String {
        var fields: [(String, OrderedJson.Value)] = []

        // First field, always. Consumers check the major version before they
        // commit to the rest of the schema.
        fields.append(("contractVersion", .string(contractVersion)))
        fields.append(("captureId", .string(request.captureId)))
        fields.append(("capturedUtc", .string(iso8601(request.capturedUtc))))
        fields.append(("pointSetId", .string(request.pointSetId)))
        fields.append(("device", .object([
            ("model", .string(request.device.model)),
            ("hasLidar", .bool(request.device.hasLidar)),
        ])))

        fields.append(("correspondences", .array(request.correspondences.map { c in
            var entry: [(String, OrderedJson.Value)] = [
                ("pointId", .string(c.pointId)),
                ("observed", OrderedJson.vector([c.observed.x, c.observed.y, c.observed.z])),
            ]
            if let sigma = c.sigma {
                entry.append(("sigma", .number(sigma)))
            }
            return .object(entry)
        })))

        if let solved {
            fields.append(("solution", .object([
                ("matrix", OrderedJson.vector(solved.solution.matrix)),
                ("scale", .number(solved.solution.scale)),
                ("rmsError", .number(solved.solution.rmsError)),
                ("maxError", .number(solved.solution.maxError)),
                // The contract says this is "the string returned by
                // classifyAccuracy()". That is the band, not a free-text
                // label — `layout`, `penetrations`, `dimensional-control`,
                // `coordination`, `context`, `unusable`. The example in
                // capture.md shows "survey", which is not one of them; the
                // prose wins over the illustration.
                ("accuracyGrade", .string(solved.grade.band.rawValue)),
                ("outlierPointIds", .array(solved.outlierPointIds.map { .string($0) })),
            ])))
        }

        fields.append(("geometry", .object([
            ("file", .string(request.geometryFile)),
            ("bytes", .int(request.geometryBytes)),
            // Additive: a consumer written against 1.0 before this field
            // existed reads no frame and assumes `capture`, which is what every
            // file written before this field existed contained.
            ("frame", .string(request.geometryFrame.rawValue)),
        ])))

        if let fieldPoints = request.fieldPoints, !fieldPoints.isEmpty {
            fields.append(("fieldPoints", .object([
                ("file", .string(CaptureUploadNames.fieldPoints)),
                ("setId", .string(fieldPoints.setId)),
                ("count", .int(fieldPoints.points.count)),
                ("baselineMetres", .number(fieldPoints.baselineMetres)),
            ])))
        }

        // Carried through verbatim from the point set. The consumer needs
        // `appliedOffset` to get back to model world coordinates, and it must
        // be the offset of the set the capture was taken against — not
        // whatever this app might have guessed.
        fields.append(("provenance", provenanceValue(request.provenance)))

        return OrderedJson.render(.object(fields)) + "\n"
    }

    static func write(_ request: CaptureExportRequest, solved: CaptureSolution?, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        try Data(render(request, solved: solved).utf8).write(to: url, options: .atomic)
        return url
    }

    private static func provenanceValue(_ p: NavProvenance) -> OrderedJson.Value {
        var fields: [(String, OrderedJson.Value)] = [
            ("navex:sourceDocument", .string(p.sourceDocument)),
            ("navex:sourceUnits", .string(p.sourceUnits)),
            ("navex:targetUnits", .string(p.targetUnits)),
            ("navex:upAxis", .string(p.upAxis)),
            ("navex:originMode", .string(p.originMode)),
            ("navex:appliedOffset", OrderedJson.vector(p.appliedOffset)),
        ]
        if let note = p.offsetNote {
            fields.append(("navex:offsetNote", .string(note)))
        }
        if let exported = p.exportedUtc {
            fields.append(("navex:exportedUtc", .string(exported)))
        }
        // Which way is up in the *capture's* frame, as opposed to the model's.
        // The consumer needs both to hold the vertical during a two-point
        // solve, and `navex:upAxis` only ever meant the model's.
        fields.append(("pixmyd:captureUpAxis", .string("Y")))
        return .object(fields)
    }

    /// `2026-08-13T16:44:52.000Z`, matching what the plugin writes.
    ///
    /// Built by hand because `ISO8601DateFormatter`'s fractional-seconds
    /// option is not available in every Foundation this file compiles
    /// against, and the format is fixed by the contract anyway.
    static func iso8601(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
        let millis = (c.nanosecond ?? 0) / 1_000_000
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            c.year ?? 1970, c.month ?? 1, c.day ?? 1,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0, millis
        )
    }
}
