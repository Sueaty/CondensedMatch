import AVFoundation
import UIKit
import Photos
import PhotosUI
import UniformTypeIdentifiers

enum StorageSpace {
    static func available(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
    static func require(_ bytes: Int64, at url: URL) throws {
        if let available = available(at: url), available < bytes {
            throw MatchError.storage
        }
    }
}

actor SourceAssetStore {
    func importVideo(at url: URL, root: URL) async throws -> MatchProject {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else {
            throw MatchError.invalidMedia(
                "This video cannot be played on this device. Try an H.264 or HEVC recording.")
        }
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw MatchError.invalidMedia("This file has no readable video. Choose another recording.")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration >= 1, duration <= 4 * 3600 else {
            throw MatchError.invalidMedia("Choose a video between 1 second and 4 hours long.")
        }
        let size = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let displaySize = size.applying(transform)
        let fps = Double(try await video.load(.nominalFrameRate))
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let bytes = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var imported = false
        defer {
            if !imported {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        try StorageSpace.require(bytes + 100_000_000, at: folder)
        let filename = "source." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        let destination = folder.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: url, to: destination)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destination.path)
        let source = SourceAssetReference(
            filename: filename, duration: duration,
            width: Int(abs(displaySize.width)), height: Int(abs(displaySize.height)),
            frameRate: fps > 0 ? fps : 30, hasAudio: !audio.isEmpty, byteCount: bytes)
        var project = MatchProject(
            id: id, title: "Match · " + Date().formatted(.dateTime.month(.abbreviated).day()), source: source)
        // Import opens a full-source edit.
        project.segments = [PointSegment(start: 0, end: duration)]
        if source.width > 3840 || source.height > 2160 {
            project.warnings.append(
                "Above 4K: this recording may take longer to process and has not been validated.")
        }
        if let free = StorageSpace.available(at: folder), free < 2_000_000_000 {
            project.warnings.append("Storage is running low. You may need to free space before exporting.")
        }
        imported = true
        return project
    }
}

enum CompositionBuilder {
    static func build(source: URL, project: MatchProject) async throws -> AVMutableComposition {
        if project.editorIsAuthoritative == true, let editor = project.editorState {
            let clips = editor.includedClips.map {
                PointSegment(start: $0.sourceStart, end: $0.sourceEnd)
            }
            return try await build(source: source, segments: clips, duration: project.source.duration)
        }
        return try await build(source: source, segments: project.segments, duration: project.source.duration)
    }
    static func build(source: URL, segments: [PointSegment], duration: Double) async throws
        -> AVMutableComposition
    {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw MatchError.missingSource
        }
        let ranges = Timeline.ranges(segments, duration: duration)
        guard !ranges.isEmpty else {
            throw MatchError.emptyTimeline
        }
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw MatchError.missingSource
        }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let composition = AVMutableComposition()
        guard
            let videoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw MatchError.invalidMedia("Unable to create a video timeline.")
        }
        videoTrack.preferredTransform = try await video.load(.preferredTransform)
        let audioTrack =
            audio == nil
            ? nil
            : composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let audioRange = try await audio?.load(.timeRange)
        var cursor = CMTime.zero
        for segment in ranges {
            try Task.checkCancellation()
            let range = CMTimeRange(
                start: CMTime(seconds: segment.sourceStart, preferredTimescale: 60_000),
                end: CMTime(seconds: segment.sourceEnd, preferredTimescale: 60_000))
            try videoTrack.insertTimeRange(range, of: video, at: cursor)
            if let audio, let audioTrack, let audioRange {
                let intersection = CMTimeRangeGetIntersection(range, otherRange: audioRange)
                if intersection.duration > .zero {
                    let offset = CMTimeSubtract(intersection.start, range.start)
                    try audioTrack.insertTimeRange(intersection, of: audio, at: CMTimeAdd(cursor, offset))
                }
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }
        return composition
    }
}

@MainActor
@Observable
final class ExportService {
    var progress = 0.0
    var isRunning = false
    private var session: AVAssetExportSession?
    private var cancellationRequested = false
    func cancel() {
        cancellationRequested = true
        session?.cancelExport()
    }
    func export(project: MatchProject, source: URL, folder: URL) async throws -> URL {
        guard !isRunning else {
            throw MatchError.invalidMedia("An export is already running.")
        }
        isRunning = true
        progress = 0
        cancellationRequested = false
        defer {
            isRunning = false
            session = nil
        }
        // High-quality export may exceed source bitrate; reserve a generous allowance.
        let estimate = Self.requiredSpace(project)
        try StorageSpace.require(estimate, at: folder)
        let composition = try await CompositionBuilder.build(source: source, project: project)
        guard !cancellationRequested else {
            throw CancellationError()
        }
        guard
            let exporter = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPresetHighestQuality)
        else {
            throw MatchError.invalidMedia("This video cannot be exported on this device.")
        }
        session = exporter
        let temporary = folder.appendingPathComponent("export-\(UUID().uuidString).partial.mp4")
        let final = folder.appendingPathComponent("Condensed-\(UUID().uuidString).mp4")
        let monitor = Task {
            [weak self] in

            while !Task.isCancelled {
                self?.progress = Double(exporter.progress)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer {
            monitor.cancel()
        }
        do {
            try await exporter.export(to: temporary, as: .mp4)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: temporary, to: final)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: final.path)
            progress = 1
            return final
        } catch {
            if FileManager.default.fileExists(atPath: temporary.path) {
                try? FileManager.default.removeItem(at: temporary)
            }
            throw error
        }
    }
    static func requiredSpace(_ project: MatchProject) -> Int64 {
        max(100_000_000, Int64(project.condensedDuration * 12_500_000) + 100_000_000)
    }
    func saveToPhotos(_ url: URL) async throws {
        let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard permission == .authorized || permission == .limited else {
            throw MatchError.invalidMedia(
                "Allow Photos access in Settings to save this video, or use Share to save it elsewhere.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
