import Foundation

/// What is being scanned, which decides how to capture it and how to process it.
///
/// The same phone scanning a doorknob and scanning a warehouse bay wants
/// opposite settings on nearly every axis, and the numbers are not guessable
/// from the viewfinder. A mode is a coherent set of them, chosen from a word
/// the user already knows.
///
/// It is a **preset, not a lock**. Picking a mode writes its values into the
/// individual settings, which stay editable. A mode that silently overrode the
/// sliders would make the sliders a lie, and the person who needs to override
/// one is exactly the person who knows why.
///
/// What a mode is *not* is a different capture pipeline. Apple's RoomPlan is a
/// separate session producing a parametric room shell and furniture boxes — a
/// different deliverable, not a tuning of this one — so "room" here means this
/// fusion with settings suited to a room.
enum ScanMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A single thing, walked around: a valve, a fitting, a piece of plant.
    case object
    /// An interior walked through.
    case room
    /// A large or outdoor extent, covered in a sweep.
    case area

    var id: String { rawValue }

    var label: String {
        switch self {
        case .object: "Object"
        case .room: "Room"
        case .area: "Area"
        }
    }

    var detail: String {
        switch self {
        case .object:
            "Close range, fine detail, and nothing discarded for being small. "
                + "For a single item you can walk around."
        case .room:
            "An interior at arm's length to a few metres. The default, and what "
                + "as-built documentation usually means."
        case .area:
            "A large extent covered at a walking pace. Coarser, and aggressive "
                + "about stray geometry."
        }
    }

    // MARK: - Capture

    /// Assumed distance to what is being scanned, metres. Sets the baseline
    /// gate: a frame is only kept once the camera has moved far enough to see
    /// something new, and how far that is scales with subject distance.
    var subjectDistance: Double {
        switch self {
        case .object: 0.6
        case .room: 2.0
        case .area: 5.0
        }
    }

    /// Requested overlap between consecutive frames.
    ///
    /// Higher for an object because the surface curves away fast at close
    /// range and a gap becomes a hole in something small enough to notice.
    var overlap: Double {
        switch self {
        case .object: 0.92
        case .room: 0.9
        case .area: 0.85
        }
    }

    /// Radians of rotation that force a keyframe regardless of movement.
    ///
    /// Tight for an object, because circling one is mostly rotation with very
    /// little translation — the baseline gate barely fires, and without this a
    /// full orbit produces a handful of frames.
    var rotationThreshold: Double {
        switch self {
        case .object: 0.09   // ~5 degrees
        case .room: 0.13     // ~7.5
        case .area: 0.17     // ~10
        }
    }

    // MARK: - Fusion

    /// Voxel edge in metres. Cost scales with the cube of this.
    var voxelSize: Double {
        switch self {
        case .object: 0.006
        case .room: 0.025
        case .area: 0.05
        }
    }

    /// Depth readings nearer than this are discarded.
    var minDepth: Float {
        switch self {
        case .object: 0.10
        case .room: 0.15
        case .area: 0.30
        }
    }

    /// Depth readings further than this are discarded.
    ///
    /// None of these exceed 5 m, including `area`. The LiDAR scanner on an
    /// iPhone stops returning usable range at roughly that distance, and a mode
    /// that accepted 15 m readings because the scene is large would fuse noise
    /// into the far side of every wall. Covering a bigger extent is done by
    /// walking it, not by trusting the sensor further than it sees.
    var maxDepth: Float {
        switch self {
        case .object: 1.5
        case .room: 5.0
        case .area: 5.0
        }
    }

    // MARK: - Cleanup

    /// Fraction of triangles to keep when simplifying, or nil to keep all.
    var keepFraction: Double? {
        switch self {
        case .object: 0.4
        case .room: 0.25
        case .area: 0.12
        }
    }

    /// Bounding-box diagonal below which a disconnected piece is noise.
    ///
    /// The floor matters more than the multiplier. A room scan can safely bin
    /// anything under 100 mm, because buildings do not have 4 cm features that
    /// float unattached. An object scan cannot: at 6 mm voxels the subject may
    /// *be* 40 mm across, and the same rule would delete the deliverable.
    func noiseExtent() -> Float {
        switch self {
        case .object: Float(max(voxelSize * 3, 0.008))
        case .room: Float(max(voxelSize * 3, 0.10))
        case .area: Float(max(voxelSize * 6, 0.25))
        }
    }
}
