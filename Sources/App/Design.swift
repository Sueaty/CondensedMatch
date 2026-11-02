import SwiftUI

struct PrimaryButton: ButtonStyle {
    var dark = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .typography(.body)
            .bold()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(dark ? .white : MatchColor.ink)
            .background(dark ? MatchColor.ink : MatchColor.lime, in: RoundedRectangle(cornerRadius: 18))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct Eyebrow: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .typography(.caption)
            .bold()
            .tracking(2)
            .foregroundStyle(MatchColor.muted)
    }
}

struct WarningCard: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "info.circle")
            .typography(.caption)
            .foregroundStyle(MatchColor.ink)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MatchColor.lime.opacity(0.22), in: RoundedRectangle(cornerRadius: 14))
    }
}
