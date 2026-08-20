import Foundation

/// Everything about finding a receiver over the air that is pure arithmetic.
///
/// The scanning itself needs CoreBluetooth and Network, which only exist on a
/// phone. What lives here is the part that decides *what was found* — how a
/// device is identified, ranked, de-duplicated, forgotten when it goes away,
/// and whether the bytes coming out of it are actually a GNSS stream. That is
/// the part where a mistake is silent, so it is the part that is tested.

// MARK: - Link

/// How a receiver is reached.
///
/// The three are not interchangeable, and the difference is worth showing: a
/// Bluetooth link is per-device and pairs once; a Wi-Fi link depends on the
/// phone being on the same network as the receiver, which on site usually
/// means joining the receiver's own access point; an MFi accessory is already
/// physically attached and needs no scan at all.
enum ReceiverLink: String, Codable, CaseIterable, Sendable {
    case bluetooth
    case wifi
    case mfi

    var label: String {
        switch self {
        case .bluetooth: "Bluetooth"
        case .wifi: "Wi-Fi"
        case .mfi: "Accessory"
        }
    }

    var systemImage: String {
        switch self {
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .wifi: "wifi"
        case .mfi: "cable.connector"
        }
    }

    /// Ordering when nothing else separates two devices. An attached accessory
    /// is the surest connection, then Bluetooth, then a network endpoint that
    /// may or may not still be reachable.
    var priority: Int {
        switch self {
        case .mfi: 0
        case .bluetooth: 1
        case .wifi: 2
        }
    }

    /// Whether devices on this link announce themselves repeatedly, so silence
    /// means "gone". Bluetooth advertises on a timer; Bonjour and MFi send an
    /// explicit removal, so their entries are never aged out on a clock.
    var expiresWhenSilent: Bool { self == .bluetooth }
}

// MARK: - Vendor

/// Receiver makers recognised by name.
///
/// This is a *heuristic on an advertised name*, and nothing depends on it
/// being right: a match promotes a device up the list and puts a maker's name
/// beside it, and a miss means the device is still listed, still connectable,
/// and still works. It exists because a scan in a car park finds forty
/// Bluetooth devices and two of them are the receiver.
enum ReceiverVendor: String, CaseIterable, Sendable {
    case emlid
    case badElf
    case trimble
    case leica
    case topcon
    case septentrio
    case ublox
    case ardusimple
    case sparkfun
    case chcnav
    case stonex
    case geomax
    case sinognss

    var label: String {
        switch self {
        case .emlid: "Emlid"
        case .badElf: "Bad Elf"
        case .trimble: "Trimble"
        case .leica: "Leica"
        case .topcon: "Topcon"
        case .septentrio: "Septentrio"
        case .ublox: "u-blox"
        case .ardusimple: "ArduSimple"
        case .sparkfun: "SparkFun"
        case .chcnav: "CHCNAV"
        case .stonex: "Stonex"
        case .geomax: "GeoMax"
        case .sinognss: "SinoGNSS"
        }
    }

    /// Lower-cased fragments that appear in the advertised name of a device
    /// from this maker.
    var needles: [String] {
        switch self {
        case .emlid: ["emlid", "reach"]
        case .badElf: ["bad elf", "badelf", "bad-elf", "flex"]
        case .trimble: ["trimble", "da2", "catalyst", "r780", "r12"]
        case .leica: ["leica", "gs18", "zeno"]
        case .topcon: ["topcon", "hiper"]
        case .septentrio: ["septentrio", "mosaic", "altus"]
        case .ublox: ["u-blox", "ublox", "zed-f9", "zedf9"]
        case .ardusimple: ["ardusimple", "simplertk"]
        case .sparkfun: ["sparkfun", "rtk facet", "rtk express", "rtk surveyor", "rtk torch"]
        case .chcnav: ["chcnav", "chc "]
        case .stonex: ["stonex"]
        case .geomax: ["geomax", "zenith"]
        case .sinognss: ["sinognss", "comnav"]
        }
    }

