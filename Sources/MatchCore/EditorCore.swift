import Foundation

public struct EditorClip: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var sourceStart: Double
    public var sourceEnd: Double
    public var isIncluded: Bool
    /// Original bounds remain available for extending a trimmed clip. Optional for older projects.
    public var untrimmedSourceStart: Double?
    public var untrimmedSourceEnd: Double?

    public init(
        id: UUID = UUID(),
        sourceStart: Double,
        sourceEnd: Double,
        isIncluded: Bool = true,
        untrimmedSourceStart: Double? = nil,
        untrimmedSourceEnd: Double? = nil
    ) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.isIncluded = isIncluded
        self.untrimmedSourceStart = untrimmedSourceStart
        self.untrimmedSourceEnd = untrimmedSourceEnd
    }

    public var duration: Double {
        max(0, sourceEnd - sourceStart)
    }

    public var availableSourceStart: Double {
        untrimmedSourceStart ?? sourceStart
    }

    public var availableSourceEnd: Double {
        untrimmedSourceEnd ?? sourceEnd
    }
}

public enum EditorTrimEdge: String, Sendable {
    case start
    case end
}

public struct EditorSnapshot: Codable, Equatable, Sendable {
    public var clips: [EditorClip]
    public var selectedClipID: EditorClip.ID?
    public var playheadTime: Double

    public init(clips: [EditorClip], selectedClipID: EditorClip.ID?, playheadTime: Double) {
        self.clips = clips
        self.selectedClipID = selectedClipID
        self.playheadTime = playheadTime
    }
}

public enum EditorCoreError: LocalizedError, Equatable, Sendable {
    case invalidTimeline
    case invalidPlayhead
    case splitAtBoundary
    case clipTooShort
    case tooManyClips
    case noSelectedClip
    case cannotExcludeOnlyIncludedClip
    case clipNotFound
    case invalidTrim

    public var errorDescription: String? {
        switch self {
        case .invalidTimeline: "The edit timeline contains an invalid or overlapping source range."
        case .invalidPlayhead: "Move the playhead inside a retained clip before splitting."
        case .splitAtBoundary:
            "Move the playhead farther inside the clip. Leave at least 0.15s and one video frame on each side."
        case .clipTooShort: "Each clip needs at least 0.15s of video and one complete frame."
        case .tooManyClips:
            "You've reached the limit of \(EditorState.maximumIncludedClipCount) clips. Remove a clip before adding another."
        case .noSelectedClip: "Select a clip before removing it."
        case .cannotExcludeOnlyIncludedClip: "At least one clip must remain in the edit."
        case .clipNotFound: "This clip is no longer part of the edit."
        case .invalidTrim: "Keep at least 0.15s and one frame within the clip's original boundaries."
        }
    }
}

public struct EditorState: Codable, Equatable, Sendable {
    public static let maximumHistoryCount = 100
    public static let maximumIncludedClipCount = 150
    public static let minimumClipDuration = 0.15

    public var sourceDuration: Double
    public private(set) var clips: [EditorClip]
    public private(set) var selectedClipID: EditorClip.ID?
    /// Position on the gap-free, included edit timeline.
    public private(set) var playheadTime: Double
    public private(set) var undoStack: [EditorSnapshot]
    public private(set) var redoStack: [EditorSnapshot]
    public private(set) var revision: UInt64

    public init(sourceDuration: Double) throws {
        guard sourceDuration.isFinite, sourceDuration > 0 else {
            throw EditorCoreError.invalidTimeline
        }
        let initial = EditorClip(sourceStart: 0, sourceEnd: sourceDuration)
        self.sourceDuration = sourceDuration
        clips = [initial]
        selectedClipID = initial.id
        playheadTime = 0
        undoStack = []
        redoStack = []
        revision = 0
    }

    public init(
        sourceDuration: Double,
        clips: [EditorClip],
        selectedClipID: EditorClip.ID? = nil,
        playheadTime: Double = 0,
        undoStack: [EditorSnapshot] = [],
        redoStack: [EditorSnapshot] = [],
        revision: UInt64 = 0
    ) throws {
        self.sourceDuration = sourceDuration
        self.clips = clips
        self.selectedClipID = selectedClipID
        self.playheadTime = playheadTime
        self.undoStack = Array(undoStack.suffix(Self.maximumHistoryCount))
        self.redoStack = Array(redoStack.suffix(Self.maximumHistoryCount))
        self.revision = revision
        try validate()
    }

