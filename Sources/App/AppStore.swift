import Foundation
import RallyKit
import SwiftUI
import UniformTypeIdentifiers

/// The result of the rally-finding video check that starts right after import.
enum VideoCheckStatus: Sendable {
    case checking
    /// `check` is nil when the check itself failed; rally finding then checks the video again.
    case passed(RallyVideoCheck?)
    case rejected(RallyRejection)

    var isChecking: Bool {
        if case .checking = self {
            return true
        }
        return false
    }

    static func run(on url: URL) async -> VideoCheckStatus {
        do {
            let check = try await RallyFinder.check(url: url)
            if let rejection = check.rejection {
                return .rejected(rejection)
            }
            return .passed(check)
        } catch {
            return .passed(nil)
        }
    }
}

/// The app's view of a finished rally search.
enum RallyFindingStatus: Sendable {
    case found([FoundRally], notes: [RallyFramingNote])
    case rejected(RallyRejection)
}

typealias RallyFinderFunction = @Sendable (
    URL, RallyVideoCheck?, @escaping @Sendable (RallyFindingProgress) -> Void
) async throws -> RallyFindingStatus

@MainActor
@Observable
final class AppStore {
    private(set) var activeProject: MatchProject?
    private(set) var videoCheck: VideoCheckStatus?
    private(set) var freeFinds: FreeFindAllowance
    /// The rally list after a finished search. While it exists, the editor shows it instead of the timeline.
    private(set) var rallyReview: RallyReview?
    /// Framing notes from the search, shown as a banner until dismissed.
    var rallyNotes: [RallyFramingNote] = []
    var errorMessage: String?
    var importing = false
    var importProgress = 0.0
    let root: URL
    /// Replaced by UI tests so they do not run the real check.
    var videoChecker: @Sendable (URL) async -> VideoCheckStatus = { url in
        await VideoCheckStatus.run(on: url)
    }
    /// Replaced by UI tests so they do not run the real search.
    var rallyFinder: RallyFinderFunction = { url, check, progress in
        switch try await RallyFinder.find(url: url, check: check, progress: progress) {
        case .rejected(let rejection):
            return .rejected(rejection)
        case .found(let result):
            return .found(result.rallies, notes: result.notes)
        }
    }
    private let assets = SourceAssetStore()
    private var importTransfer: Progress?
    private var videoCheckTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private static let freeFindsKey = "freeFindAllowance"

