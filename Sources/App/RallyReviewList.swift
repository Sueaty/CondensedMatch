import AVFoundation
import RallyKit
import SwiftUI

/// What the rally list asks the editor to do.
enum RallyReviewAction {
    case setChecked(ReviewRally.ID, Bool)
    case moveStart(ReviewRally.ID, by: Double)
    case moveEnd(ReviewRally.ID, by: Double)
    case setEdges(ReviewRally.ID, start: Double, end: Double, moving: RallyReview.Edge)
    case reset(ReviewRally.ID)
    case remove(ReviewRally.ID)
}

/// Loads small still frames from the source video, one at a time, and keeps them.
@MainActor
@Observable
final class RallyFrameLoader {
    private(set) var images: [Int: UIImage] = [:]
    private let generator: AVAssetImageGenerator
    private var queue: [Int] = []
    private var task: Task<Void, Never>?

    init(source: URL) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
    }

    func image(at time: Double) -> UIImage? {
        images[Self.key(time)]
    }

    func request(_ times: [Double]) {
        let keys = times
            .map(Self.key)
            .filter {
                images[$0] == nil && !queue.contains($0)
            }
        guard !keys.isEmpty else {
            return
        }
        queue.append(contentsOf: keys)
        guard task == nil else {
            return
        }
        task = Task { [weak self] in
            while let self, !Task.isCancelled, !self.queue.isEmpty {
                let key = self.queue.removeFirst()
                let time = CMTime(seconds: Double(key) / 10, preferredTimescale: 600)
                if let image = try? await self.generator.image(at: time).image {
                    self.images[key] = UIImage(cgImage: image)
                }
            }
            self?.task = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        queue.removeAll()
    }

    private static func key(_ time: Double) -> Int {
        Int((time * 10).rounded())
    }
}

/// Plays one rally straight from the source video, so rallies left out of the edit can be seen too.
@MainActor
@Observable
final class RallyPreviewPlayer {
    let player = AVPlayer()
    /// Seconds in the source video.
    private(set) var position = 0.0
    private(set) var isPlaying = false
    private var range: ClosedRange<Double> = 0...0
    private var timeObserver: Any?
    private var pendingSeek: Double?
    private var seekInFlight = false

    init(source: URL) {
        player.replaceCurrentItem(with: AVPlayerItem(url: source))
        player.actionAtItemEnd = .pause
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.observe(time.seconds)
            }
        }
    }

    /// Shows a rally paused at its start.
    func show(start: Double, end: Double) {
        pause()
        range = start...end
        seek(to: start)
    }

    /// Follows trimmed edges without interrupting playback.
    func updateRange(start: Double, end: Double) {
        range = start...end
        if !isPlaying {
            seek(to: start)
        }
    }

    /// Plays from the rally's start to its end once.
    func togglePlayback() {
        if isPlaying {
            pause()
            return
        }
        if position < range.lowerBound || position >= range.upperBound - 0.05 {
            seek(to: range.lowerBound)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    /// Shows the frame at a dragged edge.
    func scrub(to time: Double) {
        pause()
        seek(to: time)
    }

    func stop() {
        pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    private func observe(_ seconds: Double) {
        guard seconds.isFinite, !seekInFlight else {
            return
        }
        position = seconds
        if isPlaying && seconds >= range.upperBound {
            pause()
        }
    }

    private func seek(to time: Double) {
        position = time
        pendingSeek = time
        performPendingSeek()
    }

    private func performPendingSeek() {
        guard !seekInFlight, let target = pendingSeek else {
            return
        }
        pendingSeek = nil
        seekInFlight = true
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.seekInFlight = false
                self?.performPendingSeek()
            }
        }
    }
}

/// Stage 4: found rallies grouped into "check these" and "rallies", each expandable to trim.
struct RallyReviewList: View {
    let review: RallyReview
    let notes: [RallyFramingNote]
    let frames: RallyFrameLoader
    /// Plays the expanded rally in the preview.
    let preview: RallyPreviewPlayer
    let isEnabled: Bool
    @Binding var expandedID: ReviewRally.ID?
    let onDismissNotes: () -> Void
    let onAction: (RallyReviewAction) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if let note = notes.first {
                        FramingNoteBanner(text: note.bannerText, onDismiss: onDismissNotes)
                    }

