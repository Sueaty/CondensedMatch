import XCTest
@testable import RallyCut

@MainActor
final class EditorSplitLookupTests: XCTestCase {
    func testTimeoutUnlocksEditorAndLateResultCannotCompleteNewRequest() async throws {
        let lookup = EditorSplitLookup()
        let delayed = DelayedFrameLookup()
        var timedOut = 0
        var completed: [Double] = []
        lookup.resolve(timeout: .milliseconds(60)) {
            await delayed.value()
        } completion: { result in
            switch result {
            case .success(let boundary):
                completed.append(boundary.sourceTime)
            case .failure(let error):
                if case FrameBoundaryError.timedOut = error {
                    timedOut += 1
                } else {
                    XCTFail("Unexpected failure: \(error)")
                }
            }
        }
        XCTAssertTrue(lookup.isFindingFrame)
        let deadline = Date().addingTimeInterval(2)
        while lookup.isFindingFrame && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(lookup.isFindingFrame)
        XCTAssertEqual(timedOut, 1)
        lookup.resolve {
            ResolvedFrameBoundary(sourceTime: 2, minimumClipDuration: 1.0 / 30)
        } completion: { result in
            if case .success(let boundary) = result {
                completed.append(boundary.sourceTime)
            }
        }
        let nextDeadline = Date().addingTimeInterval(2)
        while lookup.isFindingFrame && Date() < nextDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await delayed.finish()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(completed, [2])
        XCTAssertEqual(timedOut, 1)
        XCTAssertFalse(lookup.isFindingFrame)
    }

    func testLeavingEditorCancelsCompletionAndTimeout() async throws {
        let lookup = EditorSplitLookup()
        let delayed = DelayedFrameLookup()
        var completions = 0
        lookup.resolve(timeout: .milliseconds(60)) {
            await delayed.value()
        } completion: { _ in
            completions += 1
        }
        await delayed.waitUntilStarted()
        lookup.cancel()
        XCTAssertFalse(lookup.isFindingFrame)
        await delayed.finish()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(completions, 0)
    }
}

private actor DelayedFrameLookup {
    private var continuation: CheckedContinuation<ResolvedFrameBoundary, Never>?

    func value() async -> ResolvedFrameBoundary {
        await withCheckedContinuation {
            continuation = $0
        }
    }

    func waitUntilStarted() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func finish() {
        continuation?.resume(returning: ResolvedFrameBoundary(sourceTime: 1, minimumClipDuration: 1.0 / 30))
        continuation = nil
    }
}
