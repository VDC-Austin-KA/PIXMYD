import Foundation

/// How a capture is gated, and what is being scanned.
///
/// Lives here rather than beside `CaptureWriter` because that file imports
/// ARKit and CoreImage, which do not exist off Apple platforms. The gate is
/// pure arithmetic and decides how much of a site ends up measured, so it is
/// worth having under test rather than only exercised by walking a building.

struct CaptureSettings: Equatable, Codable {
    /// What is being scanned. A preset for the three settings below, and
    /// carried into the capture so processing can default to match.
    var mode: ScanMode = .room
    /// Requested image overlap, 0-1. Drives the baseline gate.
    var overlap: Double = 0.9
    /// Assumed distance to the subject, metres. With overlap this determines
    /// how far the camera must move before a frame carries new information.
    var subjectDistance: Double = 2.0
    /// Radians of rotation that force a keyframe regardless of baseline.
    var rotationThreshold: Double = 0.13 // ~7.5 degrees
    var trigger: Trigger = .automatic
    var saveVideo = false

    /// Adopt a mode's values, leaving everything else alone.
    ///
    /// Applied when the mode is picked rather than consulted on every read, so
    /// the individual settings remain the truth and remain editable. A mode
    /// that overrode them on read would make the sliders display one number and
    /// the capture use another.
    mutating func apply(_ mode: ScanMode) {
        self.mode = mode
        overlap = mode.overlap
        subjectDistance = mode.subjectDistance
        rotationThreshold = mode.rotationThreshold
    }

    /// Whether the settings still match the mode they came from. The UI says so
    /// rather than showing a mode that no longer describes what will happen.
    var matchesMode: Bool {
        overlap == mode.overlap
            && subjectDistance == mode.subjectDistance
            && rotationThreshold == mode.rotationThreshold
    }

    enum Trigger: String, Codable, CaseIterable, Identifiable {
        case automatic, manual, timed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: "Automatic"
            case .manual: "Manual"
            case .timed: "Timed"
            }
        }
        var detail: String {
            switch self {
            case .automatic: "Captures when you have moved far enough to add detail."
            case .manual: "Captures only when you tap. For deliberate, sparse coverage."
            case .timed: "Captures at a fixed interval regardless of movement."
            }
        }
    }

    /// Metres the camera must travel before the next frame is kept.
    ///
    /// A camera at distance `d` with horizontal field of view `f` sees a strip
    /// roughly `2 d tan(f/2)` wide. Requiring `overlap` between consecutive
    /// frames means moving at most `(1 - overlap)` of that width. The 60-degree
    /// figure is a reasonable stand-in for a phone's main camera; the exact
    /// value matters less than the fact that the threshold scales with distance
    /// rather than being a constant that is wrong at both ends.
    var baseline: Float {
        let halfFov = 30.0 * .pi / 180.0
        let footprint = 2 * subjectDistance * tan(halfFov)
        return Float(max(0.02, footprint * (1 - overlap)))
    }

    static let `default` = CaptureSettings()
}