                    if !review.toReview.isEmpty {
                        groupHeader(title: "Check these", count: review.toReview.count, dot: MatchColor.amber)

                        ForEach(review.toReview) { rally in
                            row(rally)
                        }
                    }

                    if !review.confident.isEmpty {
                        groupHeader(title: "Rallies", count: review.confident.count, dot: MatchColor.lime)

                        ForEach(review.confident) { rally in
                            row(rally)
                        }
                    }
                }
                .disabled(!isEnabled)
            }
            .scrollIndicators(.hidden)
            .onChange(of: expandedID) { _, id in
                if let id {
                    withAnimation {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .accessibilityIdentifier("rally-list")
    }

    private func groupHeader(title: String, count: Int, dot: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dot)
                .frame(width: 8, height: 8)

            Text(title.uppercased())
                .font(.caption)
                .fontWeight(.bold)
                .tracking(0.6)

            Text("\(count)")
                .font(.caption)
        }
        .foregroundStyle(MatchColor.muted)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func row(_ rally: ReviewRally) -> some View {
        let isExpanded = expandedID == rally.id
        VStack(spacing: 12) {
            RallyRow(
                rally: rally,
                image: frames.image(at: rally.detectedStart),
                isExpanded: isExpanded,
                onToggleChecked: {
                    onAction(.setChecked(rally.id, !rally.isChecked))
                },
                onToggleExpanded: {
                    withAnimation(.snappy) {
                        expandedID = isExpanded ? nil : rally.id
                    }
                }
            )

            if isExpanded {
                InlineTrim(
                    rally: rally,
                    duration: review.sourceDuration,
                    frames: frames,
                    preview: preview,
                    onAction: onAction
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .background {
            if isExpanded {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.white)
                    .stroke(MatchColor.line, lineWidth: 1)
            }
        }
        .id(rally.id)
        .onAppear {
            frames.request([rally.detectedStart])
        }
    }
}

private struct FramingNoteBanner: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(MatchColor.amberIcon)

            Text(text)
                .font(.footnote)
                .foregroundStyle(MatchColor.amberText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(MatchColor.amberIcon)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("rally-note-dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(MatchColor.amberSoft, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rally-note")
    }
}

private struct RallyRow: View {
    let rally: ReviewRally
    let image: UIImage?
    let isExpanded: Bool
    let onToggleChecked: () -> Void
    let onToggleExpanded: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onToggleChecked()
            } label: {
                checkbox
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, -11)
            .accessibilityLabel("Rally \(rally.id)")
            .accessibilityValue(rally.isChecked ? "Included" : "Left out")
            .accessibilityIdentifier("rally-check-\(rally.id)")

            Button {
                onToggleExpanded()
            } label: {
                HStack(spacing: 12) {
                    thumbnail

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rally \(rally.id)")
                            .typography(.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(rally.isChecked ? MatchColor.ink : MatchColor.muted)

                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(rally.needsReview ? MatchColor.amberInk : MatchColor.muted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Collapses the trim controls" : "Shows trim controls")
            .accessibilityIdentifier("rally-row-\(rally.id)")

            Button {
                onToggleExpanded()
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(MatchColor.muted)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var checkbox: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(rally.isChecked ? MatchColor.ink : .clear)
            .strokeBorder(rally.isChecked ? .clear : MatchColor.muted.opacity(0.5), lineWidth: 1.5)
            .frame(width: 22, height: 22)
            .overlay {
                if rally.isChecked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(MatchColor.lime)
                }
            }
    }

    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(MatchColor.ink.opacity(0.15))
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                if rally.needsReview {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(MatchColor.amber, lineWidth: 2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text(RallyTime.short(rally.duration))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    .padding(3)
            }
            .frame(width: 64, height: 40)
    }

    private var subtitle: String {
        let start = RallyTime.clock(rally.start)
        if rally.needsReview {
            return start + " · Very short — a point?"
        }
        let text = start + " · " + RallyTime.short(rally.duration)
        return rally.isEdited ? text + " · edited" : text
    }
}

/// The expanded rally's trim area: a short strip around the rally with draggable edges and ±1 s buttons.
private struct InlineTrim: View {
    let rally: ReviewRally
    let duration: Double
    let frames: RallyFrameLoader
    let preview: RallyPreviewPlayer
    let onAction: (RallyReviewAction) -> Void

    @State private var dragEdges: (start: Double, end: Double)?
    @State private var window: ClosedRange<Double>?

    private static let frameCount = 6
    private static let stripSpace = "rally-trim-strip"

    var body: some View {
        let edges = dragEdges ?? (rally.start, rally.end)
        VStack(spacing: 10) {
            strip(edges: edges)

            HStack(spacing: 10) {
                Button {
                    preview.togglePlayback()
                } label: {
                    Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(MatchColor.lime)
                        .frame(width: 32, height: 32)
                        .background(MatchColor.ink, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, -6)
                .padding(.vertical, -6)
                .disabled(dragEdges != nil)
                .accessibilityLabel(preview.isPlaying ? "Pause rally" : "Play rally")
                .accessibilityIdentifier("rally-preview-play")

                Text(elapsedLabel(edges: edges))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .accessibilityIdentifier("rally-preview-time")

                Spacer(minLength: 8)

                if let was = wasLabel(edges: edges) {
                    Text(was)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(MatchColor.muted)
                        .accessibilityIdentifier("rally-trim-was")
                }
            }

            HStack {
                Button {
                    onAction(.reset(rally.id))
                } label: {
                    Label("Reset to detected", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .foregroundStyle(MatchColor.muted)
                .disabled(!rally.isEdited)
                .accessibilityIdentifier("rally-trim-reset")

                Spacer()

                Button {
                    onAction(.remove(rally.id))
                } label: {
                    Text("Not a rally")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(MatchColor.danger)
                .accessibilityIdentifier("rally-not-a-rally")
            }
            .buttonStyle(.plain)
        }
        .onAppear {
            updateWindow()
        }
        .onChange(of: rally) {
            if dragEdges == nil {
                updateWindow()
            }
        }
    }

    /// "0:03.1 / 0:13.4": how far the preview is into the rally, and the rally's length.
    private func elapsedLabel(edges: (start: Double, end: Double)) -> String {
        let length = edges.end - edges.start
        let elapsed = min(max(0, preview.position - edges.start), length)
        return RallyTime.precise(elapsed) + " / " + RallyTime.precise(length)
    }

    private func wasLabel(edges: (start: Double, end: Double)) -> String? {
        let isEdited = abs(edges.start - rally.detectedStart) > 0.000_001
            || abs(edges.end - rally.detectedEnd) > 0.000_001
        return isEdited ? "was " + RallyTime.precise(rally.detectedDuration) : nil
    }

    /// The strip shows a little before and after the rally, wide enough for both the detected and trimmed edges.
    private func updateWindow() {
        let lower = min(rally.start, rally.detectedStart)
        let upper = max(rally.end, rally.detectedEnd)
        let padding = max(3, (upper - lower) * 0.35)
        let range = max(0, lower - padding)...min(duration, upper + padding)
        guard range != window else {
            return
        }
        window = range
        frames.request(frameTimes(in: range))
    }

    private func frameTimes(in range: ClosedRange<Double>) -> [Double] {
        let step = (range.upperBound - range.lowerBound) / Double(Self.frameCount)
        return (0..<Self.frameCount).map {
            range.lowerBound + step * (Double($0) + 0.5)
        }
    }

    @ViewBuilder
    private func strip(edges: (start: Double, end: Double)) -> some View {
        if let window {
            GeometryReader { proxy in
                let width = proxy.size.width
                let span = window.upperBound - window.lowerBound
                let x = { (time: Double) -> CGFloat in
                    CGFloat((time - window.lowerBound) / span) * width
                }
                let startX = x(edges.start)
                let endX = x(edges.end)

                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(frameTimes(in: window), id: \.self) { time in
                            Rectangle()
                                .fill(MatchColor.ink.opacity(0.12))
                                .overlay {
                                    if let image = frames.image(at: time) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                    }
                                }
                                .clipped()
                        }
                    }

                    Rectangle()
                        .fill(MatchColor.paper.opacity(0.85))
                        .frame(width: max(0, startX))

                    Rectangle()
                        .fill(MatchColor.paper.opacity(0.85))
                        .frame(width: max(0, width - endX))
                        .offset(x: endX)

                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(MatchColor.lime, lineWidth: 3)
                        .frame(width: max(0, endX - startX))
                        .offset(x: startX)

                    Text("\(rally.id)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(MatchColor.ink)
                        .padding(.horizontal, 4)
                        .frame(height: 16)
                        .background(MatchColor.lime, in: RoundedRectangle(cornerRadius: 4))
                        .offset(x: startX + 14, y: 4)

                    if window.contains(preview.position) {
                        Rectangle()
                            .fill(.white)
                            .frame(width: 2)
                            .shadow(color: .black.opacity(0.4), radius: 2)
                            .offset(x: x(preview.position) - 1)
                    }

                    handle(edge: .start, edges: edges, width: width, span: span)
                        .offset(x: startX - 6)

                    handle(edge: .end, edges: edges, width: width, span: span)
                        .offset(x: endX - 6)
                }
            }
            .coordinateSpace(.named(Self.stripSpace))
            .frame(height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("rally-trim-strip")
        }
    }

    private func handle(
        edge: RallyReview.Edge, edges: (start: Double, end: Double), width: CGFloat, span: Double
    ) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(MatchColor.lime)
            .frame(width: 12)
            .overlay {
                RoundedRectangle(cornerRadius: 1)
                    .fill(MatchColor.ink)
                    .frame(width: 2, height: 18)
            }
            .contentShape(Rectangle().inset(by: -10))
            .gesture(
                // Measured in the strip's space: the handle itself moves with the finger.
                DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.stripSpace))
                    .onChanged { value in
                        let delta = Double(value.translation.width / width) * span
                        let snapped = (delta * 10).rounded() / 10
                        let start = edge == .start ? rally.start + snapped : rally.start
                        let end = edge == .end ? rally.end + snapped : rally.end
                        let clamped = RallyReview.clampedEdges(
                            start: start, end: end, duration: duration, moving: edge)
                        dragEdges = clamped
                        preview.scrub(to: edge == .start ? clamped.start : clamped.end)
                    }
                    .onEnded { _ in
                        if let dragEdges {
                            onAction(.setEdges(rally.id, start: dragEdges.start, end: dragEdges.end, moving: edge))
                        }
                        dragEdges = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(edge == .start ? "Rally start" : "Rally end")
            .accessibilityValue(RallyTime.precise(edge == .start ? edges.start : edges.end))
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 0.5 : -0.5
                onAction(edge == .start ? .moveStart(rally.id, by: delta) : .moveEnd(rally.id, by: delta))
            }
    }
}

/// Times in the rally list. All values are seconds in the source video.
enum RallyTime {
    /// "12:47", or "1:02:47" past an hour.
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        if hours > 0 {
            return "\(hours):" + String(format: "%02d:%02d", minutes, rest)
        }
        return "\(minutes):" + String(format: "%02d", rest)
    }

    /// "0:09" for a rally's length.
    static func short(_ seconds: Double) -> String {
        clock(seconds.rounded())
    }

    /// "12:58.2" for trim edges and lengths.
    static func precise(_ seconds: Double) -> String {
        let tenths = Int((seconds * 10).rounded())
        return clock(Double(tenths / 10)) + ".\(tenths % 10)"
    }
}

extension RallyFramingNote {
    var bannerText: String {
        switch self {
        case .nearPlayerOftenMissing:
            return "The near player was often out of frame, so a few rallies may be missing or cut short."
        case .farPlayersWeak:
            return "The far player was hard to see, so a few rallies may be missing."
        case .littlePlayAudio:
            return "Few ball hits could be heard, so a few rallies may be missing."
        }
    }
}
