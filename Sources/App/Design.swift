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

struct WarningCard: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "info.circle").font(.footnote).foregroundStyle(MatchStyle.ink)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(MatchStyle.lime.opacity(0.22), in: RoundedRectangle(cornerRadius: 14))
    }
}
