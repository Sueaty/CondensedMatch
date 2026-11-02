import XCTest
@testable import MatchCore

final class EditorEditingRegressionTests: XCTestCase {
    func testSplitLimitAndMinimumFramePolicyRejectWithoutChangingHistory() throws {
        var editor = try EditorState(sourceDuration: 600)
        for cut in 1..<EditorState.maximumIncludedClipCount {
            try editor.split(atEditTime: Double(cut), minimumClipDuration: 1.0 / 30)
        }
        XCTAssertEqual(editor.includedClips.count, 150)
        let before = editor
        XCTAssertEqual(editor.splitRestriction(atEditTime: 550), .tooManyClips)
        XCTAssertFalse(editor.canSplit(atEditTime: 550, minimumClipDuration: 1.0 / 30))
        XCTAssertThrowsError(try editor.split(atEditTime: 550, minimumClipDuration: 1.0 / 30)) {
            XCTAssertEqual($0 as? EditorCoreError, .tooManyClips)
        }
        XCTAssertEqual(editor, before)
        try editor.excludeSelected()
        XCTAssertNil(editor.splitRestriction(atEditTime: 100.5, minimumClipDuration: 1.0 / 30))
        try editor.split(atEditTime: 100.5, minimumClipDuration: 1.0 / 30)
        XCTAssertEqual(editor.includedClips.count, 150)
        let atLimit = editor
        let tooManyRanges = (0..<151).map {
            PointSegment(start: Double($0), end: Double($0) + 0.5)
        }
        XCTAssertThrowsError(try editor.replace(with: tooManyRanges)) {
            XCTAssertEqual($0 as? EditorCoreError, .tooManyClips)
        }
        XCTAssertEqual(editor, atLimit)

        var short = try EditorState(sourceDuration: 1.0 / 30)
        let shortBefore = short
        XCTAssertEqual(
            short.splitRestriction(atEditTime: 1.0 / 60, minimumClipDuration: 1.0 / 30), .clipTooShort)
        XCTAssertThrowsError(try short.split(atEditTime: 1.0 / 60, minimumClipDuration: 1.0 / 30))
        XCTAssertEqual(short, shortBefore)
    }

    func testReplacementRangesCannotCreateClipsBelowMinimumDuration() throws {
        var editor = try EditorState(sourceDuration: 10)
        let before = editor
        XCTAssertThrowsError(try editor.replace(with: [PointSegment(start: 1, end: 1.149)])) {
            XCTAssertEqual($0 as? EditorCoreError, .clipTooShort)
        }
        XCTAssertEqual(editor, before)
        try editor.replace(with: [PointSegment(start: 1, end: 1.15)])
        XCTAssertEqual(editor.totalDuration, 0.15, accuracy: 0.000_001)
        editor.undo()
        XCTAssertEqual(editor.clips, before.clips)
    }

    func testTrimRipplesAndRestoresBothEdgesAsSingleHistoryEntries() throws {
        var editor = try EditorState(sourceDuration: 30)
        try editor.split(atEditTime: 10, minimumClipDuration: 1.0 / 30)
        let right = editor.includedClips[1].id
        let original = editor.clips
        let history = editor.undoStack.count
        try editor.trim(right, edge: .start, toSourceTime: 12, minimumClipDuration: 1.0 / 30)
        XCTAssertEqual(editor.totalDuration, 28)
        XCTAssertEqual(editor.playheadTime, 10)
        XCTAssertEqual(try editor.sourceTime(atEditTime: 10), 12)
        XCTAssertEqual(editor.undoStack.count, history + 1)
        editor.undo()
        XCTAssertEqual(editor.clips, original)
        editor.redo()
        try editor.trim(right, edge: .end, toSourceTime: 25, minimumClipDuration: 1.0 / 30)
        XCTAssertEqual(editor.totalDuration, 23)
        XCTAssertEqual(editor.playheadTime, 23)
        try editor.trim(right, edge: .start, toSourceTime: 10, minimumClipDuration: 1.0 / 30)
        try editor.trim(right, edge: .end, toSourceTime: 30, minimumClipDuration: 1.0 / 30)
        XCTAssertEqual(editor.totalDuration, 30)
        try editor.validate()
    }

    func testSplitAfterTrimKeepsOuterMaterialRestorableWithoutCrossingTheCut() throws {
        var editor = try EditorState(sourceDuration: 30)
        let originalID = editor.clips[0].id
        try editor.trim(originalID, edge: .start, toSourceTime: 5, minimumClipDuration: 0.1)
        try editor.trim(originalID, edge: .end, toSourceTime: 25, minimumClipDuration: 0.1)
        try editor.split(atEditTime: 10, minimumClipDuration: 0.1)
        let left = editor.includedClips[0]
        let right = editor.includedClips[1]
        XCTAssertEqual(left.availableSourceStart, 0)
        XCTAssertEqual(left.availableSourceEnd, 15)
        XCTAssertEqual(right.availableSourceStart, 15)
        XCTAssertEqual(right.availableSourceEnd, 30)
        let before = editor
        XCTAssertThrowsError(try editor.trim(left.id, edge: .end, toSourceTime: 16, minimumClipDuration: 0.1))
        XCTAssertEqual(editor, before)
        try editor.trim(left.id, edge: .start, toSourceTime: 0, minimumClipDuration: 0.1)
        try editor.trim(right.id, edge: .end, toSourceTime: 30, minimumClipDuration: 0.1)
        XCTAssertEqual(editor.totalDuration, 30)
        try editor.validate()
    }

