import Foundation

public enum Timeline {
    /// Retained intervals are united to avoid duplicate playback.
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
