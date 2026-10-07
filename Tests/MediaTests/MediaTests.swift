import XCTest
import AVFoundation
@testable import RallyCut

final class MediaTests: XCTestCase {
    func testImportCompositionExportAndSourcePreservation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeVideo(in: directory)
        let original = try Data(contentsOf: source)
        let repository = try ProjectRepository(root: directory.appendingPathComponent("projects"))
        var project = try await SourceAssetStore().importVideo(at: source, repository: repository)
        XCTAssertGreaterThan(project.source.duration, 3)
        XCTAssertFalse(project.source.hasAudio)
        project.segments = [.init(start: 2, end: 3), .init(start: 0, end: 1), .init(start: 0.5, end: 1.5)]
        let folder = try await repository.directory(for: project.id)
        let owned = folder.appendingPathComponent(project.source.filename)
        let composition = try await CompositionBuilder.build(source: owned, segments: project.segments, duration: project.source.duration)
        let duration = try await composition.load(.duration)
        XCTAssertEqual(duration.seconds, 2.5, accuracy: 0.01)
        let tracks = try await composition.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let transform = try await tracks[0].load(.preferredTransform)
        XCTAssertEqual(transform, .identity)
        let exporter = await ExportService()
        let result = try await exporter.export(project: project, source: owned, folder: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        let exported = AVURLAsset(url: result)
        let exportedDuration = try await exported.load(.duration)
        XCTAssertEqual(exportedDuration.seconds, 2.5, accuracy: 0.15)
        let generator = AVAssetImageGenerator(asset: exported)
        for position in [0.0, 1.45, 1.55, 2.4] {
            let (image, _) = try await generator.image(at: CMTime(seconds: position, preferredTimescale: 600))
            XCTAssertGreaterThan(image.width, 0)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: owned), original)
    }

    func testSilentAnalysisCheckpointResumeAndCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeVideo(in: directory)
        let repository = try ProjectRepository(root: directory.appendingPathComponent("projects"))
        var project = try await SourceAssetStore().importVideo(at: source, repository: repository)
        let engine = AnalysisCoordinator()
        let full = try await engine.analyze(project: project, source: source) { _ in }
        XCTAssertEqual(full.0.stage, .complete)
        XCTAssertFalse(full.0.visual.isEmpty)
        var record = full.0
        record.stage = .video; record.completedAt = nil
        record.visual = Array(record.visual.prefix(2)); record.warnings = []
        project.analysis = record
        let resumed = try await engine.analyze(project: project, source: source) { _ in }
        XCTAssertEqual(resumed.0.visual, full.0.visual)
        let cancelledProject = project
        let task = Task { try await engine.analyze(project: cancelledProject, source: source) { _ in try Task.checkCancellation() } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testMissingSourceAndZeroResultAreRecoverable() async throws {
        do {
            _ = try await CompositionBuilder.build(source: URL(fileURLWithPath: "/missing/fixture.mov"), segments: [], duration: 10)
            XCTFail("Expected unavailable source")
        } catch { XCTAssertTrue(error is MatchError) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeVideo(in: directory)
        do { _ = try await CompositionBuilder.build(source: source, segments: [], duration: 4); XCTFail("Expected empty timeline") }
        catch { XCTAssertTrue(error is MatchError) }
    }

    func testAudioAlignmentRotatedVideoAndEnergyAnalysis() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let videoURL = try await makeVideo(in: directory)
        let audioURL = directory.appendingPathComponent("tone.caf")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64_000), let channel = buffer.floatChannelData?[0] else {
            throw MatchError.invalidMedia("Unable to create audio fixture")
        }
        buffer.frameLength = 64_000
        for index in 0..<64_000 { channel[index] = Float(sin(Double(index) * 2 * .pi * 440 / 16_000) * 0.2) }
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            try file.write(from: buffer)
        }
        let sourceVideo = AVURLAsset(url: videoURL)
        let sourceAudio = AVURLAsset(url: audioURL)
        let video = try await firstTrack(sourceVideo, .video)
        let audio = try await firstTrack(sourceAudio, .audio)
        let composition = AVMutableComposition()
        let v = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let a = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        let duration = try await sourceVideo.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        try v.insertTimeRange(range, of: video, at: .zero)
        try a.insertTimeRange(range, of: audio, at: .zero)
        v.preferredTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)
        let mux = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        let muxURL = directory.appendingPathComponent("rotated.mov")
        try await mux.export(to: muxURL, as: .mov)
        let repository = try ProjectRepository(root: directory.appendingPathComponent("projects"))
        var project = try await SourceAssetStore().importVideo(at: muxURL, repository: repository)
        XCTAssertTrue(project.source.hasAudio)
        XCTAssertEqual(project.source.width, 180)
        XCTAssertEqual(project.source.height, 320)
        let analysis = try await AnalysisCoordinator().analyze(project: project, source: muxURL) { _ in }
        XCTAssertFalse(analysis.0.audio.isEmpty)
        XCTAssertTrue(analysis.0.audio.allSatisfy { $0.value.isFinite && (0...1).contains($0.value) })
        project.segments = [.init(start: 0.5, end: 1.5), .init(start: 2, end: 3)]
        let preview = try await CompositionBuilder.build(source: muxURL, segments: project.segments, duration: project.source.duration)
        let previewVideo = try await firstTrack(preview, .video)
        let previewAudio = try await firstTrack(preview, .audio)
        let vt = try await previewVideo.load(.timeRange)
        let at = try await previewAudio.load(.timeRange)
        XCTAssertEqual(vt.duration.seconds, at.duration.seconds, accuracy: 0.001)
        XCTAssertEqual(vt.start.seconds, at.start.seconds, accuracy: 0.001)
        let rotation = try await previewVideo.load(.preferredTransform)
        XCTAssertEqual(rotation, v.preferredTransform)
        let folder = try await repository.directory(for: project.id)
        let exporter = await ExportService()
        let exported = try await exporter.export(project: project, source: muxURL, folder: folder)
        let output = AVURLAsset(url: exported)
        let outVideo = try await firstTrack(output, .video)
        let outputSize = try await outVideo.load(.naturalSize)
        let outputTransform = try await outVideo.load(.preferredTransform)
        let displaySize = outputSize.applying(outputTransform)
        XCTAssertLessThan(abs(displaySize.width), abs(displaySize.height))
        let outAudio = try await output.loadTracks(withMediaType: .audio)
        XCTAssertEqual(outAudio.count, 1)
    }

    @MainActor
    func testExportCanCancelWhilePreparingAndRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await makeVideo(in: directory)
        let repo = try ProjectRepository(root: directory.appendingPathComponent("projects"))
        var project = try await SourceAssetStore().importVideo(at: source, repository: repo)
        project.segments = [.init(start: 0, end: 2)]
        let exporter = ExportService()
        let snapshot = project
        let task = Task { try await exporter.export(project: snapshot, source: source, folder: directory) }
        while !exporter.isRunning { await Task.yield() }
        exporter.cancel()
        do { _ = try await task.value; XCTFail("Expected cancelled export") } catch {}
        XCTAssertFalse(exporter.isRunning)
        let retry = try await exporter.export(project: project, source: source, folder: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retry.path))
    }

    private func firstTrack(_ asset: AVAsset, _ type: AVMediaType) async throws -> AVAssetTrack {
        let tracks = try await asset.loadTracks(withMediaType: type)
        return try XCTUnwrap(tracks.first)
    }

    private func makeVideo(in directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("fixture.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MatchError.invalidMedia("Fixture writer failed") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<120 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var pixelBuffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
                  let pixelBuffer else { throw MatchError.invalidMedia("Fixture allocation failed") }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: 320, height: 180, bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                context.setFillColor(red: 0.12, green: 0.3, blue: 0.22, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
                context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1); context.stroke(CGRect(x: 50, y: 15, width: 220, height: 150))
                context.setFillColor(red: 0.85, green: 1, blue: 0.3, alpha: 1)
                context.fillEllipse(in: CGRect(x: 60 + (frame * 3) % 180, y: 60, width: 30, height: 30))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? MatchError.invalidMedia("Fixture append failed")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MatchError.invalidMedia("Fixture could not finish") }
        return url
    }
}
