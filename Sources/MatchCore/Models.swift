import Foundation

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
    case included, excluded
    public var label: String {
        switch self {
        case .included: "Included"
        case .excluded: "Excluded"
        }
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        // Preserve retained intervals from older schema-v1 projects.
        if value == "needsReview" {
            self = .included
        } else if let state = Self(rawValue: value) {
            self = state
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid inclusion state")
        }
    }
    public var isRetained: Bool {
        self != .excluded
    }
}

public struct PointSegment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var sourceStart: Double
    public var sourceEnd: Double
    public var inclusion: InclusionState
    public var duration: Double {
        max(0, sourceEnd - sourceStart)
    }
    public init(
        id: UUID = UUID(), start: Double, end: Double, inclusion: InclusionState = .included
    ) {
        self.id = id
        sourceStart = start
        sourceEnd = end
        self.inclusion = inclusion
    }
}

public struct MatchProject: Identifiable, Codable, Sendable {
    public var schemaVersion = 1
    public let id: UUID
    public let createdAt: Date
    public var title: String
    public var source: SourceAssetReference
    public var segments: [PointSegment] = []
    public var editorState: EditorState?
    /// Nil in projects saved before the editor became the playback authority.
    public var editorIsAuthoritative: Bool?
    public var undoHistory: [[PointSegment]] = []
    public var warnings: [String] = []
    public var exportFilename: String? {
        didSet {
            // Rally clips belong to the export they were made with.
            if exportFilename == nil {
                exportClipFilenames = nil
            }
        }
    }

    /// Per-rally clips saved alongside the condensed video (5B "Also save each rally").
    public var exportClipFilenames: [String]?
    public var rallyExportOptions: RallyExportOptions?
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
}

public enum MatchError: LocalizedError, Sendable {
    case invalidMedia(String), storage, missingSource, emptyTimeline, invalidRange
    public var errorDescription: String? {
        switch self {
        case .invalidMedia(let reason): reason
        case .storage: "There isn’t enough storage. Free up space on your iPhone and try again."
        case .missingSource: "The original video is unavailable. Import it again to create a new project."
        case .emptyTimeline: "Include a clip before previewing or exporting."
        case .invalidRange: "Choose a start before the end, within the original video."
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