    /// The first maker whose name appears in `name`, or nil.
    ///
    /// Deliberately case- and diacritic-insensitive: receivers name themselves
    /// inconsistently across firmware versions, and "REACH RX" and "Reach RX"
    /// are the same product.
    static func identify(_ name: String?) -> ReceiverVendor? {
        guard let name, !name.isEmpty else { return nil }
        let haystack = name.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                    locale: nil)
        return allCases.first { vendor in
            vendor.needles.contains { haystack.contains($0) }
        }
    }
}

// MARK: - Role

/// What a thing found on the network actually is.
///
/// The scan finds two kinds of device and they are not interchangeable. A rover
/// sends positions to the phone; a caster sends corrections to the rover. They
/// are found by the same Bonjour browse and look identical in a list, and
/// connecting to a caster as though it were a rover produces a link that opens,
/// delivers RTCM the app cannot use, and never yields a position.
enum ReceiverRole: String, Codable, Sendable {
    /// A receiver that reports where it is.
    case rover
    /// An NTRIP caster: a source of corrections, which belongs in a profile's
    /// caster field rather than on the end of a position link.
    case caster

    /// The Bonjour service types that mean "this is a correction source".
    static func of(bonjourType: String) -> ReceiverRole {
        bonjourType.hasPrefix("_ntrip") ? .caster : .rover
    }
}

/// The Bonjour service types the scan browses.
///
/// Every one of these must also be listed in `NSBonjourServices` in Info.plist:
/// iOS does not merely refuse an unlisted type, it returns no results for it,
/// which looks exactly like nothing being there. Kept here rather than on the
/// scanner so the list and the rule that classifies it can be tested together.
enum ReceiverBonjour {
    static let types = ["_ntrip._tcp", "_nmea._tcp", "_gnss._tcp", "_reach._tcp"]
}

// MARK: - A found device

/// One device seen by a scan.
///
/// `identifier` is whatever the link uses as a stable handle — the
/// CoreBluetooth peripheral identifier, a Bonjour instance name, `host:port`
/// for an endpoint typed by hand, or the MFi connection ID. It is opaque here;
/// only the scanner turns it back into something connectable.
struct DiscoveredReceiver: Identifiable, Equatable, Hashable, Sendable {
    var link: ReceiverLink
    var identifier: String
    /// What the device calls itself. Bluetooth peripherals are allowed to
    /// advertise no name at all, hence optional rather than a placeholder
    /// string — the placeholder is a display concern.
    var name: String?
    var vendor: ReceiverVendor?
    /// Received signal strength in dBm, Bluetooth only. Nil elsewhere: a Wi-Fi
    /// service gives no per-device strength, and inventing one would imply a
    /// proximity the app cannot measure.
    var rssi: Int?
    /// A short factual note — the advertised service, the resolved host — shown
    /// under the name.
    var detail: String?
    /// True when the device advertises a serial-style service this app knows
    /// how to read. A far better signal than the name, when it is present.
    var advertisesSerialService: Bool = false
    /// Whether this is something to take positions from, or something to take
    /// corrections from.
    var role: ReceiverRole = .rover
    var lastSeen: Date = .distantPast

    var id: String { "\(link.rawValue):\(identifier)" }

    var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return "Unnamed \(link.label.lowercased()) device"
    }

    /// Whether this looks like GNSS equipment rather than a pair of earbuds.
    ///
    /// Used only to decide what to show first and what to hide behind "show
    /// everything". A device that fails this test is still connectable.
    var isLikelyReceiver: Bool { vendor != nil || advertisesSerialService }

    /// Whether a position link can be opened to it. A caster is listed, and
    /// named, but there is nothing to connect a rover link to.
    var isConnectableAsRover: Bool { role == .rover }

    /// Signal strength as 0–4 bars, or nil when the link cannot measure it.
    ///
    /// The thresholds are the usual BLE ones: better than −55 dBm is arm's
    /// length, −90 dBm is at the edge of the range and will drop.
    var signalBars: Int? {
        guard let rssi else { return nil }
        switch rssi {
        case (-55)...: return 4
        case (-67)..<(-55): return 3
        case (-80)..<(-67): return 2
        case (-90)..<(-80): return 1
        default: return 0
        }
    }
}

