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

    /// How far through a leg the transfer is.
    ///
    /// Bytes, not files. The two legs are lopsided — an export is a JSON and a
    /// handful of PNGs, a return leg is a JSON and a mesh three orders of
    /// magnitude larger — so a bar driven by files completed sits still for the
    /// only part that takes time, which is indistinguishable from a hang and is
    /// exactly when somebody walks away.
    struct Progress: Equatable {
        var bytesDone: Int
        var bytesTotal: Int
        var filesDone: Int
        var filesTotal: Int
        var currentFile: String

        init(
            bytesDone: Int = 0,
            bytesTotal: Int = 0,
            filesDone: Int = 0,
            filesTotal: Int = 0,
            currentFile: String = ""
        ) {
            self.bytesDone = bytesDone
            self.bytesTotal = bytesTotal
            self.filesDone = filesDone
            self.filesTotal = filesTotal
            self.currentFile = currentFile
        }

        /// 0 to 1. A zero total reads as zero rather than as complete: an empty
        /// transfer is not evidence that anything finished.
        var fraction: Double {
            guard bytesTotal > 0 else { return 0 }
            return min(1, max(0, Double(bytesDone) / Double(bytesTotal)))
        }

        /// One line for under the bar.
        ///
        /// Written out as statements, with every intermediate typed. The
        /// compact version of this — a ternary whose branches interpolate a
        /// call to `min` over an arithmetic expression, then a second ternary
        /// mixing `+` with interpolation — is the exact shape that timed out
        /// the type checker in `ReceiverScanView` and broke a macOS build. The
        /// Linux CI only *parses* this half of the app, so nothing here catches
        /// that class of failure before a Mac does.
        var label: String {
            let done: String = Self.bytes(bytesDone)
            let total: String = Self.bytes(bytesTotal)
            let sizes: String = done + " of " + total

            var counts: String = ""
            if filesTotal > 1 {
                let index: Int = Swift.min(filesDone + 1, filesTotal)
                counts = " · file " + String(index) + " of " + String(filesTotal)
            }

            if currentFile.isEmpty { return sizes + counts }
            return currentFile + " — " + sizes + counts
        }

        /// `nonisolated` because it is a pure function of its argument, and
        /// `verify.sh` fails the build over exactly this: a static member of a
        /// `@MainActor` type inherits that isolation, so calling it from a
        /// detached task is either an error or a silent hop back to the main
        /// thread.
        nonisolated static func bytes(_ value: Int) -> String {
            if value < 1024 { return "\(value) B" }
            if value < 1_048_576 { return String(format: "%.0f KB", Double(value) / 1024) }
            if value < 1_073_741_824 { return String(format: "%.1f MB", Double(value) / 1_048_576) }
            return String(format: "%.2f GB", Double(value) / 1_073_741_824)
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

        let total = offer.totalBytes
        var done = 0

        for (index, file) in offer.files.enumerated() {
            onProgress(Progress(
                bytesDone: done, bytesTotal: total,
                filesDone: index, filesTotal: offer.files.count,
                currentFile: file.name))
            do {
                let data = try await receive(
                    request(.get, url: try plan.downloadURL(file.name))
                ) { received in
                    // `done` is the total for the files already finished; the
                    // running count is added rather than replacing it, so the
                    // bar never goes backwards between files.
                    onProgress(Progress(
                        bytesDone: done + received, bytesTotal: total,
                        filesDone: index, filesTotal: offer.files.count,
                        currentFile: file.name))
                }
                files[file.name] = data
                done += data.count
            } catch TransferError.httpStatus(404) {
                missing.append(file.name)
                // The offer said how big it was; keep the bar honest about what
                // is left rather than stalling on a file that is not coming.
                done += file.bytes
            }
        }

        guard missing.isEmpty else {
            throw TransferError.incomplete(missing: missing)
        }
        onProgress(Progress(
            bytesDone: total, bytesTotal: total,
            filesDone: offer.files.count, filesTotal: offer.files.count))

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
        onProgress: @escaping @MainActor (Progress) -> Void = { _ in }
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
        var done = 0

        for (index, entry) in ordered.enumerated() {
            onProgress(Progress(
                bytesDone: done, bytesTotal: total,
                filesDone: index, filesTotal: ordered.count,
                currentFile: entry.key))

            var upload = request(.post, url: try plan.uploadURL(entry.key))
            upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

            let sent = done
            _ = try await send(upload, body: entry.value) { bytes in
                onProgress(Progress(
                    bytesDone: sent + bytes, bytesTotal: total,
                    filesDone: index, filesTotal: ordered.count,
                    currentFile: entry.key))
            }
            done += entry.value.count
        }
        onProgress(Progress(
            bytesDone: total, bytesTotal: total,
            filesDone: ordered.count, filesTotal: ordered.count))

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

    private func send(
        _ request: URLRequest,
        body: Data? = nil,
        onBytesSent: (@MainActor (Int) -> Void)? = nil
    ) async throws -> Data {
        var request = request
        do {
            let (data, response): (Data, URLResponse)
            if let body {
                // The delegate is what turns an upload into something with a
                // bar. `upload(for:from:)` on its own reports nothing until it
                // finishes, which for a 300 MB mesh over site wifi is a minute
                // of a spinner that could equally mean the workstation died.
                let watcher = onBytesSent.map { UploadWatcher(onBytesSent: $0) }
                (data, response) = try await session.upload(
                    for: request, from: body, delegate: watcher)
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

    /// Read a response body as it arrives, reporting the running count.
    ///
    /// `data(for:)` hands back everything at once, so a single large file would
    /// jump from nothing to done. `bytes(for:)` streams, which is what a bar
    /// needs — and it costs one accumulation loop.
    private func receive(
        _ request: URLRequest,
        onBytesReceived: @MainActor (Int) -> Void
    ) async throws -> Data {
        do {
            let (stream, response) = try await session.bytes(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            try TransferStatus.check(code, sessionStarted: started)

            let expected = response.expectedContentLength
            var data = Data()
            if expected > 0 { data.reserveCapacity(Int(expected)) }

            // Reported every 64 KB rather than every byte: an unthrottled
            // callback would post to the main actor hundreds of thousands of
            // times for a bar that redraws sixty times a second.
            var sinceReport = 0
            for try await byte in stream {
                data.append(byte)
                sinceReport += 1
                if sinceReport >= 64 * 1024 {
                    sinceReport = 0
                    onBytesReceived(data.count)
                }
            }
            onBytesReceived(data.count)
            return data
        } catch let error as TransferError {
            throw error
        } catch let error as ContractError {
            throw error
        } catch {
            throw TransferError.noAnswer(host: plan.ticket.host, port: plan.ticket.port)
        }
    }
}

/// Turns `didSendBodyData` into a closure call on the main actor.
///
/// A separate object because `URLSessionTaskDelegate` is an `NSObject`
/// protocol and the client is a `@MainActor` final class — conforming it
/// directly would drag the whole class into `NSObject` for one callback.
private final class UploadWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onBytesSent: @MainActor (Int) -> Void

    init(onBytesSent: @escaping @MainActor (Int) -> Void) {
        self.onBytesSent = onBytesSent
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        // URLSession calls this on its own delegate queue.
        let sent = Int(totalBytesSent)
        Task { @MainActor in self.onBytesSent(sent) }
    }
}
