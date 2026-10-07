import Foundation

public struct BenchmarkCase: Codable, Sendable {
    public var name: String
    public var duration: Double
    public var activePoints: [AnnotatedInterval]
    public var audio: [ActivitySample]
    public var visual: [ActivitySample]
    public var hasAudio: Bool
}
public struct AnnotatedInterval: Codable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}
public struct BenchmarkResult: Codable, Sendable {
    public var name: String
    public var segmenterVersion: String
    public var pointTimeRecall: Double?
    public var deadTimeRemoval: Double?
    public var falseSegmentRate: Double?
    public var retainedSeconds: Double
    public var proposedSegments: Int
}
public enum Benchmark {
    public static func evaluate(_ fixture: BenchmarkCase) throws -> BenchmarkResult {
        guard fixture.duration.isFinite, fixture.duration > 0 else { throw MatchError.invalidRange }
        for point in fixture.activePoints { try Timeline.validate(start: point.start, end: point.end, duration: fixture.duration) }
        let fused = ObservationFusion.combine(audio: fixture.audio, visual: fixture.visual, hasAudio: fixture.hasAudio)
        let detected = PointSegmenter.generate(fused, duration: fixture.duration)
        return measure(name: fixture.name, predicted: detected, annotations: fixture.activePoints, duration: fixture.duration)
    }
    public static func measure(name: String, predicted: [PointSegment], annotations: [AnnotatedInterval], duration: Double) -> BenchmarkResult {
        let retained = Timeline.ranges(predicted, duration: duration)
        let truth = Timeline.ranges(annotations.map { PointSegment(start: $0.start, end: $0.end) }, duration: duration)
        let active = truth.reduce(0) { $0 + $1.duration }
        let kept = retained.reduce(0) { $0 + $1.duration }
        var overlap = 0.0
        var falseCount = 0
        for segment in retained {
            let intersection = truth.reduce(0.0) { total, point in
                total + max(0, min(segment.sourceEnd, point.sourceEnd) - max(segment.sourceStart, point.sourceStart))
            }
            overlap += intersection
            if intersection == 0 { falseCount += 1 }
        }
        let dead = duration - active
        return BenchmarkResult(name: name, segmenterVersion: SegmenterConfiguration.standard.version,
                               pointTimeRecall: active > 0 ? overlap / active : nil,
                               deadTimeRemoval: dead > 0 ? 1 - (kept - overlap) / dead : nil,
                               falseSegmentRate: retained.isEmpty ? nil : Double(falseCount) / Double(retained.count),
                               retainedSeconds: kept, proposedSegments: retained.count)
    }
}
