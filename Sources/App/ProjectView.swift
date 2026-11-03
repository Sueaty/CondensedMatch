import SwiftUI
import AVKit
import RallyKit

struct ProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: AppStore
    let id: UUID
    var body: some View {
        Group {
            if let project = store.project(id) {
                if !FileManager.default.fileExists(atPath: store.sourceURL(project).path) {
                    ContentUnavailableView(
                        "Original video unavailable", systemImage: "video.slash",
                        description: Text(
                            "Return to the main screen and import the video again."
                        ))
                        .toolbar {
                            fallbackBackButton
                        }
                } else {
                    VideoEditorView(store: store, id: id)
                }
            } else {
                ContentUnavailableView("Project unavailable", systemImage: "video.slash")
                    .toolbar {
                        fallbackBackButton
                    }
            }
        }
        .background(MatchColor.paper)
        .foregroundStyle(MatchColor.ink)
        .navigationTitle(store.project(id)?.title ?? "Match")
        .navigationBarTitleDisplayMode(.inline)
        // Hide the system back button here, outside the editor's conditional content, so it stays
        // hidden even when the editor renders nothing for a frame during the push.
        .navigationBarBackButtonHidden(true)
    }

    @ToolbarContentBuilder
    private var fallbackBackButton: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Back")
        }
    }
}

