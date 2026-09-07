import Foundation

// Where the model goes in the room, given however many marks have been tied
// down so far.
//
// ## Why this is not the capture solver
//
// `Registration.solveRigidTransform` is Horn's absolute orientation: six
// degrees of freedom, three pairs minimum, free to tilt. That is exactly right
// for registering a scan, where the phone's frame really can be rotated any
// which way relative to the model and the answer has to be honest about it.
//
// It is the wrong instrument here, for two reasons.
//
// The first is that it cannot answer with fewer than three pairs, and this
// screen has to draw something after the first tap. Somebody standing in a
// corridor holding a phone wants to see the model appear, then correct it —
// not tap three times into a black view and hope.
//
// The second is that six degrees of freedom is more freedom than the problem
// has. ARKit's world frame is gravity-aligned, and the model was exported
// Y-up. Both are level, so the only rotation that can legitimately differ
// between them is a turn about the vertical. Solving for tilt as well does not
// find a real tilt; it finds noise in where the operator aimed, and spends it
// leaning the building over. A four-degree-of-freedom fit — heading plus
// position — is not a weaker answer than a six, it is the answer with the two
// wrong degrees removed.
//
// So: least squares over the heading, exact on the rest, defined for any
// number of anchors, and with the operator's own nudges composed on top —
// because perfect is preferred, and a model that is roughly right and visibly
// there is worth far more than one that refuses to appear.

/// One tie-down: a point in the model, and where the operator says it is.
struct ArAnchor: Equatable, Identifiable {
    /// The point's id in `points.json`, which is what the operator picked.
    var pointId: String
    /// The point's coordinates in the exported model frame, metres, Y-up.
    var model: SIMD3<Double>
    /// Where it was tapped, in the AR session's world frame, metres.
    var world: SIMD3<Double>

    var id: String { pointId }
}

/// A model-to-world placement: a heading about the vertical and a translation.
///
/// Deliberately not a matrix. Every consumer either draws it (which wants an
/// Euler angle and a position, because that is what a SceneKit node takes) or
/// nudges it (which wants to add to one number). A 4x4 would have to be
/// decomposed at both ends.
struct ArPlacement: Equatable {
    /// Rotation about +Y, radians, applied before the translation.
    var yaw: Double
    /// Metres, in the AR world frame.
    var translation: SIMD3<Double>
    /// The point a manual heading tweak turns the model about: the anchors'
    /// own centre in the room. Turning about the world origin instead would
    /// swing a building across the site for a two-degree correction, which is
    /// not what anybody means by "rotate it slightly".
    var pivot: SIMD3<Double>
    /// How far each anchor sits from where the placement puts it, metres.
    var residuals: [String: Double]

    /// Worst anchor error, metres. Zero when there is nothing to be wrong.
    var maxError: Double { residuals.values.max() ?? 0 }

    /// Root-mean-square anchor error, metres.
    var rmsError: Double {
        guard !residuals.isEmpty else { return 0 }
        let sum = residuals.values.reduce(0) { $0 + $1 * $1 }
        return (sum / Double(residuals.count)).squareRoot()
    }

    /// Apply the placement to a point in the model frame.
    func apply(_ p: SIMD3<Double>) -> SIMD3<Double> {
        ArPlacement.rotateY(p, yaw) + translation
    }

    /// Rotation about +Y by `yaw`, right-handed.
    static func rotateY(_ p: SIMD3<Double>, _ yaw: Double) -> SIMD3<Double> {
        let c = cos(yaw), s = sin(yaw)
        return SIMD3<Double>(p.x * c + p.z * s, p.y, -p.x * s + p.z * c)
    }

