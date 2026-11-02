import SwiftUI

enum RallyBarState: Equatable {
    case idle
    case scanning(progress: Double)
    case done(rallies: Int, toCheck: Int)
}

struct RallyBar: View {
    static let height: CGFloat = 44

    let state: RallyBarState
    var onFind: () -> Void = {}
    var onCancel: () -> Void = {}
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
        .foregroundStyle(isDark ? .white : MatchColor.ink)
        .background {
            background
        }
        .overlay {
            if state == .idle {
                Capsule()
                    .strokeBorder(MatchColor.line, lineWidth: 1)
            }
        }
        .clipShape(Capsule())
        .overlay {
            if state == .idle {
                RallyBarBorderBeam()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rally-bar")
    }

    private var isDark: Bool {
        state != .idle
    }

    private var title: String {
        switch state {
        case .idle:
            return "Auto-find every rally"
        case .scanning(let progress):
            return "Finding rallies… \(Int((progress * 100).rounded()))%"
        case .done(let rallies, let toCheck):
            return toCheck > 0 ? "\(rallies) rallies · \(toCheck) to check" : "\(rallies) rallies"
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .idle:
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .medium))
        case .scanning:
            ProgressView()
                .controlSize(.small)
                .tint(MatchColor.lime)
        case .done:
            Image(systemName: "tennisball.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(MatchColor.lime)
        }
    }

    @ViewBuilder
    private var background: some View {
        switch state {
        case .idle:
            Color.white
        case .scanning(let progress):
            GeometryReader { proxy in
                MatchColor.ink
                    .overlay(alignment: .leading) {
                        MatchColor.lime
                            .opacity(0.2)
                            .frame(width: proxy.size.width * min(1, max(0, progress)))
                    }
            }
        case .done:
            MatchColor.ink
        }
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .idle:
            RallyBarActionButton(
                title: "Find rallies",
                showsChevron: true,
                fill: MatchColor.lime,
                foreground: MatchColor.ink,
                action: onFind
            )
            .accessibilityIdentifier("rally-bar-find")
        case .scanning:
            RallyBarActionButton(
                title: "Cancel",
                showsChevron: false,
                fill: .white.opacity(0.12),
                foreground: .white,
                action: onCancel
            )
            .accessibilityIdentifier("rally-bar-cancel")
        case .done:
            RallyBarActionButton(
                title: "Review",
                showsChevron: true,
                fill: MatchColor.lime,
                foreground: MatchColor.ink,
                action: onReview
            )
            .accessibilityIdentifier("rally-bar-review")
        }
    }
}

private struct RallyBarActionButton: View {
    let title: String
    let showsChevron: Bool
    let fill: Color
    let foreground: Color
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
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(fill, in: Capsule())
        }
        .buttonStyle(.plain)
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

        RallyBar(state: .scanning(progress: 0.38))

        RallyBar(state: .done(rallies: 18, toCheck: 3))
    }
    .padding(16)
    .background(MatchColor.paper)
}
