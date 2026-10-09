import AVFoundation
import CoreGraphics
import Vision

struct AnalysisUpdate: Sendable {
    var record: AnalysisRecord
    var progress: Double
}

/// Heuristic features, not a racket-hit classifier. All results require review.
actor AnalysisCoordinator {
    func analyze(
        project: MatchProject, source: URL,
        checkpoint: @Sendable (AnalysisUpdate) async throws -> Void
    ) async throws -> (AnalysisRecord, [PointSegment]) {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw MatchError.missingSource
        }
        var record = project.analysis ?? AnalysisRecord()
        if record.stage == .complete {
            record = AnalysisRecord()
        }
        let duration = project.source.duration
        if record.stage == .preparing || record.stage == .audio {
            record.stage = .audio
            try await checkpoint(.init(record: record, progress: 0.02))
            if project.source.hasAudio {
                record = try await analyzeAudio(
                    source, duration: duration, record: record, checkpoint: checkpoint)
            }
            record.stage = .video
            try await checkpoint(.init(record: record, progress: 0.35))
        }
        if record.stage == .video {
            record = try await analyzeVisual(
                source, region: project.courtRegion, duration: duration, record: record,
                checkpoint: checkpoint)
            record.stage = .generating
            try await checkpoint(.init(record: record, progress: 0.95))
        }
        try Task.checkCancellation()
        let fused = ObservationFusion.combine(
            audio: record.audio, visual: record.visual, hasAudio: project.source.hasAudio)
        let segments = PointSegmenter.generate(fused, duration: duration)
        record.warnings.append(
            "Experimental detection uses sound energy and court movement, not a trained tennis classifier. All possible points need review."
        )
        if segments.isEmpty {
            record.warnings.append(
                "No possible points found. You can still add segments manually from the full video.")
        }
        record.stage = .complete
        record.completedAt = Date()
        return (record, segments)
    }

    private func analyzeAudio(
        _ url: URL, duration: Double, record initial: AnalysisRecord,
        checkpoint: @Sendable (AnalysisUpdate) async throws -> Void
    ) async throws -> AnalysisRecord {
        var record = initial
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return record
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MatchError.invalidMedia("Audio cannot be decoded. Use manual editing for this recording.")
        }
        reader.add(output)
        let resumeAt = (record.audio.last?.time ?? -1) + 1
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: resumeAt, preferredTimescale: 16_000),
            end: CMTime(seconds: duration, preferredTimescale: 16_000))
        guard reader.startReading() else {
            throw reader.error ?? MatchError.invalidMedia("Audio reading failed.")
        }
        defer {
            reader.cancelReading()
        }
        var bucket = Int(resumeAt)
        var sum = 0.0
        var count = 0
        var peak = 0.0
        func flush() {
            if count > 0 {
                let rms = sqrt(sum / Double(count))
                let energy = min(1, max(0, (20 * log10(max(rms, 0.000001)) + 55) / 40))
                let transient = min(1, peak / max(rms * 8, 0.03))
                record.audio.append(.init(time: Double(bucket), value: energy * 0.55 + transient * 0.45))
            }
            sum = 0
            count = 0
            peak = 0
        }
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else {
                continue
            }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            let length = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = floats.withUnsafeMutableBytes { bytes in

                guard let address = bytes.baseAddress else {
                    return OSStatus(-1)
                }
                return CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: length, destination: address)
            }
            guard status == kCMBlockBufferNoErr else {
                throw MatchError.invalidMedia("An audio sample could not be read.")
            }
            for (index, sample) in floats.enumerated() {
                let second = Int(time + Double(index) / 16_000)
                if second != bucket {
                    flush()
                    bucket = second
                    if record.audio.count.isMultiple(of: 15) {
                        try await checkpoint(
                            .init(record: record, progress: 0.02 + 0.33 * min(1, Double(second) / duration)))
                    }
                }
                let value = abs(Double(sample))
                if value.isFinite {
                    sum += value * value
                    peak = max(peak, value)
                    count += 1
                }
            }
        }
        if reader.status == .failed {
            throw reader.error ?? MatchError.invalidMedia("Audio decoding stopped unexpectedly.")
        }
        flush()
        return record
    }

    private func analyzeVisual(
        _ url: URL, region: NormalizedRect, duration: Double, record initial: AnalysisRecord,
        checkpoint: @Sendable (AnalysisUpdate) async throws -> Void
    ) async throws -> AnalysisRecord {
        var record = initial
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 144)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        defer {
            generator.cancelAllCGImageGeneration()
        }
        var previous: [UInt8]?
        var previousPose: [String: CGPoint]?
        let poseRequest = VNDetectHumanBodyPoseRequest()
        let next = Int((record.visual.last?.time ?? -1) + 1)
        // Re-read one frame for a continuous motion comparison at a checkpoint boundary.
        let start = max(0, next - 1)
        var broadMotion = 0
        for second in start..<Int(ceil(duration)) {
            try Task.checkCancellation()
            let (frame, _) = try await generator.image(
                at: CMTime(seconds: Double(second), preferredTimescale: 600))
            let pixels = try Self.grayscale(frame)
            let currentPose = Self.posePoints(frame, request: poseRequest)
            let poseMotion = Self.poseMotion(previous: previousPose, current: currentPose)
            if second >= next {
                var difference = 0.0
                var outsideDifference = 0.0
                var insideCount = 0
                var outsideCount = 0
                if let previous {
                    for y in 0..<72 {
                        for x in 0..<128 {
                            let delta =
                                Double(abs(Int(pixels[y * 128 + x]) - Int(previous[y * 128 + x]))) / 255
                            let nx = Double(x) / 128, ny = Double(y) / 72
                            if nx >= region.x && nx <= region.x + region.width && ny >= region.y
                                && ny <= region.y + region.height
                            {
                                difference += delta
                                insideCount += 1
                            } else {
                                outsideDifference += delta
                                outsideCount += 1
                            }
                        }
                    }
                }
                let inside = difference / Double(max(1, insideCount))
                let outside = outsideDifference / Double(max(1, outsideCount))
                if outside > 0.07 {
                    broadMotion += 1
                }
                // Pose velocity supplements pixel motion. It is intentionally a
                // feature, not a claim that a person is playing tennis.
                let pixelActivity = (inside - outside * 0.35) * 18
                let activity = min(1, max(0, max(pixelActivity, poseMotion * 10)))
                record.visual.append(.init(time: Double(second), value: activity))
                if second.isMultiple(of: 15) {
                    try await checkpoint(
                        .init(record: record, progress: 0.35 + 0.60 * Double(second) / duration))
                }
            }
            previous = pixels
            previousPose = currentPose
        }
        // Absolute frame differences vary substantially by phone, lighting, and codec.
        // Normalize against this recording's own low/high activity instead of treating
        // compression noise as a tennis point.
        let raw = record.visual.map(\.value)
        if !raw.isEmpty {
            let sorted = raw.sorted()
            let baseline = sorted[Int(Double(sorted.count - 1) * 0.25)]
            let high = sorted[Int(Double(sorted.count - 1) * 0.90)]
            let spread = high - baseline
            if spread > 0.01 {
                record.visual = record.visual.map { sample in

                    ActivitySample(
                        time: sample.time, value: min(1, max(0, (sample.value - baseline) / spread)))
                }
            } else {
                record.warnings.append(
                    "Court motion was nearly constant. Review manually or choose a tighter court region.")
                record.visual = record.visual.map {
                    ActivitySample(time: $0.time, value: 0)
                }
            }
        }
        if broadMotion > max(5, Int(duration * 0.15)) {
            record.warnings.append(
                "Movement outside the court may indicate a moving camera. Check possible points against the original."
            )
        }
        return record
    }

    private static func posePoints(_ image: CGImage, request: VNDetectHumanBodyPoseRequest) -> [String:
        CGPoint]
    {
        do {
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            try handler.perform([request])
            // The standard 2D pose observation does not expose a box. Vision orders
            // observations by salience, so use the first stable person for this
            // behind-the-baseline camera setup.
            guard let observation = request.results?.first else {
                return [:]
            }
            let joints: [VNHumanBodyPoseObservation.JointName] = [
                .leftWrist, .rightWrist, .leftElbow, .rightElbow,
                .leftShoulder, .rightShoulder, .leftHip, .rightHip,
                .leftKnee, .rightKnee, .leftAnkle, .rightAnkle,
            ]
            var points: [String: CGPoint] = [:]
            for joint in joints {
                if let point = try? observation.recognizedPoint(joint), point.confidence >= 0.25 {
                    points[String(describing: joint)] = point.location
                }
            }
            return points
        } catch {
            return [:]
        }
    }

    private static func poseMotion(previous: [String: CGPoint]?, current: [String: CGPoint]) -> Double {
        guard let previous, !current.isEmpty else {
            return 0
        }
        let distances = current.compactMap {
            key, point -> Double? in

            guard let old = previous[key] else {
                return nil
            }
            return min(1, hypot(Double(point.x - old.x), Double(point.y - old.y)))
        }
        guard !distances.isEmpty else {
            return 0
        }
        return distances.reduce(0, +) / Double(distances.count)
    }

    private static func grayscale(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 128 * 72)
        let success = pixels.withUnsafeMutableBytes {
            bytes -> Bool in

            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: 128, height: 72, bitsPerComponent: 8,
                    bytesPerRow: 128, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else {
                return false
            }
            // Match the top-left normalized coordinates shown in court setup.
            context.translateBy(x: 0, y: 72)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 72))
            return true
        }
        guard success else {
            throw MatchError.invalidMedia("Unable to inspect a video frame.")
        }
        return pixels
    }
}
