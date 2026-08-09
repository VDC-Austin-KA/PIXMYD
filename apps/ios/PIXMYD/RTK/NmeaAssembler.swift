import Foundation

/// NMEA 0183 parsing, mirroring `packages/geo/src/nmea.ts`.
///
/// Kept in step with the TypeScript deliberately: the same sentences are parsed
/// on device during capture and again in the studio when a log is re-imported,
/// and two implementations that disagree about a hemisphere sign would be a
/// bug nobody finds until a site is in the wrong quadrant.
///
/// The rule that matters: **a sentence that fails its checksum is dropped.**
/// Bluetooth serial links drop bytes, and a corrupted latitude that still
/// parses as a number is far worse than one that fails to parse — it is a
/// plausible wrong answer, and nothing downstream can detect it.
struct NmeaSentence {
    let talker: String
    let type: String
    let fields: [String]
    let valid: Bool
}

enum Nmea {

    static func parse(_ line: String) -> NmeaSentence? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$") || trimmed.hasPrefix("!") else { return nil }

        let star = trimmed.lastIndex(of: "*")
        let bodyEnd = star ?? trimmed.endIndex
        let body = String(trimmed[trimmed.index(after: trimmed.startIndex)..<bodyEnd])

        var valid = false
        if let star {
            let checksumStart = trimmed.index(after: star)
            let checksumText = String(trimmed[checksumStart...].prefix(2))
            if let declared = UInt8(checksumText, radix: 16) {
                var sum: UInt8 = 0
                for byte in body.utf8 { sum ^= byte }
                valid = sum == declared
            }
        }

        let fields = body.components(separatedBy: ",")
        guard let tag = fields.first else { return nil }
        // Proprietary sentences start with P and have no fixed talker split.
        let talker = tag.hasPrefix("P") ? "P" : String(tag.prefix(2))
        let type = tag.hasPrefix("P") ? String(tag.dropFirst()) : String(tag.dropFirst(2))

        return NmeaSentence(talker: talker, type: type, fields: Array(fields.dropFirst()), valid: valid)
    }

    /// NMEA packs latitude as ddmm.mmmm and longitude as dddmm.mmmm.
    static func coordinate(_ value: String, hemisphere: String) -> Double? {
        guard let decimal = Double(value), decimal.isFinite else { return nil }
        let degrees = (decimal / 100).rounded(.down)
        let minutes = decimal - degrees * 100
        let signed = degrees + minutes / 60
        return (hemisphere == "S" || hemisphere == "W") ? -signed : signed
    }

    /// hhmmss.sss UTC into seconds since midnight.
    static func utcSeconds(_ value: String) -> Double? {
        guard value.count >= 6 else { return nil }
        let chars = Array(value)
        guard let hours = Double(String(chars[0..<2])),
              let minutes = Double(String(chars[2..<4])),
              let seconds = Double(String(chars[4...]))
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}

struct GgaFix {
    var utcSeconds: Double?
    var lat: Double
    var lon: Double
    var quality: FixQuality
    var satellites: Int
    var hdop: Double
    /// GGA reports height above the geoid, not above the ellipsoid.
    var orthometricHeight: Double
    var geoidSeparation: Double
}

struct GstAccuracy {
    var utcSeconds: Double?
    var latitudeSigma: Double
    var longitudeSigma: Double
    var heightSigma: Double
    var horizontalSigma: Double { (latitudeSigma * latitudeSigma + longitudeSigma * longitudeSigma).squareRoot() }
}

/// Assembles GGA and GST into a single fix.
///
/// GGA carries position and fix type; GST carries the standard deviations. They
/// arrive as separate sentences at the same epoch, and only together do they
/// describe a position honestly. HDOP from GGA is a satellite-geometry factor,
/// not an accuracy — a receiver can report an excellent HDOP while its solution
/// is decimetres out — so a fix is never given an accuracy it did not measure.
final class NmeaAssembler {
    private var pendingGga: GgaFix?
    private var pendingGst: GstAccuracy?
    private var epochUtcSeconds: Double?
    private let pairingTolerance: Double

