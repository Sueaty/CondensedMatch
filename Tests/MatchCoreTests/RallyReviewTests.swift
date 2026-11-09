import XCTest
@testable import MatchCore

final class RallyReviewTests: XCTestCase {
    private func review() -> RallyReview {
        RallyReview(
            rallies: [
                .init(start: 20, end: 24, needsReview: false),
                .init(start: 5, end: 12, needsReview: false),
                .init(start: 30, end: 31.5, needsReview: true),
                .init(start: 40, end: 50, needsReview: false),
            ],
            sourceDuration: 60
        )
    }

    func testRalliesAreNumberedInTimeOrderAndReviewOnesStartUnchecked() {
        let review = review()
        XCTAssertEqual(review.rallies.map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(review.rallies.map(\.start), [4.5, 19.5, 29.5, 39.5])
        XCTAssertEqual(review.rallies.map(\.isChecked), [true, true, false, true])
        XCTAssertEqual(review.toReview.map(\.id), [3])
        XCTAssertEqual(review.confident.map(\.id), [1, 2, 4])
        XCTAssertEqual(review.segments.count, 3)
        XCTAssertFalse(review.canUndo)
    }

    func testCheckingAndUndoRedo() {
        var review = review()
        review.setChecked(3, true)
        XCTAssertEqual(review.checkedCount, 4)
        XCTAssertTrue(review.canUndo)
        review.undo()
        XCTAssertEqual(review.checkedCount, 3)
        XCTAssertTrue(review.canRedo)
        review.redo()
        XCTAssertEqual(review.checkedCount, 4)
    }

    func testRepeatingTheSameValueDoesNotAddHistory() {
        var review = review()
        review.setChecked(1, true)
        XCTAssertFalse(review.canUndo)
    }

    func testTrimmingMarksEditedAndResetRestoresDetectedEdges() throws {
        var review = review()
        review.moveEnd(1, by: 1)
        review.moveStart(1, by: -1)
        let trimmed = try XCTUnwrap(review.rally(1))
        XCTAssertEqual(trimmed.start, 3.5, accuracy: 0.000_001)
        XCTAssertEqual(trimmed.end, 13.3, accuracy: 0.000_001)
        XCTAssertTrue(trimmed.isEdited)
        XCTAssertEqual(trimmed.detectedDuration, 7.8, accuracy: 0.000_001)

        review.resetEdges(1)
        XCTAssertFalse(try XCTUnwrap(review.rally(1)).isEdited)
    }

    func testEdgesStayInsideTheVideoAndKeepMinimumLength() throws {
        var review = review()
        review.moveStart(1, by: -10)
        XCTAssertEqual(try XCTUnwrap(review.rally(1)).start, 0)
        review.moveEnd(4, by: 20)
        XCTAssertEqual(try XCTUnwrap(review.rally(4)).end, 60)
        review.moveStart(2, by: 10)
        let squeezed = try XCTUnwrap(review.rally(2))
        XCTAssertEqual(squeezed.duration, RallyReview.minimumDuration, accuracy: 0.000_001)
        XCTAssertEqual(squeezed.end, 24.3, accuracy: 0.000_001)
    }

    func testRemovingARallyCanBeUndone() {
        var review = review()
        review.remove(2)
        XCTAssertEqual(review.rallies.map(\.id), [1, 3, 4])
        review.undo()
        XCTAssertEqual(review.rallies.map(\.id), [1, 2, 3, 4])
    }

    func testAddedRallyIsCheckedPlacedInTimeOrderAndUndoable() throws {
        var review = review()
        let id = review.add(start: 14, end: 17)
        XCTAssertEqual(id, 5)
        XCTAssertEqual(review.rallies.map(\.id), [1, 5, 2, 3, 4])
        let added = try XCTUnwrap(review.rally(id))
        XCTAssertTrue(added.isAdded)
        XCTAssertTrue(added.isChecked)
        XCTAssertFalse(added.isEdited)
        XCTAssertEqual(review.confident.map(\.id), [1, 5, 2, 4])
        XCTAssertEqual(review.segments.count, 4)

        review.undo()
        XCTAssertNil(review.rally(id))
        review.redo()
        XCTAssertNotNil(review.rally(id))
    }

    func testAddedRallyKeepsMinimumLength() throws {
        var review = review()
        let id = review.add(start: 14, end: 14.2)
        XCTAssertEqual(try XCTUnwrap(review.rally(id)).duration, RallyReview.minimumDuration, accuracy: 0.000_001)
    }

    func testSegmentsBuildTheEdit() throws {
        var review = review()
        review.setChecked(2, false)
        let editor = try EditorState.fromSegments(review.segments, sourceDuration: 60)
        XCTAssertEqual(editor.totalDuration, 7.8 + 10.8, accuracy: 0.000_001)
    }
}
