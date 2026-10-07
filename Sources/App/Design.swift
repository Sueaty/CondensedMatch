import SwiftUI

enum MatchStyle {
    static let paper = Color(red: 0.96, green: 0.96, blue: 0.92)
    static let ink = Color(red: 0.10, green: 0.20, blue: 0.16)
    static let muted = Color(red: 0.37, green: 0.42, blue: 0.37)
    static let lime = Color(red: 0.81, green: 0.93, blue: 0.37)
    static let line = Color(red: 0.84, green: 0.86, blue: 0.81)
}

struct PrimaryButton: ButtonStyle {
    var dark = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(.body, design: .rounded, weight: .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 17)
            .foregroundStyle(dark ? .white : MatchStyle.ink)
            .background(dark ? MatchStyle.ink : MatchStyle.lime, in: RoundedRectangle(cornerRadius: 18))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct Eyebrow: View {
    let title: String
    var body: some View { Text(title.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(MatchStyle.muted) }
}

struct CourtArtwork: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            let courtHeight = h * 0.68
            let courtWidth = courtHeight * (36.0 / 78.0)
            let left = (w - courtWidth) / 2
            let right = left + courtWidth
            let top = h * 0.08
            let bottom = top + courtHeight
            let singlesLeft = left + courtWidth * 0.125
            let singlesRight = right - courtWidth * 0.125
            let nearServiceLine = top + courtHeight * (21.0 / 78.0)
            let farServiceLine = bottom - courtHeight * (21.0 / 78.0)
            ZStack {
                RoundedRectangle(cornerRadius: 24).fill(MatchStyle.ink)
                Path { path in
                    path.addRect(CGRect(x: left, y: top, width: right - left, height: bottom - top))
                    path.move(to: CGPoint(x: singlesLeft, y: top)); path.addLine(to: CGPoint(x: singlesLeft, y: bottom))
                    path.move(to: CGPoint(x: singlesRight, y: top)); path.addLine(to: CGPoint(x: singlesRight, y: bottom))
                    path.move(to: CGPoint(x: singlesLeft, y: nearServiceLine)); path.addLine(to: CGPoint(x: singlesRight, y: nearServiceLine))
                    path.move(to: CGPoint(x: singlesLeft, y: farServiceLine)); path.addLine(to: CGPoint(x: singlesRight, y: farServiceLine))
                    path.move(to: CGPoint(x: w / 2, y: nearServiceLine)); path.addLine(to: CGPoint(x: w / 2, y: farServiceLine))
                    path.move(to: CGPoint(x: w / 2, y: top)); path.addLine(to: CGPoint(x: w / 2, y: top + 5))
                    path.move(to: CGPoint(x: w / 2, y: bottom)); path.addLine(to: CGPoint(x: w / 2, y: bottom - 5))
                }.stroke(.white.opacity(0.48), lineWidth: 1)
                Path { path in path.move(to: CGPoint(x: left - 10, y: h / 2)); path.addLine(to: CGPoint(x: right + 10, y: h / 2)) }
                    .stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                Path { path in
                    path.move(to: CGPoint(x: singlesLeft, y: bottom - courtHeight * 0.14))
                    path.addQuadCurve(
                        to: CGPoint(x: singlesRight, y: top + courtHeight * 0.14),
                        control: CGPoint(x: right + courtWidth * 0.55, y: h * 0.53)
                    )
                }.stroke(MatchStyle.lime.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 6]))
                Circle().fill(MatchStyle.lime).frame(width: 15, height: 15)
                    .position(x: singlesRight, y: top + courtHeight * 0.14)
                Circle().fill(.white).frame(width: 7, height: 7)
                    .position(x: singlesLeft, y: bottom - courtHeight * 0.14)
                VStack { Spacer(); HStack { Text("EVERY RALLY. LESS WAITING.").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(2); Spacer() } }.padding(18).foregroundStyle(.white.opacity(0.65))
            }
        }.accessibilityHidden(true)
    }
}

struct WarningCard: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "info.circle").font(.footnote).foregroundStyle(MatchStyle.ink)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(MatchStyle.lime.opacity(0.22), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct SegmentTimeline: View {
    let segments: [PointSegment]
    let duration: Double
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(MatchStyle.line)
                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(segment.inclusion == .excluded ? MatchStyle.muted.opacity(0.25) : MatchStyle.ink)
                        .frame(width: max(2, proxy.size.width * segment.duration / max(1, duration)))
                        .offset(x: proxy.size.width * segment.sourceStart / max(1, duration))
                }
            }.clipped()
        }.frame(height: 24).accessibilityLabel("Source timeline, \(segments.filter { $0.inclusion.isRetained }.count) retained segments")
    }
}