    public var includedClips: [EditorClip] {
        clips.filter(\.isIncluded)
    }
    public var totalDuration: Double {
        includedClips.reduce(0) {
            $0 + $1.duration
        }
    }
    public var canUndo: Bool {
        !undoStack.isEmpty
    }
    public var canRedo: Bool {
        !redoStack.isEmpty
    }

    public func canSplit(atEditTime time: Double, minimumClipDuration: Double) -> Bool {
        splitRestriction(atEditTime: time, minimumClipDuration: minimumClipDuration) == nil
    }

    /// Frame-independent checks run immediately; the resolver supplies the source's actual minimum
    /// frame duration for both the final eligibility check and the committed edit.
    public func splitRestriction(atEditTime time: Double, minimumClipDuration: Double? = nil)
        -> EditorCoreError?
    {
        guard time.isFinite,
            let clip = try? includedClip(atEditTime: time),
            let source = try? sourceTime(atEditTime: time)
        else {
            return .invalidPlayhead
        }
        guard includedClips.count < Self.maximumIncludedClipCount else {
            return .tooManyClips
        }
        let epsilon = 0.000_000_001
        guard source - clip.sourceStart > epsilon, clip.sourceEnd - source > epsilon else {
            return .splitAtBoundary
        }
        if let supplied = minimumClipDuration, !supplied.isFinite || supplied <= 0 {
            return .invalidPlayhead
        }
        let minimum = max(Self.minimumClipDuration, minimumClipDuration ?? Self.minimumClipDuration)
        guard clip.duration + epsilon >= minimum * 2 else {
            return .clipTooShort
        }
        guard source - clip.sourceStart + epsilon >= minimum,
            clip.sourceEnd - source + epsilon >= minimum
        else {
            return .splitAtBoundary
        }
        return nil
    }

    /// Builds a source-ordered edit from retained ranges, keeping gaps as excluded clips.
    public static func fromSegments(_ segments: [PointSegment], sourceDuration: Double) throws -> EditorState
    {
        let ranges = Timeline.ranges(segments, duration: sourceDuration)
        guard !ranges.isEmpty else {
            return try EditorState(sourceDuration: sourceDuration)
        }
        var clips: [EditorClip] = []
        var cursor = 0.0
        for range in ranges {
            if range.sourceStart > cursor {
                clips.append(EditorClip(sourceStart: cursor, sourceEnd: range.sourceStart, isIncluded: false))
            }
            clips.append(EditorClip(sourceStart: range.sourceStart, sourceEnd: range.sourceEnd))
            cursor = range.sourceEnd
        }
        if cursor < sourceDuration {
            clips.append(EditorClip(sourceStart: cursor, sourceEnd: sourceDuration, isIncluded: false))
        }
        return try EditorState(
            sourceDuration: sourceDuration, clips: clips, selectedClipID: clips.first(where: \.isIncluded)?.id
        )
    }

    /// Replaces the retained edit as one undoable operation.
    public mutating func replace(with segments: [PointSegment]) throws {
        guard !Timeline.ranges(segments, duration: sourceDuration).isEmpty else {
            throw EditorCoreError.invalidTimeline
        }
        let replacement = try Self.fromSegments(segments, sourceDuration: sourceDuration)
        guard replacement.includedClips.count <= Self.maximumIncludedClipCount else {
            throw EditorCoreError.tooManyClips
        }
        guard
            replacement.includedClips.allSatisfy({ $0.duration + 0.000_000_001 >= Self.minimumClipDuration })
        else {
            throw EditorCoreError.clipTooShort
        }
        let before = snapshot
        clips = replacement.clips
        selectedClipID = replacement.selectedClipID
        playheadTime = 0
        commit(before: before)
    }

    public mutating func select(_ id: EditorClip.ID?) throws {
        if let id,
            !clips.contains(where: {
                $0.id == id
            })
        {
            throw EditorCoreError.clipNotFound
        }
        selectedClipID = id
    }

