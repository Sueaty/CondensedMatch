import XCTest
@testable import MatchCore

final class MatchCoreTests: XCTestCase {
    func source() -> SourceAssetReference {
        .init(
            filename: "source.mov", duration: 100, width: 1920, height: 1080, frameRate: 30, hasAudio: true,
            byteCount: 1000)
    }
    func testTimelineOrdersClampsAndUnionsOverlaps() {
        let result = Timeline.ranges(
            [
                .init(start: 20, end: 40), .init(start: -1, end: 25),
                .init(start: 35, end: 50, inclusion: .excluded), .init(start: 90, end: 110),
            ], duration: 100)
        XCTAssertEqual(result.map(\.sourceStart), [0, 90])
        XCTAssertEqual(result.map(\.sourceEnd), [40, 100])
    }
    func testInvalidTimesNeverEnterTimeline() {
        XCTAssertThrowsError(try Timeline.validate(start: .nan, end: 2, duration: 100))
        XCTAssertThrowsError(try Timeline.validate(start: 20, end: 10, duration: 100))
        XCTAssertTrue(Timeline.ranges([.init(start: .infinity, end: 100)], duration: 100).isEmpty)
    }
    func testUndoRestoresInclusionAndInvalidatesExport() {
        var p = MatchProject(title: "Match", source: source())
        p.segments = [.init(start: 10, end: 20)]
        let original = p.segments
        p.exportFilename = "old.mp4"
        p.edit([.init(start: 50, end: 60)])
        XCTAssertNil(p.exportFilename)
        p.undo()
        XCTAssertEqual(p.segments, original)
    }
    func testEditorSplitExcludeUndoRedoAndTimeMapping() throws {
        var editor = try EditorState(sourceDuration: 30)
        try editor.split(atEditTime: 10, minimumClipDuration: 1.0 / 30.0)
        try editor.split(atEditTime: 20, minimumClipDuration: 1.0 / 30.0)

        XCTAssertEqual(editor.includedClips.map(\.sourceStart), [0, 10, 20])
        XCTAssertEqual(editor.includedClips.map(\.sourceEnd), [10, 20, 30])
        XCTAssertEqual(editor.selectedClipID, editor.includedClips[2].id)
        XCTAssertEqual(try editor.sourceTime(atEditTime: 20), 20)

        try editor.select(editor.includedClips[1].id)
        try editor.excludeSelected()
        XCTAssertEqual(editor.totalDuration, 20)
        XCTAssertEqual(editor.playheadTime, 10)
        XCTAssertEqual(try editor.sourceTime(atEditTime: 10), 20)

        editor.undo()
        XCTAssertEqual(editor.totalDuration, 30)
        editor.undo()
        editor.undo()
        XCTAssertEqual(editor.clips.count, 1)
        XCTAssertEqual(editor.totalDuration, 30)

        editor.redo()
        editor.redo()
        editor.redo()
        XCTAssertEqual(editor.totalDuration, 20)
        XCTAssertEqual(editor.includedClips.map(\.sourceStart), [0, 20])
    }

    func testEditorExcludeAndNewEditClearRedo() throws {
        var editor = try EditorState(sourceDuration: 30)
        try editor.split(atEditTime: 10, minimumClipDuration: 1.0 / 30.0)
        let removedID = try XCTUnwrap(editor.selectedClipID)
        try editor.excludeSelected()
        XCTAssertEqual(editor.totalDuration, 10)
        XCTAssertFalse(
            editor.clips.first(where: {
                $0.id == removedID
            })?.isIncluded ?? true)

        editor.undo()
        XCTAssertTrue(editor.canRedo)
        try editor.split(atEditTime: 5, minimumClipDuration: 1.0 / 30.0)
        XCTAssertFalse(editor.canRedo)

        try editor.select(removedID)
        try editor.excludeSelected()
        XCTAssertFalse(
            editor.clips.first(where: {
                $0.id == removedID
            })?.isIncluded ?? true)
    }

    func testEditorRejectsBoundarySplitAndOnlyClipExclusion() throws {
        var editor = try EditorState(sourceDuration: 30)
        XCTAssertThrowsError(try editor.split(atEditTime: 0, minimumClipDuration: 1.0 / 30.0))
        XCTAssertThrowsError(try editor.split(atEditTime: 30, minimumClipDuration: 1.0 / 30.0))
        XCTAssertThrowsError(try editor.excludeSelected()) { error in

            XCTAssertEqual(error as? EditorCoreError, .cannotExcludeOnlyIncludedClip)
        }
    }

    func testLegacySegmentsBecomeExcludedEditorClipsWithoutChangingDuration() throws {
        let segments = [PointSegment(start: 10, end: 20), PointSegment(start: 40, end: 55)]
        let edit = try EditorState.fromSegments(segments, sourceDuration: 100)
        XCTAssertEqual(edit.totalDuration, 25)
        XCTAssertEqual(edit.clips.map(\.isIncluded), [false, true, false, true, false])
        XCTAssertEqual(try edit.sourceTime(atEditTime: 10), 40)
    }

    func testReplacingRangesIsOneUndoableChange() throws {
        var edit = try EditorState(sourceDuration: 100)
        try edit.split(atEditTime: 30, minimumClipDuration: 1.0 / 30)
        let before = edit.clips
        try edit.replace(with: [PointSegment(start: 10, end: 20)])
        XCTAssertEqual(edit.totalDuration, 10)
        edit.undo()
        XCTAssertEqual(edit.clips, before)
    }

