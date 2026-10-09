import Foundation

public enum ProjectStatus: String, Codable, Sendable {
    case setup, analyzing, interrupted, ready
    public var label: String {
        switch self {
        case .setup: "Ready to edit"
        case .analyzing: "Finding possible points"
        case .interrupted: "Analysis paused"
        case .ready: "Ready to review"
        }
    }
}

public struct NormalizedRect: Codable, Equatable, Sendable {
    public var x: Double = 0.08
    public var y: Double = 0.12
    public var width: Double = 0.84
    public var height: Double = 0.80
    public init(x: Double = 0.08, y: Double = 0.12, width: Double = 0.84, height: Double = 0.80) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1.000001 && y + height <= 1.000001
    }
}

public struct SourceAssetReference: Codable, Equatable, Sendable {
    public var filename: String
    public var duration: Double
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var hasAudio: Bool
    public var byteCount: Int64
    public init(
        filename: String, duration: Double, width: Int, height: Int, frameRate: Double, hasAudio: Bool,
        byteCount: Int64
    ) {
        self.filename = filename
        self.duration = duration
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.hasAudio = hasAudio
        self.byteCount = byteCount
    }
}

public enum InclusionState: String, Codable, CaseIterable, Sendable {
    case included, needsReview, excluded
    public var label: String {
        switch self {
        case .included: "Included"
        case .needsReview: "Needs review"
        case .excluded: "Excluded"
        }
    }
    public var isRetained: Bool {
        self != .excluded
    }
}
public enum SegmentOrigin: String, Codable, Sendable {
    case automatic, userCreated, userAdjusted
}

public struct PointSegment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var sourceStart: Double
    public var sourceEnd: Double
    public var confidence: Double
    public var inclusion: InclusionState
    public var origin: SegmentOrigin
    public var duration: Double {
        max(0, sourceEnd - sourceStart)
    }
    public init(
        id: UUID = UUID(), start: Double, end: Double, confidence: Double = 1,
        inclusion: InclusionState = .included, origin: SegmentOrigin = .userCreated
    ) {
        self.id = id
        sourceStart = start
        sourceEnd = end
        self.confidence = confidence
        self.inclusion = inclusion
        self.origin = origin
    }
}

public struct ActivitySample: Codable, Equatable, Sendable {
    public var time: Double
    public var value: Double
    public init(time: Double, value: Double) {
        self.time = time
        self.value = value
    }
}

public enum AnalysisStage: String, Codable, Sendable {
    case preparing, audio, video, generating, complete
    public var label: String {
        switch self {
        case .preparing: "Preparing your match"
        case .audio: "Listening for activity"
        case .video: "Checking court movement"
        case .generating: "Building possible points"
        case .complete: "Ready for your review"
        }
    }
}
public struct AnalysisRecord: Codable, Sendable {
    public var modelVersion = "energy-motion-baseline-1 (no trained classifier)"
    public var segmenterVersion = SegmenterConfiguration.standard.version
    public var startedAt = Date()
    public var completedAt: Date?
    public var stage: AnalysisStage = .preparing
    public var audio: [ActivitySample] = []
    public var visual: [ActivitySample] = []
    public var warnings: [String] = []
    public init() {
    }
}

public struct MatchProject: Identifiable, Codable, Sendable {
    public var schemaVersion = 1
    public let id: UUID
    public let createdAt: Date
    public var title: String
    public var source: SourceAssetReference
    public var courtRegion = NormalizedRect()
    public var analysis: AnalysisRecord?
    public var pendingAnalysisSegments: [PointSegment]?
    public var segments: [PointSegment] = []
    public var editorState: EditorState?
    /// Nil in projects saved before the editor became the playback authority.
    public var editorIsAuthoritative: Bool?
    public var undoHistory: [[PointSegment]] = []
    public var status: ProjectStatus = .setup
    public var warnings: [String] = []
    public var exportFilename: String?
    public init(id: UUID = UUID(), title: String, source: SourceAssetReference, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.source = source
        self.createdAt = createdAt
        editorState = try? EditorState(sourceDuration: source.duration)
        editorIsAuthoritative = true
    }
    public var condensedDuration: Double {
        if editorIsAuthoritative == true, let editorState {
            return editorState.totalDuration
        }
        return Timeline.ranges(segments, duration: source.duration).reduce(0) {
            $0 + $1.duration
        }
    }
    public var retainedCount: Int {
        if editorIsAuthoritative == true, let editorState {
            return editorState.includedClips.count
        }
        return segments.filter {
            $0.inclusion.isRetained
        }.count
    }
    public mutating func activateEditor() throws {
        guard editorIsAuthoritative != true || editorState == nil else {
            return
        }
        editorState = try EditorState.fromSegments(segments, sourceDuration: source.duration)
        editorIsAuthoritative = true
    }
    public mutating func edit(_ segments: [PointSegment]) {
        undoHistory.append(self.segments)
        if undoHistory.count > 30 {
            undoHistory.removeFirst()
        }
        self.segments = segments.sorted {
            $0.sourceStart < $1.sourceStart
        }
        // The old file remains on disk, but must never be advertised as the current edit.
        exportFilename = nil
    }
    public mutating func undo() {
        guard let previous = undoHistory.popLast() else {
            return
        }
        segments = previous
        exportFilename = nil
    }
    public mutating func receiveAnalysis(_ record: AnalysisRecord, suggestions: [PointSegment]) {
        analysis = record
        pendingAnalysisSegments = suggestions
        status = .ready
    }
    @discardableResult
    public mutating func applyAnalysisSuggestions() -> Bool {
        guard let suggestions = pendingAnalysisSegments, !suggestions.isEmpty else {
            return false
        }
        if editorIsAuthoritative == true {
            do {
                try editorState?.replace(with: suggestions)
            } catch {
                return false
            }
        }
        edit(suggestions)
        pendingAnalysisSegments = nil
        return true
    }
}

public enum MatchError: LocalizedError, Sendable {
    case invalidMedia(String), storage, missingSource, incompatibleProject, emptyTimeline, invalidRange,
        persistence(String)
    public var errorDescription: String? {
        switch self {
        case .invalidMedia(let reason): reason
        case .storage: "There isn’t enough storage. Free up space on your iPhone and try again."
        case .missingSource: "The original video is unavailable. Import it again to create a new project."
        case .incompatibleProject:
            "This project uses an unsupported or damaged format. Its source video has been preserved."
        case .emptyTimeline: "Include a possible point or add a segment before previewing or exporting."
        case .invalidRange: "Choose a start before the end, within the original video."
        case .persistence(let reason): "Your changes could not be saved: \(reason)"
        }
    }
}

public func timeLabel(_ seconds: Double) -> String {
    guard seconds.isFinite else {
        return "00:00"
    }
    let total = max(0, Int(seconds))
    return total >= 3600
        ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
        : String(format: "%02d:%02d", total / 60, total % 60)
}