// MARK: - The list

/// The set of devices a scan has found, kept ordered and de-duplicated.
///
/// A scan is a stream of repeated sightings, not a list: the same peripheral
/// advertises several times a second, its name arrives late, and it stops
/// advertising the moment it is switched off. This turns that stream into
/// something a screen can show without flickering.
struct ReceiverList: Equatable {

    /// How long a Bluetooth device may go unheard before it is dropped.
    ///
    /// Long enough to ride out the gaps between advertisements and a few
    /// missed packets; short enough that a receiver someone has just switched
    /// off leaves the list while they are still looking at it. A stale entry is
    /// worse than no entry — it is a device that will fail to connect for
    /// reasons the list is actively hiding.
    var staleAfter: TimeInterval = 12

    private(set) var receivers: [DiscoveredReceiver] = []

    init(staleAfter: TimeInterval = 12) {
        self.staleAfter = staleAfter
    }

    /// Insert a sighting, or fold it into the one already there.
    ///
    /// Later sightings win on everything they carry, except that a sighting
    /// with no name never erases a name already known. Bluetooth advertising
    /// packets alternate between an advertisement and a scan response, and only
    /// one of them carries the local name, so a naive overwrite makes every
    /// device in the list blink between its name and nothing.
    mutating func merge(_ found: DiscoveredReceiver) {
        guard let index = receivers.firstIndex(where: { $0.id == found.id }) else {
            receivers.append(found)
            sort()
            return
        }

        var merged = found
        if merged.name == nil || merged.name?.isEmpty == true {
            merged.name = receivers[index].name
        }
        if merged.vendor == nil {
            merged.vendor = ReceiverVendor.identify(merged.name) ?? receivers[index].vendor
        }
        if merged.detail == nil { merged.detail = receivers[index].detail }
        // Once a device has been seen advertising a serial service, that fact
        // does not expire with the next packet that omits the service list.
        merged.advertisesSerialService =
            merged.advertisesSerialService || receivers[index].advertisesSerialService
        merged.lastSeen = max(merged.lastSeen, receivers[index].lastSeen)

        receivers[index] = merged
        sort()
    }

    /// Drop devices on advertising links that have gone quiet.
    ///
    /// - Returns: the identifiers removed, so a caller holding connection
    ///   handles can release them.
    @discardableResult
    mutating func expire(now: Date = Date()) -> [String] {
        let (gone, kept) = receivers.reduce(into: ([String](), [DiscoveredReceiver]())) { acc, item in
            let silent = now.timeIntervalSince(item.lastSeen) > staleAfter
            if item.link.expiresWhenSilent && silent {
                acc.0.append(item.id)
            } else {
                acc.1.append(item)
            }
        }
        receivers = kept
        return gone
    }

    mutating func remove(id: String) {
        receivers.removeAll { $0.id == id }
    }

    mutating func removeAll() {
        receivers.removeAll()
    }

    /// What to put on screen.
    ///
    /// - Parameter includingUnknown: when false, only devices that look like
    ///   receivers. A scan anywhere near people finds phones, watches, tyre
    ///   sensors and headphones; showing all of them by default buries the one
    ///   device the user is looking for.
    func visible(includingUnknown: Bool) -> [DiscoveredReceiver] {
        includingUnknown ? receivers : receivers.filter(\.isLikelyReceiver)
    }

    /// Devices hidden by the filter, for the "and N others" line.
    var hiddenCount: Int {
        receivers.filter { !$0.isLikelyReceiver }.count
    }

