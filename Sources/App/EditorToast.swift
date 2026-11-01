import SwiftUI

struct EditorToast: Identifiable {
    let id = UUID()
    let message: String
}

struct EditorToastView: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .typography(.body)
        .foregroundStyle(.white)
        .padding(14)
        .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
        .accessibilityIdentifier("editor-toast")
        .allowsHitTesting(false)
    }
}
