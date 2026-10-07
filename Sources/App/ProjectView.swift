import SwiftUI
import AVKit

struct ProjectView: View {
    @Bindable var store: AppStore
    let id: UUID
    @State private var showCourt = false
    var body: some View {
        Group {
            if let project = store.project(id) {
                if !FileManager.default.fileExists(atPath: store.sourceURL(project).path) {
                    ContentUnavailableView("Original video unavailable", systemImage: "video.slash", description: Text("Your project edits are preserved. Return to your matches and import the original video to create a new project."))
                } else if project.status == .ready {
                    ReviewView(store: store, id: id)
                } else if project.status == .analyzing || project.status == .interrupted {
                    analysisView(project)
                } else {
                    CourtSetupView(store: store, project: project)
                }
            } else { ContentUnavailableView("Project unavailable", systemImage: "video.slash") }
        }.background(MatchStyle.paper).foregroundStyle(MatchStyle.ink)
            .navigationTitle(store.project(id)?.title ?? "Match").navigationBarTitleDisplayMode(.inline)
    }
    private func analysisView(_ p: MatchProject) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Eyebrow(title: p.status == .interrupted ? "Saved. Ready when you are." : "A little less waiting, next time.")
                Text(p.status == .interrupted ? "Your progress\nis safe." : "Finding the\nflow of play.")
                    .font(.system(size: 40, design: .serif)).tracking(-1)
                CourtArtwork().frame(height: 240)
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text(p.analysis?.stage.label ?? "Preparing your match").font(.headline); Spacer(); if p.status == .analyzing { Text("\(Int(store.analysisProgress * 100))%").monospacedDigit() } }
                    if p.status == .analyzing { ProgressView(value: store.analysisProgress) }
                    Text(p.status == .interrupted ? "Continue from the last saved checkpoint, or start reviewing manually." : "Keep the app open while we work. Leaving this screen is fine; backgrounding pauses analysis.")
                        .font(.subheadline).foregroundStyle(MatchStyle.muted)
                }
                WarningCard(text: "Possible points are suggestions. This early detector uses sound and motion; it cannot identify point winners or guarantee every rally is found.")
                if p.status == .interrupted {
                    Button("Resume analysis") { store.analyze(id) }.buttonStyle(PrimaryButton()).disabled(store.activeAnalysisID != nil)
                    Button("Review manually") { Task { await store.manualReview(id) } }.frame(maxWidth: .infinity)
                } else {
                    Button("Pause analysis") { store.pauseAnalysis() }.frame(maxWidth: .infinity)
                }
            }.padding(24)
        }
    }
}

