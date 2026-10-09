import SwiftUI
import AVKit

struct ProjectView: View {
    @Bindable var store: AppStore
    let id: UUID
    var body: some View {
        Group {
            if let project = store.project(id) {
                if !FileManager.default.fileExists(atPath: store.sourceURL(project).path) {
                    ContentUnavailableView(
                        "Original video unavailable", systemImage: "video.slash",
                        description: Text(
                            "Your project edits are preserved. Return to your matches and import the original video to create a new project."
                        ))
                } else {
                    VideoEditorView(store: store, id: id)
                }
            } else {
                ContentUnavailableView("Project unavailable", systemImage: "video.slash")
            }
        }
        .background(MatchStyle.paper)
        .foregroundStyle(MatchStyle.ink)
        .navigationTitle(store.project(id)?.title ?? "Match")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CourtSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: AppStore
    let project: MatchProject
    @State private var region = NormalizedRect()
    @State private var confirmed = false
    @State private var starting = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Eyebrow(title: "01 / Set the scene")
                Text("This is your court.")
                    .typography(.brand)
                    .tracking(-0.8)
                Text(
                    "Frame the entire court to focus detection on your match. Include both baselines and both players."
                )
                .typography(.body)
                .foregroundStyle(MatchStyle.muted)
                GeometryReader { proxy in

                    ZStack(alignment: .topLeading) {
                        if let image = UIImage(contentsOfFile: store.thumbnailURL(project).path) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                        } else {
                            MatchStyle.ink
                                .overlay(
                                    Text(
                                        "Thumbnail unavailable. Use the full frame or adjust the region below."
                                    )
                                    .foregroundStyle(.white).padding())
                        }
                        Rectangle().fill(MatchStyle.lime.opacity(0.16))
                            .overlay(Rectangle().stroke(MatchStyle.lime, lineWidth: 2))
                            .frame(
                                width: proxy.size.width * region.width,
                                height: proxy.size.height * region.height
                            )
                            .offset(x: proxy.size.width * region.x, y: proxy.size.height * region.y)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .aspectRatio(
                    CGFloat(project.source.width) / CGFloat(max(1, project.source.height)), contentMode: .fit)
                VStack(spacing: 12) {
                    regionSlider(
                        "Left",
                        value: Binding(
                            get: {
                                region.x
                            },
                            set: {
                                region.x = min($0, 1 - region.width)
                            }), range: 0...max(0.001, 1 - region.width))
                    regionSlider(
                        "Top",
                        value: Binding(
                            get: {
                                region.y
                            },
                            set: {
                                region.y = min($0, 1 - region.height)
                            }), range: 0...max(0.001, 1 - region.height))
                    regionSlider(
                        "Width",
                        value: Binding(
                            get: {
                                region.width
                            },
                            set: {
                                region.width = min($0, 1 - region.x)
                            }), range: 0.1...max(0.1, 1 - region.x))
                    regionSlider(
                        "Height",
                        value: Binding(
                            get: {
                                region.height
                            },
                            set: {
                                region.height = min($0, 1 - region.y)
                            }), range: 0.1...max(0.1, 1 - region.y))
                    HStack {
                        Button("Reset region") {
                            region = NormalizedRect()
                        }

                        Spacer()
                        Button("Full frame") {
                            region = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
                        }
                    }
                    .typography(.caption)
                    .fontWeight(.bold)
                }
                .padding(18)
                .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
                ForEach(project.warnings, id: \.self) {
                    WarningCard(text: $0)
                }
                Toggle("The whole court is visible and the camera is fixed.", isOn: $confirmed)
                    .typography(.body)
                if !confirmed {
                    Text("You can still continue, but unsupported setups may need more manual corrections.")
                        .typography(.caption)
                        .foregroundStyle(MatchStyle.muted)
                }
                Button {
                    starting = true
                    Task {
                        if await store.setCourt(region, id: project.id) {
                            store.analyze(project.id)
                            dismiss()
                        }
                        starting = false
                    }
                } label: {
                    Label("Find possible points", systemImage: "sparkle")
                }
                .buttonStyle(PrimaryButton())
                .disabled(starting || store.activeAnalysisID != nil)
                Button("Back to editor") {
                    dismiss()
                }
                .typography(.body)
                .frame(maxWidth: .infinity)
                Text("Your original video will never be changed.")
                    .typography(.caption)
                    .foregroundStyle(
                        MatchStyle.muted
                    )
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
        }
        .onAppear {
            region = project.courtRegion
        }
    }
    private func regionSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>)
        -> some View
    {
        HStack {
            Text(title)
                .typography(.caption)
                .frame(width: 45, alignment: .leading)
            Slider(value: value, in: range, step: 0.01)
                .accessibilityLabel("Court \(title)")
            Text("\(Int(value.wrappedValue * 100))%")
                .typography(.caption)
                .monospacedDigit()
                .frame(
                    width: 38, alignment: .trailing)
        }
    }
}

