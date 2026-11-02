import SwiftUI
import PhotosUI

struct LibraryView: View {
    @Bindable var store: AppStore
    @State private var showPhotoPicker = false
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        HStack(spacing: 8) {
                            Image(systemName: "tennisball.fill")
                                .typography(.brand)
                            Text("Rally Cut")
                                .typography(.brand)
                                .tracking(-1)
                        }
                    }
                    .padding(.top, 12)

                    VStack(alignment: .leading, spacing: 10) {
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
                    Button {
                        showPhotoPicker = true
                    } label: {
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
            .navigationDestination(for: UUID.self) { id in
                ProjectView(store: store, id: id)
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            VideoImportPicker { provider in
                showPhotoPicker = false
                Task {
                    if let id = await store.importPhoto(provider) {
                        path.append(id)
                    }
                }
            }
        }
        .onChange(of: path) { _, path in
            if path.isEmpty {
                store.endSession()
            }
        }
        #if DEBUG
        .onChange(of: store.activeProject?.id) { _, id in
            if ProcessInfo.processInfo.environment["RALLYCUT_EDITOR_TEST_SESSION"] != nil,
                let id, path.isEmpty
            {
                path.append(id)
            }
        }
        #endif
        .task(id: store.importing) {
            while store.importing && !Task.isCancelled {
                store.refreshImportProgress()
                try? await Task.sleep(for: .milliseconds(300))
            }
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
    }
}

private struct VideoImportPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: [PHPickerResult] = []
    let onConfirm: (NSItemProvider) -> Void

    var body: some View {
        NavigationStack {
            ContinuousVideoPicker { results in
                selection = results
            }
            .navigationTitle("Select video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", systemImage: "checkmark") {
                        guard let provider = selection.first?.itemProvider else {
                            return
                        }
                        onConfirm(provider)
                    }
                    .accessibilityIdentifier("video-import-confirm")
                    .disabled(selection.isEmpty)
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

private struct ContinuousVideoPicker: UIViewControllerRepresentable {
    let onSelection: ([PHPickerResult]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .videos
        // Single-selection mode completes on a tap and omits deselection updates.
        // Keep continuous updates enabled; the coordinator enforces one selected video.
        configuration.selectionLimit = 0
        configuration.selection = .continuous
        configuration.disabledCapabilities = .selectionActions
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {
        context.coordinator.onSelection = onSelection
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var onSelection: ([PHPickerResult]) -> Void

        init(onSelection: @escaping ([PHPickerResult]) -> Void) {
            self.onSelection = onSelection
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            if results.count > 1 {
                picker.deselectAssets(withIdentifiers: results.dropLast().compactMap(\.assetIdentifier))
            }
            onSelection(Array(results.suffix(1)))
        }
    }
}