    /// The placement for a set of anchors.
    ///
    /// - Zero anchors: nil. There is nothing to place against and guessing a
    ///   spot in front of the camera would put a building through a wall.
    /// - One anchor: the model is pinned at that point with the heading the
    ///   caller passes. One tap cannot determine a heading, so the operator's
    ///   own is used and is the thing they then turn.
    /// - Two or more: the heading is the least-squares fit over every anchor's
    ///   horizontal offset from the centroid, and the position is whatever puts
    ///   the model's centroid on the world centroid. Height comes out of the
    ///   same average rather than from one anchor, so a mis-tapped floor does
    ///   not lift the whole model.
    ///
    /// `headingHint` is only consulted when the anchors cannot determine a
    /// heading: one anchor, or several stacked in the same vertical line.
    static func solve(anchors: [ArAnchor], headingHint: Double = 0) -> ArPlacement? {
        guard !anchors.isEmpty else { return nil }

        let n = Double(anchors.count)
        let modelCentre = anchors.reduce(SIMD3<Double>(repeating: 0)) { $0 + $1.model } / n
        let worldCentre = anchors.reduce(SIMD3<Double>(repeating: 0)) { $0 + $1.world } / n

        // Maximising the dot product of the turned model offsets with the world
        // offsets. `across` and `along` are the two sums that fall out of
        // differentiating it; atan2 of the pair is the turn.
        var along = 0.0     // cos term
        var across = 0.0    // sin term
        for anchor in anchors {
            let m = anchor.model - modelCentre
            let w = anchor.world - worldCentre
            along += w.x * m.x + w.z * m.z
            across += w.x * m.z - w.z * m.x
        }

        // Anchors all on one vertical line leave both sums at zero and the
        // heading genuinely undetermined -- which is a fact about the marks,
        // not a failure, so keep the operator's heading rather than snapping to
        // an arbitrary one.
        let determined = (along * along + across * across) > 1e-12
        let yaw = determined ? atan2(across, along) : headingHint

        let translation = worldCentre - rotateY(modelCentre, yaw)

        var residuals: [String: Double] = [:]
        for anchor in anchors {
            let placed = rotateY(anchor.model, yaw) + translation
            residuals[anchor.pointId] = length(placed - anchor.world)
        }

        return ArPlacement(
            yaw: yaw,
            translation: translation,
            pivot: worldCentre,
            residuals: residuals
        )
    }

    /// The placement with the operator's manual adjustment folded in.
    ///
    /// Kept separate from the solve rather than baked into the anchors: a nudge
    /// is a statement about the drawing, and an anchor is a statement about the
    /// building. Merging them would mean re-tapping a mark silently discarded
    /// the nudge, or worse, that the nudge quietly biased the next fit.
    /// The residuals are carried through untouched, and that is the point: they
    /// still say how far the *fit* is from the marks. A nudge that improves how
    /// the model looks does not improve the fit, and a number that moved when
    /// the user dragged the model would be measuring their opinion.
    func nudged(yaw extraYaw: Double, by offset: SIMD3<Double>) -> ArPlacement {
        // Turning about `pivot`: R(e)·(R(y)p + t - P) + P is the same as
        // R(y+e)p + [R(e)(t - P) + P], so the extra turn stays a yaw and only
        // the translation has to absorb the pivot.
        let turned = ArPlacement.rotateY(translation - pivot, extraYaw) + pivot
        return ArPlacement(
            yaw: yaw + extraYaw,
            translation: turned + offset,
            pivot: pivot,
            residuals: residuals
        )
    }

    private static func length(_ v: SIMD3<Double>) -> Double {
        (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
    }
}

// MARK: - Getting a survey point into the AR model's frame

extension NavArBundle {
    /// Where a point from a `points.json` sits in this AR model's coordinates.
    ///
    /// The two files do not share a frame, and nothing about them says so out
    /// loud. `points.json` carries model coordinates shifted by its own
    /// applied offset, in the document's own up axis. `ar-model.json` carries
    /// coordinates shifted by a different offset — the model's minimum corner
    /// — and then turned into glTF's Y-up so the phone can draw them.
    ///
    /// So the route between them goes through the one frame both agree on: the
    /// source document's own world coordinates. Undo the point set's offset,
    /// apply the AR export's, then turn. Doing the turn before the offset would
    /// look almost right and put the model a building's height out, which is
    /// the kind of wrong that gets found on site rather than on screen.
    func modelFrame(of point: NavPoint, in set: NavPointSet) -> SIMD3<Double> {
        let world = set.provenance.toSourceWorld(point.position)
        guard world.count >= 3 else { return SIMD3<Double>(repeating: 0) }

        let offset = provenance.appliedOffset.count >= 3
            ? provenance.appliedOffset
            : [0, 0, 0]
        let shifted = SIMD3<Double>(
            world[0] - offset[0],
            world[1] - offset[1],
            world[2] - offset[2]
        )
        // The same turn `GlbWriter` applies: (x, y, z) -> (x, z, -y).
        return provenance.turnedToYUp
            ? SIMD3<Double>(shifted.x, shifted.z, -shifted.y)
            : shifted
    }
}
