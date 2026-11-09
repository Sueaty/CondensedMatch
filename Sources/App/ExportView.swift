import SwiftUI

struct ExportView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: AppStore
    let projectID: UUID
    @State private var exporter = ExportService()
    @State private var result: URL?
    @State private var clips: [URL] = []
    @State private var options = RallyExportOptions.standard
    @State private var message: String?
    @State private var saving = false
    @State private var share = false

    /// Set once rallies were found; the page then offers the 5B rally options.
    private var review: RallyReview? {
        store.rallyReview
    }

    var body: some View {
        NavigationStack {
            if let project = store.project(projectID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Eyebrow(title: eyebrow)

                        Text(headline)
                            .typography(.title2)
                            .tracking(-1)

                        ExportResultSummary(
                            condensedDuration: plan(for: project)?.duration ?? project.condensedDuration,
                            sourceDuration: project.source.duration,
                            mentionsFootage: review == nil
                        )

                        if let plan = plan(for: project) {
                            RallyExportOptionsCard(
                                options: $options,
                                clipCount: plan.clips.count
                            )
                            .disabled(exporter.isRunning || saving)
                        } else {
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
                        }

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
                                            try await exporter.saveToPhotos([result] + clips)
                                            message = clips.isEmpty
                                                ? "Saved to Photos." : "Saved \(clips.count + 1) videos to Photos."
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
                    options = project.rallyExportOptions ?? .standard
                    restoreExport(of: project)
                }
                .onChange(of: options) { _, options in
                    keep(options)
                }
                .sheet(isPresented: $share) {
                    if let result {
                        ShareSheet(urls: [result] + clips)
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
    private var eyebrow: String {
        guard let review else {
            return "Worth watching again"
        }
        let skipped = review.rallies.count - review.checkedCount
        let rallies = "\(review.checkedCount) \(review.checkedCount == 1 ? "rally" : "rallies")"
        return skipped == 0 ? rallies : rallies + " · \(skipped) skipped"
    }

    private var headline: String {
        if result != nil {
            return "Ready for\nanother watch."
        }
        return review == nil ? "Keep the match.\nShare the moments." : "Every point.\nNone of the waiting."
    }

    private func plan(for project: MatchProject) -> RallyExportPlan? {
        guard let review else {
            return nil
        }
        return RallyExportPlan(rallies: review.segments, options: options, sourceDuration: project.source.duration)
    }

    private func restoreExport(of project: MatchProject) {
        guard let filename = project.exportFilename else {
            return
        }
        let folder = store.folder(projectID)
        let url = folder.appendingPathComponent(filename)
        let clipURLs = (project.exportClipFilenames ?? []).map {
            folder.appendingPathComponent($0)
        }
        let urls = [url] + clipURLs
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            return
        }
        result = url
        clips = clipURLs
    }

    /// Remembers the rally options; a finished video made with other options is no longer current.
    private func keep(_ options: RallyExportOptions) {
        guard var latest = store.project(projectID), (latest.rallyExportOptions ?? .standard) != options else {
            return
        }
        latest.rallyExportOptions = options
        if result != nil {
            latest.exportFilename = nil
            result = nil
            clips = []
            message = nil
        }
        Task {
            await store.updateProject(latest)
        }
    }

    private func export(_ project: MatchProject) {
        message = nil
        let source = store.sourceURL(project)
        let folder = store.folder(projectID)
        let plan = plan(for: project)
        let options = options
        Task {
            do {
                let output: (video: URL, clips: [URL])
                if let plan {
                    output = try await exporter.export(
                        plan: plan,
                        options: options,
                        source: source,
                        folder: folder,
                        sourceDuration: project.source.duration
                    )
                } else {
                    output = (try await exporter.export(project: project, source: source, folder: folder), [])
                }
                guard var latest = store.project(projectID) else {
                    return
                }
                latest.exportFilename = output.video.lastPathComponent
                latest.exportClipFilenames = output.clips.isEmpty ? nil : output.clips.map(\.lastPathComponent)
                if await store.updateProject(latest) {
                    result = output.video
                    clips = output.clips
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
    var mentionsFootage = true

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

                Text(
                    mentionsFootage
                        ? "from \(timeLabel(sourceDuration)) of footage" : "from \(timeLabel(sourceDuration))"
                )
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

/// 5B: breathing room, rally numbers and per-rally clips.
private struct RallyExportOptionsCard: View {
    @Binding var options: RallyExportOptions
    let clipCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Breathing room")
                    .typography(.body)
                    .fontWeight(.semibold)

                RallyPaddingPicker(padding: $options.padding)

                Text("Adds a moment before the serve and after the last shot.")
                    .typography(.caption)
                    .foregroundStyle(MatchColor.muted)
            }

            RallyOptionSwitch(
                title: "Rally number on screen",
                detail: "Small “Rally 7” tag in the corner",
                isOn: $options.showsRallyNumber
            )
            .accessibilityIdentifier("export-rally-number")

            RallyOptionSwitch(
                title: "Also save each rally",
                detail: "\(clipCount) separate \(clipCount == 1 ? "clip" : "clips") for sharing",
                isOn: $options.savesEachRally
            )
            .accessibilityIdentifier("export-each-rally")
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct RallyPaddingPicker: View {
    @Binding var padding: RallyExportOptions.Padding
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            ForEach(RallyExportOptions.Padding.allCases, id: \.self) { choice in
                let isSelected = choice == padding
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        padding = choice
                    }
                } label: {
                    Text(title(choice))
                        .typography(.body)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(isSelected ? MatchColor.ink : MatchColor.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.white)
                                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityTitle(choice))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("export-padding-\(title(choice).lowercased())")
            }
        }
        .padding(3)
        .background(MatchColor.ink.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func title(_ choice: RallyExportOptions.Padding) -> String {
        switch choice {
        case .none:
            return "None"
        case .one:
            return "1s"
        case .two:
            return "2s"
        }
    }

    private func accessibilityTitle(_ choice: RallyExportOptions.Padding) -> String {
        switch choice {
        case .none:
            return "No breathing room"
        case .one:
            return "1 second"
        case .two:
            return "2 seconds"
        }
    }
}

private struct RallyOptionSwitch: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                isOn.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .typography(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(MatchColor.ink)

                    Text(detail)
                        .typography(.caption)
                        .foregroundStyle(MatchColor.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Capsule()
                    .fill(isOn ? MatchColor.ink : MatchColor.ink.opacity(0.2))
                    .frame(width: 48, height: 28)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle()
                            .fill(isOn ? MatchColor.lime : .white)
                            .frame(width: 22, height: 22)
                            .padding(3)
                    }
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
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
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {
    }
}