struct VideoEditorView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var store: AppStore
    let id: UUID
    @State private var playback = EditorPlayback()
    @State private var showExport = false
    @State private var showCourt = false
    @State private var showAISuggestions = false
    @State private var showApplyConfirmation = false
    @State private var isSplitting = false
    @State private var frameResolver = VideoFrameBoundaryResolver()

    var body: some View {
        if let project = store.project(id), let editor = project.editorState {
            GeometryReader { geometry in

                let previewSize = EditorPreviewLayout.size(
                    sourceWidth: project.source.width,
                    sourceHeight: project.source.height,
                    maxWidth: max(0, geometry.size.width - 32),
                    maxHeight: min(geometry.size.height * 0.42, 360)
                )
                VStack(spacing: 16) {
                    EditorVideoSurface(player: playback.player)
                        .frame(width: previewSize.width, height: previewSize.height)
                        .background(.black, in: RoundedRectangle(cornerRadius: 14))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay {
                            if playback.isPreparing {
                                ProgressView("Preparing preview")
                                    .tint(.white)
                                    .foregroundStyle(.white)
                            }
                        }
                        .accessibilityIdentifier("editor-preview")
                        .frame(maxWidth: .infinity)

                    HStack(spacing: 18) {
                        Button {
                            playback.togglePlayback()
                        } label: {
                            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                                .typography(.brand)
                                .frame(width: 44, height: 44)
                        }
                        .disabled(!playback.isReady)
                        .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                        Spacer()
                        Button {
                            Task {
                                await store.updateEditor(id) {
                                    $0.undo()
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .disabled(!editor.canUndo)
                        .accessibilityLabel("Undo")
                        Button {
                            Task {
                                await store.updateEditor(id) {
                                    $0.redo()
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.uturn.forward")
                        }
                        .disabled(!editor.canRedo)
                        .accessibilityLabel("Redo")
                    }

                    EditorTimeline(
                        editor: editor,
                        sourceURL: store.sourceURL(project),
                        position: playback.position,
                        onScrub: {
                            playback.scrub(to: $0)
                        },
                        onScrubEnd: { time in

                            Task {
                                await store.updateEditor(id) { state in

                                    let clip = try state.includedClip(atEditTime: time)
                                    try state.setPlayhead(time)
                                    try state.select(clip.id)
                                }
                            }
                        },
                        onSelect: { clipID in

                            Task {
                                await store.updateEditor(id) {
                                    try $0.select(clipID)
                                }
                            }
                        }
                    )

                    if let selected = editor.clips.first(where: {
                        $0.id == editor.selectedClipID
                    }) {
                        HStack(spacing: 8) {
                            Text(
                                "Clip \(editor.includedClips.firstIndex(where: { $0.id == selected.id }).map { $0 + 1 } ?? 0)"
                            )
                            .typography(.body)
                            .bold()
                            Spacer(minLength: 8)
                            Text(timeLabel(selected.duration))
                                .typography(.body)
                                .monospacedDigit()
                                .accessibilityIdentifier("editor-selected-clip-duration")
                        }
                    }

                    HStack(spacing: 12) {
                        Spacer()
                        Button {
                            split(project: project)
                        } label: {
                            Label(isSplitting ? "Finding frame…" : "Split", systemImage: "scissors")
                        }
                        .disabled(
                            isSplitting || !playback.isReady || playback.position <= 0
                                || playback.position >= editor.totalDuration
                        )
                        .accessibilityIdentifier("editor-split")
                        Button {
                            Task {
                                await store.updateEditor(id) {
                                    try $0.excludeSelected()
                                }
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(editor.includedClips.count <= 1 || editor.selectedClipID == nil)
                        .accessibilityIdentifier("editor-delete")
                    }
                    .buttonStyle(.bordered)
                    .typography(.body)

                    if editor.clips.contains(where: {
                        !$0.isIncluded
                    }) {
                        Menu {
                            ForEach(
                                editor.clips.filter {
                                    !$0.isIncluded
                                }
                            ) { clip in

                                Button("\(timeLabel(clip.sourceStart)) – \(timeLabel(clip.sourceEnd))") {
                                    Task {
                                        await store.updateEditor(id) {
                                            try $0.restore(clip.id)
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("Restore removed clip", systemImage: "arrow.uturn.backward.circle")
                                .typography(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Spacer(minLength: 0)
                    Button {
                        showExport = true
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PrimaryButton(dark: true))
                }
                .padding(16)
            }
            .accessibilityIdentifier("video-editor")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Find points with AI") {
                            showCourt = true
                        }
                        if project.status == .analyzing {
                            Button("Pause AI analysis") {
                                store.pauseAnalysis()
                            }
                        } else if project.status == .interrupted {
                            Button("Resume AI analysis") {
                                store.analyze(id)
                            }
                        }
                        if project.pendingAnalysisSegments != nil {
                            Button("Review AI suggestions") {
                                showAISuggestions = true
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More project options")
                }
            }
            .onAppear {
                playback.start()
            }
            .task(id: editor.revision) {
                do {
                    try await playback.prepare(project: project, source: store.sourceURL(project))
                } catch is CancellationError {
                } catch {
                    store.errorMessage = error.localizedDescription
                }
            }
            .onDisappear {
                playback.stop()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    playback.pause()
                }
            }
            .sheet(isPresented: $showExport) {
                ExportView(store: store, projectID: id)
            }
            .sheet(isPresented: $showCourt) {
                NavigationStack {
                    CourtSetupView(store: store, project: project)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") {
                                    showCourt = false
                                }
                            }
                        }
                }
            }
            .sheet(isPresented: $showAISuggestions) {
                NavigationStack {
                    List {
                        if let suggestions = project.pendingAnalysisSegments {
                            if suggestions.isEmpty {
                                Text("No points found. Your edit is unchanged.")
                            } else {
                                ForEach(suggestions) { segment in

                                    Text(
                                        "\(timeLabel(segment.sourceStart)) – \(timeLabel(segment.sourceEnd))"
                                    )
                                    .typography(.body)
                                    .monospacedDigit()
                                }
                                Button("Apply suggestions") {
                                    showApplyConfirmation = true
                                }
                                Button("Dismiss suggestions", role: .destructive) {
                                    Task {
                                        await store.dismissAnalysisSuggestions(id)
                                    }
                                    showAISuggestions = false
                                }
                            }
                        }
                    }
                    .navigationTitle("AI suggestions")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                showAISuggestions = false
                            }
                        }
                    }
                }
                .confirmationDialog(
                    "Replace current clips with AI suggestions?", isPresented: $showApplyConfirmation
                ) {
                    Button("Replace clips") {
                        Task {
                            await store.applyAnalysisSuggestions(id)
                        }
                        showAISuggestions = false
                    }
                }
            }
        }
    }

    private func split(project: MatchProject) {
        guard let editor = project.editorState else {
            return
        }
        playback.pause()
        let time = playback.position
        isSplitting = true
        Task {
            defer {
                isSplitting = false
            }
            do {
                let clip = try editor.includedClip(atEditTime: time)
                let sourceTime = try editor.sourceTime(atEditTime: time)
                let boundary = try await frameResolver.nearestBoundary(
                    in: store.sourceURL(project), to: sourceTime,
                    clipStart: clip.sourceStart, clipEnd: clip.sourceEnd,
                    fallbackFrameRate: project.source.frameRate
                )
                guard abs(playback.position - time) < max(0.05, 1 / max(1, project.source.frameRate)) else {
                    return
                }
                await store.updateEditor(id) { state in

                    guard state.revision == editor.revision else {
                        throw EditorCoreError.invalidTimeline
                    }
                    let snappedEdit = try state.editTime(atSourceTime: boundary.sourceTime, in: clip.id)
                    try state.split(
                        atEditTime: snappedEdit, minimumClipDuration: boundary.minimumClipDuration)
                }
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

}
