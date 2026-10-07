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
}
