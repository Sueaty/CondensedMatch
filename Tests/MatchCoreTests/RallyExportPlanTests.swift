import XCTest
@testable import MatchCore

final class RallyExportPlanTests: XCTestCase {
    private let rallies = [
        PointSegment(start: 20, end: 24),
        PointSegment(start: 4.5, end: 12.3),
        PointSegment(start: 25, end: 30),
        PointSegment(start: 58.5, end: 60),
    ]

    private func options(_ padding: RallyExportOptions.Padding) -> RallyExportOptions {
        RallyExportOptions(padding: padding, showsRallyNumber: true, savesEachRally: true)
    }

    func testNoPaddingKeepsRalliesAsTheyAre() {
        let plan = RallyExportPlan(rallies: rallies, options: options(.none), sourceDuration: 60)
        XCTAssertEqual(plan.clips.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(plan.clips.map(\.sourceStart), [4.5, 20, 25, 58.5])
        XCTAssertEqual(plan.segments.count, 4)
        XCTAssertEqual(plan.duration, 7.8 + 4 + 5 + 1.5, accuracy: 0.000_001)
    }

    func testPaddingStaysInsideTheVideoAndMergesOverlaps() {
        let plan = RallyExportPlan(rallies: rallies, options: options(.two), sourceDuration: 60)
        XCTAssertEqual(plan.clips.map(\.sourceStart), [2.5, 18, 23, 56.5])
        XCTAssertEqual(plan.clips.map(\.sourceEnd), [14.3, 26, 32, 60])
        // Rallies 2 and 3 now overlap, so the condensed video plays that stretch once.
        XCTAssertEqual(plan.segments.map(\.sourceStart), [2.5, 18, 56.5])
        XCTAssertEqual(plan.segments.map(\.sourceEnd), [14.3, 32, 60])
        XCTAssertEqual(plan.duration, 11.8 + 14 + 3.5, accuracy: 0.000_001)
    }

    func testLabelsFollowTheCondensedTimeAndHandOverInsideMergedRallies() {
        let plan = RallyExportPlan(rallies: rallies, options: options(.two), sourceDuration: 60)
        let starts = plan.labels.map(\.start)
        let ends = plan.labels.map(\.end)
        XCTAssertEqual(starts[0], 0, accuracy: 0.000_001)
        XCTAssertEqual(ends[0], 11.8, accuracy: 0.000_001)
        XCTAssertEqual(starts[1], 11.8, accuracy: 0.000_001)
        // Rally 3's breathing room starts at 23, five seconds into the merged stretch.
        XCTAssertEqual(ends[1], 16.8, accuracy: 0.000_001)
        XCTAssertEqual(starts[2], 16.8, accuracy: 0.000_001)
        XCTAssertEqual(ends[2], 25.8, accuracy: 0.000_001)
        XCTAssertEqual(starts[3], 25.8, accuracy: 0.000_001)
        XCTAssertEqual(ends[3], plan.duration, accuracy: 0.000_001)
    }

    func testLeftOutRalliesAreSkipped() {
        var withExcluded = rallies
        withExcluded[0].inclusion = .excluded
        let plan = RallyExportPlan(rallies: withExcluded, options: .standard, sourceDuration: 60)
        XCTAssertEqual(plan.clips.count, 3)
        XCTAssertEqual(plan.clips.map(\.number), [1, 2, 3])
    }
}
