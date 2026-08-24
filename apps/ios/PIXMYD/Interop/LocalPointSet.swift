import Foundation

// Points the phone places for itself, when nothing was imported.
//
// The rest of the interop feature assumes the workstation went first: someone
// picked marks in Navisworks, exported `points.json`, and the phone located
// those ids in the room. That is the right order when the model is ready and
// somebody is sitting at it. It is the wrong order — and until now a dead end —
// when a crew is standing in the building and the model is three time zones
// away.
//
// So this authors a point set on the phone instead. The marks are wherever the
// operator aimed and tapped, their coordinates are ARKit's, and their ids are
// plain counters. Nothing here knows where the model thinks these points are,
// because nothing here can: that is the workstation's half, and PIXMYD-Nav
// already has it. Its "Seed phone points" button reads the `points.json` that
// travels with the capture, puts these ids in its list, and the user clicks
// each one on the model. Two frames, one set of ids, and the solve happens
// there.
//
// The frame is declared, not implied. `provenance.pixmyd:frame = "capture"` is
// what tells the plugin these coordinates are the phone's own — the same flag
// its reader has always checked, on a file nothing used to write. Getting that
// wrong would let a set of AR coordinates be read as model coordinates, which
// puts a scan a building away and says nothing about it.

extension NavPointSet {
    /// The units and frame every locally authored set is in.
    ///
    /// Metres because ARKit is, and the contract fixes `targetUnits` at metres
    /// anyway. Y-up because ARKit is; the plugin turns it on the way in.
    static func local(
        setId: String = UUID().uuidString,
        name: String,
        device: String,
        createdUtc: String
    ) -> NavPointSet {
        NavPointSet(
            setId: setId,
            setName: name,
            createdUtc: createdUtc,
            provenance: NavProvenance(
                sourceDocument: device,
                sourceUnits: "Meters",
                targetUnits: "Meters",
                upAxis: "Y",
                originMode: "CaptureOrigin",
                frame: "capture",
                offsetNote: "Placed on the phone. These are the capture frame's own "
                          + "coordinates; the model's are unknown until the same ids "
                          + "are picked in Navisworks.",
                exportedUtc: createdUtc
            ),
            points: []
        )
    }

    /// The next unused `Pnnn`.
    ///
    /// Derived from the highest number already present rather than from the
    /// count, so deleting P002 out of three points does not hand the next mark
    /// an id that is already on a printed page and in someone's notes.
    var nextLocalPointId: String {
        let highest = points.reduce(0) { best, point in
            guard point.id.count > 1, point.id.hasPrefix("P"),
                  let number = Int(point.id.dropFirst()) else { return best }
            return max(best, number)
        }
        return String(format: "P%03d", highest + 1)
    }

    /// Append a mark observed at `position`, in metres in the AR world frame.
    func addingLocalPoint(at position: SIMD3<Double>, label: String = "") -> NavPointSet {
        var copy = self
        copy.points.append(
            NavPoint(
                id: nextLocalPointId,
                label: label,
                position: [position.x, position.y, position.z]
            )
        )
        return copy
    }

    /// Drop a mark by id. Returns self unchanged when there is no such id.
    func removingPoint(id: String) -> NavPointSet {
        var copy = self
        copy.points.removeAll { $0.id == id }
        return copy
    }
}
