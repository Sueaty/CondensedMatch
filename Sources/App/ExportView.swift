import SwiftUI

struct ExportView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var store: AppStore
    let projectID: UUID
    let onDone: () -> Void
    @State private var exporter = ExportService()
    @State private var result: URL?
    @State private var message: String?
    @State private var saving = false
    @State private var share = false
    var body: some View {
        NavigationStack {
            if let project = store.project(projectID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        Eyebrow(title: "03 / Worth watching again")
                        Text(
                            result == nil
                                ? "Keep the match.\nShare the moments." : "Ready for\nanother watch."
                        )
                        .typography(.brand)
                        .tracking(-1)
                        CourtArtwork()
                            .frame(height: 190)
                        VStack(alignment: .leading, spacing: 14) {
                            LabeledContent("Condensed length", value: timeLabel(project.condensedDuration))
                            LabeledContent(
                                "Source resolution",
                                value: "\(project.source.width) × \(project.source.height)")
                            LabeledContent("Format", value: "MP4 · highest quality")
                            Text(
                                "Video is re-encoded for sharing. Source orientation is preserved; the encoder may adjust dimensions for compatibility. Audio is carried across with each segment."
                            )
                            .typography(.caption)
                            .foregroundStyle(MatchColor.muted)
                            LabeledContent(
                                "Space allowance",
                                value: ByteCountFormatter.string(
                                    fromByteCount: ExportService.requiredSpace(project), countStyle: .file))
                            Text(
                                "A conservative allowance, not a predicted file size. Keep this screen open during export."
                            )
                            .typography(.caption)
                            .foregroundStyle(MatchColor.muted)
                        }
                        .padding(20)
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
                    .padding(24)
                }
                .background(MatchColor.paper)
                .foregroundStyle(MatchColor.ink)
                .navigationTitle("Export match")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            onDone()
                        }
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
