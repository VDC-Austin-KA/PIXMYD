import Foundation

// The URLSession half of `docs/contracts/transfer.md`.
//
// There are no decisions in this file. Which names are safe, what a status
// code means, and what a session has to contain before it is worth talking to
// all live in `NavTransfer.swift`, where `swift test` can reach them. This is
// the part that cannot be tested off a phone, so it is kept as close to
// mechanical as it can be.
//
// ## On the product promise
//
// `AccountView` tells users that captures stay on the device until they export
// them, and there is no account and nothing is uploaded anywhere. A transfer
// is an export: the user starts it by scanning a code, the host it is talking
// to is named on screen before anything moves, and nothing here runs in the
// background or retries on its own. `NtripClient` aside, this is the only
// networking in the app, and like NTRIP it is a link the user set up
// deliberately to a machine they can see.
//
// Not in `portableSources` — URLSession does not exist on Linux, and the shape
// of this file is why that is acceptable.

/// A live transfer session with a PIXMYD-Nav host.
///
/// `@MainActor` because every consumer is a SwiftUI view driving a progress
/// bar, and hopping off only to hop straight back would buy nothing: the work
/// here is IO-bound, and `URLSession`'s async API already does the waiting off
/// the main thread.
@MainActor
final class NavTransferClient {
    private let plan: TransferPlan
    private let session: URLSession
    private var started = false

    /// Progress across a multi-file leg, as a fraction and a label.
    struct Progress: Equatable {
        var completed: Int
        var total: Int
        var currentFile: String

        var fraction: Double {
            total <= 0 ? 0 : Double(completed) / Double(total)
        }
    }

    init(ticket: TransferTicket) {
        self.plan = TransferPlan(ticket: ticket)

        // A site LAN is fast and close. A long timeout here means a phone that
        // sits on a spinner for a minute because the workstation went to
        // sleep, when the useful answer is "nothing answered, import by hand".
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = false
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    var ticket: TransferTicket { plan.ticket }

    // MARK: - Handshake

    /// The guest's first call. Everything else needs what this returns.
    func openSession() async throws -> TransferSession {
        let data = try await send(request(.get, url: try plan.sessionURL()))
        let session = try TransferSession.decode(data)
        started = true
        return session
    }

    // MARK: - Download

    /// Fetch every file in an offer and install it as a bundle.
    ///
    /// All or nothing, deliberately. "A point set missing three photos looks
    /// like a point set, which is worse than no point set" — a half-installed
    /// bundle would show markers with no photo and no indication that the
    /// photo ever existed, and the operator would conclude the export was
    /// wrong rather than the transfer.
    func download(
        _ offer: TransferOffer,
        into documents: URL,
        onProgress: @MainActor (Progress) -> Void = { _ in }
    ) async throws -> StoredNavBundle {
        try plan.validate(offer)

        var files: [String: Data] = [:]
        var missing: [String] = []

        for (index, file) in offer.files.enumerated() {
            onProgress(Progress(completed: index, total: offer.files.count, currentFile: file.name))
            do {
                files[file.name] = try await send(request(.get, url: try plan.downloadURL(file.name)))
            } catch TransferError.httpStatus(404) {
                missing.append(file.name)
            }
        }

        guard missing.isEmpty else {
            throw TransferError.incomplete(missing: missing)
        }
        onProgress(Progress(completed: offer.files.count, total: offer.files.count, currentFile: ""))

        // Validated as a bundle exactly as a sideloaded folder would be.
        return try NavBundleStore.install(files: files, into: documents)
    }

    // MARK: - Upload

    /// Send a capture back and ask the host to stage it.
    ///
    /// Returns the host's own message. Commit does not place geometry: the
    /// contract puts the accuracy decision at the workstation, because a
    /// person on a scaffold is the wrong one to be judging whether a 40 mm RMS
    /// is good enough for what this model is about to be used for.
    func upload(
        files: [String: Data],
        policy: TransferUploadPolicy,
        onProgress: @MainActor (Progress) -> Void = { _ in }
    ) async throws -> TransferCommitResult {
        guard policy.accepted else {
            throw TransferError.rejected("This session is not accepting uploads.")
        }

        let total = files.values.reduce(0) { $0 + $1.count }
        if policy.maxBytes > 0, total > policy.maxBytes {
            throw TransferError.tooLarge(bytes: total, limit: policy.maxBytes)
        }
        for name in files.keys where !TransferPath.isSafe(name) {
            throw TransferError.unsafeName(name)
        }

        // Sorted so the order is deterministic and a partial upload always
        // fails at the same place, which makes a report from the field mean
        // something.
        let ordered = files.sorted { $0.key < $1.key }
        for (index, entry) in ordered.enumerated() {
            onProgress(Progress(completed: index, total: ordered.count, currentFile: entry.key))
            var upload = request(.post, url: try plan.uploadURL(entry.key))
            upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            _ = try await send(upload, body: entry.value)
        }
        onProgress(Progress(completed: ordered.count, total: ordered.count, currentFile: ""))

        let data = try await send(request(.post, url: try plan.commitURL()), body: Data())
        let result = try TransferCommitResult.decode(data)
        guard result.accepted else {
            throw TransferError.rejected(result.message)
        }
        return result
    }

    // MARK: - Plumbing

    private enum Method: String {
        case get = "GET"
        case post = "POST"
    }

    private func request(_ method: Method, url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue(plan.authorization, forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    private func send(_ request: URLRequest, body: Data? = nil) async throws -> Data {
        var request = request
        do {
            let (data, response): (Data, URLResponse)
            if let body {
                (data, response) = try await session.upload(for: request, from: body)
            } else {
                request.httpBody = nil
                (data, response) = try await session.data(for: request)
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            try TransferStatus.check(code, sessionStarted: started)
            return data
        } catch let error as TransferError {
            throw error
        } catch let error as ContractError {
            throw error
        } catch {
            // Anything URLSession raises — refused, unreachable, timed out —
            // is the same thing to a user standing on a slab: nothing
            // answered, and there is another way in.
            throw TransferError.noAnswer(host: plan.ticket.host, port: plan.ticket.port)
        }
    }
}
