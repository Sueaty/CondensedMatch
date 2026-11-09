import Foundation

/// One found rally as the user reviews it: kept or not, and its edges after trimming.
public struct ReviewRally: Identifiable, Codable, Equatable, Sendable {
    /// Chronological number among found rallies, starting at 1. Added rallies get ids after every found one.
    public let id: Int
    public let detectedStart: Double
    public let detectedEnd: Double
    public let needsReview: Bool
    /// Marked by the user instead of found; shown as "Added" rather than by number.
    public let isAdded: Bool
    public var start: Double
    public var end: Double
    public var isChecked: Bool

    public init(id: Int, start: Double, end: Double, needsReview: Bool, isChecked: Bool, isAdded: Bool = false) {
        self.id = id
        detectedStart = start
        detectedEnd = end
        self.needsReview = needsReview
        self.isAdded = isAdded
        self.start = start
        self.end = end
        self.isChecked = isChecked
    }

    public var duration: Double {
        end - start
    }

    public var detectedDuration: Double {
        detectedEnd - detectedStart
    }

    public var isEdited: Bool {
        abs(start - detectedStart) > 0.000_001 || abs(end - detectedEnd) > 0.000_001
    }
}

/// The rally list shown after analysis, with its own undo history.
public struct RallyReview: Codable, Equatable, Sendable {
    /// A trimmed rally is never shorter than this.
    public static let minimumDuration = 1.0

    public let sourceDuration: Double
    public private(set) var rallies: [ReviewRally]
    private var undoStack: [[ReviewRally]] = []
    private var redoStack: [[ReviewRally]] = []

    /// Rallies get the same room and default selection as `RallySegments`.
    public init(rallies found: [RallySegments.Rally], sourceDuration: Double) {
        self.sourceDuration = sourceDuration
        let segments = RallySegments.segments(for: found, duration: sourceDuration)
        let sorted = found.sorted {
            $0.start < $1.start
        }
        rallies = zip(sorted, segments).enumerated().map { index, pair in
            ReviewRally(
                id: index + 1,
                start: pair.1.sourceStart,
                end: pair.1.sourceEnd,
                needsReview: pair.0.needsReview,
                isChecked: pair.1.inclusion == .included
            )
        }
    }

    public var toReview: [ReviewRally] {
        rallies.filter(\.needsReview)
    }

    public var confident: [ReviewRally] {
        rallies.filter {
            !$0.needsReview
        }
    }

    public var checkedCount: Int {
        rallies.filter(\.isChecked).count
    }

    /// Checked rallies as included segments; everything else is left out of the edit.
    public var segments: [PointSegment] {
        rallies
            .filter(\.isChecked)
            .map {
                PointSegment(start: $0.start, end: $0.end)
            }
    }

    public var canUndo: Bool {
        !undoStack.isEmpty
    }

    public var canRedo: Bool {
        !redoStack.isEmpty
    }

    public func rally(_ id: ReviewRally.ID) -> ReviewRally? {
        rallies.first {
            $0.id == id
        }
    }

    public mutating func setChecked(_ id: ReviewRally.ID, _ isChecked: Bool) {
        change(id) {
            $0.isChecked = isChecked
        }
    }

    /// Moves the start edge, keeping the rally inside the video and at least `minimumDuration` long.
    public mutating func moveStart(_ id: ReviewRally.ID, by delta: Double) {
        guard let rally = rally(id) else {
            return
        }
        setEdges(id, start: rally.start + delta, end: rally.end, moving: .start)
    }

    public mutating func moveEnd(_ id: ReviewRally.ID, by delta: Double) {
        guard let rally = rally(id) else {
            return
        }
        setEdges(id, start: rally.start, end: rally.end + delta, moving: .end)
    }

    public enum Edge: Sendable {
        case start
        case end
    }

    public mutating func setEdges(_ id: ReviewRally.ID, start: Double, end: Double, moving: Edge) {
        let edges = Self.clampedEdges(start: start, end: end, duration: sourceDuration, moving: moving)
        change(id) {
            $0.start = edges.start
            $0.end = edges.end
        }
    }

    public mutating func resetEdges(_ id: ReviewRally.ID) {
        change(id) {
            $0.start = $0.detectedStart
            $0.end = $0.detectedEnd
        }
    }

    /// Adds a rally the search missed, kept in the edit. Returns its id.
    @discardableResult
    public mutating func add(start: Double, end: Double) -> ReviewRally.ID {
        let edges = Self.clampedEdges(start: start, end: end, duration: sourceDuration, moving: .end)
        let id = (rallies.map(\.id).max() ?? 0) + 1
        record()
        let rally = ReviewRally(
            id: id, start: edges.start, end: edges.end, needsReview: false, isChecked: true, isAdded: true)
        let index = rallies.firstIndex {
            $0.start > rally.start
        } ?? rallies.endIndex
        rallies.insert(rally, at: index)
        return id
    }

    /// Removes a rally from the list. Undo brings it back.
    public mutating func remove(_ id: ReviewRally.ID) {
        guard rallies.contains(where: { $0.id == id }) else {
            return
        }
        record()
        rallies.removeAll {
            $0.id == id
        }
    }

    public mutating func undo() {
        guard let previous = undoStack.popLast() else {
            return
        }
        redoStack.append(rallies)
        rallies = previous
    }

    public mutating func redo() {
        guard let next = redoStack.popLast() else {
            return
        }
        undoStack.append(rallies)
        rallies = next
    }

    /// Edges as they would be after `setEdges`, for previewing a drag before it is committed.
    /// The moving edge stops `minimumDuration` before the other one; the other edge never moves.
    public static func clampedEdges(
        start: Double, end: Double, duration: Double, moving: Edge
    ) -> (start: Double, end: Double) {
        var start = max(0, start)
        var end = min(duration, end)
        switch moving {
        case .start:
            start = min(start, end - minimumDuration)
        case .end:
            end = max(end, start + minimumDuration)
        }
        return (max(0, start), min(duration, end))
    }

    private mutating func change(_ id: ReviewRally.ID, _ update: (inout ReviewRally) -> Void) {
        guard let index = rallies.firstIndex(where: { $0.id == id }) else {
            return
        }
        var rally = rallies[index]
        update(&rally)
        guard rally != rallies[index] else {
            return
        }
        record()
        rallies[index] = rally
    }

    private mutating func record() {
        undoStack.append(rallies)
        if undoStack.count > 100 {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }
}