    func testInvalidAndUnchangedTrimsDoNotChangeHistoryOrSelection() throws {
        var editor = try EditorState(sourceDuration: 10)
        let id = editor.clips[0].id
        let before = editor
        for candidate in [Double.nan, .infinity, -1, 10, 11] {
            XCTAssertThrowsError(
                try editor.trim(id, edge: .start, toSourceTime: candidate, minimumClipDuration: 0.1))
            XCTAssertEqual(editor, before)
        }
        try editor.trim(id, edge: .start, toSourceTime: 0, minimumClipDuration: 0.1)
        XCTAssertEqual(editor, before)
        try editor.trim(id, edge: .end, toSourceTime: 0.15, minimumClipDuration: 0.1)
        XCTAssertEqual(editor.totalDuration, 0.15, accuracy: 0.000_001)
        try editor.validate()
    }

    func testMinimumClipDurationAndRepeatedSplitHaveConsistentAvailability() throws {
        var editor = try EditorState(sourceDuration: 1)
        let frame = 1.0 / 30
        XCTAssertFalse(editor.canSplit(atEditTime: 1 - frame, minimumClipDuration: frame))
        XCTAssertFalse(editor.canSplit(atEditTime: 0.149, minimumClipDuration: frame))
        XCTAssertTrue(editor.canSplit(atEditTime: 0.15, minimumClipDuration: frame))
        try editor.split(atEditTime: 0.15, minimumClipDuration: frame)
        XCTAssertEqual(editor.includedClips[0].duration, 0.15, accuracy: 0.000_001)
        let before = editor
        XCTAssertFalse(editor.canSplit(atEditTime: editor.playheadTime, minimumClipDuration: frame))
        XCTAssertThrowsError(try editor.split(atEditTime: editor.playheadTime, minimumClipDuration: frame))
        XCTAssertEqual(editor, before)
    }

    func testOldClipJSONDecodesAndTrimBoundsSurviveRelaunch() throws {
        let id = UUID()
        let json = "{\"id\":\"\(id)\",\"sourceStart\":0,\"sourceEnd\":10,\"isIncluded\":true}"
        let clip = try JSONDecoder().decode(EditorClip.self, from: Data(json.utf8))
        XCTAssertEqual(clip.availableSourceStart, 0)
        XCTAssertEqual(clip.availableSourceEnd, 10)
        var editor = try EditorState(sourceDuration: 10, clips: [clip], selectedClipID: id)
        try editor.trim(id, edge: .start, toSourceTime: 3, minimumClipDuration: 0.1)
        let restored = try JSONDecoder().decode(EditorState.self, from: JSONEncoder().encode(editor))
        XCTAssertEqual(restored, editor)
        XCTAssertEqual(restored.clips[0].availableSourceStart, 0)
    }

    func testHundredsOfMixedEditsMaintainMappingCoverageAndUndoRedo() throws {
        var editor = try EditorState(sourceDuration: 600)
        for step in 0..<350 {
            let retained = editor.includedClips
            let clip = retained[(step * 17) % retained.count]
            try editor.select(clip.id)
            switch step % 7 {
            case 0, 1:
                if clip.duration >= 0.3 && retained.count < EditorState.maximumIncludedClipCount {
                    let source = clip.sourceStart + clip.duration / 2
                    try editor.split(
                        atEditTime: editor.editTime(atSourceTime: source, in: clip.id),
                        minimumClipDuration: 0.01)
                }
            case 2:
                if clip.duration >= 0.3 {
                    try editor.trim(
                        clip.id, edge: .start, toSourceTime: clip.sourceStart + clip.duration / 4,
                        minimumClipDuration: 0.01)
                }
            case 3:
                if retained.count > 1 {
                    try editor.excludeSelected()
                }
            case 4:
                editor.undo()
                editor.redo()
            case 5:
                editor.undo()
            default:
                try editor.trim(
                    clip.id, edge: .start, toSourceTime: clip.availableSourceStart, minimumClipDuration: 0.01)
            }
            try editor.validate()
            var cursor = 0.0
            for included in editor.includedClips {
                let midpoint = cursor + included.duration / 2
                let source = try editor.sourceTime(atEditTime: midpoint)
                XCTAssertEqual(source, included.sourceStart + included.duration / 2, accuracy: 0.000_001)
                XCTAssertEqual(
                    try editor.editTime(atSourceTime: source, in: included.id), midpoint, accuracy: 0.000_001)
                cursor += included.duration
            }
            XCTAssertEqual(cursor, editor.totalDuration, accuracy: 0.000_001)
        }
        let final = editor.clips
        let historyCount = editor.undoStack.count
        for _ in 0..<historyCount {
            editor.undo()
            try editor.validate()
        }
        for _ in 0..<historyCount {
            editor.redo()
            try editor.validate()
        }
        XCTAssertEqual(editor.clips, final)
    }
}
