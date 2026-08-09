import Foundation
import simd

/// The Swift half of the capture bundle schema.
///
/// This has to stay byte-compatible with `packages/core/src/bundle.ts`, because
/// the whole point of the format is that this app writes it and the web studio
/// reads it. The field names below are the JSON keys; they are deliberately
/// terse and deliberately identical to the TypeScript.
///
/// On disk:
///
///     <project>.pixmyd/
///       manifest.json      session, rig, CRS, provenance
///       frames.jsonl       one JSON object per line, one line per frame
///       imu.jsonl          raw inertial samples
///       gnss.jsonl         GNSS/RTK fixes with reported accuracy
///       control.json       surveyed control points, if any
///       images/<id>.jpg
///       depth/<id>.bin     uint16 millimetres, row-major
///       conf/<id>.bin      uint8 ARKit confidence
///
/// JSONL rather than one array because a capture is appended to in real time
/// and can be interrupted — a truncated final line costs one frame, not the
/// session. That is not hypothetical: the app is backgrounded, the battery
/// dies, the user force-quits.
enum BundleFormat {
    static let version = 1
    static let directoryExtension = "pixmyd"
}

// MARK: - Camera models

enum CameraModel: Codable, Equatable {
    case pinhole(Pinhole)
    case fisheye(Fisheye)
    case equirect(Equirect)

    struct Pinhole: Codable, Equatable {
        var model = "pinhole"
        var width: Int
        var height: Int
        var fx: Double
        var fy: Double
        var cx: Double
        var cy: Double
        var k1: Double?
        var k2: Double?
        var k3: Double?
        var p1: Double?
        var p2: Double?
    }

    struct Fisheye: Codable, Equatable {
        var model = "fisheye"
        var width: Int
        var height: Int
        var fx: Double
        var fy: Double
        var cx: Double
        var cy: Double
        var k1: Double?
        var k2: Double?
        var k3: Double?
        var k4: Double?
    }

    struct Equirect: Codable, Equatable {
        var model = "equirect"
        var width: Int
        var height: Int
        var hfov: Double?
        var vfov: Double?
    }

    // The TypeScript side is a discriminated union on `model`, so the Swift
    // encoding has to be the bare object, not Swift's default enum wrapper.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .pinhole(let c): try container.encode(c)
        case .fisheye(let c): try container.encode(c)
        case .equirect(let c): try container.encode(c)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        struct Tag: Decodable { let model: String }
        let tag = try container.decode(Tag.self)
        switch tag.model {
        case "pinhole": self = .pinhole(try container.decode(Pinhole.self))
        case "fisheye": self = .fisheye(try container.decode(Fisheye.self))
        case "equirect": self = .equirect(try container.decode(Equirect.self))
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown camera model \"\(tag.model)\""
            )
        }
    }
}

// MARK: - Pose

/// Camera-to-world, in the computer-vision convention: +X right, +Y **down**,
/// +Z forward along the optical axis.
///
/// ARKit hands back +Y up and -Z forward. The conversion happens once, in
/// `ARFrame.pixmydPose`, so that nothing downstream — here or in the web
/// studio — has to know which convention it is looking at. Getting this wrong
/// produces a reconstruction that is upside down and mirrored, and a mirrored
/// scan still looks plausible.
struct Pose: Codable, Equatable {
    /// Camera centre in world metres.
    var t: [Double]
    /// Camera-to-world rotation, [x, y, z, w].
    var q: [Double]

    init(translation: SIMD3<Float>, rotation: simd_quatf) {
        t = [Double(translation.x), Double(translation.y), Double(translation.z)]
        q = [
            Double(rotation.imag.x), Double(rotation.imag.y),
            Double(rotation.imag.z), Double(rotation.real),
        ]
    }
}

enum PoseSource: String, Codable {
    case vio, sfm, metadata, control, none
}

// MARK: - Frames

struct DepthMapRef: Codable {
    var uri: String
    var width: Int
    var height: Int
    /// Always `uint16-mm` from this app: ARKit depth is float32 metres, but a
    /// 256x192 float map is 196 KB per frame and a 30-minute scan is thousands
    /// of frames. Millimetre integers halve it and are still finer than the
    /// sensor.
    var encoding: String
    var confidenceUri: String?
    var camera: CameraModel?
    var minRange: Double?
    var maxRange: Double?
}

