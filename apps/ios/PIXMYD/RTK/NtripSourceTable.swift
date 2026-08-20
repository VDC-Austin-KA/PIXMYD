import Foundation

/// One mount point, as the caster describes it in its own source table.
///
/// The mount point is the field people get wrong, and a wrong one fails in the
/// least helpful way available: the caster answers the request by sending its
/// source table instead of corrections, the app sees a successful connection,
/// and the rover never gets a fix. Reading the table and offering what is
/// actually on it removes the guess entirely.
struct NtripMountPoint: Identifiable, Equatable, Hashable, Codable {
    /// The mount point name — what goes in the request line.
    var mountPoint: String
    /// The caster's own description, usually a place name.
    var identifier: String
    /// RTCM 3.2, RTCM 3.1, CMR+ and so on.
    var format: String
    /// GPS, GLO, GAL, BDS — whichever constellations the stream carries.
    var navSystem: String
    var country: String
    var latitude: Double?
    var longitude: Double?
    /// Whether the caster requires the rover to keep sending its position.
    ///
    /// Field 12 of an STR record, and the single most useful thing in the
    /// table: a VRS mount point with this set will connect, deliver for a
    /// minute and then go quiet if the app is not reporting a GGA, which is
    /// indistinguishable from a network outage from the outside.
    var requiresPosition: Bool
    /// The stream needs a username and password.
    var requiresAuthentication: Bool

    var id: String { mountPoint }

    /// Metres from a position, or nil when the table gave no coordinates.
    ///
    /// Great-circle distance on a sphere. Correct to a few metres in a hundred
    /// kilometres, which is far beyond what picking a base station needs — the
    /// question is "which of these is nearest", not "how far exactly".
    func distance(fromLatitude lat: Double, longitude lon: Double) -> Double? {
        guard let latitude, let longitude else { return nil }
        let radius = 6_371_008.8
        let toRadians = Double.pi / 180
        let dLat = (latitude - lat) * toRadians
        let dLon = (longitude - lon) * toRadians
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat * toRadians) * cos(latitude * toRadians) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}

/// Parses an NTRIP source table.
///
/// The format is semicolon-separated records, one per line, of which `STR`
/// records describe mount points. Casters vary in how many trailing fields
/// they send and how many they leave empty, so every field beyond the mount
/// point name is treated as optional — a table that is missing a country code
/// is still a usable list of mount points, and refusing to parse it would be
/// choosing no information over partial information.
enum NtripSourceTable {

    static func parse(_ text: String) -> [NtripMountPoint] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            parseRecord(String(line))
        }
    }

    private static func parseRecord(_ line: String) -> NtripMountPoint? {
        let fields = line.components(separatedBy: ";")
        guard fields.count >= 2, fields[0] == "STR" else { return nil }
        let mountPoint = fields[1].trimmingCharacters(in: .whitespaces)
        guard !mountPoint.isEmpty else { return nil }

        func field(_ index: Int) -> String {
            index < fields.count ? fields[index].trimmingCharacters(in: .whitespaces) : ""
        }

        return NtripMountPoint(
            mountPoint: mountPoint,
            identifier: field(2),
            format: field(3),
            navSystem: field(6),
            country: field(8),
            latitude: Double(field(9)),
            longitude: Double(field(10)),
            requiresPosition: field(11) == "1",
            // Field 16 is "N" for none, "B" for basic, "D" for digest. Anything
            // that is not an explicit "none" is treated as needing credentials,
            // because being asked for a password that turns out to be unused is
            // a smaller problem than a stream that rejects the connection.
            requiresAuthentication: !field(15).isEmpty && field(15).uppercased() != "N"
        )
    }

    /// Nearest first, when the rover's position is known and the table carries
    /// coordinates. Entries with no coordinates keep their table order at the
    /// end rather than being dropped — a mount point with no location is still
    /// a mount point, and on a single-base caster it is often the only one.
    static func ordered(
        _ mountPoints: [NtripMountPoint],
        near position: (latitude: Double, longitude: Double)?
    ) -> [NtripMountPoint] {
        guard let position else { return mountPoints }
        let measured = mountPoints.enumerated().map { index, point in
            (index: index,
             point: point,
             distance: point.distance(fromLatitude: position.latitude, longitude: position.longitude))
        }
        return measured.sorted { a, b in
            switch (a.distance, b.distance) {
            case let (x?, y?): return x == y ? a.index < b.index : x < y
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return a.index < b.index
            }
        }.map(\.point)
    }
}