struct CourtSetupView: View {
    @Bindable var store: AppStore
    let project: MatchProject
    @State private var region = NormalizedRect()
    @State private var confirmed = false
    @State private var starting = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Eyebrow(title: "01 / Set the scene")
                Text("This is your court.").font(.system(size: 34, design: .serif)).tracking(-0.8)
                Text("Frame the entire court to focus detection on your match. Include both baselines and both players.").font(.subheadline).foregroundStyle(MatchStyle.muted)
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        if let image = UIImage(contentsOfFile: store.thumbnailURL(project).path) {
                            Image(uiImage: image).resizable().scaledToFit()
                        } else { MatchStyle.ink.overlay(Text("Thumbnail unavailable. Use the full frame or adjust the region below.").foregroundStyle(.white).padding()) }
                        Rectangle().fill(MatchStyle.lime.opacity(0.16))
                            .overlay(Rectangle().stroke(MatchStyle.lime, lineWidth: 2))
                            .frame(width: proxy.size.width * region.width, height: proxy.size.height * region.height)
                            .offset(x: proxy.size.width * region.x, y: proxy.size.height * region.y)
                    }.clipShape(RoundedRectangle(cornerRadius: 16))
                }.aspectRatio(CGFloat(project.source.width) / CGFloat(max(1, project.source.height)), contentMode: .fit)
                VStack(spacing: 12) {
                    regionSlider("Left", value: Binding(get: { region.x }, set: { region.x = min($0, 1 - region.width) }), range: 0...max(0.001, 1 - region.width))
                    regionSlider("Top", value: Binding(get: { region.y }, set: { region.y = min($0, 1 - region.height) }), range: 0...max(0.001, 1 - region.height))
                    regionSlider("Width", value: Binding(get: { region.width }, set: { region.width = min($0, 1 - region.x) }), range: 0.1...max(0.1, 1 - region.x))
                    regionSlider("Height", value: Binding(get: { region.height }, set: { region.height = min($0, 1 - region.y) }), range: 0.1...max(0.1, 1 - region.y))
                    HStack { Button("Reset region") { region = NormalizedRect() }; Spacer(); Button("Full frame") { region = NormalizedRect(x: 0, y: 0, width: 1, height: 1) } }.font(.caption.bold())
                }.padding(18).background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
                ForEach(project.warnings, id: \.self) { WarningCard(text: $0) }
                Toggle("The whole court is visible and the camera is fixed.", isOn: $confirmed).font(.subheadline)
                if !confirmed { Text("You can still continue, but unsupported setups may need more manual corrections.").font(.caption).foregroundStyle(MatchStyle.muted) }
                Button {
                    starting = true
                    Task { if await store.setCourt(region, id: project.id) { store.analyze(project.id) }; starting = false }
                } label: { Label("Find possible points", systemImage: "sparkle") }.buttonStyle(PrimaryButton()).disabled(starting || store.activeAnalysisID != nil)
                Button("Skip analysis · edit manually") {
                    Task { if await store.setCourt(region, id: project.id) { await store.manualReview(project.id) } }
                }.font(.subheadline).frame(maxWidth: .infinity)
                Text("Your original video will never be changed.").font(.caption).foregroundStyle(MatchStyle.muted).frame(maxWidth: .infinity)
            }.padding(24)
        }.onAppear { region = project.courtRegion }
    }
    private func regionSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 45, alignment: .leading)
            Slider(value: value, in: range, step: 0.01).accessibilityLabel("Court \(title)")
            Text("\(Int(value.wrappedValue * 100))%").font(.caption.monospacedDigit()).frame(width: 38, alignment: .trailing)
        }
    }
}

struct ReviewView: View {
    @Bindable var store: AppStore
    let id: UUID
    @State private var player = AVPlayer()
    @State private var previewMode = "Original"
    @State private var building = false
    @State private var editor: SegmentDraft?
    @State private var showExport = false
    @State private var showReanalyze = false
    @State private var showCourt = false
    @State private var revision = 0

