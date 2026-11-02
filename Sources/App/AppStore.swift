import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppStore {
    private(set) var activeProject: MatchProject?
    var errorMessage: String?
    var importing = false
    var importProgress = 0.0
    let root: URL
    private let assets = SourceAssetStore()
    private var importTransfer: Progress?

    init(root: URL? = nil) {
        self.root = root ?? URL.cachesDirectory.appendingPathComponent("EditingSession", isDirectory: true)
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
        do {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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
            return project.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
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
