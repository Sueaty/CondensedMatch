import Foundation

/// The 5B choices made on the export page after finding rallies.
public struct RallyExportOptions: Codable, Equatable, Sendable {
    public enum Padding: Double, CaseIterable, Codable, Sendable {
        case none = 0
        case one = 1
        case two = 2
    }

    public var padding: Padding
    public var showsRallyNumber: Bool
    public var savesEachRally: Bool

    public static let standard = RallyExportOptions(padding: .one, showsRallyNumber: false, savesEachRally: false)

    public init(padding: Padding, showsRallyNumber: Bool, savesEachRally: Bool) {
        self.padding = padding
        self.showsRallyNumber = showsRallyNumber
        self.savesEachRally = savesEachRally
    }
}

/// What the rally export writes: one condensed video, plus a clip per rally when asked.
public struct RallyExportPlan: Equatable, Sendable {
    /// One rally with its breathing room, numbered in the order it plays.
    public struct Clip: Equatable, Sendable {
        public var number: Int
        public var sourceStart: Double
        public var sourceEnd: Double

        public var duration: Double {
            sourceEnd - sourceStart
        }
    }

    /// When a rally number shows, in the condensed video's time.
    public struct Label: Equatable, Sendable {
        public var number: Int
        public var start: Double
        public var end: Double
    }

    public let clips: [Clip]
    /// The padded rallies merged where their breathing room overlaps.
    public let segments: [PointSegment]
    public let labels: [Label]

    public var duration: Double {
        segments.reduce(0) {
            $0 + $1.duration
        }
    }

    /// - Parameter rallies: the checked rallies, as the editor plays them.
    public init(rallies: [PointSegment], options: RallyExportOptions, sourceDuration: Double) {
        let padding = options.padding.rawValue
        let sorted = rallies
            .filter {
                $0.inclusion.isRetained && $0.sourceEnd > $0.sourceStart
            }
            .sorted {
                $0.sourceStart < $1.sourceStart
            }
        let clips = sorted.enumerated().map { index, rally in
            Clip(
                number: index + 1,
                sourceStart: max(0, rally.sourceStart - padding),
                sourceEnd: min(sourceDuration, rally.sourceEnd + padding)
            )
        }
        let segments = Timeline.ranges(
            clips.map {
                PointSegment(start: $0.sourceStart, end: $0.sourceEnd)
            },
            duration: sourceDuration
        )

        // Where each merged segment begins in the condensed video.
        var offsets: [Double] = []
        var cursor = 0.0
        for segment in segments {
            offsets.append(cursor)
            cursor += segment.duration
        }
        let outputTime = { (sourceTime: Double) -> Double in
            guard let index = segments.lastIndex(where: { $0.sourceStart <= sourceTime }) else {
                return 0
            }
            let segment = segments[index]
            return offsets[index] + min(sourceTime, segment.sourceEnd) - segment.sourceStart
        }

        // A rally's number shows until the next rally begins, so merged rallies hand over cleanly.
        let labels = clips.enumerated().map { index, clip in
            var end = outputTime(clip.sourceEnd)
            if index + 1 < clips.count {
                end = min(end, outputTime(clips[index + 1].sourceStart))
            }
            return Label(number: clip.number, start: outputTime(clip.sourceStart), end: end)
        }

        self.clips = clips
        self.segments = segments
        self.labels = labels
    }
}
