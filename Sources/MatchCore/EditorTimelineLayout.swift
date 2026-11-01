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

    public var id: String {
        "\(clipID.uuidString)-\(tileNumber)"
    }
}

public enum EditorTimelineLayout {
    /// Tiling never adds a minimum-width spacer; adjacent clip boundaries share one x-coordinate.
    public static func tiles(
        for editor: EditorState,
        pointsPerSecond: Double,
        tileDuration: Double,
        visibleRange: ClosedRange<Double>? = nil
    ) -> [EditorTimelineTile] {
        guard pointsPerSecond.isFinite, pointsPerSecond > 0,
            tileDuration.isFinite, tileDuration > 0
        else {
            return []
        }
        var tiles: [EditorTimelineTile] = []
        var editCursor = 0.0
        for (index, clip) in editor.includedClips.enumerated() {
            let count = Int(ceil(clip.duration / tileDuration))
            let first =
                visibleRange.map {
                    max(0, Int(floor(($0.lowerBound - editCursor) / tileDuration)))
                } ?? 0
            let last =
                visibleRange.map {
                    min(count - 1, Int(floor(($0.upperBound - editCursor) / tileDuration)))
                } ?? (count - 1)
            guard first <= last else {
                editCursor += clip.duration
                continue
            }
            for tileNumber in first...last {
                let offset = Double(tileNumber) * tileDuration
                let duration = min(tileDuration, clip.duration - offset)
                tiles.append(
                    EditorTimelineTile(
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

    public static func editTime(forContentOffset offset: Double, pointsPerSecond: Double, duration: Double)
        -> Double
    {
        guard offset.isFinite, pointsPerSecond.isFinite, pointsPerSecond > 0,
            duration.isFinite, duration >= 0
        else {
            return 0
        }
        return min(duration, max(0, offset / pointsPerSecond))
    }
}

public enum EditorTimelineZoom {
    public static let initialScale = 30.0
    public static let minimumScale = 3.0
    public static let maximumScale = 480.0

    /// Stable source samples within each zoom level; widths stretch continuously between levels.
    public static func thumbnailDuration(scale: Double) -> Double {
        let bounded = scale.isFinite ? min(maximumScale, max(minimumScale, scale)) : initialScale
        return pow(2, ceil(log2(60 / bounded)))
    }

    public static func scale(startingAt scale: Double, magnification: Double) -> Double {
        guard scale.isFinite, scale > 0, magnification.isFinite, magnification > 0 else {
            return initialScale
        }
        return min(maximumScale, max(minimumScale, scale * magnification))
    }

    /// Keeps the same edit time beneath the fixed playhead while the scale changes.
    public static func contentOffset(editTime: Double, scale: Double, duration: Double) -> Double {
        guard editTime.isFinite, scale.isFinite, scale > 0, duration.isFinite, duration >= 0 else {
            return 0
        }
        return min(duration, max(0, editTime)) * scale
    }

    public static func rulerInterval(scale: Double) -> Double {
        let desired = 70 / max(minimumScale, scale)
        let power = pow(10, floor(log10(desired)))
        let step = desired / power
        return (step <= 1 ? 1 : step <= 2 ? 2 : step <= 5 ? 5 : 10) * power
    }
}

public struct EditorPreviewSize: Equatable, Sendable {
    public let width: Double
    public let height: Double
}

public enum EditorPreviewLayout {
    /// Fits the imported video's display dimensions within the available preview area.
    public static func size(sourceWidth: Int, sourceHeight: Int, maxWidth: Double, maxHeight: Double)
        -> EditorPreviewSize
    {
        guard maxWidth.isFinite, maxHeight.isFinite, maxWidth > 0, maxHeight > 0 else {
            return EditorPreviewSize(width: 0, height: 0)
        }
        let aspect =
            sourceWidth > 0 && sourceHeight > 0
            ? Double(sourceWidth) / Double(sourceHeight) : 16.0 / 9.0
        let width = min(maxWidth, maxHeight * aspect)
        return EditorPreviewSize(width: width, height: width / aspect)
    }
}
