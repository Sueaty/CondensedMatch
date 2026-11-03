import SwiftUI

@main
struct RallyCutApp: App {
    @State private var store = AppStore()

    init() {
        #if DEBUG
            if let session = ProcessInfo.processInfo.environment["RALLYCUT_EDITOR_TEST_SESSION"] {
                let root = URL.temporaryDirectory.appendingPathComponent("EditorUITests-\(session)")
                let defaults = UserDefaults(suiteName: "EditorUITests-\(session)") ?? .standard
                _store = State(initialValue: AppStore(root: root, defaults: defaults))
            }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            LibraryView(store: store)
                .tint(MatchColor.ink)
                .preferredColorScheme(.light)
                .task {
                    #if DEBUG
                        if ProcessInfo.processInfo.environment["RALLYCUT_EDITOR_TEST_SESSION"] != nil,
                            store.activeProject == nil
                        {
                            do {
                                try await EditorUITestFixture.install(in: store)
                            } catch {
                                store.errorMessage = error.localizedDescription
                            }
                        }
                    #endif
                }
        }
    }
}
