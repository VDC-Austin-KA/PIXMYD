import Foundation

// The wire shapes of `docs/contracts/transfer.md`, and the rules that decide
// whether a response is safe to act on.
//
// Split from the networking deliberately. Everything here is parsing and
// validation — the parts that decide whether a filename off a network is
// allowed to become a path, and whether a session is worth talking to — and it
// is in `portableSources` so `swift test` covers it on Linux. The URLSession
// half is in `NavTransferClient.swift` and has no decisions in it.
//
// The threat model is small but real: an HTTP response from a host on a site
// wifi. Nobody is attacking a column layout, but a malformed name that escapes
// the bundle directory is the kind of bug that only ever gets found the
// expensive way, and the check costs one function.

// MARK: - Session

/// One file the host is offering.
struct TransferFile: Decodable, Equatable {
    var name: String
    var bytes: Int
}

enum TransferKind: String, Decodable, Equatable {
    case points
    case arModel = "ar-model"
    case both
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TransferKind(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .points:  return "Point set"
        case .arModel: return "AR model"
        case .both:    return "Point set and AR model"
        case .unknown: return "Bundle"
        }
    }
}

struct TransferOffer: Decodable, Equatable {
    var name: String
    var kind: TransferKind
    var files: [TransferFile]

    var totalBytes: Int { files.reduce(0) { $0 + $1.bytes } }
}

struct TransferUploadPolicy: Decodable, Equatable {
    var accepted: Bool
    var maxBytes: Int

    // Spelled out because nothing is synthesised here: `CodingKeys` only
    // appears when the compiler generates `init(from:)` or `encode(to:)`, and
    // these types are decode-only with a hand-written initialiser.
    enum CodingKeys: String, CodingKey {
        case accepted, maxBytes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try c.decodeIfPresent(Bool.self, forKey: .accepted) ?? false
        maxBytes = try c.decodeIfPresent(Int.self, forKey: .maxBytes) ?? 0
    }

    init(accepted: Bool, maxBytes: Int) {
        self.accepted = accepted
        self.maxBytes = maxBytes
    }
}

/// What `GET /session` answers.
struct TransferSession: Decodable, Equatable {
    var contractVersion: String
    var sessionId: String
    var host: String
    var document: String?
    var expiresUtc: String?
    /// Null when the session is upload-only.
    var download: TransferOffer?
    var upload: TransferUploadPolicy

    enum CodingKeys: String, CodingKey {
        case contractVersion, sessionId, host, document, expiresUtc, download, upload
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try c.decodeIfPresent(String.self, forKey: .contractVersion) ?? "0"
        sessionId       = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        host            = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        document        = try c.decodeIfPresent(String.self, forKey: .document)
        expiresUtc      = try c.decodeIfPresent(String.self, forKey: .expiresUtc)
        download        = try c.decodeIfPresent(TransferOffer.self, forKey: .download)
        upload          = try c.decodeIfPresent(TransferUploadPolicy.self, forKey: .upload)
                            ?? TransferUploadPolicy(accepted: false, maxBytes: 0)
    }

    /// One line naming the machine on the other end, so the user can tell
    /// whether they scanned the code on the workstation in front of them.
    var hostSummary: String {
        guard let document, !document.isEmpty else { return host }
        return host.isEmpty ? document : "\(host) — \(document)"
    }

    var canDownload: Bool { (download?.files.isEmpty == false) }
    var canUpload: Bool { upload.accepted }

    static func decode(_ data: Data) throws -> TransferSession {
        let version = try probeContractVersion(data, file: "session")
        guard ContractVersion.isSupported(version) else {
            throw ContractError.unsupportedVersion(found: version, supported: ContractVersion.supportedMajor)
        }
        let session: TransferSession
        do {
            session = try JSONDecoder().decode(TransferSession.self, from: data)
        } catch {
            throw ContractError.malformed(file: "session", detail: "\(error)")
        }
        // "Both null/false at once is not a session and must not be started."
        guard session.canDownload || session.canUpload else {
            throw TransferError.emptySession
        }
        return session
    }
}

/// What `POST /capture/commit` answers.
struct TransferCommitResult: Decodable, Equatable {
    var contractVersion: String
    var accepted: Bool
    var captureId: String?
    var message: String

    enum CodingKeys: String, CodingKey {
        case contractVersion, accepted, captureId, message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try c.decodeIfPresent(String.self, forKey: .contractVersion) ?? "1.0"
        accepted        = try c.decodeIfPresent(Bool.self, forKey: .accepted) ?? false
        captureId       = try c.decodeIfPresent(String.self, forKey: .captureId)
        message         = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    init(contractVersion: String = "1.0", accepted: Bool, captureId: String?, message: String) {
        self.contractVersion = contractVersion
        self.accepted = accepted
        self.captureId = captureId
        self.message = message
    }

