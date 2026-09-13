import SwiftUI

@main struct SousChefApp: App {
    @StateObject private var store = CookingSessionStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            HomeView().environmentObject(store).tint(Palette.forest).preferredColorScheme(.light)
                .onOpenURL { url in Task { await store.handleOpenURL(url) } }
                .onChange(of: store.watchRequested) { _, watching in
                    UIApplication.shared.isIdleTimerDisabled = watching && scenePhase == .active
                }
                .onChange(of: scenePhase) { _, phase in
                    UIApplication.shared.isIdleTimerDisabled = phase == .active && store.watchRequested
                    if phase == .background { Task { await store.pauseForBackground() } }
                }
                .alert("Something needs attention", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                    Button("OK") { store.errorMessage = nil }
                } message: { Text(store.errorMessage ?? "") }
        }
    }
}
