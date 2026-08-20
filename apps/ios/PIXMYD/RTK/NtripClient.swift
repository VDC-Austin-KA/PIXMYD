import Foundation
import Network

/// Minimal NTRIP v1 client.
///
/// NTRIP is HTTP-shaped but not HTTP: the caster replies `ICY 200 OK` and then
/// streams RTCM forever on the same socket. `URLSession` cannot express that,
/// so this speaks the protocol directly over `NWConnection`.
///
/// The app never interprets the RTCM. Corrections go straight to the receiver,
/// which is the only thing that can apply them — the phone is a pipe, and
/// pretending otherwise would mean reimplementing a GNSS engine.
final class NtripClient: @unchecked Sendable {

    enum State: Equatable {
        case idle
        case connecting
        case streaming(bytesReceived: Int)
        case failed(String)

        var label: String {
            switch self {
            case .idle: "Not connected"
            case .connecting: "Connecting"
            case .streaming(let bytes):
                "Streaming — \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary))"
            case .failed(let reason): reason
            }
        }

        var isHealthy: Bool {
            if case .streaming = self { return true }
            return false
        }
    }

    var onCorrection: ((Data) -> Void)?
    var onStateChange: ((State) -> Void)?

    private let profile: RtkProfile
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.pixmyd.ntrip")
    private var bytesReceived = 0
    private var headerConsumed = false
    private var positionTimer: DispatchSourceTimer?

    /// The most recent GGA to report upstream, set by the GNSS manager.
    ///
    /// Written on the main actor as sentences arrive and read on this client's
    /// own queue by the position timer, so the two are separated by a lock. A
    /// bare `var` here is a genuine race on a `String` — not a benign one — and
    /// it went unnoticed while nothing was writing the property at all.
    var latestGga: String? {
        get {
            ggaLock.lock()
            defer { ggaLock.unlock() }
            return storedGga
        }
        set {
            ggaLock.lock()
            defer { ggaLock.unlock() }
            storedGga = newValue
        }
    }

    private let ggaLock = NSLock()
    private var storedGga: String?

    init(profile: RtkProfile) {
        self.profile = profile
    }

