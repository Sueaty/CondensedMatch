import XCTest
import AVFoundation
import UIKit
@testable import RallyCut

final class MediaTests: XCTestCase {
    @MainActor
    func testDenseFilmstripFinishesVisibleDemandAndRetainsImagesAfterCacheEviction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await makeVideo(
            in: directory,
            presentationTimes: (0...150).map {
                CMTime(value: Int64($0), timescale: 5)
            })
        let clips = (0..<150).map {
            EditorClip(sourceStart: Double($0) / 5, sourceEnd: Double($0 + 1) / 5)
        }
        let editor = try EditorState(sourceDuration: 30, clips: clips)
        let tiles = EditorTimelineLayout.tiles(
            for: editor, pointsPerSecond: 3, tileDuration: 32, visibleRange: 0...30)
        let strip = TimelineFilmstripView(frame: CGRect(x: 0, y: 0, width: 393, height: 76))
        let provider = TimelineThumbnailProvider(source: source)
        defer {
            provider.stop()
            strip.reset()
        }
        provider.onChange = {
            strip.update(tiles: tiles, clips: clips, provider: provider, inset: 0, scale: 3)
            provider.request(tiles.map(\.sourceTime))
        }
        provider.request(tiles.map(\.sourceTime))
        let deadline = Date().addingTimeInterval(15)
        while provider.cachedImage(at: 29.8) == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(provider.cachedImage(at: 29.8))
        XCTAssertNil(provider.cachedImage(at: 0), "The decoded cache must remain bounded")
        let images = strip.subviews.compactMap { $0 as? UIImageView }
        XCTAssertEqual(images.count, 150)
        XCTAssertTrue(images.allSatisfy { $0.image != nil })
        let requests = provider.generationCount
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(
            provider.generationCount, requests, "Eviction must not restart completed visible demand")
    }

    func testSplitResolverAndCommitShareActualFrameMinimumDespiteNominalRateMismatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await makeVideo(in: directory)
        let resolver = VideoFrameBoundaryResolver()
        let short = try EditorState(sourceDuration: 1.0 / 30)
        do {
            _ = try await resolver.splitBoundary(
                in: source, editor: short, at: 1.0 / 60, fallbackFrameRate: 120)
            XCTFail("A one-frame clip cannot be split using a shorter nominal frame duration")
        } catch {
            XCTAssertEqual(error as? EditorCoreError, .clipTooShort)
        }
        var twoFrames = try EditorState(sourceDuration: 10.0 / 30)
        let boundary = try await resolver.splitBoundary(
            in: source, editor: twoFrames, at: 5.0 / 30, fallbackFrameRate: 1)
        XCTAssertEqual(boundary.minimumClipDuration, 0.15, accuracy: 0.000_001)
        XCTAssertTrue(
            twoFrames.canSplit(
                atEditTime: boundary.sourceTime, minimumClipDuration: boundary.minimumClipDuration))
        try twoFrames.split(
            atEditTime: boundary.sourceTime, minimumClipDuration: boundary.minimumClipDuration)
        XCTAssertEqual(twoFrames.includedClips.count, 2)
    }

    func testCompressedReaderMarkersCannotBecomeInventedSplitBoundaries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await makeVideo(
            in: directory,
            presentationTimes: [0, 1, 300, 600].map {
                CMTime(value: Int64($0), timescale: 30)
            })
        let resolver = VideoFrameBoundaryResolver()
        do {
            _ = try await resolver.nearestBoundary(
                in: source, to: 5, clipStart: 2, clipEnd: 9, fallbackFrameRate: 30)
            XCTFail("Reader range markers are not source video frames")
        } catch {
            guard case FrameBoundaryError.noInteriorFrame = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testThumbnailDemandCoalescesAndPinchReusesFramesWithoutDecoding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await makeVideo(in: directory)
        let provider = TimelineThumbnailProvider(source: source)
        defer {
            provider.stop()
        }
        // Hundreds of obsolete visible lists must collapse into the last demand before decoding.
        for step in 0..<500 {
            provider.request([Double(step % 30) / 10])
        }
        provider.request([0])
        let initialDeadline = Date().addingTimeInterval(5)
        while provider.cachedImage(at: 0) == nil && Date() < initialDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(provider.cachedImage(at: 0))
        XCTAssertEqual(provider.generationCount, 1)

        let strip = TimelineFilmstripView(frame: CGRect(x: 0, y: 0, width: 393, height: 76))
        let editor = try EditorState(sourceDuration: 14_400)
        for step in 0..<1000 {
            let scale = EditorTimelineZoom.scale(
                startingAt: 3, magnification: pow(160, Double(step % 100) / 99))
            let tiles = EditorTimelineLayout.tiles(
                for: editor, pointsPerSecond: scale,
                tileDuration: EditorTimelineZoom.thumbnailDuration(scale: scale),
                visibleRange: (7200 - 196.5 / scale)...(7200 + 196.5 / scale))
            provider.request(tiles.map(\.sourceTime), suspended: true)
            strip.update(
                tiles: tiles, clips: editor.includedClips, provider: provider,
                inset: 196.5 - 7200 * scale, scale: scale)
            XCTAssertLessThanOrEqual(strip.subviews.count, 8)
            XCTAssertTrue(
                strip.subviews.compactMap { $0 as? UIImageView }.allSatisfy {
                    $0.image != nil && $0.bounds.width <= 121
                })
            if step.isMultiple(of: 100) {
                await Task.yield()
            }
        }
        XCTAssertEqual(provider.generationCount, 1, "Pinch changes must reuse decoded frames")
        provider.request([1, 1, 2, 2])
        let deadline = Date().addingTimeInterval(5)
        while provider.cachedImage(at: 2) == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(provider.cachedImage(at: 1))
        XCTAssertNotNil(provider.cachedImage(at: 2))
        XCTAssertEqual(provider.generationCount, 3)
        provider.stop()
        provider.request([3])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(provider.generationCount, 3)
    }

    @MainActor
    func testFilmstripKeepsBothCutsVisibleAroundSubsecondClipAfterSplitAndUndoRedo() throws {
        var editor = try EditorState(sourceDuration: 60)
        try editor.split(atEditTime: 10, minimumClipDuration: 1.0 / 30)
        let firstCutID = try XCTUnwrap(editor.includedClips.last?.id)
        try editor.split(atEditTime: 10.9, minimumClipDuration: 1.0 / 30)
        let secondCutID = try XCTUnwrap(editor.includedClips.last?.id)
        let strip = TimelineFilmstripView(frame: CGRect(x: 0, y: 0, width: 393, height: 76))
        func render() {
            let tiles = EditorTimelineLayout.tiles(
                for: editor, pointsPerSecond: 90, tileDuration: 1, visibleRange: 8...13)
            strip.update(
                tiles: tiles, clips: editor.includedClips, provider: nil,
                inset: 196.5 - 10.9 * 90, scale: 90)
        }
        func boundary(_ id: UUID) -> UIView? {
            strip.subviews.first {
                $0.accessibilityIdentifier == "editor-clip-boundary-\(id)"
            }
        }
        render()
        XCTAssertEqual(editor.includedClips.count, 3)
        XCTAssertEqual(editor.includedClips[1].duration, 0.9, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(boundary(firstCutID)).frame.minX, 115.5, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(boundary(secondCutID)).frame.minX, 196.5, accuracy: 0.5)
        XCTAssertEqual(strip.subviews.last, boundary(secondCutID))

        try editor.select(editor.includedClips[0].id)
        render()
        XCTAssertNotNil(boundary(firstCutID))
        XCTAssertNotNil(boundary(secondCutID))
        editor.undo()
        render()
        XCTAssertNotNil(boundary(firstCutID))
        XCTAssertNil(boundary(secondCutID))
        editor.redo()
        render()
        XCTAssertNotNil(boundary(firstCutID))
        XCTAssertNotNil(boundary(secondCutID))
    }

    func testSplitUsesVFRPresentationTimesInsteadOfNominalFPSGrid() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let ticks: [Int64] = [0, 12, 31, 58, 92, 140, 190]
        let source = try await makeVideo(
            in: directory,
            presentationTimes: ticks.map {
                CMTime(value: $0, timescale: 100)
            })
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let resolver = VideoFrameBoundaryResolver()
        let boundary = try await resolver.nearestBoundary(
            in: source, to: 0.78, clipStart: 0, clipEnd: duration, fallbackFrameRate: 30
        )
        XCTAssertEqual(boundary.sourceTime, 0.92, accuracy: 0.001)
        XCTAssertNotEqual(boundary.sourceTime, (0.78 * 30).rounded() / 30, accuracy: 0.001)
        let tie = try await resolver.nearestBoundary(
            in: source, to: 0.75, clipStart: 0, clipEnd: duration, fallbackFrameRate: 30
        )
        XCTAssertEqual(tie.sourceTime, 0.92, accuracy: 0.001)
        var edit = try EditorState(sourceDuration: duration)
        try edit.split(atEditTime: boundary.sourceTime, minimumClipDuration: boundary.minimumClipDuration)
        XCTAssertEqual(edit.includedClips.count, 2)
        XCTAssertEqual(edit.includedClips[0].sourceEnd, 0.92, accuracy: 0.001)
        XCTAssertEqual(edit.includedClips[1].sourceStart, 0.92, accuracy: 0.001)
    }

    @MainActor
    func testEditorSplitExcludeAndScrubKeepCompositionGapFree() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await makeVideo(in: directory)
        let store = AppStore(root: directory.appendingPathComponent("projects"))
        let importedID = await store.importURL(source)
        let id = try XCTUnwrap(importedID)
        let firstSplit = await store.updateEditor(id) {
            try $0.split(atEditTime: 1, minimumClipDuration: 1.0 / 30)
        }
        let secondSplit = await store.updateEditor(id) {
            try $0.split(atEditTime: 2, minimumClipDuration: 1.0 / 30)
        }
        XCTAssertTrue(firstSplit)
        XCTAssertTrue(secondSplit)
        let afterSplit = try XCTUnwrap(store.project(id))
        XCTAssertEqual(afterSplit.editorState?.includedClips.count, 3)
        XCTAssertEqual(afterSplit.condensedDuration, afterSplit.source.duration, accuracy: 0.001)
        let middleID = try XCTUnwrap(afterSplit.editorState?.includedClips[1].id)
        let excluded = await store.updateEditor(id) {
            try $0.select(middleID)
            try $0.excludeSelected()
        }
        XCTAssertTrue(excluded)
        let edited = try XCTUnwrap(store.project(id))
        XCTAssertEqual(edited.editorState?.includedClips.count, 2)
        XCTAssertEqual(edited.condensedDuration, edited.source.duration - 1, accuracy: 0.001)

        let composition = try await CompositionBuilder.build(source: store.sourceURL(edited), project: edited)
        let duration = try await composition.load(.duration)
        XCTAssertEqual(duration.seconds, edited.condensedDuration, accuracy: 0.001)
        let video = try await firstTrack(composition, .video)
        let sourceSegments = try await video.load(.segments)
        XCTAssertEqual(sourceSegments.count, 2)
        let generator = AVAssetImageGenerator(asset: composition)
        for time in [0.5, 1.1, edited.condensedDuration - 0.2] {
            let (frame, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
            XCTAssertGreaterThan(frame.width, 0)
        }

        let playback = EditorPlayback()
        playback.start()
        try await playback.prepare(project: edited, source: store.sourceURL(edited))
        playback.scrub(to: 1.5)
        let deadline = Date().addingTimeInterval(5)
        while abs(playback.player.currentTime().seconds - 1.5) > 0.15 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(playback.player.currentTime().seconds, 1.5, accuracy: 0.15)
        playback.stop()
    }

    func testImportCompositionExportAndSourcePreservation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await makeVideo(in: directory)
        let original = try Data(contentsOf: source)
        let repository = directory.appendingPathComponent("projects")
        var project = try await SourceAssetStore().importVideo(at: source, root: repository)
        XCTAssertGreaterThan(project.source.duration, 3)
        XCTAssertFalse(project.source.hasAudio)
        XCTAssertEqual(project.segments.count, 1)
        XCTAssertEqual(project.segments.first?.sourceStart, 0)
        XCTAssertEqual(project.segments.first?.sourceEnd, project.source.duration)
        XCTAssertEqual(project.condensedDuration, project.source.duration)
        project.segments = [.init(start: 2, end: 3), .init(start: 0, end: 1), .init(start: 0.5, end: 1.5)]
        project.editorState = try EditorState.fromSegments(
            project.segments, sourceDuration: project.source.duration)
        let folder = repository.appendingPathComponent(project.id.uuidString)
        let owned = folder.appendingPathComponent(project.source.filename)
        let composition = try await CompositionBuilder.build(source: owned, project: project)
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

    @MainActor
    func testImportThroughStoreIsImmediatelyPlayable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await makeVideo(in: directory)
        let store = AppStore(root: directory.appendingPathComponent("projects"))
        let importedID = await store.importURL(source)
        let id = try XCTUnwrap(importedID)
        let project = try XCTUnwrap(store.project(id))
        let item = AVPlayerItem(url: store.sourceURL(project))
        let playable = try await item.asset.load(.isPlayable)
        XCTAssertTrue(playable)
        XCTAssertEqual(project.segments.count, 1)
        let composition = try await CompositionBuilder.build(
            source: store.sourceURL(project), project: project)
        let duration = try await composition.load(.duration)
        XCTAssertEqual(duration.seconds, project.source.duration, accuracy: 0.001)

        await store.edit(id, segments: [.init(start: 1, end: 2)])
        let edited = try XCTUnwrap(store.project(id))
        XCTAssertEqual(edited.editorState?.includedClips.map(\.sourceStart), [1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(id).appendingPathComponent("project.json").path))
        store.endSession()
        XCTAssertNil(store.project(id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let reloaded = AppStore(root: store.root)
        XCTAssertNil(reloaded.activeProject)
    }

    @MainActor
    func testNewProcessRemovesLeftoverWorkingFilesAndRejectsEndedSessionUpdates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AppStore(root: directory)
        let source = SourceAssetReference(
            filename: "source.mov", duration: 10, width: 640, height: 360,
            frameRate: 30, hasAudio: false, byteCount: 3)
        let project = MatchProject(title: "Ended edit", source: source)
        let stale = store.folder(project.id)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: stale.appendingPathComponent(source.filename))
        let fresh = AppStore(root: directory)
        XCTAssertNil(fresh.activeProject)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        fresh.endSession()
        let accepted = await fresh.updateProject(project)
        XCTAssertFalse(accepted)
        XCTAssertNil(fresh.activeProject)
    }

    func testMissingSourceAndZeroResultAreRecoverable() async throws {
        do {
            _ = try await CompositionBuilder.build(
                source: URL(fileURLWithPath: "/missing/fixture.mov"), segments: [], duration: 10)
            XCTFail("Expected unavailable source")
        } catch {
            XCTAssertTrue(error is MatchError)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await makeVideo(in: directory)
        do {
            _ = try await CompositionBuilder.build(source: source, segments: [], duration: 4)
            XCTFail("Expected empty timeline")
        } catch {
            XCTAssertTrue(error is MatchError)
        }
    }

    func testAudioAlignmentAndRotatedVideo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let videoURL = try await makeVideo(in: directory)
        let audioURL = directory.appendingPathComponent("tone.caf")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64_000),
            let channel = buffer.floatChannelData?[0]
        else {
            throw MatchError.invalidMedia("Unable to create audio fixture")
        }
        buffer.frameLength = 64_000
        for index in 0..<64_000 {
            channel[index] = Float(sin(Double(index) * 2 * .pi * 440 / 16_000) * 0.2)
        }
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            try file.write(from: buffer)
        }
        let sourceVideo = AVURLAsset(url: videoURL)
        let sourceAudio = AVURLAsset(url: audioURL)
        let video = try await firstTrack(sourceVideo, .video)
        let audio = try await firstTrack(sourceAudio, .audio)
        let composition = AVMutableComposition()
        let v = try XCTUnwrap(
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        )
        let a = try XCTUnwrap(
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        )
        let duration = try await sourceVideo.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        try v.insertTimeRange(range, of: video, at: .zero)
        try a.insertTimeRange(range, of: audio, at: .zero)
        v.preferredTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)
        let mux = try XCTUnwrap(
            AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        let muxURL = directory.appendingPathComponent("rotated.mov")
        try await mux.export(to: muxURL, as: .mov)
        let repository = directory.appendingPathComponent("projects")
        var project = try await SourceAssetStore().importVideo(at: muxURL, root: repository)
        XCTAssertTrue(project.source.hasAudio)
        XCTAssertEqual(project.source.width, 180)
        XCTAssertEqual(project.source.height, 320)
        project.segments = [.init(start: 0.5, end: 1.5), .init(start: 2, end: 3)]
        project.editorState = try EditorState.fromSegments(
            project.segments, sourceDuration: project.source.duration)
        let preview = try await CompositionBuilder.build(source: muxURL, project: project)
        let previewVideo = try await firstTrack(preview, .video)
        let previewAudio = try await firstTrack(preview, .audio)
        let vt = try await previewVideo.load(.timeRange)
        let at = try await previewAudio.load(.timeRange)
        XCTAssertEqual(vt.duration.seconds, at.duration.seconds, accuracy: 0.001)
        XCTAssertEqual(vt.start.seconds, at.start.seconds, accuracy: 0.001)
        let rotation = try await previewVideo.load(.preferredTransform)
        XCTAssertEqual(rotation, v.preferredTransform)
        let folder = repository.appendingPathComponent(project.id.uuidString)
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
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await makeVideo(in: directory)
        let repo = directory.appendingPathComponent("projects")
        var project = try await SourceAssetStore().importVideo(at: source, root: repo)
        project.segments = [.init(start: 0, end: 2)]
        project.editorState = try EditorState.fromSegments(
            project.segments, sourceDuration: project.source.duration)
        let exporter = ExportService()
        let snapshot = project
        let task = Task {
            try await exporter.export(project: snapshot, source: source, folder: directory)
        }
        while !exporter.isRunning {
            await Task.yield()
        }
        exporter.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancelled export")
        } catch {
        }
        XCTAssertFalse(exporter.isRunning)
        let retry = try await exporter.export(project: project, source: source, folder: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retry.path))
    }

    @MainActor
    func testSeekStormStopAndReprepareKeepLatestPosition() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await makeVideo(in: directory)
        let store = AppStore(root: directory.appendingPathComponent("projects"))
        let imported = await store.importURL(source)
        let project = try XCTUnwrap(
            imported.flatMap {
                store.project($0)
            })
        let playback = EditorPlayback()
        playback.start()
        try await playback.prepare(project: project, source: store.sourceURL(project))
        playback.beginScrubbing()
        for step in 0..<200 {
            playback.scrub(to: Double(step % 37) / 10)
        }
        playback.endScrubbing(at: 2.7)
        try await waitForPlayback(playback, at: 2.7)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(playback.position, 2.7, accuracy: 0.000_001)

        playback.scrub(to: 3.5)
        playback.stop()
        playback.start()
        try await playback.prepare(project: project, source: store.sourceURL(project))
        playback.scrub(to: 1.2)
        try await waitForPlayback(playback, at: 1.2)
        XCTAssertTrue(playback.isReady)
        XCTAssertEqual(playback.position, 1.2, accuracy: 0.000_001)
        playback.stop()
    }

    @MainActor
    func testVFRTrimCompositionExportAndRestorationUseSameSourceRanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await makeVideo(
            in: directory,
            presentationTimes: [0, 12, 31, 58, 92, 140, 190].map {
                CMTime(value: Int64($0), timescale: 100)
            })
        let store = AppStore(root: directory.appendingPathComponent("projects"))
        let imported = await store.importURL(source)
        let id = try XCTUnwrap(imported)
        var project = try XCTUnwrap(store.project(id))
        let originalDuration = project.condensedDuration
        let clip = try XCTUnwrap(project.editorState?.includedClips.first)
        let resolver = VideoFrameBoundaryResolver()
        let start = try await resolver.trimBoundary(
            in: source, to: 0.78, clip: clip, edge: .start, fallbackFrameRate: 30)
        XCTAssertEqual(start.sourceTime, 0.92, accuracy: 0.001)
        let trimmed = await store.updateEditor(id) {
            try $0.trim(
                clip.id, edge: .start, toSourceTime: start.sourceTime,
                minimumClipDuration: start.minimumClipDuration)
        }
        XCTAssertTrue(trimmed)
        project = try XCTUnwrap(store.project(id))
        let composition = try await CompositionBuilder.build(
            source: store.sourceURL(project), project: project)
        let track = try await firstTrack(composition, .video)
        let segments = try await track.load(.segments)
        XCTAssertEqual(try XCTUnwrap(segments.first).timeMapping.source.start.seconds, 0.92, accuracy: 0.001)
        XCTAssertEqual(project.condensedDuration, originalDuration - 0.92, accuracy: 0.001)
        let output = try await ExportService().export(
            project: project, source: store.sourceURL(project), folder: directory)
        let exportedDuration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(exportedDuration, project.condensedDuration, accuracy: 0.05)
        let restored = await store.updateEditor(id) {
            $0.undo()
        }
        XCTAssertTrue(restored)
        XCTAssertEqual(try XCTUnwrap(store.project(id)).condensedDuration, originalDuration, accuracy: 0.001)
    }

    func testFrameResolverRoundsMinimumDurationToActualSourceFrames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await makeVideo(in: directory)
        let resolver = VideoFrameBoundaryResolver()
        for candidate in [5.0 / 30, 6.0 / 30] {
            let boundary = try await resolver.nearestBoundary(
                in: source, to: candidate, clipStart: 0, clipEnd: 11.0 / 30, fallbackFrameRate: 30)
            XCTAssertEqual(boundary.sourceTime, candidate, accuracy: 0.000_001)
            XCTAssertGreaterThanOrEqual(boundary.sourceTime, 0.15)
            XCTAssertGreaterThanOrEqual(11.0 / 30 - boundary.sourceTime, 0.15)
        }
        do {
            _ = try await resolver.nearestBoundary(
                in: source, to: 0.15, clipStart: 0, clipEnd: 0.3, fallbackFrameRate: 30)
            XCTFail("Nine source frames at 30fps cannot form two clips of at least 0.15 seconds")
        } catch {
            guard case FrameBoundaryError.noInteriorFrame = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testExactlyPointFifteenSecondsIsAllowedAtSixtyFPS() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try await makeVideo(
            in: directory,
            presentationTimes: (0..<120).map {
                CMTime(value: Int64($0), timescale: 60)
            })
        var editor = try EditorState(sourceDuration: 0.3)
        let resolver = VideoFrameBoundaryResolver()
        let boundary = try await resolver.splitBoundary(
            in: source, editor: editor, at: 0.15, fallbackFrameRate: 60)
        try editor.split(atEditTime: boundary.sourceTime, minimumClipDuration: boundary.minimumClipDuration)
        XCTAssertEqual(editor.includedClips.count, 2)
        XCTAssertEqual(editor.includedClips[0].duration, 0.15, accuracy: 0.000_001)
        XCTAssertEqual(editor.includedClips[1].duration, 0.15, accuracy: 0.000_001)
    }

    @MainActor
    private func waitForPlayback(_ playback: EditorPlayback, at time: Double) async throws {
        let deadline = Date().addingTimeInterval(5)
        while (!playback.isReady || abs(playback.player.currentTime().seconds - time) > 0.034)
            && Date() < deadline
        {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(playback.isReady)
        XCTAssertEqual(playback.player.currentTime().seconds, time, accuracy: 0.034)
    }

    private func firstTrack(_ asset: AVAsset, _ type: AVMediaType) async throws -> AVAssetTrack {
        let tracks = try await asset.loadTracks(withMediaType: type)
        return try XCTUnwrap(tracks.first)
    }

    private func makeVideo(in directory: URL, presentationTimes: [CMTime]? = nil) async throws -> URL {
        let url = directory.appendingPathComponent("fixture.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ])
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? MatchError.invalidMedia("Fixture writer failed")
        }
        writer.startSession(atSourceTime: .zero)
        let times =
            presentationTimes
            ?? (0..<120).map {
                CMTime(value: Int64($0), timescale: 30)
            }
        for (frame, presentationTime) in times.enumerated() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            var pixelBuffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
                let pixelBuffer
            else {
                throw MatchError.invalidMedia("Fixture allocation failed")
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer), width: 320, height: 180, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
            {
                context.setFillColor(red: 0.12, green: 0.3, blue: 0.22, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
                context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
                context.stroke(CGRect(x: 50, y: 15, width: 220, height: 150))
                context.setFillColor(red: 0.85, green: 1, blue: 0.3, alpha: 1)
                context.fillEllipse(in: CGRect(x: 60 + (frame * 3) % 180, y: 60, width: 30, height: 30))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? MatchError.invalidMedia("Fixture append failed")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? MatchError.invalidMedia("Fixture could not finish")
        }
        return url
    }
}