    /// - Parameter pairingTolerance: How far apart a GGA and GST timestamp may
    ///   be and still count as the same epoch. A 10 Hz receiver leaves 100 ms
    ///   between epochs, so a quarter second is generous without mis-pairing.
    init(pairingTolerance: Double = 0.25) {
        self.pairingTolerance = pairingTolerance
    }

    func push(_ line: String, since epoch: Date) -> GnssFix? {
        guard let sentence = Nmea.parse(line), sentence.valid else { return nil }

        switch sentence.type {
        case "GST":
            guard let gst = Self.parseGst(sentence) else { return nil }
            pendingGst = gst
            if let gga = pendingGga, sameEpoch(gga.utcSeconds, gst.utcSeconds) {
                pendingGga = nil
                return build(gga, gst)
            }
            return nil

        case "GGA":
            guard let gga = Self.parseGga(sentence) else { return nil }
            // Emit any GGA still waiting — its GST never arrived.
            let stale = pendingGga.map { build($0, nil) }
            if let gst = pendingGst, sameEpoch(gga.utcSeconds, gst.utcSeconds) {
                pendingGst = nil
                return stale ?? build(gga, gst)
            }
            pendingGga = gga
            return stale

        default:
            return nil
        }
    }

    func flush() -> GnssFix? {
        guard let gga = pendingGga else { return nil }
        pendingGga = nil
        let gst = pendingGst
        pendingGst = nil
        return build(gga, gst)
    }

    private func sameEpoch(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b else { return false }
        return abs(a - b) <= pairingTolerance
    }

    private func build(_ gga: GgaFix, _ gst: GstAccuracy?) -> GnssFix {
        if epochUtcSeconds == nil { epochUtcSeconds = gga.utcSeconds }
        let t: Double
        if let utc = gga.utcSeconds, let start = epochUtcSeconds { t = utc - start } else { t = 0 }

        return GnssFix(
            t: t,
            lat: gga.lat,
            lon: gga.lon,
            // GGA gives orthometric height; geodesy needs ellipsoidal.
            height: gga.orthometricHeight + gga.geoidSeparation,
            orthometricHeight: gga.orthometricHeight,
            geoidSeparation: gga.geoidSeparation,
            quality: gga.quality,
            satellites: gga.satellites,
            hdop: gga.hdop,
            hAccuracy: gst?.horizontalSigma,
            vAccuracy: gst?.heightSigma,
            leverArm: nil
        )
    }

    static func parseGga(_ sentence: NmeaSentence) -> GgaFix? {
        let f = sentence.fields
        guard f.count >= 14,
              let lat = Nmea.coordinate(f[1], hemisphere: f[2]),
              let lon = Nmea.coordinate(f[3], hemisphere: f[4])
        else { return nil }
        return GgaFix(
            utcSeconds: Nmea.utcSeconds(f[0]),
            lat: lat,
            lon: lon,
            quality: FixQuality(rawValue: Int(f[5]) ?? 0) ?? .invalid,
            satellites: Int(f[6]) ?? 0,
            hdop: Double(f[7]) ?? 0,
            orthometricHeight: Double(f[8]) ?? 0,
            geoidSeparation: Double(f[10]) ?? 0
        )
    }

    static func parseGst(_ sentence: NmeaSentence) -> GstAccuracy? {
        let f = sentence.fields
        guard f.count >= 8,
              let latSigma = Double(f[5]),
              let lonSigma = Double(f[6])
        else { return nil }
        return GstAccuracy(
            utcSeconds: Nmea.utcSeconds(f[0]),
            latitudeSigma: latSigma,
            longitudeSigma: lonSigma,
            heightSigma: Double(f[7]) ?? 0
        )
    }
}