    /// Named makers first, then anything advertising a serial service, then by
    /// link, then by signal, then alphabetically so the order is stable when
    /// nothing else distinguishes two devices.
    private mutating func sort() {
        receivers.sort { a, b in
            if a.isLikelyReceiver != b.isLikelyReceiver { return a.isLikelyReceiver }
            if (a.vendor != nil) != (b.vendor != nil) { return a.vendor != nil }
            if a.link != b.link { return a.link.priority < b.link.priority }
            if a.rssi != b.rssi { return (a.rssi ?? .min) > (b.rssi ?? .min) }
            if a.displayName != b.displayName { return a.displayName < b.displayName }
            return a.id < b.id
        }
    }
}

// MARK: - Typed endpoints

/// A `host:port` typed by hand.
///
/// Discovery covers receivers that announce themselves. Plenty do not: a rover
/// in access-point mode with a raw TCP output port is invisible to Bonjour and
/// is reached only by typing where it is. That is a normal configuration, not a
/// fallback, so parsing what the user types is done properly.
enum ReceiverEndpoint {

    /// Emlid Reach and most receivers with a "TCP output" setting default to
    /// 9000. It is a starting point in the field, not a standard.
    static let defaultPort = 9000

    static func parse(_ text: String, defaultPort: Int = defaultPort) -> (host: String, port: Int)? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Tolerate a pasted URL. The scheme carries no information here — the
        // connection is a raw socket either way — so it is stripped rather than
        // honoured.
        for scheme in ["tcp://", "http://", "https://"] where trimmed.lowercased().hasPrefix(scheme) {
            trimmed = String(trimmed.dropFirst(scheme.count))
        }
        if let slash = trimmed.firstIndex(of: "/") {
            trimmed = String(trimmed[..<slash])
        }
        guard !trimmed.isEmpty else { return nil }

        // A bracketed IPv6 literal: the colons inside the brackets are part of
        // the address, and only a colon after the closing bracket is a port.
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            guard !host.isEmpty else { return nil }
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.isEmpty { return (host, defaultPort) }
            guard rest.hasPrefix(":"), let port = validPort(String(rest.dropFirst())) else { return nil }
            return (host, port)
        }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return (String(parts[0]), defaultPort)
        case 2:
            let host = String(parts[0])
            guard !host.isEmpty, let port = validPort(String(parts[1])) else { return nil }
            return (host, port)
        default:
            // More than one colon and no brackets is a bare IPv6 address, which
            // cannot carry a port unambiguously. Take it as a host.
            guard validPort(String(parts[parts.count - 1])) == nil else { return nil }
            return (trimmed, defaultPort)
        }
    }

    private static func validPort(_ text: String) -> Int? {
        guard let port = Int(text), (1...65535).contains(port) else { return nil }
        return port
    }
}

// MARK: - What is coming out of it

/// What the first bytes off a link turn out to be.
enum ReceiverStreamKind: String, Sendable {
    /// NMEA 0183 sentences — what this app reads.
    case nmea
    /// RTCM 3 correction frames. A receiver sending these at the phone has its
    /// output configured backwards: corrections travel *to* a rover.
    case rtcm
    /// u-blox UBX binary. The device is a receiver, but in a mode this app
    /// cannot read — the fix is to enable NMEA output on the receiver.
    case ubx
    /// Bytes arrived and none of the above matched.
    case unrecognised
    /// Nothing has arrived yet.
    case silent

    /// What to tell the user. Every case says what to do next, because
    /// "connected, no position" with no explanation is the worst outcome a
    /// scan can produce.
    var advice: String? {
        switch self {
        case .nmea: nil
        case .rtcm:
            "This link is carrying RTCM corrections, not positions. It is a correction "
                + "source rather than a rover output — check which port on the receiver "
                + "this app is connected to."
        case .ubx:
            "This receiver is streaming u-blox binary. Turn on NMEA output — GGA and GST "
                + "at 1 Hz or better — in its configuration."
        case .unrecognised:
            "Data is arriving but it is not NMEA. Check the receiver's output format and "
                + "baud rate."
        case .silent:
            "Connected, but the receiver has not sent anything yet."
        }
    }
}

