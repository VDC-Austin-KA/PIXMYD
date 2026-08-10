import Foundation
import XCTest
@testable import PIXMYD

/// Scan modes are a set of numbers, and the risk with a set of numbers is that
/// one of them stops making sense relative to the others without anything
/// visibly breaking. These pin the relationships rather than the values.
final class ScanModeTests: XCTestCase {

    func testDetailGetsFinerAsTheSubjectGetsSmaller() {
        XCTAssertLessThan(ScanMode.object.voxelSize, ScanMode.room.voxelSize)
        XCTAssertLessThan(ScanMode.room.voxelSize, ScanMode.area.voxelSize)
    }

    func testTheCameraIsExpectedToBeCloserForSmallerSubjects() {
        XCTAssertLessThan(ScanMode.object.subjectDistance, ScanMode.room.subjectDistance)
        XCTAssertLessThan(ScanMode.room.subjectDistance, ScanMode.area.subjectDistance)
    }

    func testCirclingAnObjectTriggersOnRotationSooner() {
        // Orbiting a small object is mostly rotation with almost no
        // translation, so the baseline gate barely fires. Without a tighter
        // rotation threshold a full orbit yields a handful of frames.
        XCTAssertLessThan(ScanMode.object.rotationThreshold, ScanMode.room.rotationThreshold)
        XCTAssertLessThan(ScanMode.room.rotationThreshold, ScanMode.area.rotationThreshold)
    }

    func testNoModeTrustsTheSensorPastItsRange() {
        // iPhone LiDAR stops returning usable range at roughly 5 m. A mode that
        // accepted 15 m readings because the scene is large would fuse noise
        // into the far side of every wall — covering more ground is done by
        // walking, not by widening the window.
        for mode in ScanMode.allCases {
            XCTAssertLessThanOrEqual(mode.maxDepth, 5.0, "\(mode.label) accepts depth past the sensor")
            XCTAssertGreaterThan(mode.maxDepth, mode.minDepth)
            XCTAssertGreaterThan(mode.minDepth, 0)
        }
    }

    func testObjectModeWillNotDeleteASmallSubjectAsNoise() {
        // The bug this guards: a room's 100 mm noise floor applied to an object
        // scan deletes the deliverable. A 40 mm fitting is a legitimate subject.
        XCTAssertLessThan(ScanMode.object.noiseExtent(), 0.04)
        // And a room still discards specks, which is the point of having one.
        XCTAssertGreaterThanOrEqual(ScanMode.room.noiseExtent(), 0.10)
        XCTAssertGreaterThan(ScanMode.area.noiseExtent(), ScanMode.room.noiseExtent())
    }

    func testEveryModeKeepsSomeTrianglesAndTheBigOnesKeepFewer() {
        for mode in ScanMode.allCases {
            let keep = try? XCTUnwrap(mode.keepFraction)
            XCTAssertNotNil(keep)
            XCTAssertGreaterThan(keep ?? 0, 0)
            XCTAssertLessThanOrEqual(keep ?? 1, 1)
        }
        XCTAssertGreaterThan(
            ScanMode.object.keepFraction ?? 0, ScanMode.area.keepFraction ?? 1,
            "an object should survive decimation better than an area"
        )
    }

    func testModesAreCodableSoOldProjectsStillLoad() throws {
        for mode in ScanMode.allCases {
            let data = try JSONEncoder().encode(mode)
            XCTAssertEqual(try JSONDecoder().decode(ScanMode.self, from: data), mode)
        }
        // Raw values are what land in a project file; renaming one silently
        // reclassifies every capture already on disk.
        XCTAssertEqual(ScanMode.object.rawValue, "object")
        XCTAssertEqual(ScanMode.room.rawValue, "room")
        XCTAssertEqual(ScanMode.area.rawValue, "area")
    }

    // MARK: - Preset matching

    func testQualityMatchingPicksTheNearestPreset() {
        // Object asks for 6 mm, which is finer than any preset offers. The
        // answer must be the finest available, not a fallback to the middle.
        XCTAssertEqual(ProcessingQuality.matching(voxelSize: ScanMode.object.voxelSize), .fine)
        XCTAssertEqual(ProcessingQuality.matching(voxelSize: ScanMode.room.voxelSize), .balanced)
        XCTAssertEqual(ProcessingQuality.matching(voxelSize: ScanMode.area.voxelSize), .fast)
    }

    func testCleanupMatchingPicksTheNearestPreset() {
        XCTAssertEqual(
            ProcessingCleanup.matching(keepFraction: ScanMode.room.keepFraction),
            .standard
        )
        XCTAssertEqual(
            ProcessingCleanup.matching(keepFraction: ScanMode.area.keepFraction),
            .aggressive
        )
        // Nil means "keep everything", which is a real choice and must not be
        // rounded to the nearest reducing preset.
        XCTAssertEqual(ProcessingCleanup.matching(keepFraction: nil), .none)
    }

    // MARK: - Presets applied to settings

    func testApplyingAModeWritesItsValuesIntoTheSettings() {
        var settings = CaptureSettings.default
        settings.apply(.object)

        XCTAssertEqual(settings.mode, .object)
        XCTAssertEqual(settings.subjectDistance, ScanMode.object.subjectDistance)
        XCTAssertEqual(settings.overlap, ScanMode.object.overlap)
        XCTAssertEqual(settings.rotationThreshold, ScanMode.object.rotationThreshold)
        XCTAssertTrue(settings.matchesMode)
    }

    func testEditingASettingIsReportedRatherThanSilentlyKept() {
        // A mode is a preset, not a lock. The one case that must not happen is
        // the UI showing a mode that no longer describes what will happen.
        var settings = CaptureSettings.default
        settings.apply(.room)
        XCTAssertTrue(settings.matchesMode)

        settings.subjectDistance = 7.5
        XCTAssertFalse(settings.matchesMode)
        XCTAssertEqual(settings.mode, .room, "the mode should be remembered, not cleared")
    }

    func testTheBaselineGateFollowsTheModesSubjectDistance() {
        // The gate is derived from subject distance, so a mode change has to
        // actually move it — a preset that changed a label and nothing else
        // would be worse than no preset.
        var object = CaptureSettings.default
        object.apply(.object)
        var area = CaptureSettings.default
        area.apply(.area)

        XCTAssertLessThan(object.baseline, area.baseline)
        XCTAssertGreaterThan(object.baseline, 0)
    }
}