    func testTimelineTilesRemainAdjacentAcrossSplitAndDeletion() throws {
        XCTAssertEqual(timeLabel(10 + 23.0 / 30), "00:10")
        var edit = try EditorState(sourceDuration: 12)
        try edit.split(atEditTime: 3, minimumClipDuration: 1.0 / 30)
        try edit.split(atEditTime: 7, minimumClipDuration: 1.0 / 30)
        var tiles = EditorTimelineLayout.tiles(for: edit, pointsPerSecond: 30, tileDuration: 4)
        XCTAssertEqual(
            tiles.reduce(0) {
                $0 + $1.width
            }, 360, accuracy: 0.001)
        XCTAssertEqual(
            tiles.first(where: {
                $0.clipNumber == 2
            })?.editStart, 3)
        XCTAssertEqual(
            tiles.first(where: {
                $0.clipNumber == 2
            })?.clipDuration, 4)
        XCTAssertEqual(
            tiles.first(where: {
                $0.clipNumber == 3
            })?.editStart, 7)
        XCTAssertEqual(
            tiles.filter {
                $0.tileNumber == 0
            }.count, 3)
        XCTAssertEqual(try edit.includedClip(atEditTime: 3).id, edit.includedClips[1].id)

        try edit.select(edit.includedClips[1].id)
        try edit.excludeSelected()
        tiles = EditorTimelineLayout.tiles(for: edit, pointsPerSecond: 30, tileDuration: 4)
        XCTAssertEqual(edit.totalDuration, 8)
        XCTAssertEqual(
            tiles.reduce(0) {
                $0 + $1.width
            }, 240, accuracy: 0.001)
        XCTAssertEqual(
            tiles.first(where: {
                $0.clipNumber == 2
            })?.editStart, 3)
        for (left, right) in zip(tiles, tiles.dropFirst()) {
            XCTAssertEqual(left.editStart + left.duration, right.editStart, accuracy: 0.000_001)
        }
        XCTAssertEqual(
            EditorTimelineLayout.editTime(forContentOffset: 90, pointsPerSecond: 30, duration: 8), 3)
    }

    func testPreviewFitsImportedDisplayAspectRatio() {
        let landscape = EditorPreviewLayout.size(
            sourceWidth: 1920, sourceHeight: 1080, maxWidth: 360, maxHeight: 300)
        XCTAssertEqual(landscape.width, 360, accuracy: 0.001)
        XCTAssertEqual(landscape.height, 202.5, accuracy: 0.001)

        let portrait = EditorPreviewLayout.size(
            sourceWidth: 1080, sourceHeight: 1920, maxWidth: 360, maxHeight: 300)
        XCTAssertEqual(portrait.width, 168.75, accuracy: 0.001)
        XCTAssertEqual(portrait.height, 300, accuracy: 0.001)

        let square = EditorPreviewLayout.size(
            sourceWidth: 1080, sourceHeight: 1080, maxWidth: 360, maxHeight: 300)
        XCTAssertEqual(square.width, 300, accuracy: 0.001)
        XCTAssertEqual(square.height, 300, accuracy: 0.001)
    }

    func testLegacyMetadataIsDiscardedWhileSavedEditsRemainReadable() throws {
        var project = MatchProject(title: "Legacy", source: source())
        project.segments = [.init(start: 10, end: 20)]
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        object.removeValue(forKey: "editorState")
        object.removeValue(forKey: "editorIsAuthoritative")
        object["status"] = "analyzing"
        object["courtRegion"] = ["x": -1]
        object["analysis"] = ["stage": "video"]
        object["pendingAnalysisSegments"] = [["sourceStart": -100]]
        var segments = try XCTUnwrap(object["segments"] as? [[String: Any]])
        segments[0]["confidence"] = 0.7
        segments[0]["origin"] = "automatic"
        segments[0]["inclusion"] = "needsReview"
        object["segments"] = segments

        var decoded = try JSONDecoder().decode(MatchProject.self, from: JSONSerialization.data(withJSONObject: object))
        try decoded.activateEditor()
        XCTAssertEqual(decoded.editorState?.includedClips.map(\.sourceStart), [10])
        XCTAssertEqual(decoded.editorState?.includedClips.map(\.sourceEnd), [20])
        let saved = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        for key in ["status", "courtRegion", "analysis", "pendingAnalysisSegments"] {
            XCTAssertNil(saved[key])
        }
        let savedSegments = try XCTUnwrap(saved["segments"] as? [[String: Any]])
        XCTAssertNil(savedSegments[0]["confidence"])
        XCTAssertNil(savedSegments[0]["origin"])
        XCTAssertEqual(savedSegments[0]["inclusion"] as? String, "included")
    }

    func testVisibleTimeLabelsOmitFrameNumber() {
        XCTAssertEqual(timeLabel(7 * 60 + 38 + 14.0 / 30), "07:38")
        XCTAssertEqual(timeLabel(59 * 60 + 59.9), "59:59")
        XCTAssertEqual(timeLabel(3600), "1:00:00")
        XCTAssertEqual(timeLabel(.nan), "00:00")
    }
}
