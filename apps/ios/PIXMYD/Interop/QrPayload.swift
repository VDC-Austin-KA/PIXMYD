import Foundation

// Everything encoded into a QR code in this suite, and nothing else.
//
// Three payload kinds share one `pixmy://` scheme. All three are deliberately
// short: QR density drives printed marker legibility, and a long URL forces a
// higher version symbol that photographs badly on a dusty column under site
// lighting. Two of them are identifiers, not data carriers — the app resolves
// them against content it already holds and never fetches.
//
//   pixmy://p/<setId8>/<pointId>        a printed field marker on a column
//   pixmy://m/<bundleId8>               an AR model bundle
//   pixmy://t/<host8><port4>/<token16>  a transfer session on this network
//
// The third is new and is the only one that names a network endpoint. It
// exists because the alternative — copying a folder onto the phone through
// Files — is the step that actually stops people using any of this on a site.
//
// ## Why the transfer payload is shaped like that
//
// PIXMYD-Nav's QR encoder (`Core/Markers/QrEncoder.cs`) is byte mode, error
// correction level M, versions 1-3 only: a hard ceiling of 42 bytes. Versions
// 4 and up need Reed-Solomon block splitting and interleaving that the encoder
// does not implement, and it throws rather than emit a malformed symbol.
//
// So the transfer payload is packed to a fixed 39 bytes and can never drift:
//
//   "pixmy://t/"  10
//   host           8   IPv4 as hex, 2 chars per octet
//   port           4   hex
//   "/"            1
//   token         16   64 bits of hex
//   ————————————————
//                 39   always, for every session
//
// A dotted-quad and a decimal port would be up to 40 bytes and would vary with
// the address, which means a symbol that fits on one machine and throws on the
// next. Fixed-width hex costs nothing to read on a phone and removes the
// failure mode entirely.
//
// The payload carries no direction. One code serves both legs: the phone scans
// it, asks the session what it offers, and the user picks download or upload.
// Encoding the direction would mean two codes on screen and a wrong-code
// failure that looks like a broken scanner.
//
// This file is in `portableSources`, so `swift test` covers the parsing.
// Keep it Foundation-only — the camera lives elsewhere.

/// A decoded `pixmy://` QR payload.
enum PixmyPayload: Equatable {
    /// A printed field marker. `setId8` is the first 8 characters of the point
    /// set's UUID, not the whole thing.
    case point(setId8: String, pointId: String)
    /// An AR model bundle, by the first 8 characters of its id.
    case bundle(bundleId8: String)
    /// A transfer session offered by PIXMYD-Nav on the local network.
    case transfer(TransferTicket)

    static let scheme = "pixmy"

    /// Parse a scanned string.
    ///
    /// Returns nil rather than throwing: a camera pointed at the world sees a
    /// lot of barcodes that are not ours, and a parse failure is the normal
    /// case, not an error worth surfacing. The caller decides when to tell the
    /// user "that is a QR code, but not one of ours".
    static func parse(_ raw: String) -> PixmyPayload? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "\(scheme)://"
        guard text.count > prefix.count,
              text.lowercased().hasPrefix(prefix) else { return nil }

        let body = String(text.dropFirst(prefix.count))
        let parts = body.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let kind = parts.first?.lowercased() else { return nil }

        switch kind {
        case "p":
            // pixmy://p/<setId8>/<pointId>
            guard parts.count == 3 else { return nil }
            let setId8 = parts[1].lowercased()
            let pointId = parts[2]
            guard setId8.count == 8, isHex(setId8), !pointId.isEmpty else { return nil }
            return .point(setId8: setId8, pointId: pointId)

        case "m":
            // pixmy://m/<bundleId8>
            guard parts.count == 2 else { return nil }
            let bundleId8 = parts[1].lowercased()
            guard bundleId8.count == 8, isHex(bundleId8) else { return nil }
            return .bundle(bundleId8: bundleId8)

        case "t":
            // pixmy://t/<host8><port4>/<token16>
            guard parts.count == 3 else { return nil }
            guard let ticket = TransferTicket(endpointHex: parts[1], token: parts[2]) else { return nil }
            return .transfer(ticket)

        default:
            return nil
        }
    }

    /// The exact string a producer encodes. Kept next to the parser so the two
    /// cannot drift apart — the round trip is what the tests assert.
    var encoded: String {
        switch self {
        case let .point(setId8, pointId):
            return "\(Self.scheme)://p/\(setId8)/\(pointId)"
        case let .bundle(bundleId8):
            return "\(Self.scheme)://m/\(bundleId8)"
        case let .transfer(ticket):
            return ticket.encoded
        }
    }

    private static func isHex(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isHexDigit }
    }
}

/// Where a transfer session lives and the secret that opens it.
///
/// The token is 64 bits. It is not a password — it is a capability that is
/// only useful to something already on the same network segment, for the
/// minutes the desktop user has the session open and visible on screen. The
/// host end rate-limits and expires it; see the plugin's transfer server.
struct TransferTicket: Equatable {
    /// Dotted-quad IPv4. The suite targets a Windows workstation and a phone
    /// on the same site wifi, and packing a name or an IPv6 literal into 12
    /// hex characters is not possible.
    var host: String
    var port: Int
    /// 16 lowercase hex characters.
    var token: String

    init?(host: String, port: Int, token: String) {
        guard Self.octets(of: host) != nil else { return nil }
        guard (1...65535).contains(port) else { return nil }
        let t = token.lowercased()
        guard t.count == 16, t.allSatisfy({ $0.isHexDigit }) else { return nil }
        self.host = host
        self.port = port
        self.token = t
    }

    /// Build from the packed `<host8><port4>` field and the token field.
    init?(endpointHex: String, token: String) {
        let hex = endpointHex.lowercased()
        guard hex.count == 12, hex.allSatisfy({ $0.isHexDigit }) else { return nil }

        let chars = Array(hex)
        func byte(_ i: Int) -> Int? { Int(String(chars[i * 2 ..< i * 2 + 2]), radix: 16) }
        guard let a = byte(0), let b = byte(1), let c = byte(2), let d = byte(3),
              let portHi = byte(4), let portLo = byte(5) else { return nil }

        let port = portHi << 8 | portLo
        self.init(host: "\(a).\(b).\(c).\(d)", port: port, token: token)
    }

    /// The packed 12-hex endpoint field.
    var endpointHex: String {
        guard let o = Self.octets(of: host) else { return "00000000" + String(format: "%04x", port) }
        return String(format: "%02x%02x%02x%02x%04x", o[0], o[1], o[2], o[3], port)
    }

    var encoded: String {
        "\(PixmyPayload.scheme)://t/\(endpointHex)/\(token)"
    }

    /// The session's base URL. Plain HTTP on purpose: this is a link-local
    /// exchange between two devices the user is holding, and a self-signed
    /// certificate would train people to tap through TLS warnings for no gain
    /// in a threat model where the attacker is already on the wifi.
    var baseURL: URL? {
        URL(string: "http://\(host):\(port)")
    }

    private static func octets(of host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard let v = Int(p), (0...255).contains(v), !p.isEmpty else { return nil }
            // Reject "01" — a leading zero means someone is passing an octal
            // literal, and the two ends must agree byte-for-byte.
            if p.count > 1 && p.hasPrefix("0") { return nil }
            out.append(v)
        }
        return out
    }
}
