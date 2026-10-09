import SwiftUI
import PhotosUI

struct LibraryView: View {
    @Bindable var store: AppStore
    @State private var selection: PhotosPickerItem?
    @State private var path: [UUID] = []
    @State private var showPrivacy = false
    @State private var deleting: MatchProject?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack {
                        HStack(spacing: 8) {
                            Image(systemName: "tennisball.fill")
                                .typography(.brand)
                            Text("Rally Cut")
                                .typography(.brand)
                                .tracking(-1)
                        }
                        Spacer()
                        Button {
                            showPrivacy = true
                        } label: {
                            Image(systemName: "lock.shield")
                                .typography(.brand)
                                .padding(11)
                                .background(.white.opacity(0.7), in: Circle())
                        }
                        .accessibilityLabel("Privacy and import guide")
                    }
                    .padding(.top, 12)

                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow(title: "Your game. Just the good parts.")
                        Text("More tennis.\nLess downtime.")
                            .typography(.title)
                            .tracking(-1.7)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Turn a full match into a match worth rewatching.")
                            .typography(.body)
                            .foregroundStyle(MatchColor.muted)
                    }
                    CourtArtwork()
                        .frame(height: 202)
                    PhotosPicker(selection: $selection, matching: .videos, photoLibrary: .shared()) {
                        Label("Import match video", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButton(dark: true))
                    .disabled(store.importing)
                    if store.importing {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Bringing your match in…")
                                    .typography(.body)
                                    .bold()
                                Spacer()
                                Button("Cancel") {
                                    store.cancelImport()
                                }
                            }
                            ProgressView(value: store.importProgress)
                            Text("A video stored in iCloud may need to download first.")
                                .typography(.caption)
                                .foregroundStyle(MatchColor.muted)
                        }
                        .padding()
                        .background(.white, in: RoundedRectangle(cornerRadius: 18))
                    }
                    if let notice = store.notice {
                        WarningCard(text: notice)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Your matches")
                                .typography(.brand)
                            Spacer()
                            Text(String(format: "%02d", store.projects.count))
                                .typography(.caption)
                                .monospaced()
                                .foregroundStyle(MatchColor.muted)
                        }
                        if store.projects.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("A fresh court.", systemImage: "rectangle.stack")
                                    .typography(.body)
                                    .fontWeight(.semibold)
                                Text("Bring in a match video from Photos. Your original always stays intact.")
                                    .typography(.body)
                                    .foregroundStyle(MatchColor.muted)
                                    .fixedSize(
                                        horizontal: false, vertical: true)
                                HStack(spacing: 16) {
                                    Label("On-device", systemImage: "iphone")
                                    Label("No account", systemImage: "person.crop.circle.badge.checkmark")
                                }
                                .typography(.caption)
                                .foregroundStyle(MatchColor.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(22)
                            .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20).strokeBorder(
                                    MatchColor.line, style: StrokeStyle(lineWidth: 1, dash: [5])))
                        } else {
                            ForEach(store.projects) { project in
                                NavigationLink(value: project.id) {
                                    ProjectCard(project: project, thumbnail: store.thumbnailURL(project))
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Delete project…", role: .destructive) {
                                        deleting = project
                                    }
                                    .disabled(store.activeAnalysisID == project.id)
                                }
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                        Text("Your footage stays on your iPhone.")
                    }
                    .typography(.caption)
                    .foregroundStyle(MatchColor.muted)
                    .frame(maxWidth: .infinity)
                    .padding(
                        .bottom, 12)
                }
                .padding(.horizontal, 24)
            }
            .background(MatchColor.paper)
            .foregroundStyle(MatchColor.ink)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) {
                id in ProjectView(store: store, id: id)
            }
        }
        .onChange(of: selection) { _, item in
            guard let item else {
                return
            }
            Task {
                if let id = await store.importPhoto(item) {
                    path.append(id)
                }

                selection = nil
            }
        }
        .task(id: store.importing) {
            while store.importing && !Task.isCancelled {
                store.refreshImportProgress()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        .sheet(isPresented: $showPrivacy) {
            PrivacyView()
        }
        .alert(
            "Something needs attention",
            isPresented: Binding(
                get: {
                    store.errorMessage != nil
                },
                set: {
                    if !$0 {
                        store.errorMessage = nil
                    }
                })
        ) {
            Button("OK") {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete \(deleting?.title ?? "project")?",
            isPresented: Binding(
                get: {
                    deleting != nil
                },
                set: {
                    if !$0 {
                        deleting = nil
                    }
                }), titleVisibility: .visible
        ) {
            if let project = deleting {
                Button("Delete project only", role: .destructive) {
                    Task {
                        await store.delete(project.id, includingMedia: false)
                        deleting = nil
                    }
                }
                Button("Delete project, local video & exports", role: .destructive) {
                    Task {
                        await store.delete(project.id, includingMedia: true)
                        deleting = nil
                    }
                }
            }
        } message: {
            Text(
                "Your original in Photos is never deleted. ‘Project only’ keeps media in Files → On My iPhone → Rally Cut → Matches. Deleted app files cannot be undone."
            )
        }
    }
}

struct ProjectCard: View {
    let project: MatchProject
    let thumbnail: URL
    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let image = UIImage(contentsOfFile: thumbnail.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(MatchColor.ink)
                        .overlay(
                            Image(systemName: "tennisball").foregroundStyle(MatchColor.lime))
                }
            }
            .frame(width: 90, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 6) {
                Text(project.title)
                    .typography(.body)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                Text(project.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .typography(.caption)
                    .foregroundStyle(MatchColor.muted)
                Text(
                    project.status == .ready
                        ? "\(timeLabel(project.source.duration)) → \(timeLabel(project.condensedDuration))"
                        : timeLabel(project.source.duration)
                )
                .typography(.caption)
                .monospacedDigit()
                Text(project.status.label)
                    .typography(.caption)
                    .bold()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(MatchColor.lime.opacity(0.35), in: Capsule())
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .typography(.caption)
                .foregroundStyle(MatchColor.muted)
        }
        .padding(12)
        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 22))
    }
}

struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "lock.shield")
                        .typography(.brand)
                    Text("Your court.\nYour footage.")
                        .typography(.brand)
                    Text(
                        "Analysis and editing happen on your iPhone. No account, uploads, analytics, or cloud processing. Photos may download a video from iCloud when you choose to import it."
                    )
                    Divider()
                    Label("Set up for a better result", systemImage: "video")
                        .typography(.body)
                        .fontWeight(.semibold)
                    Text(
                        "Import footage recorded with a fixed, landscape camera behind the baseline. Keep one entire singles court in view and include audio. Handheld, doubles, broadcast, and multi-court videos are not validated."
                    )
                    Text(
                        "Automatic detection is an experimental sound-and-motion baseline. It does not know the score, point winner, or whether a ball was in. Review every possible point before sharing."
                    )
                    Text(
                        "Current input limit: 1 second–4 hours. Use H.264 or HEVC video up to 4K where possible. Device performance and detection accuracy have not been benchmarked."
                    )
                    .typography(.caption)
                    .foregroundStyle(MatchColor.muted)
                }
                .padding(28)
            }
            .background(MatchColor.paper)
            .foregroundStyle(MatchColor.ink)
            .navigationTitle(
                "A little peace of mind"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
