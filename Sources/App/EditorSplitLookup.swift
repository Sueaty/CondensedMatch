import Foundation
import Observation

/// Bounds the user's wait even if an underlying media read is slow to acknowledge cancellation.
/// A cancelled or timed-out request can never deliver a result to a newer edit.
@MainActor
@Observable
final class EditorSplitLookup {
    nonisolated static let timeout: Duration = .seconds(3)
    private(set) var isFindingFrame = false
    private var request: UUID?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func resolve(
        timeout: Duration = EditorSplitLookup.timeout,
        operation: @escaping @Sendable () async throws -> ResolvedFrameBoundary,
        completion: @escaping @MainActor (Result<ResolvedFrameBoundary, Error>) -> Void
    ) {
        cancel()
        let id = UUID()
        request = id
        isFindingFrame = true
        worker = Task { [weak self] in
            let result: Result<ResolvedFrameBoundary, Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            self?.finish(id, result: result, completion: completion)
        }
        timer = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.worker?.cancel()
            self?.finish(id, result: .failure(FrameBoundaryError.timedOut), completion: completion)
        }
    }

    func cancel() {
        request = nil
        worker?.cancel()
        timer?.cancel()
        worker = nil
        timer = nil
        isFindingFrame = false
    }

    private func finish(
        _ id: UUID, result: Result<ResolvedFrameBoundary, Error>,
        completion: @MainActor (Result<ResolvedFrameBoundary, Error>) -> Void
    ) {
        guard request == id else {
            return
        }
        request = nil
        timer?.cancel()
        timer = nil
        worker = nil
        isFindingFrame = false
        completion(result)
    }
}
