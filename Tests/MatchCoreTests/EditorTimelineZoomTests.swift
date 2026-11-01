import XCTest
@testable import MatchCore

final class EditorTimelineZoomTests: XCTestCase {
    func testZoomPreservesPlayheadAcrossScalesAndEndpoints() {
        for time in [0, 0.033_333, 17.625, 3599.99, 14_400] {
            for factor in [0.001, 0.5, 1, 2, 1000] {
                let scale = EditorTimelineZoom.scale(startingAt: 30, magnification: factor)
                let offset = EditorTimelineZoom.contentOffset(editTime: time, scale: scale, duration: 14_400)
                XCTAssertEqual(
                    EditorTimelineLayout.editTime(
                        forContentOffset: offset, pointsPerSecond: scale, duration: 14_400),
                    time, accuracy: 0.000_000_01)
                XCTAssertGreaterThanOrEqual(scale, EditorTimelineZoom.minimumScale)
                XCTAssertLessThanOrEqual(scale, EditorTimelineZoom.maximumScale)
            }
        }
    }

    func testZoomedLongVideoOnlyBuildsVisibleTilesAndPreservesExactWidths() throws {
        var editor = try EditorState(sourceDuration: 14_400)
        try editor.split(atEditTime: 7200, minimumClipDuration: 1.0 / 30)
        let tiles = EditorTimelineLayout.tiles(
            for: editor, pointsPerSecond: 480, tileDuration: 60.0 / 480,
            visibleRange: 7199...7201)
        XCTAssertLessThan(tiles.count, 20)
        XCTAssertEqual(Set(tiles.map(\.clipID)).count, 2)
        for tile in tiles {
            XCTAssertEqual(tile.width, 60, accuracy: 0.000_001)
        }
        for (left, right) in zip(tiles, tiles.dropFirst()) {
            XCTAssertEqual(left.editStart + left.duration, right.editStart, accuracy: 0.000_001)
        }
    }

    func testInvalidZoomInputsCannotProduceInvalidGeometry() {
        for invalid in [Double.nan, .infinity, -1, 0] {
            XCTAssertEqual(EditorTimelineZoom.scale(startingAt: 30, magnification: invalid), 30)
            XCTAssertEqual(EditorTimelineZoom.scale(startingAt: invalid, magnification: 2), 30)
            XCTAssertEqual(EditorTimelineZoom.contentOffset(editTime: invalid, scale: 30, duration: 60), 0)
        }
    }
}