    public mutating func setPlayhead(_ time: Double) throws {
        guard time.isFinite, time >= 0, time <= totalDuration else {
            throw EditorCoreError.invalidPlayhead
        }
        playheadTime = time
    }

    public func includedClip(atEditTime editTime: Double) throws -> EditorClip {
        guard editTime.isFinite, editTime >= 0, editTime <= totalDuration else {
            throw EditorCoreError.invalidPlayhead
        }
        var cursor = 0.0
        let retained = includedClips
        for (index, clip) in retained.enumerated() {
            let end = cursor + clip.duration
            if editTime < end || (index == retained.count - 1 && editTime == end) {
                return clip
            }
            cursor = end
        }
        throw EditorCoreError.invalidPlayhead
    }

    public func sourceTime(atEditTime editTime: Double) throws -> Double {
        guard editTime.isFinite, editTime >= 0, editTime <= totalDuration else {
            throw EditorCoreError.invalidPlayhead
        }
        var cursor = 0.0
        let retained = includedClips
        for (index, clip) in retained.enumerated() {
            let end = cursor + clip.duration
            if editTime < end || (index == retained.count - 1 && editTime == end) {
                return min(clip.sourceEnd, clip.sourceStart + editTime - cursor)
            }
            cursor = end
        }
        throw EditorCoreError.invalidPlayhead
    }

    public func editTime(atSourceTime sourceTime: Double, in clipID: EditorClip.ID) throws -> Double {
        guard sourceTime.isFinite,
            let target = clips.first(where: {
                $0.id == clipID
            }),
            target.isIncluded,
            sourceTime >= target.sourceStart,
            sourceTime <= target.sourceEnd
        else {
            throw EditorCoreError.clipNotFound
        }
        var cursor = 0.0
        for clip in includedClips {
            if clip.id == clipID {
                return cursor + sourceTime - clip.sourceStart
            }
            cursor += clip.duration
        }
        throw EditorCoreError.clipNotFound
    }

    /// Splits the retained clip under the edit playhead and selects the new right-hand clip.
    public mutating func split(atEditTime editTime: Double, minimumClipDuration: Double) throws {
        if let restriction = splitRestriction(atEditTime: editTime, minimumClipDuration: minimumClipDuration)
        {
            throw restriction
        }

        var cursor = 0.0
        for index in clips.indices where clips[index].isIncluded {
            let clip = clips[index]
            let editEnd = cursor + clip.duration
            if editTime > cursor && editTime < editEnd {
                let sourceSplit = clip.sourceStart + editTime - cursor
                let before = snapshot
                let left = EditorClip(
                    id: clip.id,
                    sourceStart: clip.sourceStart,
                    sourceEnd: sourceSplit,
                    isIncluded: true,
                    untrimmedSourceStart: clip.availableSourceStart,
                    untrimmedSourceEnd: sourceSplit
                )
                let right = EditorClip(
                    sourceStart: sourceSplit,
                    sourceEnd: clip.sourceEnd,
                    isIncluded: true,
                    untrimmedSourceStart: sourceSplit,
                    untrimmedSourceEnd: clip.availableSourceEnd
                )
                clips.replaceSubrange(index...index, with: [left, right])
                selectedClipID = right.id
                playheadTime = editTime
                commit(before: before)
                return
            }
            cursor = editEnd
        }
        throw EditorCoreError.splitAtBoundary
    }