    init(root: URL? = nil, defaults: UserDefaults = .standard) {
        self.root = root ?? URL.cachesDirectory.appendingPathComponent("EditingSession", isDirectory: true)
        self.defaults = defaults
        // Free finds outlive the editing session, which is deleted on every launch.
        freeFinds = defaults.data(forKey: Self.freeFindsKey)
            .flatMap {
                try? JSONDecoder().decode(FreeFindAllowance.self, from: $0)
            } ?? FreeFindAllowance()
        do {
            // A new process starts a fresh session. Backgrounding does not recreate the store.
            if FileManager.default.fileExists(atPath: self.root.path) {
                try FileManager.default.removeItem(at: self.root)
            }
            if root == nil {
                let legacy = URL.documentsDirectory.appendingPathComponent("Matches", isDirectory: true)
                if FileManager.default.fileExists(atPath: legacy.path) {
                    try FileManager.default.removeItem(at: legacy)
                }
            }
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func project(_ id: UUID) -> MatchProject? {
        activeProject?.id == id ? activeProject : nil
    }

    func endSession() {
        activeProject = nil
        cancelVideoCheck()
        do {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var freeFindsLeft: Int {
        freeFinds.remaining(on: .now)
    }

    /// Uses one of today's free finds. Returns false when none are left.
    /// Call this only when rally analysis finishes with at least one rally, so a cancelled, failed or empty
    /// analysis keeps the free find.
    @discardableResult
    func consumeFreeFind() -> Bool {
        guard freeFinds.consume(on: .now) else {
            return false
        }
        if let data = try? JSONEncoder().encode(freeFinds) {
            defaults.set(data, forKey: Self.freeFindsKey)
        }
        return true
    }

    func folder(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func sourceURL(_ project: MatchProject) -> URL {
        folder(project.id).appendingPathComponent(project.source.filename)
    }

    func importPhoto(_ provider: NSItemProvider) async -> UUID? {
        guard !importing else {
            return nil
        }
        importing = true
        importProgress = 0
        defer {
            importing = false
            importTransfer = nil
        }
        do {
            let movieURL: URL = try await withCheckedThrowingContinuation { continuation in
                importTransfer = provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                    do {
                        if let error {
                            throw error
                        }
                        guard let url else {
                            throw MatchError.invalidMedia(
                                "The selected video is unavailable. Download it in Photos, then try again.")
                        }
                        // The provider removes its temporary file after this callback returns.
                        let destination = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)
                            .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
                        try FileManager.default.copyItem(at: url, to: destination)
                        continuation.resume(returning: destination)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            importProgress = 0.9
            defer {
                try? FileManager.default.removeItem(at: movieURL)
            }
            return await importURL(movieURL)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func refreshImportProgress() {
        if let importTransfer {
            importProgress = importTransfer.fractionCompleted * 0.9
        }
    }

    func cancelImport() {
        importTransfer?.cancel()
    }

    func importURL(_ url: URL) async -> UUID? {
        do {
            let project = try await assets.importVideo(at: url, root: root)
            activeProject = project
            startVideoCheck(for: project)
            return project.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Checks the video in the background so tapping Find rallies can reject it or start right away.
    private func startVideoCheck(for project: MatchProject) {
        cancelVideoCheck()
        videoCheck = .checking
        let source = sourceURL(project)
        let checker = videoChecker
        let work = Task.detached(priority: .utility) {
            await checker(source)
        }
        videoCheckTask = Task { [weak self] in
            let status = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, let self, self.activeProject?.id == project.id else {
                return
            }
            self.videoCheck = status
        }
    }

    private func cancelVideoCheck() {
        videoCheckTask?.cancel()
        videoCheckTask = nil
        videoCheck = nil
        rallyReview = nil
        rallyNotes = []
    }

    /// Saves the rally list and rebuilds the edit from its checked rallies as one editor change.
    /// The list keeps its own undo history; the editor's history is not used while reviewing.
    @discardableResult
    func updateRallyReview(
        _ id: UUID, focusing rallyID: ReviewRally.ID? = nil, _ change: (inout RallyReview) -> Void
    ) async -> Bool {
        guard var review = rallyReview, var project = project(id), var editor = project.editorState else {
            return false
        }
        change(&review)
        do {
            if review.checkedCount > 0 {
                try editor.replace(with: review.segments)
                if let rallyID, let rally = review.rally(rallyID), rally.isChecked {
                    try Self.movePlayhead(of: &editor, to: rally.start)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        project.editorState = editor
        project.exportFilename = nil
        guard await updateProject(project) else {
            return false
        }
        rallyReview = review
        return true
    }

    /// Puts the playhead where `sourceTime` plays in the edit, when it is part of the edit.
    private static func movePlayhead(of editor: inout EditorState, to sourceTime: Double) throws {
        if let time = editTime(of: sourceTime, in: editor) {
            try editor.setPlayhead(time)
        }
    }

    /// Where `sourceTime` plays in the edit, or nil when that moment is left out.
    static func editTime(of sourceTime: Double, in editor: EditorState) -> Double? {
        let clip = editor.includedClips.first {
            $0.sourceStart <= sourceTime + 0.000_001 && sourceTime < $0.sourceEnd
        }
        guard let clip else {
            return nil
        }
        return try? editor.editTime(atSourceTime: max(sourceTime, clip.sourceStart), in: clip.id)
    }

    /// Starts reviewing found rallies; the edit becomes their checked rallies.
    func beginRallyReview(_ id: UUID, review: RallyReview, notes: [RallyFramingNote]) async -> Bool {
        rallyReview = review
        rallyNotes = notes
        let applied = await updateRallyReview(id) { _ in
        }
        if !applied {
            rallyReview = nil
            rallyNotes = []
        }
        return applied
    }

    @discardableResult
    func updateProject(_ project: MatchProject) async -> Bool {
        guard activeProject?.id == project.id else {
            return false
        }
        do {
            guard let editor = project.editorState,
                abs(editor.sourceDuration - project.source.duration) < 0.000_001
            else {
                throw EditorCoreError.invalidTimeline
            }
            try editor.validate()
            activeProject = project
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func edit(_ id: UUID, segments: [PointSegment]) async {
        guard var p = project(id) else {
            return
        }
        do {
            for s in segments {
                try Timeline.validate(start: s.sourceStart, end: s.sourceEnd, duration: p.source.duration)
            }
            if p.editorIsAuthoritative == true {
                guard var editor = p.editorState else {
                    throw EditorCoreError.invalidTimeline
                }
                try editor.replace(with: segments)
                p.editorState = editor
            }
            p.edit(segments)
            await updateProject(p)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func undo(_ id: UUID) async {
        guard var p = project(id) else {
            return
        }

        p.undo()
        await updateProject(p)
    }

    @discardableResult
    func updateEditor(_ id: UUID, _ change: (inout EditorState) throws -> Void) async -> Bool {
        guard var project = project(id), var editor = project.editorState else {
            return false
        }
        do {
            let oldRevision = editor.revision
            try change(&editor)
            project.editorState = editor
            if editor.revision != oldRevision {
                project.exportFilename = nil
            }
            return await updateProject(project)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
