import SwiftUI

struct ExportView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: AppStore
    let projectID: UUID
    @State private var exporter = ExportService()
    @State private var result: URL?
    @State private var message: String?
    @State private var saving = false
    @State private var share = false
    var body: some View {
        NavigationStack {
            if let project = store.project(projectID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Eyebrow(title: "Worth watching again")

                        Text(
                            result == nil
                                ? "Keep the match.\nShare the moments." : "Ready for\nanother watch."
                        )
                        .typography(.title2)
                        .tracking(-1)

                        ExportResultSummary(
                            condensedDuration: project.condensedDuration,
                            sourceDuration: project.source.duration
                        )

                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("Source resolution") {
                                Text("\(project.source.width) × \(project.source.height)")
                                    .foregroundStyle(MatchColor.muted)
                            }

                            LabeledContent("Format") {
                                Text("MP4 · highest quality")
                                    .foregroundStyle(MatchColor.muted)
                            }

                            Text("Keep this screen open while exporting.")
                                .typography(.caption)
                                .foregroundStyle(MatchColor.muted)
                        }
                        .padding(.vertical, 16)
                        .padding(.horizontal, 20)
                        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
                        if let message {
                            WarningCard(text: message)
                        }
                        if exporter.isRunning {
                            ProgressView(value: exporter.progress) {
                                Text("Exporting · \(Int(exporter.progress * 100))%")
                                    .typography(.body)
                            }
                            Button("Cancel export") {
                                exporter.cancel()
                            }
                            .frame(maxWidth: .infinity)
                        } else if let result {
                            ExportActionsLayout {
                                Button {
                                    saving = true
                                    Task {
                                        do {
                                            try await exporter.saveToPhotos(result)
                                            message = "Saved to Photos."
                                        } catch {
                                            message = error.localizedDescription
                                        }
                                        saving = false
                                    }
                                } label: {
                                    Text(saving ? "Saving…" : "Save to Photos")
                                        .frame(maxHeight: .infinity)
                                }
                                .buttonStyle(PrimaryButton(dark: true))
                                .disabled(saving)

                                Button {
                                    share = true
                                } label: {
                                    Label("Share video", systemImage: "square.and.arrow.up")
                                        .frame(maxHeight: .infinity)
                                }
                                .buttonStyle(PrimaryButton())
                            }
                        } else {
                            Button {
                                export(project)
                            } label: {
                                Label("Create condensed video", systemImage: "arrow.up.right.video")
                            }
                            .buttonStyle(PrimaryButton())
                        }
                    }
                    .padding(.vertical, 18)
                    .padding(.horizontal, 24)
                }
                .background(MatchColor.paper)
                .foregroundStyle(MatchColor.ink)
                .navigationTitle("Export match")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("Editing")
                            }
                        }
                        .accessibilityLabel("Back to editing")
                        .accessibilityIdentifier("export-back-to-editing")
                        .disabled(exporter.isRunning || saving)
                    }
                }
                .interactiveDismissDisabled(exporter.isRunning || saving)
                .onAppear {
                    if let filename = project.exportFilename {
                        let url = store.folder(projectID).appendingPathComponent(filename)
                        if FileManager.default.fileExists(atPath: url.path) {
                            result = url
                        }
                    }
                }
                .sheet(isPresented: $share) {
                    if let result {
                        ShareSheet(url: result)
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in

            if phase == .background && exporter.isRunning {
                exporter.cancel()
                message =
                    "Export paused when the app left the foreground. Your edits are safe; retry when ready."
            }
        }
    }
    private func export(_ project: MatchProject) {
        message = nil
        Task {
            do {
                let url = try await exporter.export(
                    project: project, source: store.sourceURL(project), folder: store.folder(projectID))
                guard var latest = store.project(projectID) else {
                    return
                }
                latest.exportFilename = url.lastPathComponent
                if await store.updateProject(latest) {
                    result = url
                }
            } catch {
                message =
                    "Export did not complete. \(error.localizedDescription) Your original and edits are safe; you can retry."
            }
        }
    }
}

private struct ExportResultSummary: View {
    let condensedDuration: Double
    let sourceDuration: Double

    private var keptFraction: Double {
        guard sourceDuration > 0 else {
            return 1
        }
        return min(1, max(0, condensedDuration / sourceDuration))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(timeLabel(condensedDuration))
                    .font(.system(size: 48, weight: .regular, design: .serif))
                    .tracking(-1.5)
                    .monospacedDigit()
                    .foregroundStyle(.white)

                Text("from \(timeLabel(sourceDuration)) of footage")
                    .typography(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }

            Capsule()
                .fill(.white.opacity(0.15))
                .frame(height: 8)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(MatchColor.lime)
                            .frame(width: proxy.size.width * keptFraction)
                    }
                }

            Text(
                "\(Int((keptFraction * 100).rounded()))% kept · \(timeLabel(max(0, sourceDuration - condensedDuration))) of downtime cut"
            )
            .typography(.caption)
            .tracking(0.5)
            .foregroundStyle(.white.opacity(0.65))
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MatchColor.ink, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }
}

private struct ExportActionsLayout: Layout {
    private let spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let availableWidth = max(0, width - spacing)
        let heights = subviews.enumerated().map { index, subview in
            subview.sizeThatFits(
                ProposedViewSize(width: availableWidth * (index == 0 ? 0.7 : 0.3), height: nil)
            ).height
        }
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let availableWidth = max(0, bounds.width - spacing)
        for (index, subview) in subviews.enumerated() {
            let width = availableWidth * (index == 0 ? 0.7 : 0.3)
            let x = index == 0 ? bounds.minX : bounds.minX + availableWidth * 0.7 + spacing
            subview.place(
                at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height))
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {
    }
}
