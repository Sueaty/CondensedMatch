import Foundation

/// Turns found rallies into timeline segments.
public enum RallySegments {
    /// RallyKit's boundaries tend to start late and end early, so each rally gets a little room.
    public static let leadIn = 0.5
    public static let tail = 0.3

    public struct Rally: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var needsReview: Bool

        public init(start: Double, end: Double, needsReview: Bool) {
            self.start = start
            self.end = end
            self.needsReview = needsReview
        }
    }

    /// Confident rallies are kept and rallies to review are left out. When every rally needs review,
    /// all of them are kept so the edit is never empty. Returns an empty array when there are no rallies.
    public static func segments(for rallies: [Rally], duration: Double) -> [PointSegment] {
        let keepsReview = rallies.allSatisfy(\.needsReview)
        return rallies
            .sorted {
                $0.start < $1.start
            }
            .map { rally in
                PointSegment(
                    start: max(0, rally.start - leadIn),
                    end: min(duration, rally.end + tail),
                    inclusion: rally.needsReview && !keepsReview ? .excluded : .included
                )
            }
            .filter {
                $0.duration > 0
            }
    }
}
