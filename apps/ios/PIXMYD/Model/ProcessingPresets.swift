import Foundation

/// The two presets that decide what a processed scan costs and what it weighs.
///
/// Kept out of `ProcessingPipeline` because that is an `ObservableObject` and
/// therefore needs Combine, which does not exist off Apple platforms. These are
/// plain enums with plain arithmetic, so living here means they are compiled and
/// tested on every push rather than only when somebody builds the app.
/// `ProcessingPipeline` re-exports both under their old names.
enum ProcessingQuality: String, CaseIterable, Identifiable {
    case fast, balanced, fine
    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .fine: "Fine"
        }
    }

    /// Voxel edge in metres. This is the single knob that decides both
    /// detail and cost, and cost scales with its cube.
    var voxelSize: Double {
        switch self {
        case .fast: 0.05
        case .balanced: 0.025
        case .fine: 0.012
        }
    }

    var detail: String {
        switch self {
        case .fast:
            "50 mm voxels. Quick, and enough for volumes and context."
        case .balanced:
            "25 mm voxels. The right default for as-built documentation."
        case .fine:
            "12 mm voxels. Slow and memory-hungry; use it on a single room, "
                + "not a floorplate."
        }
    }

    /// The preset whose voxel size is closest to a mode's.
    ///
    /// Nearest rather than exact: a mode is free to ask for 6 mm, which is
    /// finer than any preset offers, and the answer there should be the
    /// finest available rather than a fallback to the middle.
    static func matching(voxelSize: Double) -> ProcessingQuality {
        allCases.min { abs($0.voxelSize - voxelSize) < abs($1.voxelSize - voxelSize) }
            ?? .balanced
    }

    /// Metres per texel to aim for when projecting the captured photographs
    /// back onto the mesh.
    ///
    /// Deliberately far finer than the voxel size, and not derived from it. The
    /// two answer different questions: the voxel decides where the surface is,
    /// the texel decides what is written on it. A 12-megapixel frame at two
    /// metres resolves about half a millimetre of wall, so asking for one is
    /// asking the camera for what it already has — and it is roughly the size
    /// at which printed plant tagging becomes readable rather than merely
    /// present. The atlas has a ceiling, so on a large model the baker coarsens
    /// this until the whole model fits rather than sharpening part of it.
    var photoTexelMetres: Float {
        switch self {
        case .fast: 0.004
        case .balanced: 0.002
        case .fine: 0.001
        }
    }

    /// Frames processed per second, measured on an A17-class device. Used
    /// only for the time estimate — a wrong estimate is better than none,
    /// but it should be roughly right.
    var framesPerSecond: Double {
        switch self {
        case .fast: 22
        case .balanced: 9
        case .fine: 2.5
        }
    }
}

/// How hard to work at making the file small.
///
/// Separate from `Quality` on purpose. Voxel size decides what the scan
/// *measured*; this decides how much of that measurement survives into the
/// file. Conflating them means someone who wants a small file has to scan
/// coarsely, throwing away accuracy they already paid for on site.
///
/// Marching tetrahedra emits triangles in proportion to surface area rather
/// than to detail, so a bare wall costs as much as pipework. That is why raw
/// exports run to hundreds of megabytes, and why decimation — not a coarser
/// scan — is the right fix.
enum ProcessingCleanup: String, CaseIterable, Identifiable {
    case none, standard, aggressive
    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .standard: "Standard"
        case .aggressive: "Small file"
        }
    }

    /// Fraction of triangles to keep.
    var keepFraction: Double? {
        switch self {
        case .none: nil
        case .standard: 0.25
        case .aggressive: 0.06
        }
    }

    /// Bounding-box diagonal below which a disconnected piece is noise,
    /// as a multiple of the voxel size.
    var noiseExtentInVoxels: Float {
        switch self {
        case .none: 0
        case .standard: 3
        case .aggressive: 6
        }
    }

    /// The preset closest to a mode's requested keep fraction.
    static func matching(keepFraction: Double?) -> ProcessingCleanup {
        guard let keepFraction else { return .none }
        return allCases
            .filter { $0.keepFraction != nil }
            .min {
                abs(($0.keepFraction ?? 1) - keepFraction)
                    < abs(($1.keepFraction ?? 1) - keepFraction)
            } ?? .standard
    }

    var detail: String {
        switch self {
        case .none:
            "Every triangle fusion produced. Largest files by far, and full "
                + "of isolated specks."
        case .standard:
            "Quarter of the triangles, and floating fragments removed. "
                + "Visually near-identical; the geometry that mattered is kept."
        case .aggressive:
            "About a sixteenth of the triangles. Flat surfaces stay flat and "
                + "corners stay sharp, but fine relief is lost."
        }
    }
}
