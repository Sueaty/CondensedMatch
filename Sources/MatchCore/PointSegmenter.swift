import Foundation

public struct SegmenterConfiguration: Codable, Sendable {
    public var version = "retention-heuristic-1"
    public var startThreshold = 0.38
    public var endThreshold = 0.20
    public var endHold = 2.5
    public var preRoll = 1.5
    public var postRoll = 2.5
    public var minimumActivity = 1.0
    // Keep a first-serve fault together, but do not bridge ordinary between-point setup.
    public var mergeGap = 6.0
    public var maximumDuration = 180.0
    public static let standard = SegmenterConfiguration()
}

public enum ObservationFusion {
    public static func combine(audio: [ActivitySample], visual: [ActivitySample], hasAudio: Bool)
        -> [ActivitySample]
    {
        let audioMap = Dictionary(
            audio.map {
                (Int($0.time), $0.value)
            }, uniquingKeysWith: max)
        return visual.map { sample in

            let sound = audioMap[Int(sample.time), default: 0]
            // Motion inside the selected court gates sounds from surrounding courts.
            let probability =
                hasAudio
                ? sample.value * (0.55 + 0.45 * sound)
                : sample.value * 0.9
            return ActivitySample(time: sample.time, value: min(1, max(0, probability)))
        }
    }
}

public enum PointSegmenter {
    public static func generate(
        _ samples: [ActivitySample], duration: Double, configuration c: SegmenterConfiguration = .standard
    ) -> [PointSegment] {
        guard duration.isFinite, duration > 0 else {
            return []
        }
        let sorted = samples.filter {
            $0.time.isFinite && $0.value.isFinite && $0.time >= 0 && $0.time <= duration
        }.sorted {
            $0.time < $1.time
        }
        var start: Double?
        var lastActivity = 0.0
        var values: [Double] = []
        var raw: [PointSegment] = []
        func finish() {
            guard let first = start, lastActivity - first >= c.minimumActivity else {
                start = nil
                values = []
                return
            }
            let confidence = values.reduce(0, +) / Double(max(1, values.count))
            raw.append(
                PointSegment(
                    start: max(0, first - c.preRoll), end: min(duration, lastActivity + c.postRoll),
                    confidence: confidence, inclusion: .needsReview, origin: .automatic))
            start = nil
            values = []
        }
        for sample in sorted {
            if start != nil && sample.time - lastActivity >= c.endHold {
                finish()
            }
            if start == nil && sample.value >= c.startThreshold {
                start = sample.time
            }
            if let first = start {
                if sample.value >= c.endThreshold {
                    lastActivity = sample.time
                    values.append(sample.value)
                }
                if sample.time - first >= c.maximumDuration {
                    finish()
                }
            }
        }
        finish()
        var merged: [PointSegment] = []
        for segment in raw {
            if var last = merged.last, segment.sourceStart - last.sourceEnd <= c.mergeGap,
                segment.sourceEnd - last.sourceStart <= c.maximumDuration
            {
                merged.removeLast()
                last.sourceEnd = max(last.sourceEnd, segment.sourceEnd)
                last.confidence = min(last.confidence, segment.confidence)
                merged.append(last)
            } else {
                merged.append(segment)
            }
        }
        return merged
    }
}

public enum Timeline {
    /// Included and needs-review intervals are united to avoid duplicate playback.
    public static func ranges(_ segments: [PointSegment], duration: Double) -> [PointSegment] {
        guard duration.isFinite, duration > 0 else {
            return []
        }
        let sorted = segments.filter {
            $0.inclusion.isRetained && $0.sourceStart.isFinite && $0.sourceEnd.isFinite
        }
        .map { item in

            var s = item
            s.sourceStart = max(0, s.sourceStart)
            s.sourceEnd = min(duration, s.sourceEnd)
            return s
        }.filter {
            $0.sourceEnd > $0.sourceStart
        }.sorted {
            $0.sourceStart < $1.sourceStart
        }
        var result: [PointSegment] = []
        for segment in sorted {
            if var previous = result.last, segment.sourceStart <= previous.sourceEnd {
                result.removeLast()
                previous.sourceEnd = max(previous.sourceEnd, segment.sourceEnd)
                result.append(previous)
            } else {
                result.append(segment)
            }
        }
        return result
    }
    public static func validate(start: Double, end: Double, duration: Double) throws {
        guard [start, end, duration].allSatisfy(\.isFinite), start >= 0, end > start, end <= duration else {
            throw MatchError.invalidRange
        }
    }
}
