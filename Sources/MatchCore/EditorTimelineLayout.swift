import Foundation

public struct EditorTimelineTile: Identifiable, Equatable, Sendable {
    public let clipID: UUID
    public let clipNumber: Int
    public let tileNumber: Int
    public let isLastInClip: Bool
    public let sourceTime: Double
    public let editStart: Double
    public let duration: Double
    public let clipDuration: Double
    public let width: Double

    public var id: String { "\(clipID.uuidString)-\(tileNumber)" }
}

public enum EditorTimelineLayout {
    /// Tiling never adds a minimum-width spacer; adjacent clip boundaries share one x-coordinate.
    public static func tiles(
        for editor: EditorState,
        pointsPerSecond: Double,
        tileDuration: Double
    ) -> [EditorTimelineTile] {
        guard pointsPerSecond.isFinite, pointsPerSecond > 0,
              tileDuration.isFinite, tileDuration > 0 else { return [] }
        var tiles: [EditorTimelineTile] = []
        var editCursor = 0.0
        for (index, clip) in editor.includedClips.enumerated() {
            let count = Int(ceil(clip.duration / tileDuration))
            for tileNumber in 0..<count {
                let offset = Double(tileNumber) * tileDuration
                let duration = min(tileDuration, clip.duration - offset)
                tiles.append(EditorTimelineTile(
                    clipID: clip.id,
                    clipNumber: index + 1,
                    tileNumber: tileNumber,
                    isLastInClip: tileNumber == count - 1,
                    sourceTime: clip.sourceStart + offset,
                    editStart: editCursor + offset,
                    duration: duration,
                    clipDuration: clip.duration,
                    width: duration * pointsPerSecond
                ))
            }
            editCursor += clip.duration
        }
        return tiles
    }

    public static func editTime(forContentOffset offset: Double, pointsPerSecond: Double, duration: Double) -> Double {
        guard offset.isFinite, pointsPerSecond.isFinite, pointsPerSecond > 0,
              duration.isFinite, duration >= 0 else { return 0 }
        return min(duration, max(0, offset / pointsPerSecond))
    }
}

public struct EditorPreviewSize: Equatable, Sendable {
    public let width: Double
    public let height: Double
}

public enum EditorPreviewLayout {
    /// Fits the imported video's display dimensions within the available preview area.
    public static func size(sourceWidth: Int, sourceHeight: Int, maxWidth: Double, maxHeight: Double) -> EditorPreviewSize {
        guard maxWidth.isFinite, maxHeight.isFinite, maxWidth > 0, maxHeight > 0 else {
            return EditorPreviewSize(width: 0, height: 0)
        }
        let aspect = sourceWidth > 0 && sourceHeight > 0
            ? Double(sourceWidth) / Double(sourceHeight) : 16.0 / 9.0
        let width = min(maxWidth, maxHeight * aspect)
        return EditorPreviewSize(width: width, height: width / aspect)
    }
}
