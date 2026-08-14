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

/// Everything `capture.json` needs that is not derived from the solve.
struct CaptureExportRequest {
    var captureId: String
    var capturedUtc: Date
    var device: CaptureDevice
    /// The set the correspondences were taken against.
    var pointSet: NavPointSet
    var correspondences: [CaptureCorrespondence]
    /// Sibling filename of the mesh payload, and its size.
    var geometryFile: String
    var geometryBytes: Int

    init(
        captureId: String = UUID().uuidString,
        capturedUtc: Date = Date(),
        device: CaptureDevice,
        pointSet: NavPointSet,
        correspondences: [CaptureCorrespondence],
        geometryFile: String = "capture.glb",
        geometryBytes: Int
    ) {
        self.captureId = captureId
        self.capturedUtc = capturedUtc
        self.device = device
        self.pointSet = pointSet
        self.correspondences = correspondences
        self.geometryFile = geometryFile
        self.geometryBytes = geometryBytes
    }
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
        correspondences: [CaptureCorrespondence]
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
        let solution = try solveRigidTransform(pairs, options: SolveOptions(estimateScale: false))
        return CaptureSolution(
            solution: solution,
            grade: classifyAccuracy(solution.rmsError),
            outliers: findOutliers(solution)
        )
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
        fields.append(("pointSetId", .string(request.pointSet.setId)))
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
        ])))

        // Carried through verbatim from the point set. The consumer needs
        // `appliedOffset` to get back to model world coordinates, and it must
        // be the offset of the set the capture was taken against — not
        // whatever this app might have guessed.
        fields.append(("provenance", provenanceValue(request.pointSet.provenance)))

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