    static func decode(_ data: Data) throws -> TransferCommitResult {
        do {
            return try JSONDecoder().decode(TransferCommitResult.self, from: data)
        } catch {
            throw ContractError.malformed(file: "commit", detail: "\(error)")
        }
    }
}

// MARK: - Errors

enum TransferError: Error, CustomStringConvertible, Equatable {
    case noAnswer(host: String, port: Int)
    case unauthorised
    case expired
    case emptySession
    case unsafeName(String)
    case fileMissing(String)
    case tooLarge(bytes: Int, limit: Int)
    case incomplete(missing: [String])
    case rejected(String)
    case httpStatus(Int)

    var description: String {
        switch self {
        case let .noAnswer(host, port):
            return "Nothing answered at \(host):\(port). Check the code is still on screen, "
                 + "and that this phone is on the same network. You can still import the folder by hand."
        case .unauthorised:
            return "That session did not accept this code. Show a fresh code in PIXMYD-Nav and scan again."
        case .expired:
            return "That transfer session has ended. Show the code again in PIXMYD-Nav."
        case .emptySession:
            return "That session is offering nothing and accepting nothing. Start a transfer in PIXMYD-Nav first."
        case let .unsafeName(name):
            return "The host offered a file called \"\(name)\", which is not a name this app will write."
        case let .fileMissing(name):
            return "The host no longer has \(name). The transfer was discarded rather than half-installed."
        case let .tooLarge(bytes, limit):
            return "This capture is \(bytes / 1_048_576) MB and the host accepts \(limit / 1_048_576) MB."
        case let .incomplete(missing):
            return "The transfer did not complete: \(missing.joined(separator: ", ")) never arrived."
        case let .rejected(message):
            return message.isEmpty ? "The host rejected the capture." : message
        case let .httpStatus(code):
            return "The host answered with HTTP \(code)."
        }
    }
}

// MARK: - Name safety

enum TransferPath {
    /// Whether a name off the wire may become a path component.
    ///
    /// Applied to every entry in `/session` before a single byte is fetched,
    /// so a hostile or buggy host produces one refusal rather than a partial
    /// download that has already written somewhere it should not have.
    static func isSafe(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255 else { return false }
        // A backslash is a separator on the producing platform, so a name
        // containing one means two ends disagree about what a path is.
        guard !name.contains("\\") else { return false }
        guard !name.hasPrefix("/") else { return false }
        // "C:" and friends.
        guard !name.contains(":") else { return false }
        guard !name.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return false }

        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return false }
        for part in parts {
            if part.isEmpty || part == "." || part == ".." { return false }
        }
        return true
    }

    /// The percent-encoded form for a request path.
    static func encoded(_ name: String) -> String? {
        guard isSafe(name) else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        return name.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}

// MARK: - Request planning

/// The URLs and headers a transfer needs, worked out without a network stack
/// so the rules can be tested.
struct TransferPlan {
    var ticket: TransferTicket

    init(ticket: TransferTicket) {
        self.ticket = ticket
    }

    var authorization: String { "Bearer \(ticket.token)" }

    func sessionURL() throws -> URL {
        try url(path: "/session")
    }

    func downloadURL(_ name: String) throws -> URL {
        guard let encoded = TransferPath.encoded(name) else {
            throw TransferError.unsafeName(name)
        }
        return try url(path: "/file/\(encoded)")
    }

    func uploadURL(_ name: String) throws -> URL {
        guard let encoded = TransferPath.encoded(name) else {
            throw TransferError.unsafeName(name)
        }
        return try url(path: "/capture/\(encoded)")
    }

    func commitURL() throws -> URL {
        try url(path: "/capture/commit")
    }

    /// Check the whole offer before fetching any of it.
    func validate(_ offer: TransferOffer) throws {
        for file in offer.files where !TransferPath.isSafe(file.name) {
            throw TransferError.unsafeName(file.name)
        }
    }

    private func url(path: String) throws -> URL {
        guard let base = ticket.baseURL, let url = URL(string: base.absoluteString + path) else {
            throw TransferError.noAnswer(host: ticket.host, port: ticket.port)
        }
        return url
    }
}

/// Map an HTTP status onto the error the user should read.
///
/// Kept out of the client so the mapping is testable and so there is one
/// place that decides what a 401 means — the contract uses it for both a bad
/// token and an expired session, and the difference matters to the user even
/// though it does not to the protocol.
enum TransferStatus {
    static func check(_ code: Int, sessionStarted: Bool) throws {
        switch code {
        case 200, 201, 204:
            return
        case 401, 403:
            throw sessionStarted ? TransferError.expired : TransferError.unauthorised
        case 404:
            throw TransferError.httpStatus(404)
        case 413:
            throw TransferError.httpStatus(413)
        default:
            throw TransferError.httpStatus(code)
        }
    }
}
