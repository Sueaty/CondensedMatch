import XCTest
@testable import MatchCore

final class MatchCoreTests: XCTestCase {
    func source() -> SourceAssetReference { .init(filename: "source.mov", duration: 100, width: 1920, height: 1080, frameRate: 30, hasAudio: true, byteCount: 1000) }
    func testPaddingClampsAndRejectsSingleTrigger() {
        let input = [ActivitySample(time: 0, value: 0.8), .init(time: 1, value: 0.7), .init(time: 98, value: 0.8), .init(time: 99, value: 0.8)]
        let result = PointSegmenter.generate(input, duration: 100)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.sourceStart, 0)
        XCTAssertEqual(result.last?.sourceEnd, 100)
        XCTAssertTrue(PointSegmenter.generate([.init(time: 10, value: 1)], duration: 100).isEmpty)
    }
    func testFirstServeFaultGapMerges() {
        let input = [ActivitySample(time: 10, value: 0.8), .init(time: 11, value: 0.8), .init(time: 21, value: 0.8), .init(time: 22, value: 0.8)]
        let segments = PointSegmenter.generate(input, duration: 100)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].sourceStart, 8.5)
        XCTAssertEqual(segments[0].sourceEnd, 24.5)
        XCTAssertEqual(segments[0].inclusion, .needsReview)
    }
    func testLongDeadTimeRemainsExcluded() {
        let input = [ActivitySample(time: 10, value: 0.8), .init(time: 12, value: 0.8), .init(time: 70, value: 0.8), .init(time: 72, value: 0.8)]
        XCTAssertEqual(PointSegmenter.generate(input, duration: 100).count, 2)
    }
    func testTimelineOrdersClampsAndUnionsOverlaps() {
        let result = Timeline.ranges([.init(start: 20, end: 40), .init(start: -1, end: 25), .init(start: 35, end: 50, inclusion: .excluded), .init(start: 90, end: 110)], duration: 100)
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
    func testVisualGateReducesOffCourtSound() {
        let fused = ObservationFusion.combine(audio: [.init(time: 0, value: 1)], visual: [.init(time: 0, value: 0)], hasAudio: true)
        XCTAssertLessThan(fused[0].value, SegmenterConfiguration.standard.startThreshold)
        XCTAssertGreaterThan(ObservationFusion.combine(audio: [], visual: [.init(time: 0, value: 0.9)], hasAudio: false)[0].value, 0.5)
    }
    func testPersistenceRelaunchAndInterruptedRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ProjectRepository(root: root)
        var p = MatchProject(title: "Saved match", source: source())
        p.status = .analyzing
        p.analysis = AnalysisRecord()
        p.analysis?.stage = .video
        p.analysis?.visual = [.init(time: 15, value: 0.8)]
        p.edit([.init(start: 5, end: 10)])
        try await repo.save(p)
        let fresh = try ProjectRepository(root: root)
        let loaded = try await fresh.load()
        XCTAssertEqual(loaded.projects[0].status, .interrupted)
        XCTAssertEqual(loaded.projects[0].segments, p.segments)
        XCTAssertEqual(loaded.projects[0].analysis?.visual.last?.time, 15)
        XCTAssertEqual(loaded.projects[0].undoHistory.count, 1)
    }
    func testFutureSchemaRejectedAndSourceRetainedOnMetadataDelete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ProjectRepository(root: root)
        var p = MatchProject(title: "Match", source: source())
        try await repo.save(p)
        let directory = try await repo.directory(for: p.id)
        let media = directory.appendingPathComponent("source.mov")
        try Data([1, 2, 3]).write(to: media)
        p.schemaVersion = 2
        XCTAssertThrowsError(try ProjectRepository.decode(JSONEncoder().encode(p)))
        try await repo.delete(p.id, includingMedia: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))
        let loaded = try await repo.load()
        XCTAssertTrue(loaded.projects.isEmpty)
    }
    func testMaximumDurationAndEmptyInputs() {
        let samples = (0..<600).map { ActivitySample(time: Double($0), value: 0.9) }
        let segments = PointSegmenter.generate(samples, duration: 600)
        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy { $0.duration <= 185 })
        XCTAssertTrue(PointSegmenter.generate([], duration: 100).isEmpty)
    }
    func testBenchmarkUsesIntervalUnionAndReportsUndefinedDenominators() {
        let result = Benchmark.measure(name: "known", predicted: [.init(start: 5, end: 20), .init(start: 15, end: 25), .init(start: 70, end: 80)],
                                       annotations: [.init(start: 10, end: 20), .init(start: 20, end: 30)], duration: 100)
        XCTAssertEqual(result.pointTimeRecall ?? -1, 0.75, accuracy: 0.0001)
        XCTAssertEqual(result.deadTimeRemoval ?? -1, 0.8125, accuracy: 0.0001)
        XCTAssertEqual(result.falseSegmentRate, 0.5)
        let empty = Benchmark.measure(name: "empty", predicted: [], annotations: [], duration: 100)
        XCTAssertNil(empty.pointTimeRecall)
        XCTAssertNil(empty.falseSegmentRate)
        XCTAssertEqual(empty.deadTimeRemoval, 1)
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

    func testEditorRestoreAndNewEditClearRedo() throws {
        var editor = try EditorState(sourceDuration: 30)
        try editor.split(atEditTime: 10, minimumClipDuration: 1.0 / 30.0)
        let removedID = try XCTUnwrap(editor.selectedClipID)
        try editor.excludeSelected()
        XCTAssertEqual(editor.totalDuration, 10)
        XCTAssertFalse(editor.clips.first(where: { $0.id == removedID })?.isIncluded ?? true)

        editor.undo()
        XCTAssertTrue(editor.canRedo)
        try editor.split(atEditTime: 5, minimumClipDuration: 1.0 / 30.0)
        XCTAssertFalse(editor.canRedo)

        try editor.select(removedID)
        try editor.excludeSelected()
        try editor.restore(removedID)
        XCTAssertTrue(editor.clips.first(where: { $0.id == removedID })?.isIncluded ?? false)
    }

    func testEditorRejectsBoundarySplitAndOnlyClipExclusion() throws {
        var editor = try EditorState(sourceDuration: 30)
        XCTAssertThrowsError(try editor.split(atEditTime: 0, minimumClipDuration: 1.0 / 30.0))
        XCTAssertThrowsError(try editor.split(atEditTime: 30, minimumClipDuration: 1.0 / 30.0))
        XCTAssertThrowsError(try editor.excludeSelected()) { error in
            XCTAssertEqual(error as? EditorCoreError, .cannotExcludeOnlyIncludedClip)
        }
    }

    func testEditorStatePersistsWithProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ProjectRepository(root: root)
        var project = MatchProject(title: "Editable", source: source())
        try project.editorState?.split(atEditTime: 25, minimumClipDuration: 1.0 / 30.0)
        try await repository.save(project)

        let loaded = try await repository.load().projects[0]
        XCTAssertEqual(loaded.editorState, project.editorState)
        XCTAssertEqual(loaded.editorState?.clips.count, 2)
    }

    func testLegacyProjectWithoutEditorStateStillDecodes() throws {
        let project = MatchProject(title: "Legacy", source: source())
        let encoded = try JSONEncoder().encode(project)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "editorState")
        object.removeValue(forKey: "pendingAnalysisSegments")

        let decoded = try ProjectRepository.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.editorState)
        XCTAssertEqual(decoded.title, project.title)
    }

    func testAnalysisSuggestionsRequireExplicitApplicationAndUndoRestoresManualEdit() {
        var project = MatchProject(title: "Manual edit", source: source())
        project.segments = [.init(start: 0, end: 100)]
        project.edit([.init(start: 5, end: 30)])
        project.exportFilename = "manual.mp4"
        let manual = project.segments
        let undoHistory = project.undoHistory
        let suggestions = [PointSegment(start: 10, end: 20, inclusion: .needsReview, origin: .automatic)]

        project.receiveAnalysis(AnalysisRecord(), suggestions: suggestions)
        XCTAssertEqual(project.segments, manual)
        XCTAssertEqual(project.undoHistory, undoHistory)
        XCTAssertEqual(project.exportFilename, "manual.mp4")
        XCTAssertEqual(project.pendingAnalysisSegments, suggestions)

        XCTAssertTrue(project.applyAnalysisSuggestions())
        XCTAssertEqual(project.segments, suggestions)
        XCTAssertNil(project.pendingAnalysisSegments)
        XCTAssertNil(project.exportFilename)
        project.undo()
        XCTAssertEqual(project.segments, manual)
    }

    func testEmptyAnalysisSuggestionsPreserveTimeline() {
        var project = MatchProject(title: "No points", source: source())
        project.segments = [.init(start: 0, end: 100)]
        let before = project.segments
        project.receiveAnalysis(AnalysisRecord(), suggestions: [])
        XCTAssertFalse(project.applyAnalysisSuggestions())
        XCTAssertEqual(project.segments, before)
        XCTAssertTrue(project.undoHistory.isEmpty)
    }

    func testLegacySegmentsBecomeRestorableEditorClipsWithoutChangingDuration() throws {
        let segments = [PointSegment(start: 10, end: 20), PointSegment(start: 40, end: 55)]
        let edit = try EditorState.fromSegments(segments, sourceDuration: 100)
        XCTAssertEqual(edit.totalDuration, 25)
        XCTAssertEqual(edit.clips.map(\.isIncluded), [false, true, false, true, false])
        XCTAssertEqual(try edit.sourceTime(atEditTime: 10), 40)
    }

    func testAcceptedSuggestionsReplaceEditorAsOneUndoableChange() throws {
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
        XCTAssertEqual(tiles.reduce(0) { $0 + $1.width }, 360, accuracy: 0.001)
        XCTAssertEqual(tiles.first(where: { $0.clipNumber == 2 })?.editStart, 3)
        XCTAssertEqual(tiles.first(where: { $0.clipNumber == 2 })?.clipDuration, 4)
        XCTAssertEqual(tiles.first(where: { $0.clipNumber == 3 })?.editStart, 7)
        XCTAssertEqual(tiles.filter { $0.tileNumber == 0 }.count, 3)
        XCTAssertEqual(try edit.includedClip(atEditTime: 3).id, edit.includedClips[1].id)

        try edit.select(edit.includedClips[1].id)
        try edit.excludeSelected()
        tiles = EditorTimelineLayout.tiles(for: edit, pointsPerSecond: 30, tileDuration: 4)
        XCTAssertEqual(edit.totalDuration, 8)
        XCTAssertEqual(tiles.reduce(0) { $0 + $1.width }, 240, accuracy: 0.001)
        XCTAssertEqual(tiles.first(where: { $0.clipNumber == 2 })?.editStart, 3)
        for (left, right) in zip(tiles, tiles.dropFirst()) {
            XCTAssertEqual(left.editStart + left.duration, right.editStart, accuracy: 0.000_001)
        }
        XCTAssertEqual(EditorTimelineLayout.editTime(forContentOffset: 90, pointsPerSecond: 30, duration: 8), 3)
    }

    func testPreviewFitsImportedDisplayAspectRatio() {
        let landscape = EditorPreviewLayout.size(sourceWidth: 1920, sourceHeight: 1080, maxWidth: 360, maxHeight: 300)
        XCTAssertEqual(landscape.width, 360, accuracy: 0.001)
        XCTAssertEqual(landscape.height, 202.5, accuracy: 0.001)

        let portrait = EditorPreviewLayout.size(sourceWidth: 1080, sourceHeight: 1920, maxWidth: 360, maxHeight: 300)
        XCTAssertEqual(portrait.width, 168.75, accuracy: 0.001)
        XCTAssertEqual(portrait.height, 300, accuracy: 0.001)

        let square = EditorPreviewLayout.size(sourceWidth: 1080, sourceHeight: 1080, maxWidth: 360, maxHeight: 300)
        XCTAssertEqual(square.width, 300, accuracy: 0.001)
        XCTAssertEqual(square.height, 300, accuracy: 0.001)
    }

    func testVisibleTimeLabelsOmitFrameNumber() {
        XCTAssertEqual(timeLabel(7 * 60 + 38 + 14.0 / 30), "07:38")
        XCTAssertEqual(timeLabel(59 * 60 + 59.9), "59:59")
        XCTAssertEqual(timeLabel(3600), "1:00:00")
        XCTAssertEqual(timeLabel(.nan), "00:00")
    }

    func testAnalysisSuggestionsPersistSeparatelyFromEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ProjectRepository(root: root)
        var project = MatchProject(title: "Suggestions", source: source())
        project.segments = [.init(start: 0, end: 100)]
        project.receiveAnalysis(AnalysisRecord(), suggestions: [.init(start: 10, end: 20)])
        try await repo.save(project)
        let loaded = try await repo.load().projects[0]
        XCTAssertEqual(loaded.segments, project.segments)
        XCTAssertEqual(loaded.pendingAnalysisSegments, project.pendingAnalysisSegments)
        XCTAssertTrue(loaded.undoHistory.isEmpty)
    }
}
