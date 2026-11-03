import RallyKit
import SwiftUI

enum RallyBarState: Equatable {
    /// Ready to find rallies, with today's free finds still available.
    case idle(freeFindsLeft: Int)
    /// Today's free finds are used up. Go Pro replaces Find rallies.
    case outOfFreeFinds
    /// Find rallies was tapped before the video check finished.
    case checking
    /// The video check rejected this video. Find rallies stays disabled.
    case rejected
    case done(rallies: Int, toCheck: Int)
}

struct RallyBar: View {
    static let height: CGFloat = 54

    let state: RallyBarState
    var onFind: () -> Void = {}
    var onGoPro: () -> Void = {}
    var onReview: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .typography(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if let subtitle {
                    RallyBarSubtitleRow(subtitle: subtitle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            action
        }
        .padding(.leading, 16)
        .padding(.trailing, 11)
        .frame(minHeight: Self.height)
        .foregroundStyle(foreground)
        .background(isDark ? MatchColor.ink : .white)
        .overlay {
            if !isDark {
                Capsule()
                    .strokeBorder(MatchColor.line, lineWidth: hasBorderBeam ? 1 : 1.5)
            }
        }
        .clipShape(Capsule())
        .overlay {
            // Every glowing state shares this branch so the glow does not restart between them.
            if hasBorderBeam {
                RallyBarBorderBeam()
            }
        }
        .shadow(
            color: hasBorderBeam || isDark ? .clear : MatchColor.ink.opacity(0.06),
            radius: 4,
            y: 2
        )
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
        switch state {
        case .idle, .checking:
            return true
        case .outOfFreeFinds, .rejected, .done:
            return false
        }
    }

    private var foreground: Color {
        switch state {
        case .idle, .outOfFreeFinds, .checking:
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
        case .outOfFreeFinds:
            return "Free finds refill tomorrow"
        case .checking:
            return "Checking this video…"
        case .done(let rallies, let toCheck):
            return toCheck > 0 ? "\(rallies) rallies · \(toCheck) to check" : "\(rallies) rallies"
        }
    }

    private var subtitle: RallyBarSubtitle? {
        switch state {
        case .idle(let freeFindsLeft):
            return RallyBarSubtitle(freeFindsLeft: freeFindsLeft)
        case .outOfFreeFinds:
            return RallyBarSubtitle(
                text: "Or go unlimited with Pro",
                freeFindsLeft: 0,
                color: MatchColor.muted,
                weight: .regular
            )
        case .checking:
            return RallyBarSubtitle(
                text: "Rally finding starts right after",
                freeFindsLeft: nil,
                color: MatchColor.muted,
                weight: .regular
            )
        case .rejected, .done:
            return nil
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .idle, .rejected:
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .medium))
        case .outOfFreeFinds:
            Image(systemName: "moon.stars")
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
        case .outOfFreeFinds:
            RallyBarActionButton(
                title: "Go Pro",
                style: .dark,
                action: onGoPro
            )
            .accessibilityIdentifier("rally-bar-go-pro")
        case .checking:
            RallyBarActionButton(
                title: "Checking",
                style: .disabled,
                showsChevron: false,
                action: {}
            )
            .accessibilityIdentifier("rally-bar-checking")
        case .rejected:
            RallyBarActionButton(
                title: "Find rallies",
                style: .disabled,
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

/// The bar's second line: today's free finds as dots, then a short note.
private struct RallyBarSubtitle {
    let text: String
    /// Nil hides the dots.
    let freeFindsLeft: Int?
    let color: Color
    let weight: Font.Weight

    init(text: String, freeFindsLeft: Int?, color: Color, weight: Font.Weight) {
        self.text = text
        self.freeFindsLeft = freeFindsLeft
        self.color = color
        self.weight = weight
    }

    /// The last free find of the day turns amber.
    init(freeFindsLeft: Int) {
        let isLast = freeFindsLeft == 1
        self.init(
            text: isLast ? "1 free find left today" : "\(freeFindsLeft) free finds left today",
            freeFindsLeft: freeFindsLeft,
            color: isLast ? MatchColor.amberInk : MatchColor.muted,
            weight: isLast ? .semibold : .regular
        )
    }
}

private struct RallyBarSubtitleRow: View {
    let subtitle: RallyBarSubtitle

    var body: some View {
        HStack(spacing: 5) {
            if let left = subtitle.freeFindsLeft {
                ForEach(0..<FreeFindAllowance.dailyLimit, id: \.self) { index in
                    Circle()
                        .fill(dotColor(index: index, left: left))
                        .frame(width: 6, height: 6)
                }
            }

            Text(subtitle.text)
                .font(.caption2)
                .fontWeight(subtitle.weight)
                .foregroundStyle(subtitle.color)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(subtitle.text)
        .accessibilityIdentifier("rally-bar-subtitle")
    }

    private func dotColor(index: Int, left: Int) -> Color {
        guard index < left else {
            return MatchColor.ink.opacity(0.15)
        }
        return left == 1 ? MatchColor.amber : MatchColor.limeDeep
    }
}

private struct RallyBarActionButton: View {
    enum Style {
        case primary
        case dark
        case disabled
    }

    let title: String
    var style = Style.primary
    var showsChevron = true
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
            .background(background, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(style == .disabled)
    }

    private var foreground: Color {
        switch style {
        case .primary:
            return MatchColor.ink
        case .dark:
            return MatchColor.lime
        case .disabled:
            return MatchColor.ink.opacity(0.4)
        }
    }

    private var background: Color {
        switch style {
        case .primary:
            return MatchColor.lime
        case .dark:
            return MatchColor.ink
        case .disabled:
            return Color(uiColor: .tertiarySystemFill)
        }
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
        RallyBar(state: .idle(freeFindsLeft: 2))

        RallyBar(state: .idle(freeFindsLeft: 1))

        RallyBar(state: .outOfFreeFinds)

        RallyBar(state: .checking)

        RallyBar(state: .rejected)

        RallyBar(state: .done(rallies: 18, toCheck: 3))
    }
    .padding(16)
    .background(MatchColor.paper)
}
