import SwiftUI
import AVFoundation

/// Owns the composition player; scrubbing coalesces seeks to the latest time.
@MainActor
@Observable
final class EditorPlayback {
    let player = AVPlayer()
    private(set) var position = 0.0
    private(set) var isPlaying = false
    private(set) var isPreparing = false
    private(set) var isReady = false
    private var timeObserver: Any?
    private var generation = 0
    private var pendingSeek: Double?
    private var seekInFlight = false
    private var duration = 0.0

    func start() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.timeObserver != nil, !self.seekInFlight,
                      self.pendingSeek == nil, time.seconds.isFinite else { return }
                self.position = min(self.duration, max(0, time.seconds))
                if self.isPlaying && self.position >= self.duration - 0.05 { self.isPlaying = false }
            }
        }
    }

    func prepare(project: MatchProject, source: URL) async throws {
        generation &+= 1
        let request = generation
        isPreparing = true
        isReady = false
        pause()
        duration = project.condensedDuration
        pendingSeek = nil
        position = min(project.editorState?.playheadTime ?? 0, duration)
        do {
            let composition = try await CompositionBuilder.build(source: source, project: project)
            guard request == generation else { return }
            let target = pendingSeek ?? position
            pendingSeek = nil
            seekInFlight = false
            player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
            isReady = true
            isPreparing = false
            scrub(to: target)
        } catch {
            if request == generation { isPreparing = false }
            throw error
        }
    }

    func scrub(to time: Double) {
        pause()
        let clamped = min(duration, max(0, time))
        position = clamped
        pendingSeek = clamped
        performPendingSeek()
    }

    private func performPendingSeek() {
        guard isReady, !seekInFlight, let target = pendingSeek else { return }
        pendingSeek = nil
        seekInFlight = true
        let request = generation
        let tolerance = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 60_000),
            toleranceBefore: tolerance, toleranceAfter: tolerance
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, request == self.generation else { return }
                self.seekInFlight = false
                self.performPendingSeek()
            }
        }
    }

    func togglePlayback() {
        guard isReady else { return }
        if isPlaying { pause() }
        else {
            if position >= duration - 0.05 { scrub(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func stop() {
        generation &+= 1
        pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.replaceCurrentItem(with: nil)
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
        view.playerLayer.player = player
    }
}

final class PlayerSurfaceView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
