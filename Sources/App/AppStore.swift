import Foundation
import SwiftUI
import PhotosUI

@MainActor
@Observable
final class AppStore {
    var projects: [MatchProject] = []
    var errorMessage: String?
    var notice: String?
    var importing = false
    var importProgress = 0.0
    var activeAnalysisID: UUID?
    var analysisProgress = 0.0
    var root: URL
    private var repository: ProjectRepository?
    private let assets = SourceAssetStore()
    private let analyzer = AnalysisCoordinator()
    private var analysisTask: Task<Void, Never>?
    private var importTransfer: Progress?

    init(root: URL? = nil) {
        self.root = root ?? URL.documentsDirectory.appendingPathComponent("Matches", isDirectory: true)
        do { repository = try ProjectRepository(root: self.root) }
        catch { errorMessage = error.localizedDescription }
    }
    func load() async {
        guard let repository else { return }
        do {
            let result = try await repository.load()
            projects = result.projects
            if result.unreadableCount > 0 { notice = "\(result.unreadableCount) project(s) could not be opened. Their files have been preserved in On My iPhone → Rally Cut → Matches." }
        } catch { errorMessage = error.localizedDescription }
    }
    func project(_ id: UUID) -> MatchProject? { projects.first { $0.id == id } }
    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func sourceURL(_ project: MatchProject) -> URL { folder(project.id).appendingPathComponent(project.source.filename) }
    func thumbnailURL(_ project: MatchProject) -> URL { folder(project.id).appendingPathComponent("thumbnail.jpg") }

    func importPhoto(_ item: PhotosPickerItem) async -> UUID? {
        importing = true; importProgress = 0
        defer { importing = false; importTransfer = nil }
        do {
            let movie: ImportedMovie? = try await withCheckedThrowingContinuation { continuation in
                importTransfer = item.loadTransferable(type: ImportedMovie.self) { result in continuation.resume(with: result) }
            }
            guard let movie else { throw MatchError.invalidMedia("The selected video is unavailable. Download it in Photos, then try again.") }
            importProgress = 0.9
            defer { try? FileManager.default.removeItem(at: movie.url) }
            return await importURL(movie.url)
        } catch { errorMessage = error.localizedDescription; return nil }
    }
    func refreshImportProgress() { if let importTransfer { importProgress = importTransfer.fractionCompleted * 0.9 } }
    func cancelImport() { importTransfer?.cancel() }
    func importURL(_ url: URL) async -> UUID? {
        guard let repository else { return nil }
        do {
            let project = try await assets.importVideo(at: url, repository: repository)
            projects.insert(project, at: 0)
            return project.id
        } catch { errorMessage = error.localizedDescription; return nil }
    }
    @discardableResult
    func save(_ project: MatchProject) async -> Bool {
        guard let repository else { return false }
        do {
            try await repository.save(project)
            if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func setCourt(_ region: NormalizedRect, id: UUID) async -> Bool {
        guard var p = project(id) else { return false }
        p.courtRegion = region; p.analysis = nil; p.status = .setup
        return await save(p)
    }
    func manualReview(_ id: UUID) async {
        guard var p = project(id) else { return }
        p.status = .ready; await save(p)
    }
    func edit(_ id: UUID, segments: [PointSegment]) async {
        guard var p = project(id) else { return }
        do {
            for s in segments { try Timeline.validate(start: s.sourceStart, end: s.sourceEnd, duration: p.source.duration) }
            p.edit(segments); await save(p)
        } catch { errorMessage = error.localizedDescription }
    }
    func undo(_ id: UUID) async {
        guard var p = project(id) else { return }; p.undo(); await save(p)
    }
    func delete(_ id: UUID, includingMedia: Bool) async {
        guard id != activeAnalysisID, let repository else { return }
        do { try await repository.delete(id, includingMedia: includingMedia); projects.removeAll { $0.id == id } }
        catch { errorMessage = error.localizedDescription }
    }
    func analyze(_ id: UUID) {
        guard activeAnalysisID == nil, var p = project(id), let repository else { return }
        activeAnalysisID = id; analysisProgress = 0
        p.status = .analyzing
        let initial = p
        analysisTask = Task {
            defer { activeAnalysisID = nil; analysisTask = nil; UIApplication.shared.isIdleTimerDisabled = false }
            UIApplication.shared.isIdleTimerDisabled = true
            guard await save(initial) else { return }
            do {
                let result = try await analyzer.analyze(project: initial, source: sourceURL(initial)) { [weak self] update in
                    guard let self else { throw CancellationError() }
                    try await self.checkpoint(id: id, update: update, repository: repository)
                }
                try Task.checkCancellation()
                guard var latest = project(id) else { return }
                latest.analysis = result.0; latest.edit(result.1); latest.status = .ready
                if !(await save(latest)) { throw MatchError.persistence("The completed analysis could not be committed. Free storage and retry.") }
            } catch {
                if var latest = project(id) {
                    latest.status = .interrupted
                    // Remain actionable in this session even if storage is unavailable.
                    if let index = projects.firstIndex(where: { $0.id == id }) { projects[index] = latest }
                    await save(latest)
                }
                if !(error is CancellationError) { errorMessage = "Analysis paused. \(error.localizedDescription) You can retry or edit manually." }
            }
        }
    }
    private func checkpoint(id: UUID, update: AnalysisUpdate, repository: ProjectRepository) async throws {
        try Task.checkCancellation()
        guard var p = project(id) else { throw CancellationError() }
        p.analysis = update.record; p.status = .analyzing
        try await repository.save(p)
        if let index = projects.firstIndex(where: { $0.id == id }) { projects[index] = p }
        analysisProgress = update.progress
    }
    func pauseAnalysis() { analysisTask?.cancel() }
}
