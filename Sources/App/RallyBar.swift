import RallyKit
import SwiftUI

enum RallyBarState: Equatable {
    case idle
    /// Find rallies was tapped before the video check finished.
    case checking
    /// The video check rejected this video. Find rallies stays disabled.
    case rejected
    case done(rallies: Int, toCheck: Int)
}

struct RallyBar: View {
    static let height: CGFloat = 44

    let state: RallyBarState
    var onFind: () -> Void = {}
    var onReview: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            icon

            Text(title)
                .typography(.body)
                .fontWeight(.medium)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            action
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: Self.height)
        .foregroundStyle(foreground)
        .background(isDark ? MatchColor.ink : .white)
        .overlay {
            if !isDark {
                Capsule()
                    .strokeBorder(MatchColor.line, lineWidth: state == .rejected ? 1.5 : 1)
            }
        }
        .clipShape(Capsule())
        .overlay {
            // Idle and checking share this branch so the glow does not restart between them.
            if hasBorderBeam {
                RallyBarBorderBeam()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rally-bar")
    }

    private var isDark: Bool {
        if case .done = state {
            return true
        }
        return false
    }

    private var hasBorderBeam: Bool {
        state == .idle || state == .checking
    }

    private var foreground: Color {
        switch state {
        case .idle, .checking:
            return MatchColor.ink
        case .rejected:
            return MatchColor.muted
        case .done:
            return .white
        }
    }

    private var title: String {
        switch state {
        case .idle, .rejected:
            return "Auto-find every rally"
        case .checking:
            return "Checking this video…"
        case .done(let rallies, let toCheck):
            return toCheck > 0 ? "\(rallies) rallies · \(toCheck) to check" : "\(rallies) rallies"
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .idle, .rejected:
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .medium))
        case .checking:
            ProgressView()
                .controlSize(.small)
                .tint(MatchColor.ink)
        case .done:
            Image(systemName: "tennisball.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(MatchColor.lime)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .idle:
            RallyBarActionButton(
                title: "Find rallies",
                action: onFind
            )
            .accessibilityIdentifier("rally-bar-find")
        case .checking:
            RallyBarActionButton(
                title: "Checking",
                showsChevron: false,
                isEnabled: false,
                action: {}
            )
            .accessibilityIdentifier("rally-bar-checking")
        case .rejected:
            RallyBarActionButton(
                title: "Find rallies",
                isEnabled: false,
                action: onFind
            )
            .accessibilityIdentifier("rally-bar-find")
        case .done:
            RallyBarActionButton(
                title: "Review",
                action: onReview
            )
            .accessibilityIdentifier("rally-bar-review")
        }
    }
}

private struct RallyBarActionButton: View {
    let title: String
    var showsChevron = true
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .typography(.body)
                    .fontWeight(.semibold)

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundStyle(isEnabled ? MatchColor.ink : MatchColor.ink.opacity(0.4))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                isEnabled ? MatchColor.lime : Color(uiColor: .tertiarySystemFill),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

extension RallyRejection {
    var alertTitle: String {
        switch self {
        case .lowFrameRate(let frameRate):
            return "This video is \(Int(frameRate.rounded())) fps"
        case .cameraTooClose:
            return "The camera is too close"
        }
    }

    var alertMessage: String {
        let reason: String
        switch self {
        case .lowFrameRate:
            reason = "Rally finding works on videos filmed at 30 fps or more."
        case .cameraTooClose:
            reason = "To find rallies, the whole court needs to be in view. Next time, film from 2–3 m behind the baseline, up high."
        }
        return reason + "\n\nYou can still edit this video by hand. No free find was used."
    }
}

/// A lime highlight that runs clockwise around the bar's border once at a constant speed,
/// then settles into a soft, steady glow around the whole border.
private struct RallyBarBorderBeam: View {
    private enum Phase {
        case waiting
        case lap(start: Date)
        case resting
    }

    private static let lapDuration: TimeInterval = 1.5
    private static let tailLength = 0.35
    private static let segmentCount = 28
    private static let lineWidth: CGFloat = 2.5
    private static let glowWidth: CGFloat = 7
    private static let restingLineWidth: CGFloat = 1.5
    private static let tail = MatchColor.lime
    private static let head = Color(red: 0.88, green: 1.0, blue: 0.45)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = Phase.waiting

    var body: some View {
        ZStack {
            switch phase {
            case .waiting:
                EmptyView()
            case .lap(let start):
                TimelineView(.animation) { context in
                    let elapsed = context.date.timeIntervalSince(start)
                    let headPosition = min(1, elapsed / Self.lapDuration)

                    ZStack {
                        beam(headPosition: headPosition, lineWidth: Self.glowWidth)
                            .blur(radius: 6)
                            .opacity(0.9)

                        beam(headPosition: headPosition, lineWidth: Self.lineWidth)
                    }
                }
                .transition(.opacity)
            case .resting:
                restingGlow
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            guard !reduceMotion else {
                phase = .resting
                return
            }
            phase = .lap(start: .now)
            try? await Task.sleep(for: .seconds(Self.lapDuration))
            guard !Task.isCancelled else {
                return
            }
            withAnimation(.easeInOut(duration: 0.6)) {
                phase = .resting
            }
        }
    }

    private var restingGlow: some View {
        ZStack {
            Capsule()
                .inset(by: Self.lineWidth / 2)
                .stroke(Self.tail, lineWidth: Self.glowWidth)
                .blur(radius: 6)
                .opacity(0.45)

            Capsule()
                .strokeBorder(Self.tail, lineWidth: Self.restingLineWidth)
        }
    }

    /// Draws the tail as short slices along the border. Trimming is measured by path length,
    /// so the head moves the same distance every frame on the straight edges and the rounded ends.
    private func beam(headPosition: Double, lineWidth: CGFloat) -> some View {
        let sliceLength = Self.tailLength / Double(Self.segmentCount)
        return ZStack {
            ForEach(0..<Self.segmentCount, id: \.self) { index in
                let strength = Double(index + 1) / Double(Self.segmentCount)
                let end = headPosition - Self.tailLength + sliceLength * Double(index + 1)
                let start = end - sliceLength
                let color = strength > 0.85 ? Self.head : Self.tail

                BorderSlice(start: start, end: end, inset: Self.lineWidth / 2)
                    .stroke(
                        color.opacity(strength * strength),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                    )
            }
        }
    }
}

/// A piece of the capsule border between two fractions of its length, wrapping past the start point.
private struct BorderSlice: Shape {
    let start: Double
    let end: Double
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let border = Capsule()
            .inset(by: inset)
            .path(in: rect)
        let from = start - floor(start)
        let to = from + (end - start)
        guard to > 1 else {
            return border.trimmedPath(from: from, to: to)
        }
        var path = border.trimmedPath(from: from, to: 1)
        path.addPath(border.trimmedPath(from: 0, to: to - 1))
        return path
    }
}

#Preview {
    VStack(spacing: 12) {
        RallyBar(state: .idle)

        RallyBar(state: .checking)

        RallyBar(state: .rejected)

        RallyBar(state: .done(rallies: 18, toCheck: 3))
    }
    .padding(16)
    .background(MatchColor.paper)
}
