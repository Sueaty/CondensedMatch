import SwiftUI

@main
struct RallyCutApp: App {
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            LibraryView(store: store)
                .tint(MatchStyle.ink)
                .preferredColorScheme(.light)
                .task { await store.load() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        store.pauseAnalysis()
                    }
                }
        }
    }
}
