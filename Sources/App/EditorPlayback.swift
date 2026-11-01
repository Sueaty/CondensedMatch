import SwiftUI
import AVFoundation

/// Serializes seeks and ignores callbacks belonging to a replaced player item.
@MainActor
@Observable
final class EditorPlayback {
    let player = AVPlayer()
    private(set) var position = 0.0
    private(set) var isPlaying = false
    private(set) var isPreparing = false
    private(set) var isReady = false
    private(set) var interactionRevision: UInt64 = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var generation: UInt64 = 0
    private var pendingSeek: Double?
    private var seekInFlight = false
    private var isBuilding = false
    private var isScrubbing = false
    private var duration = 0.0
    private var observing = false

    func start() {
        observing = true
        installObservers()
    }

    private func installObservers() {
        removeObservers()
        guard observing else {
            return
        }
        let request = generation
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, request == self.generation, self.observing,
                    self.isPlaying, !self.isScrubbing, !self.seekInFlight,
                    self.pendingSeek == nil, time.seconds.isFinite
                else {
                    return
                }
                self.position = min(self.duration, max(0, time.seconds))
            }
        }
        if let item = player.currentItem {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, request == self.generation, self.isPlaying,
                        !self.seekInFlight, self.pendingSeek == nil
                    else {
                        return
                    }
                    self.pause()
                    self.position = self.duration
                }
            }
        }
    }

    private func removeObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        timeObserver = nil
        endObserver = nil
    }

    private func reset(duration: Double, position: Double) {
        generation &+= 1
        interactionRevision &+= 1
        pause()
        player.currentItem?.cancelPendingSeeks()
        pendingSeek = nil
        seekInFlight = false
        isScrubbing = false
        isReady = false
        isPreparing = true
        self.duration = duration
        self.position = min(duration, max(0, position))
    }

    func prepare(project: MatchProject, source: URL) async throws {
        reset(duration: project.condensedDuration, position: project.editorState?.playheadTime ?? 0)
        let request = generation
        isBuilding = true
        do {
            let composition = try await CompositionBuilder.build(source: source, project: project)
            try Task.checkCancellation()
            guard request == generation else {
                return
            }
            isBuilding = false
            player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
            installObservers()
            pendingSeek = pendingSeek ?? position
            performPendingSeek()
        } catch {
            guard request == generation else {
                return
            }
            isBuilding = false
            isPreparing = false
            if !Task.isCancelled {
                throw error
            }
        }
    }

    func beginScrubbing() {
        interactionRevision &+= 1
        isScrubbing = true
        pause()
    }

    func endScrubbing(at time: Double) {
        scrub(to: time)
        isScrubbing = false
    }

    func scrub(to time: Double) {
        guard time.isFinite else {
            return
        }
        interactionRevision &+= 1
        pause()
        position = min(duration, max(0, time))
        pendingSeek = position
        performPendingSeek()
    }

    private func performPendingSeek() {
        guard !isBuilding, player.currentItem != nil, !seekInFlight, let target = pendingSeek else {
            return
        }
        pendingSeek = nil
        seekInFlight = true
        let request = generation
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 60_000),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, request == self.generation else {
                    return
                }
                self.seekInFlight = false
                if self.pendingSeek != nil {
                    self.performPendingSeek()
                } else {
                    self.isPreparing = false
                    self.isReady = finished
                    if self.isPlaying && finished {
                        self.player.play()
                    }
                }
            }
        }
    }

    func togglePlayback() {
        guard isReady, !isScrubbing else {
            return
        }
        if isPlaying {
            pause()
        } else {
            if position >= duration {
                scrub(to: 0)
            }
            isPlaying = true
            if !seekInFlight && pendingSeek == nil {
                player.play()
            }
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func stop() {
        generation &+= 1
        interactionRevision &+= 1
        pause()
        observing = false
        removeObservers()
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
        pendingSeek = nil
        seekInFlight = false
        isBuilding = false
        isScrubbing = false
        isReady = false
        isPreparing = false
    }
}

/// AVPlayerLayer only displays video; SwiftUI owns transport and edit controls.
struct EditorVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerSurfaceView {
        let view = PlayerSurfaceView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerSurfaceView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    static func dismantleUIView(_ view: PlayerSurfaceView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

final class PlayerSurfaceView: UIView {
    override static var layerClass: AnyClass {
        AVPlayerLayer.self
    }
    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}
