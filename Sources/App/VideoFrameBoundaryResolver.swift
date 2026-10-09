import AVFoundation

enum FrameBoundaryError: LocalizedError {
    case noVideoTrack
    case noInteriorFrame
    case readerFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The original video track is unavailable."
        case .noInteriorFrame: "Move the playhead farther inside the clip before splitting."
        case .readerFailed: "The video frame times could not be read. Try this clip again."
        }
    }
}

struct ResolvedFrameBoundary: Sendable {
    let sourceTime: Double
    let minimumClipDuration: Double
}

/// Reads nearby presentation timestamps instead of assuming a constant frame cadence.
actor VideoFrameBoundaryResolver {
    func nearestBoundary(
        in source: URL,
        to candidate: Double,
        clipStart: Double,
        clipEnd: Double,
        fallbackFrameRate: Double
    ) async throws -> ResolvedFrameBoundary {
        guard candidate.isFinite, clipStart.isFinite, clipEnd.isFinite,
              clipStart < candidate, candidate < clipEnd else {
            throw FrameBoundaryError.noInteriorFrame
        }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw FrameBoundaryError.noVideoTrack
        }
        let loadedMinimum = (try? await track.load(.minFrameDuration))?.seconds ?? .nan
        let fallbackMinimum = 1 / max(1, fallbackFrameRate)
        let minimum = loadedMinimum.isFinite && loadedMinimum > 0 ? loadedMinimum : fallbackMinimum
        guard clipEnd - clipStart > minimum * 2 else {
            throw FrameBoundaryError.noInteriorFrame
        }

        for radius in [0.5, 2.0, 8.0] {
            try Task.checkCancellation()
            let start = max(0, candidate - radius)
            let end = min(clipEnd, candidate + radius)
            let stamps = try readPresentationTimes(asset: asset, track: track, start: start, end: end)
            let valid = stamps.filter {
                $0 > clipStart + minimum && $0 < clipEnd - minimum
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

    private func readPresentationTimes(
        asset: AVURLAsset,
        track: AVAssetTrack,
        start: Double,
        end: Double
    ) throws -> [Double] {
        guard end > start else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 60_000),
            end: CMTime(seconds: end, preferredTimescale: 60_000)
        )
        guard reader.startReading() else { throw reader.error ?? FrameBoundaryError.readerFailed }
        var stamps: [Double] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            for index in 0..<max(1, buffer.numSamples) {
                let stamp = (try? buffer.sampleTimingInfo(at: index).presentationTimeStamp)
                    ?? buffer.presentationTimeStamp
                let time = stamp.seconds
                if time.isFinite, time >= start, time <= end { stamps.append(time) }
            }
        }
        if reader.status == .failed { throw reader.error ?? FrameBoundaryError.readerFailed }
        return stamps
    }
}