    func start() {
        guard profile.isComplete else {
            onStateChange?(.failed("Profile is missing a host or mount point."))
            return
        }
        setState(.connecting)

        let endpoint = NWEndpoint.hostPort(
            host: .init(profile.host),
            port: .init(rawValue: UInt16(profile.port)) ?? 2101
        )
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendRequest()
                self.receive()
            case .failed(let error):
                self.setState(.failed(error.localizedDescription))
            case .cancelled:
                self.setState(.idle)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func stop() {
        positionTimer?.cancel()
        positionTimer = nil
        connection?.cancel()
        connection = nil
        headerConsumed = false
        bytesReceived = 0
        setState(.idle)
    }

    // MARK: - Protocol

    private func sendRequest() {
        let credentials = "\(profile.username):\(profile.password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        let request = """
        GET /\(profile.mountPoint) HTTP/1.0\r
        User-Agent: NTRIP PIXMYD/\(Bundle.main.shortVersion)\r
        Accept: */*\r
        Authorization: Basic \(encoded)\r
        Connection: close\r
        \r

        """
        connection?.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            if let error {
                self?.setState(.failed(error.localizedDescription))
            }
        })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.setState(.failed(error.localizedDescription))
                return
            }

            if var data, !data.isEmpty {
                if !self.headerConsumed {
                    // The caster's reply header ends at the first blank line.
                    // Everything after it is RTCM and must not be swallowed.
                    if let range = data.range(of: Data("\r\n\r\n".utf8)) {
                        let header = String(decoding: data[..<range.lowerBound], as: UTF8.self)
                        guard header.contains("200") else {
                            self.setState(.failed(Self.describe(header)))
                            return
                        }
                        self.headerConsumed = true
                        data = data[range.upperBound...]
                        self.startPositionReports()
                    } else {
                        // Header split across reads; wait for the rest.
                        self.receive()
                        return
                    }
                }

                if !data.isEmpty {
                    self.bytesReceived += data.count
                    self.onCorrection?(data)
                    self.setState(.streaming(bytesReceived: self.bytesReceived))
                }
            }

            if isComplete {
                self.setState(.failed("The caster closed the connection."))
                return
            }
            self.receive()
        }
    }

    /// Most VRS networks stop sending corrections unless the rover keeps
    /// reporting where it is, so the GGA goes back up the same socket. Without
    /// this the stream connects, delivers for a minute, and quietly stalls —
    /// which presents as "RTK stopped working" with no error anywhere.
    private func startPositionReports() {
        guard profile.sendPositionToCaster else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self, let gga = self.latestGga else { return }
            self.connection?.send(
                content: Data((gga + "\r\n").utf8),
                completion: .idempotent
            )
        }
        timer.resume()
        positionTimer = timer
    }

    private static func describe(_ header: String) -> String {
        if header.contains("401") { return "Caster rejected the username or password." }
        if header.contains("404") { return "Mount point not found on this caster." }
        if header.localizedCaseInsensitiveContains("SOURCETABLE") {
            return "Caster returned its source table, which means the mount point is wrong."
        }
        return "Caster refused the connection."
    }

    private func setState(_ state: State) {
        onStateChange?(state)
    }
}

// MARK: - Source table

/// One request for a caster's source table.
///
/// A request for `/` returns the table rather than a stream — the same
/// behaviour that makes a wrong mount point so baffling mid-connection is,
/// here, exactly what is wanted. The point is to stop the mount point being
/// something a user types from memory: the caster already knows what it
/// serves, including which streams need a position report, and asking it is
/// cheaper than getting it wrong on site.
///
/// A class rather than a function with captured state: the network callbacks
/// are `@Sendable`, so a buffer accumulated across several reads cannot be a
/// local variable. It holds itself alive until it finishes, because nothing
/// else has a reason to.
final class NtripSourceTableProbe: @unchecked Sendable {

    enum Failure: Error, Equatable {
        case message(String)

        var label: String {
            switch self {
            case .message(let reason): reason
            }
        }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.pixmyd.ntrip.sourcetable")
    private let username: String
    private let password: String
    private let timeout: TimeInterval

    private var received = Data()
    private var finished = false
    private var completion: ((Result<[NtripMountPoint], Failure>) -> Void)?
    private var keepAlive: NtripSourceTableProbe?

    init?(host: String, port: Int, username: String, password: String, timeout: TimeInterval = 12) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let port16 = UInt16(exactly: port),
              let endpointPort = NWEndpoint.Port(rawValue: port16)
        else { return nil }

        self.connection = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(trimmed), port: endpointPort),
            using: .tcp
        )
        self.username = username
        self.password = password
        self.timeout = timeout
    }

    /// - Parameter completion: called exactly once, on the main queue.
    func start(completion: @escaping (Result<[NtripMountPoint], Failure>) -> Void) {
        self.completion = completion
        keepAlive = self

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendRequest()
                self.receive()
            case .failed(let error), .waiting(let error):
                self.finish(.failure(.message(error.localizedDescription)))
            default:
                break
            }
        }
        connection.start(queue: queue)

        // A caster that accepts the connection and then says nothing would
        // otherwise leave a spinner turning for ever.
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(.message("The caster did not answer.")))
        }
    }

    private func sendRequest() {
        let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
        let request = """
        GET / HTTP/1.0\r
        User-Agent: NTRIP PIXMYD/\(Bundle.main.shortVersion)\r
        Accept: */*\r
        Authorization: Basic \(credentials)\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(request.utf8), completion: .idempotent)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.received.append(data) }
            if let error {
                self.finish(.failure(.message(error.localizedDescription)))
                return
            }
            if isComplete {
                self.finish(Self.interpret(self.received))
                return
            }
            self.receive()
        }
    }

    private func finish(_ result: Result<[NtripMountPoint], Failure>) {
        queue.async {
            guard !self.finished else { return }
            self.finished = true
            self.connection.cancel()
            let completion = self.completion
            self.completion = nil
            DispatchQueue.main.async {
                completion?(result)
                self.keepAlive = nil
            }
        }
    }

    private static func interpret(_ data: Data) -> Result<[NtripMountPoint], Failure> {
        // Latin-1 never fails, and a source table is ASCII apart from the
        // occasional accented place name. Insisting on UTF-8 would throw away
        // a whole table for one stray byte in a station description.
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        guard !text.isEmpty else {
            return .failure(.message("The caster sent nothing back."))
        }
        let mountPoints = NtripSourceTable.parse(text)
        if mountPoints.isEmpty {
            if text.contains("401") {
                return .failure(.message("Caster rejected the username or password."))
            }
            return .failure(.message("The caster answered, but its reply lists no mount points."))
        }
        return .success(mountPoints)
    }
}
