#if DEBUG
    import AVFoundation
    import RallyKit

    /// Only invoked by the UI test launch environment, with an isolated temporary project root.
    enum EditorUITestFixture {
        static func delayFrameLookupIfRequested() async throws {
            let environment = ProcessInfo.processInfo.environment
            if environment["RALLYCUT_EDITOR_TEST_SESSION"] != nil,
                environment["RALLYCUT_EDITOR_TEST_DELAY_FRAME"] == "1"
            {
                try await Task.sleep(for: .seconds(4))
            }
        }

        @MainActor
        static func install(in store: AppStore) async throws {
            store.videoChecker = videoChecker()
            let usedFreeFinds = ProcessInfo.processInfo.environment["RALLYCUT_EDITOR_TEST_FREE_FINDS_USED"]
                .flatMap {
                    Int($0)
                } ?? 0
            for _ in 0..<usedFreeFinds {
                store.consumeFreeFind()
            }
            if let path = ProcessInfo.processInfo.environment["RALLYCUT_EDITOR_TEST_SOURCE"] {
                try await importSource(URL(fileURLWithPath: path), in: store)
                return
            }
            let source = store.root.appendingPathComponent("fixture.mov")
            let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: 640,
                    AVVideoHeightKey: 360,
                ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                    kCVPixelBufferWidthKey as String: 640,
                    kCVPixelBufferHeightKey as String: 360,
                    kCVPixelBufferCGImageCompatibilityKey as String: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                ])
            writer.add(input)
            guard writer.startWriting() else {
                throw writer.error ?? MatchError.invalidMedia("Test fixture writer failed")
            }
            writer.startSession(atSourceTime: .zero)
            for frame in 0..<1800 {
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(2))
                }
                var buffer: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool,
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                    let buffer
                else {
                    throw MatchError.invalidMedia("Test fixture allocation failed")
                }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let context = CGContext(
                    data: CVPixelBufferGetBaseAddress(buffer), width: 640, height: 360,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
                {
                    // Distinct opaque colors let UI tests detect missing filmstrip images.
                    context.setFillColor(red: 0.85, green: 0.08, blue: 0.12, alpha: 1)
                    context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
                    context.setFillColor(red: 0.08, green: 0.12, blue: 0.85, alpha: 1)
                    let x = (frame / 30).isMultiple(of: 2) ? 0 : 320
                    context.fill(CGRect(x: x, y: 0, width: 320, height: 360))
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30))
                else {
                    throw writer.error ?? MatchError.invalidMedia("Test fixture append failed")
                }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw writer.error ?? MatchError.invalidMedia("Test fixture import failed")
            }
            try await importSource(source, in: store)
        }

        /// `RALLYCUT_EDITOR_TEST_VIDEO_CHECK`: `lowFrameRate` or `cameraTooClose` rejects the video.
        /// `RALLYCUT_EDITOR_TEST_VIDEO_CHECK_DELAY`: seconds before the result arrives.
        private static func videoChecker() -> @Sendable (URL) async -> VideoCheckStatus {
            let environment = ProcessInfo.processInfo.environment
            let delay = environment["RALLYCUT_EDITOR_TEST_VIDEO_CHECK_DELAY"].flatMap(Double.init) ?? 0
            let status: VideoCheckStatus
            switch environment["RALLYCUT_EDITOR_TEST_VIDEO_CHECK"] {
            case "lowFrameRate":
                status = .rejected(.lowFrameRate(24))
            case "cameraTooClose":
                status = .rejected(.cameraTooClose(nearPlayerHeight: 0.4))
            default:
                status = .passed(nil)
            }
            return { _ in
                try? await Task.sleep(for: .seconds(delay))
                return status
            }
        }

        @MainActor
        private static func importSource(_ source: URL, in store: AppStore) async throws {
            guard let id = await store.importURL(source), var project = store.project(id) else {
                throw MatchError.invalidMedia("Test fixture import failed")
            }
            project.title = "Editor regression"
            if ProcessInfo.processInfo.environment["RALLYCUT_EDITOR_TEST_NEARBY_SPLIT"] == "1" {
                var editor = try EditorState(sourceDuration: project.source.duration)
                try editor.split(atEditTime: 10, minimumClipDuration: 1.0 / 30)
                try editor.setPlayhead(10.9)
                project.editorState = editor
                project.editorIsAuthoritative = true
            }
            if ProcessInfo.processInfo.environment["RALLYCUT_EDITOR_TEST_CLIP_LIMIT"] == "1" {
                let count = EditorState.maximumIncludedClipCount
                let duration = project.source.duration / Double(count)
                let clips = (0..<count).map { index in
                    EditorClip(sourceStart: Double(index) * duration, sourceEnd: Double(index + 1) * duration)
                }
                project.editorState = try EditorState(
                    sourceDuration: project.source.duration, clips: clips,
                    selectedClipID: clips[count / 2].id,
                    playheadTime: (Double(count / 2) + 0.5) * duration)
                project.editorIsAuthoritative = true
            }
            if ProcessInfo.processInfo.environment["RALLYCUT_EDITOR_TEST_SHORT_CLIP"] == "1" {
                let clip = EditorClip(sourceStart: 0, sourceEnd: 0.29)
                project.editorState = try EditorState(
                    sourceDuration: project.source.duration,
                    clips: [
                        clip,
                        EditorClip(sourceStart: 0.29, sourceEnd: project.source.duration, isIncluded: false),
                    ],
                    selectedClipID: clip.id, playheadTime: 0.145)
                project.editorIsAuthoritative = true
            }
            await store.updateProject(project)
        }
    }
#endif