    /// Changes one edge, ripples following clips, and records the whole gesture as one edit.
    public mutating func trim(
        _ clipID: EditorClip.ID,
        edge: EditorTrimEdge,
        toSourceTime time: Double,
        minimumClipDuration: Double
    ) throws {
        guard
            let index = clips.firstIndex(where: {
                $0.id == clipID
            }), clips[index].isIncluded
        else {
            throw EditorCoreError.clipNotFound
        }
        let clip = clips[index]
        let start = edge == .start ? time : clip.sourceStart
        let end = edge == .end ? time : clip.sourceEnd
        guard time.isFinite, minimumClipDuration.isFinite, minimumClipDuration > 0,
            start >= clip.availableSourceStart, end <= clip.availableSourceEnd,
            end - start + 0.000_000_001 >= max(Self.minimumClipDuration, minimumClipDuration)
        else {
            throw EditorCoreError.invalidTrim
        }
        guard start != clip.sourceStart || end != clip.sourceEnd else {
            return
        }
        let before = snapshot
        let editStart = clips[..<index].filter(\.isIncluded).reduce(0) {
            $0 + $1.duration
        }
        clips[index].untrimmedSourceStart = clip.availableSourceStart
        clips[index].untrimmedSourceEnd = clip.availableSourceEnd
        clips[index].sourceStart = start
        clips[index].sourceEnd = end
        selectedClipID = clipID
        playheadTime = edge == .start ? editStart : editStart + end - start
        commit(before: before)
    }

    /// Removes the selected clip from the condensed timeline without losing its source range.
    public mutating func excludeSelected() throws {
        guard let selectedClipID else {
            throw EditorCoreError.noSelectedClip
        }
        guard
            let index = clips.firstIndex(where: {
                $0.id == selectedClipID
            })
        else {
            throw EditorCoreError.clipNotFound
        }
        guard clips[index].isIncluded else {
            throw EditorCoreError.noSelectedClip
        }
        guard includedClips.count > 1 else {
            throw EditorCoreError.cannotExcludeOnlyIncludedClip
        }

        let before = snapshot
        let joinTime = clips[..<index].filter(\.isIncluded).reduce(0) {
            $0 + $1.duration
        }
        clips[index].isIncluded = false
        let right = clips[(index + 1)...].first(where: \.isIncluded)
        let left = clips[..<index].last(where: \.isIncluded)
        self.selectedClipID = right?.id ?? left?.id
        playheadTime = min(joinTime, totalDuration)
        commit(before: before)
    }

    public mutating func undo() {
        guard let previous = undoStack.popLast() else {
            return
        }
        redoStack.append(snapshot)
        trimHistory(&redoStack)
        restore(previous)
        revision &+= 1
    }

    public mutating func redo() {
        guard let next = redoStack.popLast() else {
            return
        }
        undoStack.append(snapshot)
        trimHistory(&undoStack)
        restore(next)
        revision &+= 1
    }

    public func validate() throws {
        guard sourceDuration.isFinite, sourceDuration > 0,
            !clips.isEmpty,
            clips.contains(where: \.isIncluded),
            playheadTime.isFinite,
            playheadTime >= 0,
            playheadTime <= totalDuration,
            selectedClipID == nil
                || clips.contains(where: {
                    $0.id == selectedClipID
                })
        else {
            throw EditorCoreError.invalidTimeline
        }

        var previousEnd = 0.0
        var ids = Set<UUID>()
        for clip in clips {
            guard clip.sourceStart.isFinite,
                clip.sourceEnd.isFinite,
                clip.availableSourceStart.isFinite,
                clip.availableSourceEnd.isFinite,
                clip.availableSourceStart >= previousEnd,
                clip.sourceStart >= clip.availableSourceStart,
                clip.sourceEnd > clip.sourceStart,
                clip.sourceEnd <= clip.availableSourceEnd,
                clip.availableSourceEnd <= sourceDuration,
                ids.insert(clip.id).inserted
            else {
                throw EditorCoreError.invalidTimeline
            }
            previousEnd = clip.availableSourceEnd
        }
    }

    private var snapshot: EditorSnapshot {
        EditorSnapshot(clips: clips, selectedClipID: selectedClipID, playheadTime: playheadTime)
    }

    private mutating func commit(before: EditorSnapshot) {
        undoStack.append(before)
        trimHistory(&undoStack)
        redoStack.removeAll()
        revision &+= 1
    }

    private mutating func restore(_ snapshot: EditorSnapshot) {
        clips = snapshot.clips
        selectedClipID = snapshot.selectedClipID
        playheadTime = snapshot.playheadTime
    }

    private func trimHistory(_ history: inout [EditorSnapshot]) {
        if history.count > Self.maximumHistoryCount {
            history.removeFirst(history.count - Self.maximumHistoryCount)
        }
    }
}
