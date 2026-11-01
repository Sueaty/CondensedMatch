import AVFoundation

enum FrameBoundaryError: LocalizedError {
    case noVideoTrack
    case noInteriorFrame
    case readerFailed
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The original video couldn't be opened. Reopen the project and try again."
        case .noInteriorFrame:
            "No cut point is available here. Move the playhead a little and try again."
        case .readerFailed: "We couldn't read this video. Move the playhead slightly and try Split again."
        case .timedOut: "Finding a cut point took too long. Please try Split again."
        }
    }
}

struct ResolvedFrameBoundary: Sendable {
    let sourceTime: Double
    let minimumClipDuration: Double
}

/// Reads nearby presentation timestamps instead of assuming a constant frame cadence.
actor VideoFrameBoundaryResolver {
    static let maximumSplitSnapDistance = 0.5

    func splitBoundary(
        in source: URL, editor: EditorState, at editTime: Double, fallbackFrameRate: Double
    ) async throws -> ResolvedFrameBoundary {
        try Task.checkCancellation()
        if let restriction = editor.splitRestriction(atEditTime: editTime) {
            throw restriction
        }
        let clip = try editor.includedClip(atEditTime: editTime)
        let boundary = try await nearestBoundary(
            in: source, to: editor.sourceTime(atEditTime: editTime),
            clipStart: clip.sourceStart, clipEnd: clip.sourceEnd, fallbackFrameRate: fallbackFrameRate)
        let snapped = try editor.editTime(atSourceTime: boundary.sourceTime, in: clip.id)
        if let restriction = editor.splitRestriction(
            atEditTime: snapped, minimumClipDuration: boundary.minimumClipDuration)
        {
            throw restriction
        }
        return boundary
    }

    func nearestBoundary(
        in source: URL,
        to candidate: Double,
        clipStart: Double,
        clipEnd: Double,
        fallbackFrameRate: Double
    ) async throws -> ResolvedFrameBoundary {
        guard candidate.isFinite, clipStart.isFinite, clipEnd.isFinite,
            clipStart < candidate, candidate < clipEnd
        else {
            throw FrameBoundaryError.noInteriorFrame
        }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw FrameBoundaryError.noVideoTrack
        }
        let loadedMinimum = (try? await track.load(.minFrameDuration))?.seconds ?? .nan
        let fallbackMinimum = 1 / max(1, fallbackFrameRate)
        let minimum = max(
            EditorState.minimumClipDuration,
            loadedMinimum.isFinite && loadedMinimum > 0 ? loadedMinimum : fallbackMinimum)
        guard clipEnd - clipStart + 0.000_000_001 >= minimum * 2 else {
            throw EditorCoreError.clipTooShort
        }

        for radius in [0.5, 2.0, 8.0] {
            try Task.checkCancellation()
            let start = max(0, candidate - radius)
            let end = min(clipEnd, candidate + radius)
            let stamps = try readPresentationTimes(asset: asset, track: track, start: start, end: end)
            let valid = stamps.filter {
                $0 + 0.000_000_001 >= clipStart + minimum
                    && $0 - 0.000_000_001 <= clipEnd - minimum
                    && abs($0 - candidate) <= Self.maximumSplitSnapDistance + 0.000_000_001
            }
            if let nearest = valid.min(by: { left, right in

                let leftDistance = abs(left - candidate)
                let rightDistance = abs(right - candidate)
                return abs(leftDistance - rightDistance) < 0.000_000_001
                    ? left > right : leftDistance < rightDistance
            }) {
                return ResolvedFrameBoundary(sourceTime: nearest, minimumClipDuration: minimum)
            }
        }
        throw FrameBoundaryError.noInteriorFrame
    }

    func trimBoundary(
        in source: URL,
        to candidate: Double,
        clip: EditorClip,
        edge: EditorTrimEdge,
        fallbackFrameRate: Double
    ) async throws -> ResolvedFrameBoundary {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw FrameBoundaryError.noVideoTrack
        }
        let loaded = (try? await track.load(.minFrameDuration))?.seconds ?? .nan
        let minimum = max(
            EditorState.minimumClipDuration,
            loaded.isFinite && loaded > 0 ? loaded : 1 / max(1, fallbackFrameRate))
        let lower = edge == .start ? clip.availableSourceStart : clip.sourceStart + minimum
        let upper = edge == .start ? clip.sourceEnd - minimum : clip.availableSourceEnd
        guard candidate.isFinite, upper + 0.000_000_001 >= lower else {
            throw FrameBoundaryError.noInteriorFrame
        }
        let target = min(upper, max(lower, candidate))
        let originalEdge = edge == .start ? clip.availableSourceStart : clip.availableSourceEnd
        if abs(target - originalEdge) < 0.000_000_001 {
            return ResolvedFrameBoundary(sourceTime: originalEdge, minimumClipDuration: minimum)
        }
        for radius in [0.5, 2.0, 8.0] {
            try Task.checkCancellation()
            let stamps = try readPresentationTimes(
                asset: asset, track: track,
                start: max(0, target - radius), end: min(clip.availableSourceEnd, target + radius)
            )
            let valid = stamps.filter {
                $0 + 0.000_000_001 >= lower && $0 - 0.000_000_001 <= upper
            }
            if let nearest = valid.min(by: { left, right in
                let difference = abs(left - target) - abs(right - target)
                return abs(difference) < 0.000_000_001 ? left > right : difference < 0
            }) {
                return ResolvedFrameBoundary(sourceTime: nearest, minimumClipDuration: minimum)
            }
        }
        throw FrameBoundaryError.noInteriorFrame
    }

    private func readPresentationTimes(
        asset: AVURLAsset,
        track: AVAssetTrack,
        start: Double,
        end: Double
    ) throws -> [Double] {
        guard end > start else {
            return []
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 60_000),
            end: CMTime(seconds: end, preferredTimescale: 60_000)
        )
        guard reader.startReading() else {
            throw reader.error ?? FrameBoundaryError.readerFailed
        }
        defer {
            reader.cancelReading()
        }
        var stamps: [Double] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            // Compressed output also yields marker-only buffers. They are not video frames.
            for index in 0..<buffer.numSamples {
                let stamp =
                    (try? buffer.sampleTimingInfo(at: index).presentationTimeStamp)
                    ?? buffer.presentationTimeStamp
                let time = stamp.seconds
                if time.isFinite, time >= start, time <= end {
                    stamps.append(time)
                }
            }
        }
        if reader.status == .failed {
            throw reader.error ?? FrameBoundaryError.readerFailed
        }
        return stamps
    }
}