struct Frame: Codable {
    var id: String
    /// Seconds since the session epoch.
    var t: Double
    var imageUri: String
    var camera: Int
    var pose: Pose?
    var poseSource: PoseSource
    var poseWeight: Double?
    var depth: DepthMapRef?
    var exposure: Double?
    var iso: Double?
    var blur: Double?
    var gnss: GnssFix?
}

// MARK: - GNSS

/// NMEA GGA quality indicator. The distinction that matters operationally is
/// 4 versus everything else: only an integer-ambiguity fix is centimetre work.
/// A float solution looks identical on screen and is decimetres out.
enum FixQuality: Int, Codable {
    case invalid = 0
    case singlePoint = 1
    case dgps = 2
    case pps = 3
    case rtkFixed = 4
    case rtkFloat = 5
    case deadReckoning = 6
    case manual = 7
    case simulation = 8

    var label: String {
        switch self {
        case .rtkFixed: "RTK fixed"
        case .rtkFloat: "RTK float"
        case .dgps: "DGPS"
        case .singlePoint: "GNSS"
        case .pps: "PPS"
        case .deadReckoning: "Dead reckoning"
        case .manual: "Manual"
        case .simulation: "Simulated"
        case .invalid: "No fix"
        }
    }

    /// Whether this fix supports centimetre-grade georeferencing. Only one
    /// value does, and the UI must not blur that line.
    var isSurveyGrade: Bool { self == .rtkFixed }
}

struct GnssFix: Codable {
    var t: Double
    var lat: Double
    var lon: Double
    /// Metres above the ellipsoid.
    var height: Double
    var orthometricHeight: Double?
    var geoidSeparation: Double?
    var quality: FixQuality
    var satellites: Int?
    var hdop: Double?
    /// 1-sigma, metres, as reported by the receiver's GST sentence.
    var hAccuracy: Double?
    var vAccuracy: Double?
    /// Antenna phase centre to camera centre, device body axes, metres.
    var leverArm: [Double]?
}

// MARK: - IMU

struct ImuSample: Codable {
    var t: Double
    var gyro: [Double]
    var accel: [Double]
}

// MARK: - Control

struct ControlPoint: Codable, Identifiable, Equatable {
    var id: String
    /// Project coordinates, in the project CRS and units.
    var project: [Double]
    /// Where it was observed in the capture's local frame, metres.
    var observed: [Double]?
    var role: Role
    var description: String?
    var sigma: Double?

    enum Role: String, Codable {
        /// Constrains the solve.
        case gcp
        /// Withheld from the solve and used to grade it.
        case checkpoint
    }
}

// MARK: - CRS

struct CrsBlock: Codable, Equatable {
    var code: String
    var name: String?
    /// Never the string "feet". The US survey foot and the international foot
    /// differ by 2 ppm, which is 27 feet at a Texas State Plane northing.
    var unit: String
    var metresPerUnit: Double
    var origin: [Double]?
    var verticalDatum: String?
    var geoidModel: String?
}

// MARK: - Manifest

struct DeviceInfo: Codable {
    var kind: String
    var model: String?
    var os: String?
    var producer: String?
    var hasMetricDepth: Bool?
    var gnssReceiver: String?
}

struct ToProject: Codable {
    var matrix: [Double]
    /// RMS residual of the solve, metres. The number the user has to see.
    var rms: Double
    var method: String
    var usedControl: [String]?
}

struct CaptureManifest: Codable {
    var formatVersion: Int
    var id: String
    var name: String
    /// ISO 8601. Every other timestamp is seconds relative to this.
    var startedAt: String
    var device: DeviceInfo
    var cameras: [CameraModel]
    var crs: CrsBlock?
    var toProject: ToProject?
    var frameCount: Int
    var bounds: Bounds?
    var notes: String?

    struct Bounds: Codable {
        var min: [Double]
        var max: [Double]
    }
}