struct VideoEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var store: AppStore
    let id: UUID
    @State private var playback = EditorPlayback()
    @State private var showExport = false
    @State private var showDiscardConfirmation = false
    @State private var isOperating = false
    @State private var isUserScrolling = false
    @State private var splitLookup = EditorSplitLookup()
    @State private var toast: EditorToast?
    @State private var toastTask: Task<Void, Never>?
    @State private var editTask: Task<Void, Never>?
    @State private var frameResolver = VideoFrameBoundaryResolver()
    @State private var controlsHeight = 500.0
    @State private var isWaitingForVideoCheck = false
    @State private var rallyRejection: RallyRejection?
    @State private var isRallyFindingRejected = false

    var body: some View {
        if let project = store.project(id), let editor = project.editorState {
            GeometryReader { geometry in

                let previewSize = EditorPreviewLayout.size(
                    sourceWidth: project.source.width,
                    sourceHeight: project.source.height,
                    maxWidth: max(0, geometry.size.width - 32),
                    maxHeight: max(
                        0, min(geometry.size.height * 0.42, geometry.size.height - controlsHeight - 36))
                )
                VStack(spacing: 12) {
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

                    VStack(spacing: 12) {
                        HStack(spacing: 0) {
                            HStack(spacing: 4) {
                                Text(timeLabel(playback.position))
                                    .fontWeight(.semibold)
                                    .accessibilityIdentifier("editor-playback-time")
                                    .accessibilityValue(String(format: "%.4f", playback.position))

                                Text("/ \(timeLabel(editor.totalDuration))")
                                    .foregroundStyle(MatchColor.muted)
                                    .accessibilityIdentifier("editor-total-duration")
                                    .accessibilityValue(String(format: "%.4f", editor.totalDuration))
                            }
                            .typography(.body)
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Button {
                                playback.togglePlayback()
                            } label: {
                                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 20, weight: .bold))
                                    .frame(width: 44, height: 44)
                                    .background(MatchColor.ink.opacity(0.12), in: Circle())
                            }
                            .disabled(!canEdit)
                            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

                            HStack(spacing: 0) {
                                Button {
                                    performEdit {
                                        $0.undo()
                                    }
                                } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                        .opacity(editor.canUndo ? 1 : 0.3)
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .disabled(!canEdit || !editor.canUndo)
                                .accessibilityLabel("Undo")

                                Button {
                                    performEdit {
                                        $0.redo()
                                    }
                                } label: {
                                    Image(systemName: "arrow.uturn.forward")
                                        .opacity(editor.canRedo ? 1 : 0.3)
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .disabled(!canEdit || !editor.canRedo)
                                .accessibilityLabel("Redo")
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }

                        EditorTimeline(
                            editor: editor,
                            sourceURL: store.sourceURL(project),
                            position: playback.position,
                            isEnabled: playback.isReady && !playback.isPreparing && !isOperating
                                && !splitLookup.isFindingFrame,
                            onScrubStart: {
                                isUserScrolling = true
                                playback.beginScrubbing()
                            },
                            onScrub: {
                                playback.scrub(to: $0)
                            },
                            onScrubEnd: { time in
                                playback.endScrubbing(at: time)
                                isUserScrolling = false
                                Task {
                                    await store.updateEditor(id) { state in
                                        guard state.revision == editor.revision else {
                                            return
                                        }
                                        try state.setPlayhead(min(time, state.totalDuration))
                                    }
                                }
                            },
                            onSelect: { clipID in
                                playback.pause()
                                Task {
                                    await store.updateEditor(id) { state in
                                        guard state.revision == editor.revision else {
                                            return
                                        }
                                        try state.select(clipID)
                                        try state.setPlayhead(min(playback.position, state.totalDuration))
                                    }
                                }
                            }
                        )

                        HStack(spacing: 8) {
                            if let selected = editor.clips.first(where: {
                                $0.id == editor.selectedClipID
                            }) {
                                Text(
                                    "Clip \(editor.includedClips.firstIndex(where: { $0.id == selected.id }).map { $0 + 1 } ?? 0)"
                                )
                                .typography(.body)
                                .bold()
                                .lineLimit(1)
                                .accessibilityIdentifier("editor-selected-clip")
                                .accessibilityValue(String(editor.includedClips.count))
                            }

                            Spacer(minLength: 8)

                            HStack(spacing: 12) {
                                Button {
                                    split(project: project)
                                } label: {
                                    Label(
                                        splitLookup.isFindingFrame ? "Finding frame…" : "Split",
                                        systemImage: "scissors")
                                }
                                .disabled(!canEdit)
                                .accessibilityIdentifier("editor-split")

                                Button {
                                    performEdit {
                                        try $0.excludeSelected()
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .disabled(
                                    !canEdit || editor.includedClips.count <= 1 || editor.selectedClipID == nil
                                )
                                .accessibilityIdentifier("editor-delete")
                            }
                            .buttonStyle(.bordered)
                            .typography(.body)
                        }

                        RallyBar(
                            state: rallyBarState,
                            onFind: {
                                findRallies()
                            }
                        )

                        Button {
                            showExport = true
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(PrimaryButton(dark: true))
                        .disabled(!canEdit)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: Double.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        controlsHeight = height
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
            }
            .overlay(alignment: .top) {
                if let toast {
                    EditorToastView(message: toast.message)
                        .transition(.opacity)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("video-editor")
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
                editTask?.cancel()
                playback.stop()
                splitLookup.cancel()
                toastTask?.cancel()
                toast = nil
                isUserScrolling = false
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    playback.pause()
                    splitLookup.cancel()
                }
            }
            .onChange(of: store.videoCheck?.isChecking ?? false) { _, isChecking in
                if !isChecking && isWaitingForVideoCheck {
                    isWaitingForVideoCheck = false
                    findRallies()
                }
            }
            .onChange(of: showExport) { _, shown in
                if shown {
                    playback.pause()
                }
            }
            .sheet(isPresented: $showExport) {
                ExportView(store: store, projectID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if hasEdits(editor) {
                            playback.pause()
                            showDiscardConfirmation = true
                        } else {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("editor-back")
                }
            }
            .alert("Discard this edit?", isPresented: $showDiscardConfirmation) {
                Button("Discard Edit", role: .destructive) {
                    dismiss()
                }

                Button("Keep Editing", role: .cancel) {
                }
            } message: {
                Text("Your splits and deletions will be lost. Videos already saved to Photos stay there.")
            }
            .alert(
                rallyRejection?.alertTitle ?? "",
                isPresented: Binding(
                    get: {
                        rallyRejection != nil
                    },
                    set: { isPresented in
                        if !isPresented {
                            rallyRejection = nil
                        }
                    }
                ),
                presenting: rallyRejection
            ) { _ in
                Button("OK") {
                    isRallyFindingRejected = true
                }
            } message: { rejection in
                Text(rejection.alertMessage)
            }
        }
    }

    private var rallyBarState: RallyBarState {
        if isRallyFindingRejected {
            return .rejected
        }
        if isWaitingForVideoCheck {
            return .checking
        }
        return .idle
    }

    /// Waits in the bar while the import-time check runs, rejects the video with an alert,
    /// or continues to rally finding once the check passes.
    private func findRallies() {
        guard !isRallyFindingRejected, !isWaitingForVideoCheck else {
            return
        }
        switch store.videoCheck {
        case .checking:
            isWaitingForVideoCheck = true
        case .rejected(let rejection):
            playback.pause()
            rallyRejection = rejection
        case .passed, nil:
            showToast("Rally detection is coming soon.")
        }
    }

    private func hasEdits(_ editor: EditorState) -> Bool {
        editor.canUndo || editor.clips.count > 1
    }

    private var canEdit: Bool {
        playback.isReady && !playback.isPreparing && !isOperating && !isUserScrolling
            && !splitLookup.isFindingFrame
    }

    private func performEdit(_ change: @escaping (inout EditorState) throws -> Void) {
        guard canEdit, let editor = store.project(id)?.editorState else {
            return
        }
        playback.pause()
        let time = playback.position
        isOperating = true
        editTask = Task { @MainActor in
            defer {
                isOperating = false
            }
            guard !Task.isCancelled else {
                return
            }
            guard var project = store.project(id), var state = project.editorState,
                state.revision == editor.revision
            else {
                showToast("The edit changed. Please try again.")
                return
            }
            do {
                try state.setPlayhead(min(time, state.totalDuration))
                try change(&state)
                project.editorState = state
                if state.revision != editor.revision {
                    project.exportFilename = nil
                }
                if !(await store.updateProject(project)) {
                    showToast("Your edit could not be applied. Please try again.")
                }
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    private func split(project: MatchProject) {
        guard canEdit, let editor = project.editorState else {
            return
        }
        playback.pause()
        let time = playback.position
        if let restriction = editor.splitRestriction(atEditTime: time) {
            showToast(restriction.localizedDescription)
            return
        }
        let interaction = playback.interactionRevision
        let source = store.sourceURL(project)
        let resolver = frameResolver
        splitLookup.resolve {
            #if DEBUG
                try await EditorUITestFixture.delayFrameLookupIfRequested()
            #endif
            return try await resolver.splitBoundary(
                in: source, editor: editor, at: time, fallbackFrameRate: project.source.frameRate)
        } completion: { result in
            switch result {
            case .success(let boundary):
                commitSplit(boundary, editor: editor, time: time, interaction: interaction)
            case .failure(let error):
                if !(error is CancellationError) {
                    showToast(error.localizedDescription)
                }
            }
        }
    }

    private func commitSplit(
        _ boundary: ResolvedFrameBoundary, editor: EditorState, time: Double, interaction: UInt64
    ) {
        isOperating = true
        editTask = Task { @MainActor in
            defer {
                isOperating = false
            }
            guard !Task.isCancelled else {
                return
            }
            guard interaction == playback.interactionRevision, var project = store.project(id),
                var state = project.editorState, state.revision == editor.revision
            else {
                showToast("The edit position changed. Please try Split again.")
                return
            }
            do {
                try state.setPlayhead(time)
                let clip = try state.includedClip(atEditTime: time)
                let snappedEdit = try state.editTime(atSourceTime: boundary.sourceTime, in: clip.id)
                try state.split(atEditTime: snappedEdit, minimumClipDuration: boundary.minimumClipDuration)
                project.editorState = state
                project.exportFilename = nil
                if !(await store.updateProject(project)) {
                    showToast("Your split could not be applied. Please try again.")
                }
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        let next = EditorToast(message: message)
        withAnimation(.easeOut(duration: 0.15)) {
            toast = next
        }
        UIAccessibility.post(notification: .announcement, argument: message)
        toastTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard toast?.id == next.id else {
                return
            }
            withAnimation(.easeOut(duration: 0.15)) {
                toast = nil
            }
        }
    }
}
