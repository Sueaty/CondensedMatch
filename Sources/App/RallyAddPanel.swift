import SwiftUI

/// 4B: marks a rally the search missed. Replaces the rally list while it is open.
struct RallyAddPanel: View {
    let review: RallyReview
    let preview: RallyPreviewPlayer
    let frames: RallyFrameLoader
    /// Where the new rally starts, once marked.
    let markedStart: Double?
    let onMarkStart: () -> Void
    let onRemarkStart: () -> Void
    let onMarkEnd: () -> Void
    let onCancel: () -> Void

    @State private var window: ClosedRange<Double>?

    /// The strip shows this much before and after where playback is.
    private static let reach = 120.0
    private static let frameCount = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            banner

            if let window {
                Text(RallyTime.clock(window.lowerBound) + " – " + RallyTime.clock(window.upperBound))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(MatchColor.muted)

                strip(window: window)
            }

            HStack(spacing: 10) {
                RallyPlayButton(preview: preview)

                Text(RallyTime.precise(preview.position))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .accessibilityIdentifier("rally-add-time")

                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(MatchColor.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            actions

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rally-add-panel")
        .onAppear {
            recenter(on: preview.position)
        }
        .onChange(of: preview.position) { _, position in
            guard let window else {
                return
            }
            // Follow playback once it nears either end of the strip.
            let margin = (window.upperBound - window.lowerBound) * 0.1
            if position < window.lowerBound + margin && window.lowerBound > 0
                || position > window.upperBound - margin && window.upperBound < review.sourceDuration
            {
                recenter(on: position)
            }
        }
    }

    private var banner: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(MatchColor.lime)

            Text(markedStart == nil ? "Adding a rally — play to where it starts" : "Adding a rally — play to where it ends")
                .font(.footnote)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onCancel()
            } label: {
                Text("Cancel")
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .foregroundStyle(MatchColor.lime)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("rally-add-cancel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(MatchColor.ink, in: RoundedRectangle(cornerRadius: 14))
    }

    private var hint: String {
        guard let markedStart else {
            return "Play or drag to where the rally starts"
        }
        let soFar = max(0, preview.position - markedStart)
        return "Start set at \(RallyTime.clock(markedStart)) · \(RallyTime.short(soFar)) so far"
    }

    private var canMarkEnd: Bool {
        guard let markedStart else {
            return false
        }
        return preview.position - markedStart >= RallyReview.minimumDuration
    }

    @ViewBuilder
    private var actions: some View {
        if markedStart == nil {
            markButton("Start rally here", systemImage: "flag", id: "rally-add-start", isEnabled: true) {
                onMarkStart()
            }
        } else {
            HStack(spacing: 10) {
                Button {
                    onRemarkStart()
                } label: {
                    Label("Re-mark start", systemImage: "arrow.counterclockwise")
                        .typography(.body)
                        .fontWeight(.medium)
                        .padding(.horizontal, 18)
                        .frame(height: 48)
                        .background(MatchColor.ink.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("rally-add-remark")

                markButton("End rally here", systemImage: "flag.checkered", id: "rally-add-end", isEnabled: canMarkEnd) {
                    onMarkEnd()
                }
            }
        }
    }

    private func markButton(
        _ title: String, systemImage: String, id: String, isEnabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .typography(.body)
                .fontWeight(.bold)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(MatchColor.lime, in: Capsule())
                .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier(id)
    }

    private func recenter(on time: Double) {
        let duration = review.sourceDuration
        let lower = max(0, min(time - Self.reach, duration - Self.reach * 2))
        let range = lower...min(duration, lower + Self.reach * 2)
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

    private func strip(window: ClosedRange<Double>) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let span = max(0.001, window.upperBound - window.lowerBound)
            let x = { (time: Double) -> CGFloat in
                CGFloat((time - window.lowerBound) / span) * width
            }
            let visible = review.rallies.filter {
                $0.end > window.lowerBound && $0.start < window.upperBound
            }

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

                ForEach(downtime(in: window, rallies: visible), id: \.lowerBound) { gap in
                    Rectangle()
                        .fill(MatchColor.paper.opacity(0.85))
                        .frame(width: max(0, x(gap.upperBound) - x(gap.lowerBound)))
                        .offset(x: x(gap.lowerBound))
                }

                ForEach(visible) { rally in
                    let left = max(0, x(rally.start))
                    let right = min(width, x(rally.end))
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(rally.needsReview ? MatchColor.amber : MatchColor.lime, lineWidth: 2)
                        .frame(width: max(0, right - left))
                        .offset(x: left)

                    if right - left > 22 {
                        Text(rally.isAdded ? "+" : "\(rally.id)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(MatchColor.ink)
                            .padding(.horizontal, 4)
                            .frame(height: 16)
                            .background(MatchColor.lime, in: RoundedRectangle(cornerRadius: 4))
                            .offset(x: left + 3, y: 3)
                    }
                }

                if let markedStart, window.contains(markedStart) {
                    let startX = x(markedStart)
                    let endX = min(width, max(startX, x(preview.position)))
                    Rectangle()
                        .fill(.white.opacity(0.35))
                        .overlay {
                            Rectangle()
                                .strokeBorder(.white, lineWidth: 2)
                        }
                        .frame(width: endX - startX)
                        .offset(x: startX)

                    Text("NEW")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(MatchColor.ink)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 4))
                        .offset(x: startX + 3, y: 3)

                    Rectangle()
                        .fill(MatchColor.ink)
                        .frame(width: 2)
                        .offset(x: startX - 1)
                }

                if window.contains(preview.position) {
                    Rectangle()
                        .fill(.white)
                        .frame(width: 2)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .offset(x: x(preview.position) - 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                // Tap or drag anywhere on the strip to move there.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(0, value.location.x / width), 1)
                        preview.scrub(to: window.lowerBound + Double(fraction) * span)
                    }
            )
        }
        .frame(height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement()
        .accessibilityLabel("Video position")
        .accessibilityValue(RallyTime.precise(preview.position))
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 1.0 : -1.0
            preview.scrub(to: min(max(0, preview.position + delta), review.sourceDuration))
        }
        .accessibilityIdentifier("rally-add-strip")
    }

    /// Stretches of the strip outside every rally, dimmed like the inline trim.
    private func downtime(in window: ClosedRange<Double>, rallies: [ReviewRally]) -> [ClosedRange<Double>] {
        var gaps: [ClosedRange<Double>] = []
        var cursor = window.lowerBound
        for rally in rallies.sorted(by: { $0.start < $1.start }) {
            if rally.start > cursor {
                gaps.append(cursor...rally.start)
            }
            cursor = max(cursor, rally.end)
        }
        if cursor < window.upperBound {
            gaps.append(cursor...window.upperBound)
        }
        return gaps
    }
}

/// The dark round play button used by the expanded rally and the add panel.
struct RallyPlayButton: View {
    let preview: RallyPreviewPlayer
    var isEnabled = true

    var body: some View {
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
        .disabled(!isEnabled)
        .accessibilityLabel(preview.isPlaying ? "Pause rally" : "Play rally")
        .accessibilityIdentifier("rally-preview-play")
    }
}