/// Identifies a stream from its first bytes.
///
/// Connecting is not the same as working. A link that opens and then delivers
/// something unreadable presents to the user as "it connected and there is no
/// position", which is indistinguishable from a receiver with no sky view. This
/// tells the two apart.
enum ReceiverProbe {

    /// - Parameter data: the first bytes off the link. A few hundred is plenty;
    ///   a 1 Hz receiver sends a full sentence set every second.
    static func classify(_ data: Data) -> ReceiverStreamKind {
        guard !data.isEmpty else { return .silent }
        let bytes = [UInt8](data)

        if containsNmea(bytes) { return .nmea }
        if containsRtcm3(bytes) { return .rtcm }
        // UBX frames start with the sync pair 0xB5 0x62.
        if bytes.count >= 2 {
            for index in 0..<(bytes.count - 1) where bytes[index] == 0xB5 && bytes[index + 1] == 0x62 {
                return .ubx
            }
        }
        return .unrecognised
    }

    /// A `$` or `!` followed by five ASCII letters and a comma — the shape of
    /// every NMEA sentence header, and specific enough that arbitrary text does
    /// not match it.
    private static func containsNmea(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 7 else { return false }
        for index in 0...(bytes.count - 7) where bytes[index] == 0x24 || bytes[index] == 0x21 {
            let tag = bytes[(index + 1)...(index + 5)]
            let allLetters = tag.allSatisfy { byte in
                (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
            }
            if allLetters && bytes[index + 6] == 0x2C { return true }
        }
        return false
    }

    /// RTCM 3 frames are `0xD3`, six reserved bits that are always zero, then a
    /// ten-bit length. Checking the reserved bits as well as the preamble keeps
    /// a stray 0xD3 in arbitrary binary from being read as a correction stream.
    private static func containsRtcm3(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 3 else { return false }
        for index in 0...(bytes.count - 3)
        where bytes[index] == 0xD3 && (bytes[index + 1] & 0xFC) == 0 {
            let length = (Int(bytes[index + 1] & 0x03) << 8) | Int(bytes[index + 2])
            // A zero-length frame is legal but meaningless; requiring a real
            // payload avoids matching a run of zero bytes after a 0xD3.
            if length > 0 { return true }
        }
        return false
    }
}

// MARK: - Line assembly

/// Reassembles NMEA lines from arbitrary byte chunks.
///
/// Every air link delivers whatever fits in a packet: a BLE notification is 20
/// bytes by default, a TCP read is whatever arrived. Sentences straddle those
/// boundaries in both directions — one read can hold three sentences and half
/// of a fourth.
///
/// Bytes are held as bytes, not as a `String`, deliberately. Decoding each
/// chunk as ASCII on arrival fails whenever a receiver interleaves binary — a
/// single 0x80 byte discards a whole read, including any complete sentences in
/// it — and it cannot represent a sentence split across a decode boundary.
struct NmeaLineBuffer {

    /// A receiver in binary mode never sends a newline. Without a ceiling the
    /// buffer grows for as long as the link is up.
    var limit: Int

    private var bytes: [UInt8] = []

    init(limit: Int = 4096) {
        self.limit = limit
    }

    /// Feed a chunk in, get whole lines out.
    ///
    /// Lines are ASCII; any byte outside printable ASCII is dropped rather than
    /// substituted, so a corrupted sentence fails its checksum downstream
    /// instead of being repaired into something plausible.
    mutating func append(_ data: Data) -> [String] {
        bytes.append(contentsOf: data)

        var lines: [String] = []
        var start = bytes.startIndex
        for index in bytes.indices where bytes[index] == 0x0A {
            let raw = bytes[start..<index].filter { $0 >= 0x20 && $0 < 0x7F }
            if !raw.isEmpty, let line = String(bytes: raw, encoding: .ascii) {
                lines.append(line)
            }
            start = bytes.index(after: index)
        }
        bytes.removeSubrange(bytes.startIndex..<start)

        if bytes.count > limit { bytes.removeAll(keepingCapacity: true) }
        return lines
    }

    mutating func reset() {
        bytes.removeAll(keepingCapacity: true)
    }
}