    var body: some View {
        if let project = store.project(id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Eyebrow(title: "02 / Make it your match")
                        Spacer()
                        Menu {
                            Button("Adjust court & analyze again") { showReanalyze = true }
                        } label: { Image(systemName: "ellipsis.circle").font(.title3) }.accessibilityLabel("Project options")
                    }
                    Text("The match.\nMinus the waiting.").font(.system(size: 36, design: .serif)).tracking(-1)
                    VideoPlayer(player: player).aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 18))
                    HStack {
                        Label(previewMode == "Condensed" ? "Condensed position" : "Source position", systemImage: "play.rectangle")
                        Spacer()
                        Text(previewMode)
                    }.font(.caption).foregroundStyle(MatchStyle.muted)
                    HStack(spacing: 12) {
                        metric("ORIGINAL", timeLabel(project.source.duration))
                        Image(systemName: "arrow.right").foregroundStyle(MatchStyle.muted)
                        metric("CONDENSED", timeLabel(project.condensedDuration))
                        Spacer()
                        metric("RETAINED", "\(project.retainedCount)")
                    }.padding(18).background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
                    HStack(spacing: 12) {
                        Button { Task { await preview(project) } } label: { Label(building ? "Preparing…" : "Play condensed", systemImage: "play.fill") }
                            .buttonStyle(PrimaryButton()).disabled(building || project.retainedCount == 0)
                        Button { player.replaceCurrentItem(with: AVPlayerItem(url: store.sourceURL(project))); previewMode = "Original" } label: { Image(systemName: "film.stack").padding(18).background(.white, in: RoundedRectangle(cornerRadius: 18)) }.accessibilityLabel("Show full original video")
                    }
                    SegmentTimeline(segments: project.segments, duration: project.source.duration)
                    HStack {
                        Text("Possible points").font(.system(.title2, design: .serif))
                        Spacer()
                        Button { Task { await store.undo(id); invalidatePreview(project) } } label: { Image(systemName: "arrow.uturn.backward") }.disabled(project.undoHistory.isEmpty).accessibilityLabel("Undo last segment edit")
                        Button { editor = SegmentDraft(segment: nil, duration: project.source.duration, position: sourcePosition(project), fps: project.source.frameRate) } label: { Image(systemName: "plus.circle.fill").font(.title2) }.accessibilityLabel("Add a segment from original video")
                    }
                    if project.segments.isEmpty {
                        WarningCard(text: "No segments yet. Watch the original, then tap + to keep a rally. You can add any portion of the source video.")
                    }
                    ForEach(Array(project.segments.enumerated()), id: \.element.id) { index, segment in
                        segmentRow(segment, number: index + 1, project: project)
                    }
                    if project.segments.contains(where: { $0.inclusion == .needsReview }) {
                        WarningCard(text: "Needs-review segments are kept in your condensed match. Open each one to adjust it or mark it reviewed.")
                    }
                    ForEach(project.analysis?.warnings ?? [], id: \.self) { WarningCard(text: $0) }
                    Button { showExport = true } label: { Label("Export match", systemImage: "square.and.arrow.up") }
                        .buttonStyle(PrimaryButton(dark: true)).disabled(project.retainedCount == 0)
                }.padding(24)
            }
            .task { player.replaceCurrentItem(with: AVPlayerItem(url: store.sourceURL(project))) }
            .onDisappear { player.pause() }
            .sheet(item: $editor) { draft in
                SegmentEditor(draft: draft, sourceURL: store.sourceURL(project)) { edited in
                    Task {
                        guard let latest = store.project(id) else { return }
                        var segments = latest.segments
                        if let index = segments.firstIndex(where: { $0.id == edited.id }) { segments[index] = edited } else { segments.append(edited) }
                        await store.edit(id, segments: segments); invalidatePreview(project)
                    }
                }
            }
            .sheet(isPresented: $showExport) { ExportView(store: store, projectID: id) }
            .sheet(isPresented: $showCourt) { NavigationStack { CourtSetupView(store: store, project: project).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showCourt = false } } } } }
            .confirmationDialog("Analyze again?", isPresented: $showReanalyze, titleVisibility: .visible) {
                Button("Adjust court & continue") { showCourt = true }
            } message: { Text("New suggestions replace your current segments when analysis completes. Your previous edit is available through Undo.") }
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Eyebrow(title: title); Text(value).font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit() }
    }
    private func sourcePosition(_ project: MatchProject) -> Double {
        previewMode == "Original" && player.currentTime().seconds.isFinite ? max(0, min(project.source.duration - 0.1, player.currentTime().seconds)) : 0
    }
    private func invalidatePreview(_ project: MatchProject) {
        revision += 1; player.pause(); player.replaceCurrentItem(with: AVPlayerItem(url: store.sourceURL(project))); previewMode = "Original"
    }
    private func preview(_ project: MatchProject) async {
        building = true; let currentRevision = revision
        defer { building = false }
        do {
            let composition = try await CompositionBuilder.build(source: store.sourceURL(project), segments: project.segments, duration: project.source.duration)
            guard currentRevision == revision else { return }
            player.replaceCurrentItem(with: AVPlayerItem(asset: composition)); previewMode = "Condensed"; player.play()
        } catch { store.errorMessage = error.localizedDescription }
    }
    private func segmentRow(_ s: PointSegment, number: Int, project: MatchProject) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    player.replaceCurrentItem(with: AVPlayerItem(url: store.sourceURL(project)))
                    player.seek(to: CMTime(seconds: max(0, s.sourceStart - 2), preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
                    previewMode = "Original"; player.play()
                } label: { Image(systemName: "play.fill").font(.caption).frame(width: 42, height: 42).background(MatchStyle.paper, in: Circle()) }.accessibilityLabel("Play source context for possible point \(number)")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Possible point \(String(format: "%02d", number))").font(.subheadline.bold())
                    Text("\(timeLabel(s.sourceStart)) – \(timeLabel(s.sourceEnd)) · \(timeLabel(s.duration))").font(.caption.monospacedDigit()).foregroundStyle(MatchStyle.muted)
                }
                Spacer()
                Button { editor = SegmentDraft(segment: s, duration: project.source.duration, position: s.sourceStart, fps: project.source.frameRate) } label: { Image(systemName: "slider.horizontal.3").padding(10) }.accessibilityLabel("Edit possible point \(number)")
            }
            HStack {
                Label(s.inclusion.label, systemImage: s.inclusion == .excluded ? "minus.circle" : s.inclusion == .needsReview ? "eye" : "checkmark.circle.fill").font(.caption)
                Spacer()
                Button(s.inclusion == .excluded ? "Include" : "Exclude") {
                    Task {
                        guard let latest = store.project(id) else { return }
                        var edited = latest.segments
                        if let index = edited.firstIndex(where: { $0.id == s.id }) { edited[index].inclusion = s.inclusion == .excluded ? .included : .excluded }
                        await store.edit(id, segments: edited); invalidatePreview(project)
                    }
                }.font(.caption.bold())
            }
        }.padding(16).background(.white.opacity(s.inclusion == .excluded ? 0.4 : 0.8), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct SegmentDraft: Identifiable {
    let id = UUID()
    var segment: PointSegment
    var sourceDuration: Double
    var fps: Double
    init(segment: PointSegment?, duration: Double, position: Double, fps: Double) {
        self.segment = segment ?? PointSegment(start: min(position, max(0, duration - 1)), end: min(duration, position + 10))
        self.sourceDuration = duration; self.fps = max(1, fps)
    }
}

struct SegmentEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: SegmentDraft
    let sourceURL: URL
    let onSave: (PointSegment) -> Void
    @State private var player = AVPlayer()
    var valid: Bool { draft.segment.sourceStart >= 0 && draft.segment.sourceEnd > draft.segment.sourceStart && draft.segment.sourceEnd <= draft.sourceDuration }
    var body: some View {
        NavigationStack {
            Form {
                Section { VideoPlayer(player: player).frame(height: 190).listRowInsets(EdgeInsets()) }
                Section("Source boundaries") {
                    boundary("Start", value: $draft.segment.sourceStart)
                    boundary("End", value: $draft.segment.sourceEnd)
                    Text("Use + / − for one-frame changes (\(Int(draft.fps.rounded())) fps). The original is never re-encoded when editing.").font(.caption).foregroundStyle(.secondary)
                    if !valid { Text("The end must come after the start.").foregroundStyle(.red) }
                }
                Section("In condensed match") {
                    Picker("Status", selection: $draft.segment.inclusion) {
                        ForEach(InclusionState.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if draft.segment.origin == .automatic {
                        Text("Heuristic confidence: \(Int(draft.segment.confidence * 100))%. This is an activity estimate, not a calibrated probability of a tennis point.").font(.caption)
                    }
                    Button("Mark reviewed & include") { draft.segment.inclusion = .included }
                }
            }.navigationTitle("Edit possible point").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if draft.segment.origin != .userCreated { draft.segment.origin = .userAdjusted }
                            onSave(draft.segment); dismiss()
                        }.disabled(!valid)
                    }
                }
        }.task { player.replaceCurrentItem(with: AVPlayerItem(url: sourceURL)); seek(draft.segment.sourceStart) }.onDisappear { player.pause() }
    }
    private func boundary(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title).font(.headline); Spacer(); Text(String(format: "%.3f s", value.wrappedValue)).monospacedDigit().font(.subheadline) }
            Slider(value: value, in: 0...draft.sourceDuration, step: 1 / draft.fps).accessibilityLabel("\(title) time")
                .onChange(of: value.wrappedValue) { _, time in seek(time) }
            Stepper("\(title): \(timeLabel(value.wrappedValue))", value: value, in: 0...draft.sourceDuration, step: 1 / draft.fps)
        }
    }
    private func seek(_ time: Double) { player.seek(to: CMTime(seconds: time, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero) }
}
