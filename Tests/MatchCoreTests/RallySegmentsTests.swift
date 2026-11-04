import XCTest
@testable import MatchCore

final class RallySegmentsTests: XCTestCase {
    func testConfidentRalliesGetRoomAndReviewRalliesAreLeftOut() throws {
        let segments = RallySegments.segments(
            for: [
                .init(start: 20, end: 24, needsReview: false),
                .init(start: 5, end: 12, needsReview: false),
                .init(start: 30, end: 31.5, needsReview: true),
            ],
            duration: 60
        )
        XCTAssertEqual(segments.map(\.sourceStart), [4.5, 19.5, 29.5])
        XCTAssertEqual(segments.map(\.sourceEnd), [12.3, 24.3, 31.8])
        XCTAssertEqual(segments.map(\.inclusion), [.included, .included, .excluded])

        let editor = try EditorState.fromSegments(segments, sourceDuration: 60)
        XCTAssertEqual(editor.includedClips.count, 2)
        XCTAssertEqual(editor.totalDuration, 7.8 + 4.8, accuracy: 0.000_001)
    }

    func testRoomIsClampedToTheVideo() {
        let segments = RallySegments.segments(
            for: [
                .init(start: 0.2, end: 3, needsReview: false),
                .init(start: 55, end: 59.9, needsReview: false),
            ],
            duration: 60
        )
        XCTAssertEqual(segments.first?.sourceStart, 0)
        XCTAssertEqual(segments.last?.sourceEnd, 60)
    }

    func testOnlyReviewRalliesAreAllKept() {
        let segments = RallySegments.segments(
            for: [
                .init(start: 10, end: 11, needsReview: true),
                .init(start: 20, end: 22, needsReview: true),
            ],
            duration: 60
        )
        XCTAssertEqual(segments.map(\.inclusion), [.included, .included])
    }

    func testNoRalliesGiveNoSegments() {
        XCTAssertTrue(RallySegments.segments(for: [], duration: 60).isEmpty)
    }
}
